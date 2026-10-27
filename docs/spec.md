# Спецификация витрин и выгрузок

Здесь полные определения метрик проекта. SQL (`sql/`) и независимый пересчёт на Python (`checks/verify_independent.py`) написаны по этому документу независимо друг от друга. README и дашборд ссылаются на него и дают только короткие пояснения; при расхождении прав этот документ.

Тип документа — справочник. Актуален на 28.10.2026. 27.10 по вопросам независимого пересчёта уточнены R5, R8, подписи и «модуль» в фактах CMA; 28.10 по рецензии уточнено обоснование R7. Определения не менялись.

## Источник

Open University Learning Analytics Dataset (OULAD), 7 CSV-файлов в `data/raw/`. Каждое значение в кавычках, первая строка — имена колонок, пропуск записан как `?`. Все числа целые, кроме `assessments.weight` (бывает `12.5`).

Связи: `studentRegistration` и `studentInfo` — одна строка на регистрацию «модуль, поток, студент», 1:1 по `(code_module, code_presentation, id_student)`. `studentAssessment` связан с `assessments` по `id_assessment`, поток сдачи — поток задания. `studentVle` содержит `(code_module, code_presentation, id_student, id_site, date, sum_click)`.

## Термины

- **Поток** — модуль в конкретном запуске: `(code_module, code_presentation)`, 22 потока. `code_presentation` = год + `B` (старт в феврале) или `J` (в октябре).
- **Регистрация** — строка `studentRegistration` вместе со своей строкой `studentInfo`, 32 593 строки. Один студент может быть зарегистрирован на несколько потоков.
- **День** — номер дня относительно старта потока (день 0). Все даты в OULAD уже даны так. `reg` — `date_registration`, `unreg` — `date_unregistration`, пропуск — `NULL`.
- **Длина потока** `length` — `courses.module_presentation_length`. Дни потока — от 0 до `length` включительно.
- **Неделя курса** `w = floor(day / 7)`: дни 0–6 — неделя 0, дни 7–13 — неделя 1. Последняя неделя потока `last_week = floor(length / 7)`.

## Правила

- **R1. Отписался до старта:** `unreg IS NOT NULL AND unreg <= 0`. Такая регистрация не входит в поток. Остальные регистрации — **приступившие** (`started`).
- **R2. Числится на курсе в окне дней `[d1, d2]`:** `(reg IS NULL OR reg <= d2) AND (unreg IS NULL OR unreg >= d1)`. Нет даты регистрации — считается зарегистрированным с начала.
- **R3. Группа итога** по `final_result`: `Distinction` и `Pass` → `pass`, `Fail` → `fail`, `Withdrawn` → `withdrawn`.
- **R4. Задания в витринах** — только `assessment_type` `TMA` и `CMA` (182 задания). Экзамены (`Exam`) исключены: результаты экзаменов есть только в модулях CCC и DDD, у 11 из 24 экзаменов нет даты.
- **R5. Должен был сдать задание** `A` со сроком `D = assessments.date`: регистрация на поток задания, которая числится на курсе в окне `[D, D]` (R2), и при этом у этой пары «задание, студент» нет строки `studentAssessment` с `is_banked = 1` (результат перенесён из прошлого потока). Условия R1 здесь нет, но отписавшиеся до старта в R5 не попадают: самый ранний срок TMA/CMA — день 12.
- **R6. Сдал:** должен был сдать (R5) и есть строка `studentAssessment` по этой паре с `is_banked = 0`. Строки сдачи от тех, кто не должен был сдавать, в численник не входят и считаются отдельно (`submitted_not_expected`). Пустая оценка (`score = ?`) не мешает: сдача есть.
- **R7. Сдал в срок:** сдал (R6) и `date_submitted <= D`. В итоговые доли «в срок» входят только задания `TMA` (`on_time_measurable`): у CMA в модулях BBB, CCC и DDD почти все сдачи одного задания записаны одним днём, через 2–6 дней после записанного срока, а в FFF и GGG у всех CMA потока один общий срок в конце курса, то есть поле срока у CMA не ведёт себя как срок отдельного задания.
- **R8. Активен на неделе `w`:** у регистрации есть хотя бы одна строка `studentVle` с днём в `[7w, 7w + 6]`. `sum_click` всегда ≥ 1. Окно последней недели может выходить за `length`, но кликов позже `length` в журнале нет (это проверяется при сборке).
- **R9. Когорта недели `w`:** приступившие (R1), которые числятся на курсе в окне `[7w, 7w + 6]` (R2).
- **Порядковый номер задания** `seq`: номер среди заданий TMA/CMA своего потока по возрастанию `(D, id_assessment)`, с 1.

## Выгрузки

Все файлы — JSON-массив объектов в `dashboard/data/`, плюс CSV витрины студентов. Доли — `numeric` без округления; доля с нулевым знаменателем — `null`. Целые — точные. Порядок строк задан ниже, текст сортируется по байтам (`COLLATE "C"`).

### `presentation_outcome.json` — итоги потока, 22 строки

Порядок: `code_module`, `code_presentation`.

| Колонка | Определение |
|---|---|
| `code_module`, `code_presentation` | поток |
| `start_year` | первые 4 символа `code_presentation`, целое |
| `start_month_code` | последний символ `code_presentation`: `B` или `J` |
| `length_days` | `length` |
| `registered` | регистраций на поток |
| `withdrew_before_start` | регистраций по R1 |
| `started` | `registered − withdrew_before_start` |
| `started_distinction`, `started_pass`, `started_fail`, `started_withdrawn` | приступившие с `final_result` = `Distinction` / `Pass` / `Fail` / `Withdrawn`; в сумме дают `started` |
| `pass_rate` | `(started_distinction + started_pass) / started` |
| `withdrawn_rate` | `started_withdrawn / started` |
| `pass_rate_registered` | регистраций с группой `pass` (R3) / `registered`, для сравнения со знаменателем «все регистрации» |
| `expected_assessments` | сумма `expected` по заданиям потока (`assessment_submission.json`) |
| `submitted_assessments` | сумма `submitted` по заданиям потока |
| `tma_submitted` | сумма `submitted` по заданиям TMA потока |
| `tma_on_time` | сумма `on_time` по заданиям TMA потока |
| `submission_rate` | `submitted_assessments / expected_assessments` |
| `tma_on_time_share` | `tma_on_time / tma_submitted` |

### `assessment_submission.json` — сдача заданий и сдача в срок, 182 строки

Одна строка на задание TMA/CMA. Порядок: `code_module`, `code_presentation`, `seq`.

| Колонка | Определение |
|---|---|
| `code_module`, `code_presentation`, `id_assessment`, `assessment_type` | задание |
| `seq` | порядковый номер задания в потоке |
| `deadline_day` | `D` |
| `weight` | `assessments.weight`, число |
| `expected` | число регистраций, которые должны были сдать (R5) |
| `submitted` | из них сдали (R6) |
| `on_time` | из них сдали в срок (R7, считается у всех заданий, включая CMA) |
| `banked` | строк `studentAssessment` по заданию с `is_banked = 1` |
| `submitted_not_expected` | строк по заданию с `is_banked = 0` от студентов, которые не должны были сдавать (R5 не выполнено) |
| `on_time_measurable` | `true` для TMA, `false` для CMA |
| `submission_rate` | `submitted / expected` |
| `on_time_share` | `on_time / submitted` |

Тождество: `submitted + banked + submitted_not_expected` = число строк `studentAssessment` по заданию.

### `cohort_week_activity.json` — активность когорт, 2 451 строка

Полная сетка: каждый поток × каждая неделя `0..last_week` × каждая группа итога (`fail`, `pass`, `withdrawn`), даже если в ячейке нули. Порядок: `code_module`, `code_presentation`, `week`, `outcome_group`.

| Колонка | Определение |
|---|---|
| `code_module`, `code_presentation`, `week`, `outcome_group` | ячейка |
| `enrolled` | регистраций в когорте недели (R9) с этой группой итога (R3) |
| `active` | из них активных на неделе (R8) |
| `clicks` | сумма `sum_click` этих `active` регистраций по дням `[7w, 7w + 6]` |

### `data_quality.json` — качество данных, 16 строк

Порядок: `seq`. Колонки: `seq`, `code`, `severity` (всегда `warning`), `n`, `unit`, `description`, `handling`. Значение `n` по коду:

| `code` | `n` |
|---|---|
| `reg_day_missing` | регистраций без `reg` |
| `late_registration` | регистраций с `reg > 0` |
| `withdrawn_no_unreg_day` | регистраций с `final_result = Withdrawn` и без `unreg` |
| `fail_withdrew_before_start` | регистраций с `final_result ≠ Withdrawn`, отписавшихся до старта (R1) |
| `unreg_day_not_withdrawn` | регистраций с `final_result ≠ Withdrawn` и непустым `unreg` |
| `unreg_after_end` | регистраций с `unreg > length` |
| `banked` | строк `studentAssessment` по заданиям TMA/CMA с `is_banked = 1` |
| `submitted_not_expected` | строк `studentAssessment` по заданиям TMA/CMA с `is_banked = 0`, где студент не должен был сдавать (R5) |
| `score_missing` | строк `studentAssessment` с `score = ?` (все задания, включая экзамены) |
| `exam_out_of_scope` | строк `studentAssessment` по заданиям `Exam` |
| `cma_deadline` | сдач (R6) заданий CMA в модулях, где сдач CMA в срок (R7) меньше 1% от сдач CMA модуля |
| `vle_repeated_key` | строк `studentVle` минус число различных `(code_module, code_presentation, id_student, id_site, date)` |
| `vle_exact_duplicate` | строк `studentVle` минус число различных строк по всем шести колонкам |
| `vle_before_start` | строк `studentVle` с `date < 0` |
| `vle_after_unreg` | строк `studentVle` с `date > unreg` своей регистрации |
| `no_vle` | регистраций без единой строки `studentVle` |

### `readme_facts.json` — факты для README и дашборда, 39 строк

Порядок: `ord`. Колонки: `ord`, `code`, `value` (число или `null` у текстовых фактов), `display` (подпись). Сверяется `value`; у текстовых фактов — `display`.

| `code` | `value` |
|---|---|
| `modules` | число различных `code_module` |
| `presentations` | число потоков |
| `registrations` | сумма `registered` |
| `withdrew_before_start` | сумма `withdrew_before_start` |
| `started` | сумма `started` |
| `started_passed` | сумма `started_distinction + started_pass` |
| `pass_rate` | `started_passed / started` |
| `started_withdrawn` | сумма `started_withdrawn` |
| `withdrawn_rate` | `started_withdrawn / started` |
| `started_failed` | сумма `started_fail` |
| `pass_rate_min`, `pass_rate_max` | наименьший и наибольший `pass_rate` потока |
| `pass_rate_min_presentation`, `pass_rate_max_presentation` | `display` = `"<code_module> <code_presentation>"` этого потока (при равенстве — первый по модулю и потоку) |
| `pass_rate_feb`, `pass_rate_oct` | `(Σ started_distinction + Σ started_pass) / Σ started` по потокам `B` / `J` |
| `feb_oct_pairs` | число пар «поток B и поток J одного модуля и одного года» |
| `feb_lower_pairs` | из них пар, где `pass_rate` потока J больше, чем потока B |
| `feb_gap_min`, `feb_gap_max` | наименьшая и наибольшая разница `pass_rate(J) − pass_rate(B)` по этим парам |
| `feb_length_min`, `feb_length_max` | наименьшая и наибольшая `length_days` потоков B |
| `oct_length_min`, `oct_length_max` | то же для потоков J |
| `submission_rate` | `Σ submitted_assessments / Σ expected_assessments` |
| `first_expected` | пар «задание с `seq = 1`, регистрация», которые должны были его сдать (R5) |
| `first_not_submitted` | из них не сдали (R6 не выполнено) |
| `first_not_submitted_share` | `first_not_submitted / first_expected` |
| `first_not_submitted_pass_rate` | среди не сдавших первое задание — доля регистраций с группой `pass` |
| `first_not_submitted_withdrawn_rate` | среди них же — доля с `final_result = Withdrawn` |
| `first_submitted_pass_rate` | среди сдавших первое задание — доля с группой `pass` |
| `tma_on_time_share` | `Σ tma_on_time / Σ tma_submitted` |
| `cma_low_modules` | число модулей (`code_module` по всем его потокам), где сдач CMA в срок меньше 1% от сдач CMA модуля |
| `cma_low_submitted`, `cma_low_on_time` | сдач CMA и сдач CMA в срок в этих модулях |
| `cma_other_on_time_share` | сдачи CMA в срок / сдачи CMA в остальных модулях, где есть CMA |
| `week12_active_pass`, `week12_active_fail` | `Σ active / Σ enrolled` недели 12 по всем потокам для группы `pass` / `fail` |
| `week12_fail_on_course` | `Σ enrolled` недели 12 для группы `fail` |

Подписи: проценты — `round(100 · value, 1)` с запятой и знаком `%`, половина округляется от нуля; разница долей — то же с « п.п.» через обычный пробел; целые до 10 000 — просто цифры, от 10 000 — с неразрывным пробелом между тысячами.

### `.tmp/export/student_presentation.csv` — витрина студентов, 32 593 строки

Одна строка на регистрацию, в репозиторий не попадает. Порядок: `code_module`, `code_presentation`, `id_student`. Логические значения — `t` / `f`, пропуск — пустая строка.

| Колонка | Определение |
|---|---|
| `code_module`, `code_presentation`, `id_student` | регистрация |
| `reg_day`, `unreg_day` | `reg`, `unreg` |
| `final_result`, `outcome_group` | итог и группа (R3) |
| `withdrew_before_start`, `started` | R1 |
| `expected_assessments`, `submitted_assessments` | заданий TMA/CMA, которые должен был сдать (R5) и сдал (R6) |
| `tma_submitted`, `tma_on_time` | из них TMA: сдал и сдал в срок (R7) |
| `vle_clicks` | сумма `sum_click` за все дни, включая дни до старта |
| `vle_active_days` | число различных дней с кликами, включая дни до старта |
| `vle_first_day` | первый день с кликом, пусто без кликов |
| `vle_active_days_first_2w` | число различных дней с кликами в `[0, 13]` |
| `vle_active_weeks` | число различных недель курса с кликами среди дней `[0, length]` |

## Сверка

Целые сравниваются точно, доли — с допуском `1e-12`, текст — точно. Ключи, порядок и число строк в выгрузке должны совпасть с пересчётом.
