-- Витрины. Определения и обоснования — docs/spec.md (номера правил R1–R9 в комментариях).
-- Числа в витринах аддитивные (численник и знаменатель лежат рядом), доли считаются из них:
-- так любую долю можно пересобрать на любом уровне, а не усреднять доли.
BEGIN;
DROP TABLE IF EXISTS mart.expected_submission, mart.assessment_submission, mart.student_presentation,
                     mart.presentation_outcome, mart.cohort_week_activity CASCADE;

-- Кто должен был сдать задание (R5): студент числится на курсе в день срока (R2) и результат
-- не перенесён из прошлого потока (R6). Зерно — задание × студент. Сдано (R6) — есть строка сдачи
-- без переноса; в срок (R7) — в день срока или раньше.
CREATE TABLE mart.expected_submission AS
SELECT a.code_module,
       a.code_presentation,
       a.id_assessment,
       a.assessment_type,
       a.deadline_day,
       e.id_student,
       s.submitted_day,
       s.id_assessment IS NOT NULL                                   AS submitted,
       coalesce(rules.is_on_time(s.submitted_day, a.deadline_day), false) AS on_time
FROM clean.assessment a
JOIN clean.enrolment e
  ON (e.code_module, e.code_presentation) = (a.code_module, a.code_presentation)
 AND rules.on_course(e.reg_day, e.unreg_day, a.deadline_day, a.deadline_day)
LEFT JOIN clean.submission s
  ON (s.id_assessment, s.id_student) = (a.id_assessment, e.id_student) AND NOT s.is_banked
WHERE a.in_scope
  AND NOT EXISTS (SELECT 1 FROM clean.submission b
                  WHERE (b.id_assessment, b.id_student) = (a.id_assessment, e.id_student) AND b.is_banked);
ALTER TABLE mart.expected_submission ADD PRIMARY KEY (id_assessment, id_student);

-- Сдача заданий и сдача в срок, зерно — задание TMA/CMA. on_time и on_time_share считаются у всех
-- заданий, но в итоги «в срок» входят только задания с on_time_measurable (R7, только TMA).
CREATE TABLE mart.assessment_submission AS
WITH x AS (
    SELECT id_assessment,
           count(*)                           AS expected,
           count(*) FILTER (WHERE submitted)  AS submitted,
           count(*) FILTER (WHERE on_time)    AS on_time
    FROM mart.expected_submission GROUP BY id_assessment
), b AS (
    SELECT s.id_assessment,
           count(*) FILTER (WHERE s.is_banked) AS banked,
           count(*) FILTER (WHERE NOT s.is_banked AND x.id_student IS NULL) AS submitted_not_expected
    FROM clean.submission s
    LEFT JOIN mart.expected_submission x USING (id_assessment, id_student)
    GROUP BY s.id_assessment
)
SELECT a.code_module,
       a.code_presentation,
       a.id_assessment,
       a.assessment_type,
       a.seq,
       a.deadline_day,
       a.weight,
       coalesce(x.expected, 0)               AS expected,
       coalesce(x.submitted, 0)              AS submitted,
       coalesce(x.on_time, 0)                AS on_time,
       coalesce(b.banked, 0)                 AS banked,
       coalesce(b.submitted_not_expected, 0) AS submitted_not_expected,
       rules.on_time_measurable(a.assessment_type)  AS on_time_measurable,
       x.submitted::numeric / nullif(x.expected, 0) AS submission_rate,
       x.on_time::numeric / nullif(x.submitted, 0)  AS on_time_share
FROM clean.assessment a
LEFT JOIN x USING (id_assessment)
LEFT JOIN b USING (id_assessment)
WHERE a.in_scope;
ALTER TABLE mart.assessment_submission ADD PRIMARY KEY (id_assessment);

-- Студент на потоке: итог, задания и активность в VLE. Зерно — регистрация (32 593 строки).
CREATE TABLE mart.student_presentation AS
WITH x AS (
    SELECT code_module, code_presentation, id_student,
           count(*)                          AS expected_assessments,
           count(*) FILTER (WHERE submitted) AS submitted_assessments,
           count(*) FILTER (WHERE submitted AND rules.on_time_measurable(assessment_type)) AS tma_submitted,
           count(*) FILTER (WHERE on_time AND rules.on_time_measurable(assessment_type))   AS tma_on_time
    FROM mart.expected_submission GROUP BY 1, 2, 3
), v AS (
    SELECT d.code_module, d.code_presentation, d.id_student,
           sum(d.clicks)                                             AS vle_clicks,
           count(*)                                                  AS vle_active_days,
           min(d.day)                                                AS vle_first_day,
           count(*) FILTER (WHERE d.day BETWEEN 0 AND 13)            AS vle_active_days_first_2w,
           count(DISTINCT rules.week_of(d.day)) FILTER (WHERE d.day BETWEEN 0 AND p.length_days) AS vle_active_weeks
    FROM clean.vle_day d
    JOIN clean.presentation p USING (code_module, code_presentation)
    GROUP BY 1, 2, 3
)
SELECT e.code_module,
       e.code_presentation,
       e.id_student,
       e.reg_day,
       e.unreg_day,
       e.final_result,
       e.outcome_group,
       e.withdrew_before_start,
       NOT e.withdrew_before_start                 AS started,
       coalesce(x.expected_assessments, 0)         AS expected_assessments,
       coalesce(x.submitted_assessments, 0)        AS submitted_assessments,
       coalesce(x.tma_submitted, 0)                AS tma_submitted,
       coalesce(x.tma_on_time, 0)                  AS tma_on_time,
       coalesce(v.vle_clicks, 0)                   AS vle_clicks,
       coalesce(v.vle_active_days, 0)              AS vle_active_days,
       v.vle_first_day,
       coalesce(v.vle_active_days_first_2w, 0)     AS vle_active_days_first_2w,
       coalesce(v.vle_active_weeks, 0)             AS vle_active_weeks
FROM clean.enrolment e
LEFT JOIN x USING (code_module, code_presentation, id_student)
LEFT JOIN v USING (code_module, code_presentation, id_student);
ALTER TABLE mart.student_presentation ADD PRIMARY KEY (code_module, code_presentation, id_student);

-- Итоги по потоку (R1, R3): поток — только те, кто не отписался до старта.
CREATE TABLE mart.presentation_outcome AS
WITH e AS (
    SELECT code_module, code_presentation,
           count(*)                                                                   AS registered,
           count(*) FILTER (WHERE withdrew_before_start)                              AS withdrew_before_start,
           count(*) FILTER (WHERE started)                                            AS started,
           count(*) FILTER (WHERE started AND final_result = 'Distinction')           AS started_distinction,
           count(*) FILTER (WHERE started AND final_result = 'Pass')                  AS started_pass,
           count(*) FILTER (WHERE started AND final_result = 'Fail')                  AS started_fail,
           count(*) FILTER (WHERE started AND final_result = 'Withdrawn')             AS started_withdrawn,
           count(*) FILTER (WHERE outcome_group = 'pass')                             AS registered_passed
    FROM mart.student_presentation GROUP BY 1, 2
), s AS (
    SELECT code_module, code_presentation,
           sum(expected)  AS expected_assessments,
           sum(submitted) AS submitted_assessments,
           sum(submitted) FILTER (WHERE on_time_measurable) AS tma_submitted,
           sum(on_time)   FILTER (WHERE on_time_measurable) AS tma_on_time
    FROM mart.assessment_submission GROUP BY 1, 2
)
SELECT p.code_module,
       p.code_presentation,
       p.start_year,
       p.start_month_code,
       p.length_days,
       e.registered,
       e.withdrew_before_start,
       e.started,
       e.started_distinction,
       e.started_pass,
       e.started_fail,
       e.started_withdrawn,
       (e.started_distinction + e.started_pass)::numeric / nullif(e.started, 0) AS pass_rate,
       e.started_withdrawn::numeric / nullif(e.started, 0)                       AS withdrawn_rate,
       e.registered_passed::numeric / nullif(e.registered, 0)                    AS pass_rate_registered,
       s.expected_assessments,
       s.submitted_assessments,
       s.tma_submitted,
       s.tma_on_time,
       s.submitted_assessments::numeric / nullif(s.expected_assessments, 0)      AS submission_rate,
       s.tma_on_time::numeric / nullif(s.tma_submitted, 0)                       AS tma_on_time_share
FROM clean.presentation p
JOIN e USING (code_module, code_presentation)
JOIN s USING (code_module, code_presentation);
ALTER TABLE mart.presentation_outcome ADD PRIMARY KEY (code_module, code_presentation);

-- Активность когорт (R8, R9): поток × неделя курса × группа итога. Полная сетка: недели 0..last_week
-- для каждой группы, даже если в группе на этой неделе никого нет (тогда нули).
CREATE TABLE mart.cohort_week_activity AS
WITH grid AS (
    SELECT p.code_module, p.code_presentation, w AS week, g AS outcome_group
    FROM clean.presentation p
    CROSS JOIN LATERAL generate_series(0, p.last_week) AS w
    CROSS JOIN (VALUES ('pass'), ('fail'), ('withdrawn')) AS gg (g)
), ew AS (
    SELECT e.code_module, e.code_presentation, e.id_student, e.outcome_group, w AS week
    FROM clean.enrolment e
    JOIN clean.presentation p USING (code_module, code_presentation)
    CROSS JOIN LATERAL generate_series(0, p.last_week) AS w
    WHERE NOT e.withdrew_before_start
      AND rules.on_course(e.reg_day, e.unreg_day, 7 * w, 7 * w + 6)
), vw AS (
    SELECT code_module, code_presentation, id_student, rules.week_of(day) AS week, sum(clicks) AS clicks
    FROM clean.vle_day WHERE day >= 0
    GROUP BY 1, 2, 3, 4
)
SELECT g.code_module,
       g.code_presentation,
       g.week,
       g.outcome_group,
       count(ew.id_student)          AS enrolled,
       count(vw.id_student)          AS active,
       coalesce(sum(vw.clicks), 0)   AS clicks
FROM grid g
LEFT JOIN ew USING (code_module, code_presentation, week, outcome_group)
LEFT JOIN vw ON (vw.code_module, vw.code_presentation, vw.id_student, vw.week)
              = (ew.code_module, ew.code_presentation, ew.id_student, ew.week)
GROUP BY 1, 2, 3, 4;
ALTER TABLE mart.cohort_week_activity ADD PRIMARY KEY (code_module, code_presentation, week, outcome_group);
COMMIT;

ANALYZE mart.expected_submission, mart.assessment_submission, mart.student_presentation,
        mart.presentation_outcome, mart.cohort_week_activity;
