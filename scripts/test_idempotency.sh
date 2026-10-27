#!/usr/bin/env bash
# Идемпотентность: две сборки подряд дают побайтно те же выгрузки, что и в dashboard/data,
# а число объектов в схемах не растёт (CREATE OR REPLACE и пересоздание таблиц не плодят копий).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
T=.tmp/idempotency
rm -rf "$T"; mkdir -p "$T"

objects() {  # своя метка в выводе, а не текст сообщений сервера
    "${PSQL[@]}" -tA -c "SELECT 'fp|' || n.nspname || '|' || c.relkind::text || '|' || count(*)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('raw', 'rules', 'clean', 'mart', 'qa') GROUP BY n.nspname, c.relkind ORDER BY 1" \
        -c "SELECT 'fp|' || n.nspname || '|function|' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('raw', 'rules', 'clean', 'mart', 'qa') GROUP BY n.nspname ORDER BY 1" | grep '^fp|'
}

for run in 1 2; do
    echo "→ сборка $run"
    OUT_DIR="$T/run$run" STUDENTS_CSV="$T/run$run/student_presentation.csv" LOG_DIR="$T/logs$run" scripts/build.sh > "$T/build$run.log" 2>&1 \
        || { cat "$T/build$run.log"; exit 1; }
    objects > "$T/objects$run.txt"
done

n=$(wc -l < "$T/objects1.txt" | tr -d " ")
[ "$n" -ge 10 ] || { echo "отпечаток объектов не работает: строк $n"; exit 1; }
diff "$T/objects1.txt" "$T/objects2.txt" >/dev/null || { echo "число объектов изменилось:"; diff "$T/objects1.txt" "$T/objects2.txt"; exit 1; }
echo "  объекты в схемах после двух сборок совпадают ($n строк отпечатка)"

files=0
for f in "$T"/run1/*; do
    b=$(basename "$f")
    cmp -s "$f" "$T/run2/$b" || { echo "сборки разошлись: $b"; exit 1; }
    if [ "$b" = student_presentation.csv ]; then ref=.tmp/export/student_presentation.csv; else ref="dashboard/data/$b"; fi
    cmp -s "$f" "$ref" || { echo "выгрузка отличается от $ref"; exit 1; }
    files=$((files + 1))
done
[ "$files" -eq 6 ] || { echo "сравнено файлов $files, ожидалось 6"; exit 1; }
echo "ok: две сборки подряд дали побайтно одинаковые выгрузки, $files файлов совпали и с dashboard/data"
