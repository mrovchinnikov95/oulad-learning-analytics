#!/usr/bin/env bash
# Проверка проверок: каждую порчу данных, правил или витрин должна поймать своя проверка.
# Порча в базе делается внутри транзакции в том же сеансе psql, что и проверка, и откатывается
# при выходе: рабочие данные не меняются, и каждый случай начинается с чистых данных.
# Порча файлов (заголовок CSV, контрольная сумма, выгрузка при упавшей сборке) — в отдельной базе
# ${PGDATABASE}_test и во временных каталогах .tmp/controls/.
# Подменённая функция правила обязана иметь те же имена параметров, иначе CREATE OR REPLACE упадёт
# раньше проверки (харнесс отличает такое падение от пойманной порчи).
# Запускать после успешной scripts/build.sh. Код возврата 1 — хотя бы одна порча не поймана.
# CSV OULAD — с окончаниями строк CRLF: правки файлов ниже не опираются на конец строки.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
T=.tmp/controls
rm -rf "$T"; mkdir -p "$T"
passed=0; failed=0

# случай: имя, SQL порчи, файл проверок, подстрока имени проверки, которая обязана упасть
sql_case() {
    local name="$1" mutation="$2" gate="$3" expect="$4" log="$T/case_$((passed + failed + 1)).log"
    if "${PSQL[@]}" -c "BEGIN" -c "$mutation" -f "$gate" > "$log" 2>&1; then
        echo "  НЕ ПОЙМАНО: $name (проверки прошли)"; failed=$((failed + 1)); return
    fi
    if grep -F "| FAIL |" "$log" | grep -qF "$expect"; then
        echo "  ok: $name → «$expect»"; passed=$((passed + 1))
    else
        echo "  НЕ ПОЙМАНО: $name (упало, но не проверкой «$expect», см. $log)"; failed=$((failed + 1))
    fi
}

echo "→ порча сырья (sql/25_raw_checks.sql)"
R=sql/25_raw_checks.sql
sql_case "неизвестный итог курса" "UPDATE raw.student_info SET final_result = 'Passed' WHERE src_row = 1" $R "недопустимое значение final_result"
sql_case "оценка 101" "UPDATE raw.student_assessment SET score = '101' WHERE src_row = 1" $R "score вне 0–100"
sql_case "пропуск в обязательном поле" "UPDATE raw.student_assessment SET id_student = '?' WHERE src_row = 1" $R "пустые обязательные поля в student_assessment"
sql_case "буква вместо цифры в дате" "UPDATE raw.student_registration SET date_registration = '1O' WHERE src_row = 1" $R "не число в student_registration.date_registration"
sql_case "дробный день сдачи" "UPDATE raw.student_assessment SET date_submitted = '18.5' WHERE src_row = 1" $R "не число в student_assessment.date_submitted"
sql_case "сдача неизвестного задания" "UPDATE raw.student_assessment SET id_assessment = '999999' WHERE src_row = 1" $R "сдача неизвестного задания"
sql_case "дубль строки studentInfo" "INSERT INTO raw.student_info (code_module, code_presentation, id_student, gender, region, highest_education, imd_band, age_band, num_of_prev_attempts, studied_credits, disability, final_result) SELECT code_module, code_presentation, id_student, gender, region, highest_education, imd_band, age_band, num_of_prev_attempts, studied_credits, disability, final_result FROM raw.student_info WHERE src_row = 1" $R "дубли ключа student_info"
sql_case "регистрация без studentInfo" "UPDATE raw.student_registration SET id_student = '1' WHERE src_row = 1" $R "регистрация без строки studentInfo"
sql_case "ноль кликов" "UPDATE raw.student_vle SET sum_click = '0' WHERE src_row = 1" $R "sum_click меньше 1"
sql_case "клик по материалу чужого потока" "UPDATE raw.student_vle SET id_site = (SELECT id_site FROM raw.vle WHERE (code_module, code_presentation) <> ('AAA', '2013J') LIMIT 1) WHERE src_row = 1" $R "клики по материалу другого потока"
sql_case "срок задания позже конца потока" "UPDATE raw.assessments SET date = '400' WHERE src_row = 1" $R "срок задания вне"
sql_case "флаг переноса 2" "UPDATE raw.student_assessment SET is_banked = '2' WHERE src_row = 1" $R "is_banked"
sql_case "отписка раньше регистрации" "UPDATE raw.student_registration SET date_unregistration = '-400' WHERE src_row = 1" $R "отписка раньше регистрации"
sql_case "задание TMA без срока" "UPDATE raw.assessments SET date = '?' WHERE src_row = 1" $R "assessments.date пуст не у экзамена"
sql_case "потерянная строка courses" "DELETE FROM raw.courses WHERE src_row = 22" $R "строк в courses"
sql_case "потерянные строки журнала VLE" "DELETE FROM raw.student_vle WHERE src_row <= 10" $R "строк в student_vle"

echo "→ порча правил и витрин (sql/90_checks.sql)"
M=sql/90_checks.sql
sql_case "срок сдачи строго раньше дня срока" "CREATE OR REPLACE FUNCTION rules.is_on_time(submitted_day int, deadline_day int) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT submitted_day < deadline_day'" $M "правило: is_on_time"
sql_case "отписка в день старта считается приступившим" "CREATE OR REPLACE FUNCTION rules.withdrew_before_start(unreg_day int) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT unreg_day IS NOT NULL AND unreg_day < 0'" $M "правило: withdrew_before_start"
sql_case "окно курса без дня отписки" "CREATE OR REPLACE FUNCTION rules.on_course(reg_day int, unreg_day int, from_day int, to_day int) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT (reg_day IS NULL OR reg_day <= to_day) AND (unreg_day IS NULL OR unreg_day > from_day)'" $M "правило: on_course"
sql_case "неделя с 1, а не с 0" "CREATE OR REPLACE FUNCTION rules.week_of(day int) RETURNS int LANGUAGE sql IMMUTABLE AS 'SELECT floor(day / 7.0)::int + 1'" $M "правило: week_of"
sql_case "лишняя сдача в витрине заданий" "UPDATE mart.assessment_submission SET submitted = submitted + 1 WHERE seq = 1 AND code_module = 'AAA' AND code_presentation = '2013J'" $M "сдали + перенесено + сдали не обязанные"
sql_case "потерянная ячейка сетки активности" "DELETE FROM mart.cohort_week_activity WHERE code_module = 'AAA' AND code_presentation = '2013J' AND week = 5 AND outcome_group = 'pass'" $M "ячеек сетки активности"
sql_case "лишний клик в витрине активности" "UPDATE mart.cohort_week_activity SET clicks = clicks + 1 WHERE code_module = 'AAA' AND code_presentation = '2013J' AND week = 5 AND outcome_group = 'pass'" $M "мост кликов"
sql_case "лишний сдавший в итогах потока" "UPDATE mart.presentation_outcome SET started_pass = started_pass + 1 WHERE code_module = 'AAA' AND code_presentation = '2013J'" $M "started = сумма четырёх итогов"
sql_case "перенесённый результат в «должны сдать»" "INSERT INTO mart.expected_submission (code_module, code_presentation, id_assessment, assessment_type, deadline_day, id_student, submitted, on_time) SELECT a.code_module, a.code_presentation, s.id_assessment, a.assessment_type, a.deadline_day, s.id_student, false, false FROM clean.submission s JOIN clean.assessment a USING (id_assessment) WHERE s.is_banked AND a.in_scope LIMIT 1" $M "перенесённый результат не входит"
sql_case "потерянный факт README" "ALTER VIEW mart.readme_facts RENAME TO readme_facts_full; CREATE VIEW mart.readme_facts AS SELECT * FROM mart.readme_facts_full WHERE code <> 'pass_rate'" $M "фактов для README"

echo "→ порча файлов"
TEST_DB="${PGDATABASE}_test"
"${PSQL[@]}" -d postgres -q -c "DROP DATABASE IF EXISTS $TEST_DB" -c "CREATE DATABASE $TEST_DB"
mkdir -p "$T/bad_header" "$T/bad_sha" "$T/bad_score" "$T/out"
for d in bad_header bad_sha bad_score; do
    for f in data/raw/*.csv data/raw/OULAD.names; do ln -sf "$PWD/$f" "$T/$d/$(basename "$f")"; done
done

# 1. Переставленные колонки в заголовке CSV: HEADER MATCH роняет загрузку, raw не меняется.
rm "$T/bad_header/assessments.csv"
sed '1s/"assessment_type","date"/"date","assessment_type"/' data/raw/assessments.csv > "$T/bad_header/assessments.csv"
before=$("${PSQL[@]}" -tAc "SELECT count(*) FROM raw.assessments")
if "${PSQL[@]}" -q -v data_dir="$PWD/$T/bad_header" -f sql/20_raw_load.sql > "$T/header.log" 2>&1; then
    echo "  НЕ ПОЙМАНО: заголовок CSV с переставленными колонками загрузился"; failed=$((failed + 1))
else
    after=$("${PSQL[@]}" -tAc "SELECT count(*) FROM raw.assessments")
    if grep -q "22P04\|header\|заголов" "$T/header.log" && [ "$before" = "$after" ] && [ "$after" -gt 0 ]; then
        echo "  ok: заголовок CSV с переставленными колонками → загрузка откатилась, в raw.assessments по-прежнему $after строк"
        passed=$((passed + 1))
    else
        echo "  НЕ ПОЙМАНО: загрузка упала не на заголовке или raw изменился ($before → $after), см. $T/header.log"; failed=$((failed + 1))
    fi
fi

# 2. Изменённый файл: контрольная сумма останавливает сборку до загрузки.
rm "$T/bad_sha/courses.csv"
sed 's/^"AAA","2013J","268"/"AAA","2013J","267"/' data/raw/courses.csv > "$T/bad_sha/courses.csv"
if PGDATABASE=$TEST_DB DATA_DIR="$T/bad_sha" OUT_DIR="$T/out" scripts/build.sh > "$T/sha.log" 2>&1; then
    echo "  НЕ ПОЙМАНО: сборка прошла на файле с другой контрольной суммой"; failed=$((failed + 1))
elif grep -q "courses.csv: FAILED" "$T/sha.log" && ! grep -q "sql/00_schemas.sql" "$T/sha.log"; then
    echo "  ok: изменённый courses.csv → сборка остановлена на сверке сумм, до загрузки"; passed=$((passed + 1))
else
    echo "  НЕ ПОЙМАНО: сборка упала не на сверке сумм, см. $T/sha.log"; failed=$((failed + 1))
fi

# 3. Битые данные при отключённой сверке сумм: падает гейт сырья, выгрузка не перезаписывается.
rm "$T/bad_score/studentAssessment.csv"
awk 'NR == 2 { sub(/,"78"/, ",\"178\"") } { print }' data/raw/studentAssessment.csv > "$T/bad_score/studentAssessment.csv"
echo "sentinel" > "$T/out/presentation_outcome.json"
if PGDATABASE=$TEST_DB SKIP_SHA=1 DATA_DIR="$T/bad_score" OUT_DIR="$T/out" STUDENTS_CSV="$T/out/students.csv" \
        scripts/build.sh > "$T/score.log" 2>&1; then
    echo "  НЕ ПОЙМАНО: сборка прошла с оценкой 178"; failed=$((failed + 1))
elif grep -F "| FAIL |" "$T/score.log" | grep -qF "score вне 0–100" && [ "$(cat "$T/out/presentation_outcome.json")" = "sentinel" ] \
        && ! grep -q "sql/30_clean.sql" "$T/score.log"; then
    echo "  ok: оценка 178 в CSV → гейт сырья остановил сборку до витрин, выгрузка не перезаписана"; passed=$((passed + 1))
else
    echo "  НЕ ПОЙМАНО: см. $T/score.log"; failed=$((failed + 1))
fi
"${PSQL[@]}" -d postgres -q -c "DROP DATABASE IF EXISTS $TEST_DB"

echo "Порч поймано: $passed из $((passed + failed))"
[ "$failed" -eq 0 ]
