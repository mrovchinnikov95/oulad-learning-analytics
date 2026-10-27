-- Загрузка CSV в raw. Одна транзакция: при любой ошибке raw остаётся прежним.
-- HEADER MATCH (PostgreSQL 15+) сверяет заголовок файла со списком колонок: переставленная
-- или переименованная колонка в файле — ошибка загрузки, а не тихий сдвиг данных.
-- Каталог с CSV — переменная psql data_dir (см. scripts/build.sh). \copy не подставляет переменные
-- в свою строку, поэтому сначала переходим в каталог данных через \cd.
\cd :data_dir
BEGIN;
TRUNCATE raw.courses, raw.assessments, raw.student_info, raw.student_registration,
         raw.student_assessment, raw.vle, raw.student_vle RESTART IDENTITY;
\copy raw.courses (code_module, code_presentation, module_presentation_length) FROM 'courses.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.assessments (code_module, code_presentation, id_assessment, assessment_type, date, weight) FROM 'assessments.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.student_info (code_module, code_presentation, id_student, gender, region, highest_education, imd_band, age_band, num_of_prev_attempts, studied_credits, disability, final_result) FROM 'studentInfo.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.student_registration (code_module, code_presentation, id_student, date_registration, date_unregistration) FROM 'studentRegistration.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.student_assessment (id_assessment, id_student, date_submitted, is_banked, score) FROM 'studentAssessment.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.vle (id_site, code_module, code_presentation, activity_type, week_from, week_to) FROM 'vle.csv' WITH (FORMAT csv, HEADER MATCH)
\copy raw.student_vle (code_module, code_presentation, id_student, id_site, date, sum_click) FROM 'studentVle.csv' WITH (FORMAT csv, HEADER MATCH)
COMMIT;
ANALYZE raw.courses, raw.assessments, raw.student_info, raw.student_registration,
        raw.student_assessment, raw.vle, raw.student_vle;
