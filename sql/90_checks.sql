-- Проверки витрин. Запускаются внутри scripts/build.sh до выгрузки: хотя бы одна непрошедшая —
-- RAISE EXCEPTION, и выгрузка для дашборда не перезаписывается. Печатаются все проверки.
-- Ожидаемые значения граничных случаев записаны здесь отдельно от функций sql/05_rules.sql:
-- это вторая копия правил, чтобы сверить с ней функции.
CREATE TEMP TABLE chk (seq serial, check_name text, bad bigint, note text);

-- 1. Граничные случаи правил на синтетических значениях.
INSERT INTO chk (check_name, bad, note)
SELECT 'правило: ' || name, count(*) FILTER (WHERE got IS DISTINCT FROM expected),
       string_agg(format('%s → %s (ожидалось %s)', args, got, expected), '; ') FILTER (WHERE got IS DISTINCT FROM expected)
FROM (
    SELECT 'week_of' AS name, d::text AS args, rules.week_of(d)::text AS got, e::text AS expected
    FROM (VALUES (-8, -2), (-1, -1), (0, 0), (6, 0), (7, 1), (13, 1), (14, 2), (268, 38)) v (d, e)
    UNION ALL
    SELECT 'withdrew_before_start', coalesce(u::text, 'NULL'), rules.withdrew_before_start(u)::text, e::text
    FROM (VALUES (NULL::int, false), (-5, true), (0, true), (1, false)) v (u, e)
    UNION ALL
    SELECT 'on_course', format('reg=%s unreg=%s [%s,%s]', r, u, a, b), rules.on_course(r, u, a, b)::text, e::text
    FROM (VALUES (NULL::int, NULL::int, 0, 6, true),
                 (6, NULL, 0, 6, true),    -- регистрация в последний день окна
                 (7, NULL, 0, 6, false),   -- регистрация после окна
                 (NULL, 0, 0, 6, true),    -- отписка в первый день окна
                 (NULL, -1, 0, 6, false),  -- отписка до окна
                 (NULL, 6, 7, 13, false),
                 (NULL, 7, 7, 13, true),
                 (19, NULL, 19, 19, true), -- регистрация в день срока
                 (20, NULL, 19, 19, false),
                 (NULL, 19, 19, 19, true), -- отписка в день срока
                 (NULL, 18, 19, 19, false)) v (r, u, a, b, e)
    UNION ALL
    SELECT 'is_on_time', format('%s/%s', s, d), rules.is_on_time(s, d)::text, e::text
    FROM (VALUES (19, 19, true), (20, 19, false), (-1, 19, true)) v (s, d, e)
    UNION ALL
    SELECT 'outcome_group', coalesce(f, 'NULL'), rules.outcome_group(f), e
    FROM (VALUES ('Distinction', 'pass'), ('Pass', 'pass'), ('Fail', 'fail'), ('Withdrawn', 'withdrawn'),
                 ('pass', NULL), (NULL, NULL)) v (f, e)
    UNION ALL
    SELECT 'assessment_in_scope', t, rules.assessment_in_scope(t)::text, e::text
    FROM (VALUES ('TMA', true), ('CMA', true), ('Exam', false)) v (t, e)
    UNION ALL
    SELECT 'on_time_measurable', t, rules.on_time_measurable(t)::text, e::text
    FROM (VALUES ('TMA', true), ('CMA', false)) v (t, e)
    UNION ALL
    SELECT 'na', quote_literal(x), coalesce(rules.na(x), 'NULL'), e
    FROM (VALUES ('?', 'NULL'), ('', 'NULL'), ('0', '0'), ('-1', '-1')) v (x, e)
) t
GROUP BY name;

-- 2. Граничные строки в реальных данных есть и разобраны по правилам. Сначала проверяем, что они
-- есть: проверка на пустом множестве прошла бы всегда.
INSERT INTO chk (check_name, bad, note)
SELECT 'граница: ' || name, CASE WHEN n_rows = 0 THEN 1 ELSE n_bad END, format('строк %s, нарушений %s', n_rows, n_bad)
FROM (
    SELECT 'сдача в день срока считается сдачей в срок' AS name,
           count(*) AS n_rows, count(*) FILTER (WHERE NOT on_time) AS n_bad
    FROM mart.expected_submission WHERE submitted AND submitted_day = deadline_day
    UNION ALL
    SELECT 'сдача на день позже срока — не в срок',
           count(*), count(*) FILTER (WHERE on_time)
    FROM mart.expected_submission WHERE submitted AND submitted_day = deadline_day + 1
    UNION ALL
    SELECT 'отписка в день срока — должен был сдать',
           count(*), count(*) FILTER (WHERE x.id_student IS NULL)
    FROM clean.assessment a
    JOIN clean.enrolment e ON (e.code_module, e.code_presentation) = (a.code_module, a.code_presentation)
                          AND e.unreg_day = a.deadline_day
    LEFT JOIN mart.expected_submission x ON (x.id_assessment, x.id_student) = (a.id_assessment, e.id_student)
    WHERE a.in_scope
      AND NOT EXISTS (SELECT 1 FROM clean.submission b
                      WHERE (b.id_assessment, b.id_student) = (a.id_assessment, e.id_student) AND b.is_banked)
    UNION ALL
    SELECT 'отписка за день до срока — не должен был сдать',
           count(*), count(*) FILTER (WHERE x.id_student IS NOT NULL)
    FROM clean.assessment a
    JOIN clean.enrolment e ON (e.code_module, e.code_presentation) = (a.code_module, a.code_presentation)
                          AND e.unreg_day = a.deadline_day - 1
    LEFT JOIN mart.expected_submission x ON (x.id_assessment, x.id_student) = (a.id_assessment, e.id_student)
    WHERE a.in_scope
    UNION ALL
    SELECT 'отписка в день старта — не приступил',
           count(*), count(*) FILTER (WHERE started)
    FROM mart.student_presentation WHERE unreg_day = 0
    UNION ALL
    SELECT 'отписка на первый день — приступил',
           count(*), count(*) FILTER (WHERE NOT started)
    FROM mart.student_presentation WHERE unreg_day = 1
    UNION ALL
    SELECT 'перенесённый результат не входит в «должны сдать»',
           count(*), count(*) FILTER (WHERE x.id_student IS NOT NULL)
    FROM clean.submission s JOIN clean.assessment a USING (id_assessment)
    LEFT JOIN mart.expected_submission x USING (id_assessment, id_student)
    WHERE a.in_scope AND s.is_banked
) t;

-- 3. Сверки витрин с сырьём и между собой.
INSERT INTO chk (check_name, bad, note)
SELECT 'сверка: ' || name, abs(a - b), format('%s против %s', a, b)
FROM (
    SELECT 'строк витрины студентов = регистраций в raw' AS name,
           (SELECT count(*) FROM mart.student_presentation) AS a, (SELECT count(*) FROM raw.student_registration) AS b
    UNION ALL
    SELECT 'сумма registered по потокам = регистраций в raw',
           (SELECT sum(registered) FROM mart.presentation_outcome), (SELECT count(*) FROM raw.student_registration)
    UNION ALL
    SELECT 'потоков в итогах = потоков в raw',
           (SELECT count(*) FROM mart.presentation_outcome), (SELECT count(*) FROM raw.courses)
    UNION ALL
    SELECT 'заданий в витрине сдачи = заданий TMA/CMA в raw',
           (SELECT count(*) FROM mart.assessment_submission),
           (SELECT count(*) FROM raw.assessments WHERE assessment_type IN ('TMA', 'CMA'))
    UNION ALL
    SELECT 'сдали + перенесено + сдали не обязанные = строк сдачи TMA/CMA в raw',
           (SELECT sum(submitted + banked + submitted_not_expected) FROM mart.assessment_submission),
           (SELECT count(*) FROM raw.student_assessment s JOIN raw.assessments a USING (id_assessment)
            WHERE a.assessment_type IN ('TMA', 'CMA'))
    UNION ALL
    SELECT 'expected из витрины студентов = expected из витрины заданий',
           (SELECT sum(expected_assessments) FROM mart.student_presentation), (SELECT sum(expected) FROM mart.assessment_submission)
    UNION ALL
    SELECT 'submitted из витрины студентов = submitted из витрины заданий',
           (SELECT sum(submitted_assessments) FROM mart.student_presentation), (SELECT sum(submitted) FROM mart.assessment_submission)
    UNION ALL
    SELECT 'TMA в срок: витрина студентов = итоги потоков',
           (SELECT sum(tma_on_time) FROM mart.student_presentation), (SELECT sum(tma_on_time) FROM mart.presentation_outcome)
    UNION ALL
    SELECT 'строк журнала VLE в свёртке по дням = строк в raw',
           (SELECT sum(log_rows) FROM clean.vle_day), (SELECT count(*) FROM raw.student_vle)
    UNION ALL
    SELECT 'кликов в свёртке по дням = кликов в raw',
           (SELECT sum(clicks) FROM clean.vle_day), (SELECT sum(sum_click::bigint) FROM raw.student_vle)
    UNION ALL
    SELECT 'ячеек сетки активности = потоки × недели × 3 группы',
           (SELECT count(*) FROM mart.cohort_week_activity), (SELECT sum((last_week + 1) * 3) FROM clean.presentation)
    UNION ALL
    -- Мост кликов: все клики raw = клики когорт + клики не приступивших + клики приступивших до старта
    -- + клики приступивших в недели, когда они не числились на курсе. Последнее слагаемое считается
    -- по дням, а не по сетке недель, — другим путём, чем витрина.
    SELECT 'мост кликов: raw = когорты + не приступившие + до старта + вне когорты',
           (SELECT sum(sum_click::bigint) FROM raw.student_vle),
           (SELECT sum(clicks) FROM mart.cohort_week_activity)
         + (SELECT coalesce(sum(d.clicks), 0) FROM clean.vle_day d JOIN clean.enrolment e USING (code_module, code_presentation, id_student)
            WHERE e.withdrew_before_start)
         + (SELECT coalesce(sum(d.clicks), 0) FROM clean.vle_day d JOIN clean.enrolment e USING (code_module, code_presentation, id_student)
            WHERE NOT e.withdrew_before_start AND d.day < 0)
         + (SELECT coalesce(sum(d.clicks), 0) FROM clean.vle_day d JOIN clean.enrolment e USING (code_module, code_presentation, id_student)
            WHERE NOT e.withdrew_before_start AND d.day >= 0
              AND NOT rules.on_course(e.reg_day, e.unreg_day, 7 * rules.week_of(d.day), 7 * rules.week_of(d.day) + 6))
    UNION ALL
    SELECT 'фактов для README',
           (SELECT count(*) FROM mart.readme_facts WHERE coalesce(value::text, display) IS NOT NULL AND display IS NOT NULL), 39
    UNION ALL
    SELECT 'строк качества данных', (SELECT count(*) FROM qa.data_quality), 16
) t;

-- Итоги приступивших по каждому final_result — напрямую из регистраций, мимо витрины студентов.
-- Число сопоставленных итогов входит в проверку: пустое соединение не должно пройти.
INSERT INTO chk (check_name, bad, note)
WITH m AS (
    SELECT 'Distinction' AS r, (SELECT sum(started_distinction) FROM mart.presentation_outcome) AS m
    UNION ALL SELECT 'Pass', (SELECT sum(started_pass) FROM mart.presentation_outcome)
    UNION ALL SELECT 'Fail', (SELECT sum(started_fail) FROM mart.presentation_outcome)
    UNION ALL SELECT 'Withdrawn', (SELECT sum(started_withdrawn) FROM mart.presentation_outcome)
), d AS (
    SELECT i.final_result AS r, count(*) AS d
    FROM raw.student_info i
    JOIN raw.student_registration g USING (code_module, code_presentation, id_student)
    WHERE CASE WHEN rules.na(g.date_unregistration) IS NULL THEN true ELSE g.date_unregistration::int > 0 END
    GROUP BY i.final_result
)
SELECT 'сверка: приступившие по итогам курса напрямую из raw',
       count(*) FILTER (WHERE m.m <> d.d) + abs(4 - count(*)),
       string_agg(format('%s: %s против %s', r, m.m, d.d), '; ' ORDER BY r)
FROM m JOIN d USING (r);

-- «Должны сдать» по каждому заданию — вторым выражением, мимо витрины: числятся в день срока минус перенесённые.
INSERT INTO chk (check_name, bad, note)
SELECT 'сверка: expected по заданиям вторым выражением',
       count(*) FILTER (WHERE m.expected <> d.expected) + abs(182 - count(*)),  -- пустое соединение не должно пройти
       format('сверено заданий %s; ', count(*))
       || coalesce(string_agg(format('%s: %s против %s', m.id_assessment, m.expected, d.expected), '; ') FILTER (WHERE m.expected <> d.expected), '')
FROM mart.assessment_submission m
JOIN (
    SELECT a.id_assessment,
           count(*) FILTER (WHERE (e.reg_day IS NULL OR e.reg_day <= a.deadline_day)
                              AND (e.unreg_day IS NULL OR e.unreg_day >= a.deadline_day)
                              AND b.id_student IS NULL) AS expected
    FROM clean.assessment a
    JOIN clean.enrolment e ON (e.code_module, e.code_presentation) = (a.code_module, a.code_presentation)
    LEFT JOIN clean.submission b ON (b.id_assessment, b.id_student) = (a.id_assessment, e.id_student) AND b.is_banked
    WHERE a.assessment_type IN ('TMA', 'CMA')
    GROUP BY a.id_assessment
) d USING (id_assessment);

-- 4. Инварианты.
INSERT INTO chk (check_name, bad)
SELECT 'инвариант: ' || name, n FROM (VALUES
    ('registered = withdrew_before_start + started', (SELECT count(*) FROM mart.presentation_outcome
        WHERE registered <> withdrew_before_start + started)),
    ('started = сумма четырёх итогов', (SELECT count(*) FROM mart.presentation_outcome
        WHERE started <> started_distinction + started_pass + started_fail + started_withdrawn)),
    ('submitted ≤ expected, on_time ≤ submitted', (SELECT count(*) FROM mart.assessment_submission
        WHERE submitted > expected OR on_time > submitted)),
    ('доли в [0, 1]', (SELECT count(*) FROM mart.assessment_submission
        WHERE submission_rate NOT BETWEEN 0 AND 1 OR on_time_share NOT BETWEEN 0 AND 1)
        + (SELECT count(*) FROM mart.presentation_outcome
           WHERE pass_rate NOT BETWEEN 0 AND 1 OR withdrawn_rate NOT BETWEEN 0 AND 1 OR pass_rate_registered NOT BETWEEN 0 AND 1
              OR submission_rate NOT BETWEEN 0 AND 1 OR tma_on_time_share NOT BETWEEN 0 AND 1)),
    ('у каждого задания есть кто-то, кто должен сдать', (SELECT count(*) FROM mart.assessment_submission WHERE expected = 0)),
    ('active ≤ enrolled', (SELECT count(*) FROM mart.cohort_week_activity WHERE active > enrolled)),
    ('клики только у активных', (SELECT count(*) FROM mart.cohort_week_activity
        WHERE (active = 0 AND clicks <> 0) OR (active > 0 AND clicks < active))),
    ('в когорте недели не больше приступивших своей группы', (SELECT count(*) FROM mart.cohort_week_activity c
        JOIN (SELECT code_module, code_presentation, outcome_group, count(*) AS n FROM mart.student_presentation
              WHERE started GROUP BY 1, 2, 3) s USING (code_module, code_presentation, outcome_group)
        WHERE c.enrolled > s.n)),
    ('сдано TMA в срок ≤ сдано TMA у студента', (SELECT count(*) FROM mart.student_presentation
        WHERE tma_on_time > tma_submitted OR tma_submitted > submitted_assessments OR submitted_assessments > expected_assessments)),
    ('не приступившие не должны сдавать задания', (SELECT count(*) FROM mart.student_presentation
        WHERE withdrew_before_start AND expected_assessments > 0)),
    ('seq у заданий TMA/CMA без пропусков', (SELECT count(*) FROM (
        SELECT code_module, code_presentation FROM clean.assessment WHERE in_scope
        GROUP BY 1, 2 HAVING min(seq) <> 1 OR max(seq) <> count(*) OR count(DISTINCT seq) <> count(*)) x)),
    ('повторов ключа VLE не меньше полных дублей', (SELECT count(*) FROM qa.data_quality a, qa.data_quality b
        WHERE a.code = 'vle_repeated_key' AND b.code = 'vle_exact_duplicate' AND a.n < b.n))
) AS x (name, n);

SELECT seq AS "№", CASE WHEN bad = 0 THEN 'ok' ELSE 'FAIL' END AS "итог", check_name AS "проверка", bad AS "нарушений", note AS "детали"
FROM chk ORDER BY seq;
SELECT format('Проверок витрин: %s, не прошло: %s', count(*), count(*) FILTER (WHERE bad <> 0)) AS "итог" FROM chk;

DO $$
DECLARE failed text;
BEGIN
    SELECT string_agg(check_name, '; ' ORDER BY seq) INTO failed FROM chk WHERE bad <> 0;
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'Проверки витрин не прошли: %', failed;
    END IF;
END $$;
