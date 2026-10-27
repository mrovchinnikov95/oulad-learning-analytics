# Короткие команды. Подключение — переменные PG* (см. scripts/env.sh).
.PHONY: all data db build check test screenshot stop reset

all: data db build check

data:        ## скачать OULAD и сверить с data/SHA256SUMS
	scripts/get_data.sh

db:          ## одноразовый кластер PostgreSQL в ./.pgdata на localhost:54331
	scripts/pg_local.sh start

build:       ## схемы, загрузка CSV, проверки сырья, витрины, проверки витрин, выгрузка JSON
	scripts/build.sh

check:       ## независимый пересчёт из CSV, его самопроверка, числа README
	scripts/check.sh

test:        ## идемпотентность и проверка проверок порчей данных
	scripts/test_idempotency.sh
	scripts/test_controls.sh

screenshot:  ## отрисовка дашборда без ошибок в консоли + docs/dashboard.png
	node scripts/screenshot.mjs

stop:
	scripts/pg_local.sh stop

reset:       ## удалить кластер и поднять заново
	scripts/pg_local.sh reset
