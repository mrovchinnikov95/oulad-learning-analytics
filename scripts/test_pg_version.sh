#!/usr/bin/env bash
# Сборка на другой версии PostgreSQL в отдельном кластере и сравнение выгрузок с dashboard/data.
# Использование: scripts/test_pg_version.sh /opt/homebrew/opt/postgresql@17/bin [порт]
set -euo pipefail
cd "$(dirname "$0")/.."
PG_BIN="${1:?путь к каталогу с initdb и pg_ctl другой версии}"
export PG_BIN PGPORT="${2:-54332}" PG_DATA_DIR="$PWD/.tmp/pg_version/data"
T=.tmp/pg_version
mkdir -p "$T"
source scripts/env.sh
scripts/pg_local.sh start
trap 'scripts/pg_local.sh stop >/dev/null' EXIT
OUT_DIR="$T/out" STUDENTS_CSV="$T/out/student_presentation.csv" LOG_DIR="$T/logs" scripts/build.sh > "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
grep -E "^  Проверок" "$T/build.log"
files=0
for f in "$T"/out/*; do
    b=$(basename "$f")
    if [ "$b" = student_presentation.csv ]; then ref=.tmp/export/student_presentation.csv; else ref="dashboard/data/$b"; fi
    cmp -s "$f" "$ref" || { echo "выгрузка $b отличается от $ref"; exit 1; }
    files=$((files + 1))
done
[ "$files" -eq 6 ] || { echo "сравнено файлов $files, ожидалось 6"; exit 1; }
version=$("${PSQL[@]}" -tAc 'SHOW server_version')   # set -e остановит скрипт, если запрос упадёт
echo "ok: PostgreSQL $version — все $files выгрузок побайтно совпали с dashboard/data"
