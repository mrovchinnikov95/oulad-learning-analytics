# Общие настройки подключения. По умолчанию — локальный кластер из scripts/pg_local.sh;
# для своего сервера переопределите PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-54331}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-oulad}"
# PG_BIN — каталог с initdb, pg_ctl, psql и createdb, если их нет в PATH (Homebrew postgresql@16 — keg-only).
if [ -n "${PG_BIN:-}" ]; then export PATH="$PG_BIN:$PATH"; fi
# Без ~/.psqlrc, с остановкой на первой ошибке.
PSQL=(psql -X -v ON_ERROR_STOP=1)
# NOTICE от IF NOT EXISTS при повторном запуске — не ошибка, в выводе не нужен.
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
