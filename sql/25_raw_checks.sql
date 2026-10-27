-- Проверки сырья до очистки. Читают raw напрямую, а не типизированные таблицы: битое значение
-- уронило бы приведение типа раньше, чем проверка покажет причину. Приведение типа — только внутри
-- CASE после проверки формата: PostgreSQL не гарантирует порядок вычисления условий в WHERE.
-- Печатаются все проверки; хотя бы одна непрошедшая — RAISE EXCEPTION, и сборка останавливается.
CREATE TEMP TABLE chk (seq serial, check_name text, bad bigint, note text);

CREATE FUNCTION pg_temp.is_int(v text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT v ~ '^-?[0-9]{1,9}$' $$;
-- Вес задания бывает дробным (12.5, 17.5, 7.5).
CREATE FUNCTION pg_temp.is_num(v text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT v ~ '^[0-9]{1,3}(\.[0-9]{1,4})?$' $$;

-- 1. Число строк — как в описании набора (Kuzilek et al., Scientific Data, 2017).
INSERT INTO chk (check_name, bad, note)
SELECT 'raw: строк в ' || t, abs(n - expected), n || ' при ожидаемых ' || expected
FROM (VALUES
    ('courses',              (SELECT count(*) FROM raw.courses),               22),
    ('assessments',          (SELECT count(*) FROM raw.assessments),          206),
    ('student_info',         (SELECT count(*) FROM raw.student_info),       32593),
    ('student_registration', (SELECT count(*) FROM raw.student_registration), 32593),
    ('student_assessment',   (SELECT count(*) FROM raw.student_assessment), 173912),
    ('vle',                  (SELECT count(*) FROM raw.vle),                 6364),
    ('student_vle',          (SELECT count(*) FROM raw.student_vle),     10655280)
) AS x (t, n, expected);

-- 2. Обязательные поля не пусты и не «?».
INSERT INTO chk (check_name, bad)
SELECT 'raw: пустые обязательные поля в ' || t, n FROM (VALUES
    ('courses', (SELECT count(*) FROM raw.courses
                 WHERE rules.na(code_module) IS NULL OR rules.na(code_presentation) IS NULL
                    OR rules.na(module_presentation_length) IS NULL)),
    ('assessments', (SELECT count(*) FROM raw.assessments
                 WHERE rules.na(code_module) IS NULL OR rules.na(code_presentation) IS NULL
                    OR rules.na(id_assessment) IS NULL OR rules.na(assessment_type) IS NULL
                    OR rules.na(weight) IS NULL)),
    ('student_info', (SELECT count(*) FROM raw.student_info
                 WHERE rules.na(code_module) IS NULL OR rules.na(code_presentation) IS NULL
                    OR rules.na(id_student) IS NULL OR rules.na(final_result) IS NULL
                    OR rules.na(num_of_prev_attempts) IS NULL OR rules.na(studied_credits) IS NULL)),
    ('student_registration', (SELECT count(*) FROM raw.student_registration
                 WHERE rules.na(code_module) IS NULL OR rules.na(code_presentation) IS NULL
                    OR rules.na(id_student) IS NULL)),
    ('student_assessment', (SELECT count(*) FROM raw.student_assessment
                 WHERE rules.na(id_assessment) IS NULL OR rules.na(id_student) IS NULL
                    OR rules.na(date_submitted) IS NULL OR rules.na(is_banked) IS NULL)),
    ('vle', (SELECT count(*) FROM raw.vle
                 WHERE rules.na(id_site) IS NULL OR rules.na(code_module) IS NULL
                    OR rules.na(code_presentation) IS NULL OR rules.na(activity_type) IS NULL)),
    ('student_vle', (SELECT count(*) FROM raw.student_vle
                 WHERE rules.na(code_module) IS NULL OR rules.na(code_presentation) IS NULL
                    OR rules.na(id_student) IS NULL OR rules.na(id_site) IS NULL
                    OR rules.na(date) IS NULL OR rules.na(sum_click) IS NULL))
) AS x (t, n);

-- 3. Числа там, где они ожидаются (пропуск «?» допустим только в документированных полях).
INSERT INTO chk (check_name, bad)
SELECT 'raw: не число в ' || t, n FROM (VALUES
    ('courses.module_presentation_length', (SELECT count(*) FROM raw.courses WHERE NOT pg_temp.is_int(module_presentation_length))),
    ('assessments.id_assessment', (SELECT count(*) FROM raw.assessments WHERE NOT pg_temp.is_int(id_assessment))),
    ('assessments.date',          (SELECT count(*) FROM raw.assessments WHERE rules.na(date) IS NOT NULL AND NOT pg_temp.is_int(date))),
    ('assessments.weight',        (SELECT count(*) FROM raw.assessments WHERE NOT pg_temp.is_num(weight))),
    ('student_info.id_student',   (SELECT count(*) FROM raw.student_info WHERE NOT pg_temp.is_int(id_student))),
    ('student_info.num_of_prev_attempts', (SELECT count(*) FROM raw.student_info WHERE NOT pg_temp.is_int(num_of_prev_attempts))),
    ('student_info.studied_credits', (SELECT count(*) FROM raw.student_info WHERE NOT pg_temp.is_int(studied_credits))),
    ('student_registration.id_student', (SELECT count(*) FROM raw.student_registration WHERE NOT pg_temp.is_int(id_student))),
    ('student_registration.date_registration', (SELECT count(*) FROM raw.student_registration
        WHERE rules.na(date_registration) IS NOT NULL AND NOT pg_temp.is_int(date_registration))),
    ('student_registration.date_unregistration', (SELECT count(*) FROM raw.student_registration
        WHERE rules.na(date_unregistration) IS NOT NULL AND NOT pg_temp.is_int(date_unregistration))),
    ('student_assessment.id_assessment', (SELECT count(*) FROM raw.student_assessment WHERE NOT pg_temp.is_int(id_assessment))),
    ('student_assessment.id_student', (SELECT count(*) FROM raw.student_assessment WHERE NOT pg_temp.is_int(id_student))),
    ('student_assessment.date_submitted', (SELECT count(*) FROM raw.student_assessment WHERE NOT pg_temp.is_int(date_submitted))),
    ('student_assessment.score', (SELECT count(*) FROM raw.student_assessment WHERE rules.na(score) IS NOT NULL AND NOT pg_temp.is_int(score))),
    ('vle.id_site',   (SELECT count(*) FROM raw.vle WHERE NOT pg_temp.is_int(id_site))),
    ('vle.week_from', (SELECT count(*) FROM raw.vle WHERE rules.na(week_from) IS NOT NULL AND NOT pg_temp.is_int(week_from))),
    ('vle.week_to',   (SELECT count(*) FROM raw.vle WHERE rules.na(week_to) IS NOT NULL AND NOT pg_temp.is_int(week_to))),
    ('student_vle.id_student', (SELECT count(*) FROM raw.student_vle WHERE NOT pg_temp.is_int(id_student))),
    ('student_vle.id_site',    (SELECT count(*) FROM raw.student_vle WHERE NOT pg_temp.is_int(id_site))),
    ('student_vle.date',       (SELECT count(*) FROM raw.student_vle WHERE NOT pg_temp.is_int(date))),
    ('student_vle.sum_click',  (SELECT count(*) FROM raw.student_vle WHERE NOT pg_temp.is_int(sum_click)))
) AS x (t, n);

-- 4. Допустимые значения.
INSERT INTO chk (check_name, bad)
SELECT 'raw: недопустимое значение ' || t, n FROM (VALUES
    ('code_presentation (ожидается ГГГГB или ГГГГJ)', (SELECT count(*) FROM raw.courses WHERE code_presentation !~ '^20[0-9]{2}[BJ]$')),
    ('assessment_type', (SELECT count(*) FROM raw.assessments WHERE assessment_type NOT IN ('TMA', 'CMA', 'Exam'))),
    ('assessments.date пуст не у экзамена', (SELECT count(*) FROM raw.assessments WHERE rules.na(date) IS NULL AND assessment_type <> 'Exam')),
    ('assessments.weight вне 0–100', (SELECT count(*) FROM raw.assessments
        WHERE CASE WHEN pg_temp.is_num(weight) THEN weight::numeric NOT BETWEEN 0 AND 100 ELSE false END)),
    ('final_result', (SELECT count(*) FROM raw.student_info WHERE rules.outcome_group(final_result) IS NULL)),
    ('is_banked (ожидается 0 или 1)', (SELECT count(*) FROM raw.student_assessment WHERE is_banked NOT IN ('0', '1'))),
    ('score вне 0–100', (SELECT count(*) FROM raw.student_assessment
        WHERE CASE WHEN pg_temp.is_int(score) THEN score::int NOT BETWEEN 0 AND 100 ELSE false END)),
    ('sum_click меньше 1', (SELECT count(*) FROM raw.student_vle
        WHERE CASE WHEN pg_temp.is_int(sum_click) THEN sum_click::int < 1 ELSE false END)),
    ('длина потока не положительна', (SELECT count(*) FROM raw.courses
        WHERE CASE WHEN pg_temp.is_int(module_presentation_length) THEN module_presentation_length::int <= 0 ELSE false END))
) AS x (t, n);

-- 5. Уникальность ключей.
INSERT INTO chk (check_name, bad)
SELECT 'raw: дубли ключа ' || t, n FROM (VALUES
    ('courses (модуль, поток)', (SELECT count(*) - count(DISTINCT (code_module, code_presentation)) FROM raw.courses)),
    ('assessments (id_assessment)', (SELECT count(*) - count(DISTINCT id_assessment) FROM raw.assessments)),
    ('student_info (модуль, поток, студент)', (SELECT count(*) - count(DISTINCT (code_module, code_presentation, id_student)) FROM raw.student_info)),
    ('student_registration (модуль, поток, студент)', (SELECT count(*) - count(DISTINCT (code_module, code_presentation, id_student)) FROM raw.student_registration)),
    ('student_assessment (задание, студент)', (SELECT count(*) - count(DISTINCT (id_assessment, id_student)) FROM raw.student_assessment)),
    ('vle (id_site)', (SELECT count(*) - count(DISTINCT id_site) FROM raw.vle))
) AS x (t, n);

-- 6. Связи между таблицами.
INSERT INTO chk (check_name, bad)
SELECT 'raw: связь ' || t, n FROM (VALUES
    ('регистрация без строки studentInfo', (SELECT count(*) FROM raw.student_registration r
        WHERE NOT EXISTS (SELECT 1 FROM raw.student_info i
                          WHERE (i.code_module, i.code_presentation, i.id_student) = (r.code_module, r.code_presentation, r.id_student)))),
    ('studentInfo без регистрации', (SELECT count(*) FROM raw.student_info i
        WHERE NOT EXISTS (SELECT 1 FROM raw.student_registration r
                          WHERE (i.code_module, i.code_presentation, i.id_student) = (r.code_module, r.code_presentation, r.id_student)))),
    ('регистрация на поток, которого нет в courses', (SELECT count(*) FROM raw.student_registration r
        WHERE NOT EXISTS (SELECT 1 FROM raw.courses c WHERE (c.code_module, c.code_presentation) = (r.code_module, r.code_presentation)))),
    ('задание потока, которого нет в courses', (SELECT count(*) FROM raw.assessments a
        WHERE NOT EXISTS (SELECT 1 FROM raw.courses c WHERE (c.code_module, c.code_presentation) = (a.code_module, a.code_presentation)))),
    ('сдача неизвестного задания', (SELECT count(*) FROM raw.student_assessment s
        WHERE NOT EXISTS (SELECT 1 FROM raw.assessments a WHERE a.id_assessment = s.id_assessment))),
    ('сдача студентом, не зарегистрированным на поток задания', (SELECT count(*) FROM raw.student_assessment s
        JOIN raw.assessments a USING (id_assessment)
        WHERE NOT EXISTS (SELECT 1 FROM raw.student_registration r
                          WHERE (r.code_module, r.code_presentation, r.id_student) = (a.code_module, a.code_presentation, s.id_student)))),
    ('материал VLE потока, которого нет в courses', (SELECT count(*) FROM raw.vle v
        WHERE NOT EXISTS (SELECT 1 FROM raw.courses c WHERE (c.code_module, c.code_presentation) = (v.code_module, v.code_presentation)))),
    ('клики студента, не зарегистрированного на поток', (SELECT count(*) FROM raw.student_vle s
        WHERE NOT EXISTS (SELECT 1 FROM raw.student_registration r
                          WHERE (r.code_module, r.code_presentation, r.id_student) = (s.code_module, s.code_presentation, s.id_student)))),
    ('клики по материалу другого потока или неизвестному', (SELECT count(*) FROM raw.student_vle s
        WHERE NOT EXISTS (SELECT 1 FROM raw.vle v
                          WHERE v.id_site = s.id_site AND (v.code_module, v.code_presentation) = (s.code_module, s.code_presentation))))
) AS x (t, n);

-- 7. Даты.
INSERT INTO chk (check_name, bad)
SELECT 'raw: даты ' || t, n FROM (VALUES
    ('отписка раньше регистрации', (SELECT count(*) FROM raw.student_registration
        WHERE CASE WHEN pg_temp.is_int(date_registration) AND pg_temp.is_int(date_unregistration)
                   THEN date_unregistration::int < date_registration::int ELSE false END)),
    ('срок задания вне [0, длина потока]', (SELECT count(*) FROM raw.assessments a
        JOIN raw.courses c USING (code_module, code_presentation)
        WHERE CASE WHEN pg_temp.is_int(a.date) AND pg_temp.is_int(c.module_presentation_length)
                   THEN a.date::int NOT BETWEEN 0 AND c.module_presentation_length::int ELSE false END)),
    ('клик позже последнего дня потока', (SELECT count(*) FROM raw.student_vle s
        JOIN raw.courses c USING (code_module, code_presentation)
        WHERE CASE WHEN pg_temp.is_int(s.date) AND pg_temp.is_int(c.module_presentation_length)
                   THEN s.date::int > c.module_presentation_length::int ELSE false END))
) AS x (t, n);

SELECT seq AS "№", CASE WHEN bad = 0 THEN 'ok' ELSE 'FAIL' END AS "итог", check_name AS "проверка", bad AS "нарушений", note AS "детали"
FROM chk ORDER BY seq;
SELECT format('Проверок сырья: %s, не прошло: %s', count(*), count(*) FILTER (WHERE bad <> 0)) AS "итог" FROM chk;

DO $$
DECLARE failed text;
BEGIN
    SELECT string_agg(check_name, '; ' ORDER BY seq) INTO failed FROM chk WHERE bad <> 0;
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'Проверки сырья не прошли: %', failed;
    END IF;
END $$;
