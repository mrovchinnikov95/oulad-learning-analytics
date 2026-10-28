-- Факты для README и плиток дашборда. Каждое число в выводах README берётся отсюда (колонка display):
-- checks/check_readme_numbers.py не пропускает в проверяемых блоках README чисел, которых нет среди подписей
-- (место числа в тексте он не проверяет), а checks/verify_independent.py пересчитывает value заново из CSV.
-- Определения — docs/spec.md, раздел про readme_facts.json.

-- Форматирование только для подписей: в расчётах значения не округляются.
-- Тысячи отделяются неразрывным пробелом с 10 000 (четырёхзначные числа без пробела).
CREATE OR REPLACE FUNCTION mart.fmt_int(n numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN abs(n) < 10000 THEN n::bigint::text
                ELSE regexp_replace(n::bigint::text, '(\d)(?=(\d{3})+$)', E'\\1\u00a0', 'g') END
$$;
CREATE OR REPLACE FUNCTION mart.fmt_pct(x numeric, digits int DEFAULT 1) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT replace(round(100 * x, digits)::text, '.', ',') || '%' $$;
CREATE OR REPLACE FUNCTION mart.fmt_pp(x numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT replace(round(100 * x, 1)::text, '.', ',') || ' п.п.' $$;

DROP VIEW IF EXISTS mart.readme_facts;
CREATE VIEW mart.readme_facts AS
WITH po AS (SELECT * FROM mart.presentation_outcome),
tot AS (
    SELECT sum(registered) AS registered, sum(withdrew_before_start) AS withdrew_before_start,
           sum(started) AS started, sum(started_distinction + started_pass) AS passed,
           sum(started_withdrawn) AS withdrawn, sum(started_fail) AS failed,
           sum(expected_assessments) AS expected, sum(submitted_assessments) AS submitted,
           sum(tma_submitted) AS tma_submitted, sum(tma_on_time) AS tma_on_time
    FROM po
),
pr AS (
    SELECT code_module, code_presentation, pass_rate,
           row_number() OVER (ORDER BY pass_rate, code_module, code_presentation) AS rn_min,
           row_number() OVER (ORDER BY pass_rate DESC, code_module, code_presentation) AS rn_max
    FROM po
),
month AS (
    SELECT start_month_code,
           sum(started_distinction + started_pass)::numeric / sum(started) AS pass_rate,
           min(length_days) AS len_min, max(length_days) AS len_max
    FROM po GROUP BY start_month_code
),
-- Пары «февраль — октябрь» одного модуля и одного года.
pairs AS (
    SELECT b.code_module, b.start_year, j.pass_rate - b.pass_rate AS gap
    FROM po b JOIN po j ON j.code_module = b.code_module AND j.start_year = b.start_year
    WHERE b.start_month_code = 'B' AND j.start_month_code = 'J'
),
-- Первое задание потока (seq = 1): кто должен был его сдать и чем закончил курс.
first AS (
    SELECT x.submitted, x.submitted_day, x.deadline_day, sp.outcome_group, sp.final_result
    FROM mart.expected_submission x
    JOIN clean.assessment a ON a.id_assessment = x.id_assessment AND a.seq = 1
    JOIN mart.student_presentation sp
      ON (sp.code_module, sp.code_presentation, sp.id_student) = (x.code_module, x.code_presentation, x.id_student)
),
fs AS (
    SELECT count(*) AS expected,
           count(*) FILTER (WHERE NOT submitted) AS not_submitted,
           count(*) FILTER (WHERE NOT submitted AND outcome_group = 'pass')::numeric
               / count(*) FILTER (WHERE NOT submitted) AS ns_pass_rate,
           count(*) FILTER (WHERE NOT submitted AND final_result = 'Withdrawn')::numeric
               / count(*) FILTER (WHERE NOT submitted) AS ns_withdrawn_rate,
           count(*) FILTER (WHERE submitted AND outcome_group = 'pass')::numeric
               / count(*) FILTER (WHERE submitted) AS s_pass_rate
    FROM first
),
-- То же, но так, как это видно по ходу курса: «не сдал к дню срока» и «не сдал за неделю после срока».
-- «Так и не сдал» (fs) известно только задним числом: в день срока опоздавших не отличить от несдавших.
fw AS (
    SELECT count(*) FILTER (WHERE NOT d0)                                    AS d0_not,
           count(*) FILTER (WHERE NOT d0 AND outcome_group = 'pass')::numeric / count(*) FILTER (WHERE NOT d0) AS d0_not_pass,
           count(*) FILTER (WHERE NOT d7)                                    AS d7_not,
           count(*) FILTER (WHERE NOT d7 AND outcome_group = 'pass')::numeric / count(*) FILTER (WHERE NOT d7) AS d7_not_pass,
           count(*) FILTER (WHERE d7 AND outcome_group = 'pass')::numeric / count(*) FILTER (WHERE d7)         AS d7_pass,
           count(*) FILTER (WHERE late)                                      AS late,
           count(*) FILTER (WHERE late AND outcome_group = 'pass')::numeric / count(*) FILTER (WHERE late)     AS late_pass,
           count(*)                                                          AS expected
    FROM (SELECT outcome_group,
                 submitted AND submitted_day <= deadline_day     AS d0,
                 submitted AND submitted_day <= deadline_day + 7 AS d7,
                 submitted AND submitted_day > deadline_day      AS late
          FROM first) t
),
cma AS (
    SELECT code_module,
           count(*) FILTER (WHERE submitted) AS submitted,
           count(*) FILTER (WHERE on_time)   AS on_time
    FROM mart.expected_submission WHERE assessment_type = 'CMA' GROUP BY code_module
),
cma_low AS (SELECT * FROM cma WHERE rules.cma_deadline_unreliable(on_time, submitted)),
w12 AS (
    SELECT outcome_group, sum(enrolled) AS enrolled, sum(active)::numeric / sum(enrolled) AS active_share
    FROM mart.cohort_week_activity WHERE week = 12 GROUP BY outcome_group
)
SELECT ord, code, value, display FROM (
    SELECT 1 AS ord, 'modules' AS code, (SELECT count(DISTINCT code_module) FROM po)::numeric AS value, NULL::text AS display
    UNION ALL SELECT 2, 'presentations', (SELECT count(*) FROM po), NULL
    UNION ALL SELECT 3, 'registrations', registered, NULL FROM tot
    UNION ALL SELECT 4, 'withdrew_before_start', withdrew_before_start, NULL FROM tot
    UNION ALL SELECT 5, 'started', started, NULL FROM tot
    UNION ALL SELECT 6, 'started_passed', passed, NULL FROM tot
    UNION ALL SELECT 7, 'pass_rate', passed / started, 'pct' FROM tot
    UNION ALL SELECT 8, 'started_withdrawn', withdrawn, NULL FROM tot
    UNION ALL SELECT 9, 'withdrawn_rate', withdrawn / started, 'pct' FROM tot
    UNION ALL SELECT 10, 'started_failed', failed, NULL FROM tot
    UNION ALL SELECT 11, 'pass_rate_min', pass_rate, 'pct' FROM pr WHERE rn_min = 1
    UNION ALL SELECT 12, 'pass_rate_min_presentation', NULL, code_module || ' ' || code_presentation FROM pr WHERE rn_min = 1
    UNION ALL SELECT 13, 'pass_rate_max', pass_rate, 'pct' FROM pr WHERE rn_max = 1
    UNION ALL SELECT 14, 'pass_rate_max_presentation', NULL, code_module || ' ' || code_presentation FROM pr WHERE rn_max = 1
    UNION ALL SELECT 15, 'pass_rate_feb', pass_rate, 'pct' FROM month WHERE start_month_code = 'B'
    UNION ALL SELECT 16, 'pass_rate_oct', pass_rate, 'pct' FROM month WHERE start_month_code = 'J'
    UNION ALL SELECT 17, 'feb_oct_pairs', (SELECT count(*) FROM pairs), NULL
    UNION ALL SELECT 18, 'feb_lower_pairs', (SELECT count(*) FROM pairs WHERE gap > 0), NULL
    UNION ALL SELECT 19, 'feb_gap_min', (SELECT min(gap) FROM pairs), 'pp'
    UNION ALL SELECT 20, 'feb_gap_max', (SELECT max(gap) FROM pairs), 'pp'
    UNION ALL SELECT 21, 'feb_length_min', len_min, NULL FROM month WHERE start_month_code = 'B'
    UNION ALL SELECT 22, 'feb_length_max', len_max, NULL FROM month WHERE start_month_code = 'B'
    UNION ALL SELECT 23, 'oct_length_min', len_min, NULL FROM month WHERE start_month_code = 'J'
    UNION ALL SELECT 24, 'oct_length_max', len_max, NULL FROM month WHERE start_month_code = 'J'
    UNION ALL SELECT 25, 'submission_rate', submitted / expected, 'pct' FROM tot
    UNION ALL SELECT 26, 'first_expected', expected, NULL FROM fs
    UNION ALL SELECT 27, 'first_not_submitted', not_submitted, NULL FROM fs
    UNION ALL SELECT 28, 'first_not_submitted_share', not_submitted::numeric / expected, 'pct' FROM fs
    UNION ALL SELECT 29, 'first_not_submitted_pass_rate', ns_pass_rate, 'pct' FROM fs
    UNION ALL SELECT 30, 'first_not_submitted_withdrawn_rate', ns_withdrawn_rate, 'pct' FROM fs
    UNION ALL SELECT 31, 'first_submitted_pass_rate', s_pass_rate, 'pct' FROM fs
    UNION ALL SELECT 32, 'tma_on_time_share', tma_on_time / tma_submitted, 'pct' FROM tot
    UNION ALL SELECT 33, 'cma_low_modules', (SELECT count(*) FROM cma_low), NULL
    UNION ALL SELECT 34, 'cma_low_submitted', (SELECT sum(submitted) FROM cma_low), NULL
    UNION ALL SELECT 35, 'cma_low_on_time', (SELECT sum(on_time) FROM cma_low), NULL
    UNION ALL SELECT 36, 'cma_other_on_time_share',
        (SELECT sum(on_time)::numeric / sum(submitted) FROM cma WHERE code_module NOT IN (SELECT code_module FROM cma_low)), 'pct'
    UNION ALL SELECT 37, 'week12_active_pass', active_share, 'pct' FROM w12 WHERE outcome_group = 'pass'
    UNION ALL SELECT 38, 'week12_active_fail', active_share, 'pct' FROM w12 WHERE outcome_group = 'fail'
    UNION ALL SELECT 39, 'week12_fail_on_course', enrolled, NULL FROM w12 WHERE outcome_group = 'fail'
    UNION ALL SELECT 40, 'first_deadline_not_submitted', d0_not, NULL FROM fw
    UNION ALL SELECT 41, 'first_deadline_not_submitted_share', d0_not::numeric / expected, 'pct' FROM fw
    UNION ALL SELECT 42, 'first_deadline_not_submitted_pass_rate', d0_not_pass, 'pct' FROM fw
    UNION ALL SELECT 43, 'first_week_not_submitted', d7_not, NULL FROM fw
    UNION ALL SELECT 44, 'first_week_not_submitted_share', d7_not::numeric / expected, 'pct' FROM fw
    UNION ALL SELECT 45, 'first_week_not_submitted_pass_rate', d7_not_pass, 'pct' FROM fw
    UNION ALL SELECT 46, 'first_week_submitted_pass_rate', d7_pass, 'pct' FROM fw
    UNION ALL SELECT 47, 'first_late_submitted', late, NULL FROM fw
    UNION ALL SELECT 48, 'first_late_submitted_pass_rate', late_pass, 'pct' FROM fw
) f (ord, code, value, display_kind)
CROSS JOIN LATERAL (SELECT CASE
    WHEN display_kind = 'pct' THEN mart.fmt_pct(value)
    WHEN display_kind = 'pp'  THEN mart.fmt_pp(value)
    WHEN value IS NULL        THEN display_kind
    ELSE mart.fmt_int(value) END AS display) d;
