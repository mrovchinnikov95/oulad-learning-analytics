-- Слой clean: типы, пропуски «?» → NULL, ключи и индексы. Строится только после проверок сырья
-- (sql/25_raw_checks.sql), поэтому приведения типов здесь не падают. Пересоздаётся целиком
-- в одной транзакции: повторный запуск даёт тот же результат.
BEGIN;
DROP TABLE IF EXISTS clean.presentation, clean.assessment, clean.enrolment, clean.submission,
                     clean.vle_site, clean.vle_day CASCADE;

-- Поток — модуль в конкретном запуске (2013B — старт в феврале 2013, 2014J — в октябре 2014).
-- Дни потока — от 0 до length_days включительно: в журнале VLE есть клики ровно в день length_days.
CREATE TABLE clean.presentation AS
SELECT code_module,
       code_presentation,
       module_presentation_length::int                    AS length_days,
       left(code_presentation, 4)::int                    AS start_year,
       right(code_presentation, 1)                        AS start_month_code,
       rules.week_of(module_presentation_length::int)     AS last_week
FROM raw.courses;
ALTER TABLE clean.presentation ADD PRIMARY KEY (code_module, code_presentation);

-- Задания. seq — порядковый номер задания TMA/CMA в потоке по сроку (при равном сроке — по id).
CREATE TABLE clean.assessment AS
SELECT code_module,
       code_presentation,
       id_assessment::int                      AS id_assessment,
       assessment_type,
       rules.na(date)::int                     AS deadline_day,
       weight::numeric                         AS weight,
       rules.assessment_in_scope(assessment_type) AS in_scope
FROM raw.assessments;
ALTER TABLE clean.assessment ADD PRIMARY KEY (id_assessment);
ALTER TABLE clean.assessment ADD COLUMN seq int;
UPDATE clean.assessment a SET seq = s.seq
FROM (SELECT id_assessment,
             row_number() OVER (PARTITION BY code_module, code_presentation
                                ORDER BY deadline_day, id_assessment)::int AS seq
      FROM clean.assessment WHERE in_scope) s
WHERE s.id_assessment = a.id_assessment;

-- Регистрация студента на поток: studentRegistration + studentInfo (1:1, проверено в raw-гейте).
CREATE TABLE clean.enrolment AS
SELECT r.code_module,
       r.code_presentation,
       r.id_student::int                               AS id_student,
       rules.na(r.date_registration)::int              AS reg_day,
       rules.na(r.date_unregistration)::int            AS unreg_day,
       i.final_result,
       rules.outcome_group(i.final_result)             AS outcome_group,
       rules.withdrew_before_start(rules.na(r.date_unregistration)::int) AS withdrew_before_start,
       i.gender,
       i.region,
       i.highest_education,
       rules.na(i.imd_band)                            AS imd_band,
       i.age_band,
       i.num_of_prev_attempts::int                     AS num_of_prev_attempts,
       i.studied_credits::int                          AS studied_credits,
       i.disability
FROM raw.student_registration r
JOIN raw.student_info i USING (code_module, code_presentation, id_student);
ALTER TABLE clean.enrolment ADD PRIMARY KEY (code_module, code_presentation, id_student);

-- Сдачи заданий. Поток берётся из задания: в studentAssessment его нет.
CREATE TABLE clean.submission AS
SELECT a.code_module,
       a.code_presentation,
       s.id_assessment::int        AS id_assessment,
       s.id_student::int           AS id_student,
       s.date_submitted::int       AS submitted_day,
       s.is_banked = '1'           AS is_banked,
       rules.na(s.score)::int      AS score
FROM raw.student_assessment s
JOIN clean.assessment a ON a.id_assessment = s.id_assessment::int;
ALTER TABLE clean.submission ADD PRIMARY KEY (id_assessment, id_student);

CREATE TABLE clean.vle_site AS
SELECT id_site::int AS id_site, code_module, code_presentation, activity_type,
       rules.na(week_from)::int AS week_from, rules.na(week_to)::int AS week_to
FROM raw.vle;
ALTER TABLE clean.vle_site ADD PRIMARY KEY (id_site);

-- Журнал VLE, свёрнутый до «студент × поток × день». В исходнике ключ (студент, материал, день)
-- повторяется (qa.data_quality, vle_repeated_key): строки не схлопываются, клики суммируются.
-- log_rows сохраняет число исходных строк, чтобы сверить свёртку с raw.
CREATE TABLE clean.vle_day AS
SELECT code_module,
       code_presentation,
       id_student::int        AS id_student,
       date::int              AS day,
       sum(sum_click::int)    AS clicks,
       count(*)               AS log_rows,
       count(DISTINCT id_site) AS sites
FROM raw.student_vle
GROUP BY code_module, code_presentation, id_student::int, date::int;
ALTER TABLE clean.vle_day ADD PRIMARY KEY (code_module, code_presentation, id_student, day);
COMMIT;

ANALYZE clean.presentation, clean.assessment, clean.enrolment, clean.submission, clean.vle_site, clean.vle_day;
