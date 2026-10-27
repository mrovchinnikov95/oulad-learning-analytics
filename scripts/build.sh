#!/usr/bin/env bash
# Сборка: сверка CSV с data/SHA256SUMS → схемы и правила → raw (загрузка CSV) → проверки сырья →
# clean → витрины → качество данных → факты → проверки витрин → выгрузка JSON для дашборда.
# Любая непрошедшая проверка останавливает сборку, и выгрузка не перезаписывается.
# DATA_DIR — каталог с CSV (по умолчанию data/raw); SKIP_SHA=1 — не сверять суммы (для тестов порчи);
# OUT_DIR — куда выгружать JSON (по умолчанию dashboard/data).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
DATA_DIR="$(cd "${DATA_DIR:-data/raw}" && pwd)"
mkdir -p .tmp

# GNU sha256sum (Linux) или shasum (macOS: системный sha256sum не знает --quiet).
sha_check() { if sha256sum --version 2>/dev/null | grep -q GNU; then sha256sum --check --quiet; else shasum -a 256 --check --quiet; fi; }
if [ "${SKIP_SHA:-0}" != "1" ]; then
    echo "→ data/SHA256SUMS"
    # Суммы записаны для data/raw/*.csv; сверяем файлы того каталога, из которого грузим.
    (cd "$DATA_DIR" && sed -n 's|  raw/|  |p' "$OLDPWD/data/SHA256SUMS" | sha_check)
fi

run() { echo "→ $1"; "${PSQL[@]}" -q -v data_dir="$DATA_DIR" -f "$1"; }
gate() {  # проверки: печатаем итог, при падении — весь отчёт
    local log=".tmp/$(basename "$1" .sql).log"
    echo "→ $1"
    "${PSQL[@]}" -q -f "$1" > "$log" 2>&1 || { cat "$log"; exit 1; }
    grep -E "^ Проверок" "$log" | sed 's/^ */  /'
}

run sql/00_schemas.sql
run sql/05_rules.sql
run sql/10_raw_tables.sql
run sql/20_raw_load.sql
gate sql/25_raw_checks.sql
run sql/30_clean.sql
run sql/40_marts.sql
run sql/50_quality.sql
run sql/60_facts.sql
gate sql/90_checks.sql

scripts/export.sh
