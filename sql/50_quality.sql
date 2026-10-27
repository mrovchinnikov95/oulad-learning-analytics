-- Качество данных: что нашлось в OULAD и как это учтено в витринах. Здесь только предупреждения —
-- ошибки (дубли ключей, битые связи, форматы) останавливают сборку раньше, в sql/25_raw_checks.sql.
-- Счётчик n каждой строки пересчитывается независимо (checks/verify_independent.py).
BEGIN;
DROP TABLE IF EXISTS qa.data_quality CASCADE;
CREATE TABLE qa.data_quality (
    seq int PRIMARY KEY,
    code text NOT NULL UNIQUE,
    severity text NOT NULL CHECK (severity = 'warning'),
    n bigint NOT NULL,
    unit text NOT NULL,
    description text NOT NULL,
    handling text NOT NULL
);

INSERT INTO qa.data_quality (seq, code, severity, n, unit, description, handling)
SELECT row_number() OVER (ORDER BY ord), code, 'warning', n, unit, description, handling FROM (VALUES
 (1, 'reg_day_missing',
  (SELECT count(*) FROM clean.enrolment WHERE reg_day IS NULL), 'регистраций',
  'Нет даты регистрации.',
  'Считаем зарегистрированными с начала потока (R2).'),
 (2, 'late_registration',
  (SELECT count(*) FROM clean.enrolment WHERE reg_day > 0), 'регистраций',
  'Регистрация после старта потока.',
  'Задания и недели — только с дня регистрации (R2).'),
 (3, 'withdrawn_no_unreg_day',
  (SELECT count(*) FROM clean.enrolment WHERE final_result = 'Withdrawn' AND unreg_day IS NULL), 'регистраций',
  'Итог Withdrawn, но даты отписки нет.',
  'Остаются в потоке до конца, итог — «отписался» (R1, R3).'),
 (4, 'fail_withdrew_before_start',
  (SELECT count(*) FROM clean.enrolment WHERE final_result <> 'Withdrawn' AND withdrew_before_start), 'регистраций',
  'Итог Fail, хотя отписка в день старта или раньше.',
  'Не входят в поток по дате отписки (R1); в число провалов не попадают.'),
 (5, 'unreg_day_not_withdrawn',
  (SELECT count(*) FROM clean.enrolment WHERE final_result <> 'Withdrawn' AND unreg_day IS NOT NULL), 'регистраций',
  'Есть дата отписки, но итог не Withdrawn (включая строки fail_withdrew_before_start).',
  'Дата отписки ограничивает задания и недели, итог берётся как есть.'),
 (6, 'unreg_after_end',
  (SELECT count(*) FROM clean.enrolment e JOIN clean.presentation p USING (code_module, code_presentation)
   WHERE e.unreg_day > p.length_days), 'регистраций',
  'Дата отписки позже последнего дня потока.',
  'Ни на что не влияет: студент числится до конца потока.'),
 (7, 'banked',
  (SELECT count(*) FROM clean.submission s JOIN clean.assessment a USING (id_assessment)
   WHERE a.in_scope AND s.is_banked), 'сдач',
  'Результат перенесён из прошлого потока; день сдачи у всех −1, это не дата сдачи.',
  'Не входят ни в «должны сдать», ни в «сдали» (R5).'),
 (8, 'submitted_not_expected',
  (SELECT count(*) FROM clean.submission s JOIN clean.assessment a USING (id_assessment)
   WHERE a.in_scope AND NOT s.is_banked
     AND NOT EXISTS (SELECT 1 FROM mart.expected_submission x
                     WHERE (x.id_assessment, x.id_student) = (s.id_assessment, s.id_student))), 'сдач',
  'Сдача от студента, который в день срока не числился на курсе (отписался раньше или зарегистрировался позже).',
  'Не входят в доли сдачи: численник считается только по тем, кто должен был сдать (R6).'),
 (9, 'score_missing',
  (SELECT count(*) FROM clean.submission WHERE score IS NULL), 'сдач',
  'Сдача без оценки.',
  'Считается сдачей: витрины не используют оценку.'),
 (10, 'exam_out_of_scope',
  (SELECT count(*) FROM clean.submission s JOIN clean.assessment a USING (id_assessment) WHERE NOT a.in_scope), 'сдач',
  'Сдачи итоговых экзаменов: результаты есть только в CCC и DDD, у 11 из 24 экзаменов нет даты.',
  'Экзамены не входят в витрины сдачи (R4).'),
 (11, 'cma_deadline',
  (SELECT count(*) FROM mart.expected_submission x
   WHERE x.assessment_type = 'CMA' AND x.submitted
     AND x.code_module IN (SELECT code_module FROM mart.expected_submission
                           WHERE assessment_type = 'CMA' AND submitted
                           GROUP BY code_module HAVING count(*) FILTER (WHERE on_time) < 0.01 * count(*))), 'сдач',
  'Сдачи CMA в модулях, где в срок приходит меньше 1% CMA (BBB, CCC, DDD: в срок 2 сдачи, обе за месяцы до срока).',
  'Доля «в срок» считается только по TMA (R7); сдача CMA в доли сдачи входит.'),
 (12, 'vle_repeated_key',
  (SELECT sum(log_rows) - count(*) FROM (
       SELECT count(*) AS log_rows FROM raw.student_vle
       GROUP BY code_module, code_presentation, id_student, id_site, date) k), 'строк журнала',
  'Ключ «студент, материал, день» повторяется, хотя таблица описана как дневные итоги.',
  'Клики суммируются; активность недели (был ли клик) от повторов не зависит.'),
 (13, 'vle_exact_duplicate',
  (SELECT sum(c) - count(*) FROM (
       SELECT count(*) AS c FROM raw.student_vle
       GROUP BY code_module, code_presentation, id_student, id_site, date, sum_click) k), 'строк журнала',
  'Из них полностью совпадают с другой строкой, включая число кликов.',
  'Отличить повторную выгрузку от второй сессии за день нельзя; клики суммируются.'),
 (14, 'vle_before_start',
  (SELECT sum(log_rows) FROM clean.vle_day WHERE day < 0), 'строк журнала',
  'Клики до старта потока: материалы открываются за несколько недель.',
  'В недельную активность не входят: недели считаются с 0.'),
 (15, 'vle_after_unreg',
  (SELECT sum(d.log_rows) FROM clean.vle_day d JOIN clean.enrolment e USING (code_module, code_presentation, id_student)
   WHERE d.day > e.unreg_day), 'строк журнала',
  'Клики после даты отписки.',
  'Неделя считается, пока студент числится хотя бы один её день (R9); клики в последующие недели не учитываются.'),
 (16, 'no_vle',
  (SELECT count(*) FROM clean.enrolment e
   WHERE NOT EXISTS (SELECT 1 FROM clean.vle_day d
                     WHERE (d.code_module, d.code_presentation, d.id_student) = (e.code_module, e.code_presentation, e.id_student))), 'регистраций',
  'Ни одного клика в VLE за всё время.',
  'Остаются в знаменателях: неактивность — тоже результат.')
) AS x (ord, code, n, unit, description, handling);
COMMIT;
