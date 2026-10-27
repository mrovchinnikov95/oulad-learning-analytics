-- Слой raw: таблицы повторяют CSV OULAD один к одному. Все поля текстом, пропуск в файле — «?».
-- src_row — номер строки данных в файле (1 = первая строка после заголовка), чтобы любую ошибку
-- можно было найти в исходнике. Никаких преобразований здесь нет.
CREATE TABLE IF NOT EXISTS raw.courses (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    code_module text, code_presentation text, module_presentation_length text
);
CREATE TABLE IF NOT EXISTS raw.assessments (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    code_module text, code_presentation text, id_assessment text, assessment_type text, date text, weight text
);
CREATE TABLE IF NOT EXISTS raw.student_info (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    code_module text, code_presentation text, id_student text, gender text, region text,
    highest_education text, imd_band text, age_band text, num_of_prev_attempts text,
    studied_credits text, disability text, final_result text
);
CREATE TABLE IF NOT EXISTS raw.student_registration (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    code_module text, code_presentation text, id_student text, date_registration text, date_unregistration text
);
CREATE TABLE IF NOT EXISTS raw.student_assessment (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    id_assessment text, id_student text, date_submitted text, is_banked text, score text
);
CREATE TABLE IF NOT EXISTS raw.vle (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    id_site text, code_module text, code_presentation text, activity_type text, week_from text, week_to text
);
CREATE TABLE IF NOT EXISTS raw.student_vle (
    src_row bigint GENERATED ALWAYS AS IDENTITY,
    code_module text, code_presentation text, id_student text, id_site text, date text, sum_click text
);
