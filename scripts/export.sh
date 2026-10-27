#!/usr/bin/env bash
# Выгрузка витрин в JSON для дашборда (dashboard/data/*.json, каталог меняется через OUT_DIR) и витрины студентов в CSV для
# независимого пересчёта (.tmp/export/student_presentation.csv, в репозиторий не попадает).
# Порядок строк фиксирован и не зависит от локали базы (COLLATE "C").
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
OUT_DIR="${OUT_DIR:-dashboard/data}"
STUDENTS_CSV="${STUDENTS_CSV:-.tmp/export/student_presentation.csv}"
mkdir -p "$OUT_DIR" "$(dirname "$STUDENTS_CSV")"

export_json() {  # имя файла, запрос с колонками, ORDER BY
    local out="$OUT_DIR/$1.json"
    "${PSQL[@]}" -tA -c "SELECT coalesce(json_agg(t ORDER BY $3), '[]'::json) FROM ($2) t" > "$out.tmp"
    mv "$out.tmp" "$out"
    echo "  $out: $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out") строк"
}

echo "→ выгрузка"
export_json presentation_outcome "SELECT * FROM mart.presentation_outcome" \
    'code_module COLLATE "C", code_presentation COLLATE "C"'
export_json assessment_submission "SELECT * FROM mart.assessment_submission" \
    'code_module COLLATE "C", code_presentation COLLATE "C", seq'
export_json cohort_week_activity "SELECT * FROM mart.cohort_week_activity" \
    'code_module COLLATE "C", code_presentation COLLATE "C", week, outcome_group COLLATE "C"'
export_json data_quality "SELECT seq, code, severity, n, unit, description, handling FROM qa.data_quality" 'seq'
export_json readme_facts "SELECT ord, code, value, display FROM mart.readme_facts" 'ord'

"${PSQL[@]}" -c "\\copy (SELECT * FROM mart.student_presentation ORDER BY code_module COLLATE \"C\", code_presentation COLLATE \"C\", id_student) TO '$STUDENTS_CSV' WITH (FORMAT csv, HEADER)" >/dev/null
echo "  $STUDENTS_CSV: $(($(wc -l < "$STUDENTS_CSV") - 1)) строк"
