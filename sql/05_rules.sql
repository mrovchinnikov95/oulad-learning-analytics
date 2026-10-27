-- Правила — в одном месте. Чистый слой, витрины и проверки вызывают эти функции; второй копии
-- правил в SQL нет. Исключение намеренное: в sql/90_checks.sql граничные случаи записаны
-- отдельно ожидаемыми значениями, чтобы сверить с ними функции.
-- Все дни — относительно старта потока (день 0), как в OULAD. Определения — docs/spec.md.

-- «?» в CSV OULAD — пропуск.
CREATE OR REPLACE FUNCTION rules.na(v text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT CASE WHEN v = '?' OR v = '' THEN NULL ELSE v END $$;

-- Неделя курса: дни 0–6 — неделя 0, дни 7–13 — неделя 1; дни до старта дают отрицательные недели.
CREATE OR REPLACE FUNCTION rules.week_of(day int) RETURNS int
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT floor(day / 7.0)::int $$;

-- Отписался до старта: дата отписки в день старта или раньше. Такой студент не входит в поток.
CREATE OR REPLACE FUNCTION rules.withdrew_before_start(unreg_day int) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT unreg_day IS NOT NULL AND unreg_day <= 0 $$;

-- Числится на курсе хотя бы один день из окна [from_day, to_day]: зарегистрирован не позже конца
-- окна и не отписался раньше его начала. Нет даты регистрации — считаем зарегистрированным с начала.
CREATE OR REPLACE FUNCTION rules.on_course(reg_day int, unreg_day int, from_day int, to_day int) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT (reg_day IS NULL OR reg_day <= to_day) AND (unreg_day IS NULL OR unreg_day >= from_day)
$$;

-- Сдано в срок: в день срока или раньше.
CREATE OR REPLACE FUNCTION rules.is_on_time(submitted_day int, deadline_day int) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT submitted_day <= deadline_day $$;

-- Итог курса в три группы. Неизвестное значение — NULL, и проверка сырья его не пропустит.
CREATE OR REPLACE FUNCTION rules.outcome_group(final_result text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE final_result
        WHEN 'Distinction' THEN 'pass'
        WHEN 'Pass'        THEN 'pass'
        WHEN 'Fail'        THEN 'fail'
        WHEN 'Withdrawn'   THEN 'withdrawn'
    END
$$;

-- В витрины сдачи входят только задания с проверкой тьютором и компьютером. У итоговых экзаменов
-- результаты есть только в двух модулях из семи, а у 11 из 24 нет даты (docs/spec.md, R4).
CREATE OR REPLACE FUNCTION rules.assessment_in_scope(assessment_type text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT assessment_type IN ('TMA', 'CMA') $$;

-- Долю «в срок» можно мерить только у TMA. У CMA в модулях BBB, CCC и DDD в день срока или раньше
-- пришли 2 сдачи из 30 526 (почти все сдачи задания — одним днём, через 2–6 дней после срока), а в FFF и GGG у всех CMA потока
-- один общий срок в конце курса: срок у CMA в разных модулях значит разное (qa.data_quality, cma_deadline).
CREATE OR REPLACE FUNCTION rules.on_time_measurable(assessment_type text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT assessment_type = 'TMA' $$;

-- Модуль, где срок CMA не работает как срок: в срок приходит меньше 1% сдач CMA модуля.
-- Порог один для качества данных (cma_deadline) и для фактов README (cma_low_*).
CREATE OR REPLACE FUNCTION rules.cma_deadline_unreliable(on_time bigint, submitted bigint) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT on_time < 0.01 * submitted $$;
