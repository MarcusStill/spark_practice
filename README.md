# spark_practice

Мини-стенд DE на одном ноутбуке: **Docker + Postgres + Spark + Jupyter**.

Задача — пройти путь от сырых CSV до слоя STG, а дальше — к core и витринам.

---

## Сервисы

- JupyterLab — http://localhost:8890
- Spark Master UI — http://localhost:18080
- Spark Workers UI — http://localhost:8081, http://localhost:8082

Postgres (для DBeaver и psql):

- host: localhost
- port: 5433  (внутри Docker — postgres:5432)
- db: dwh
- user: app
- password: см. .env / docker-compose.yml

---

## Быстрый старт

```bash
git clone url-репозитория spark_01
cd spark_01

# поднять весь стек
docker compose up -d
# или только postgres
# docker compose up -d postgres
```

Проверка:

```bash
docker compose ps
```

Веб-интерфейс:

- Jupyter: http://localhost:8890
- Spark Master: http://localhost:18080

## Структура проекта

- `data/raw/` — сырые данные с разбивкой по `ingest_date=YYYY-MM-DD`
- `db/postgres/init/` — DDL, которые запускаются при первом старте БД
- `db/templates/` — шаблонные SQL-файлы (**не менять**)
- `db/work/` — рабочие SQL-скрипты
- `files/` — исходные csv Olist
- `modules/` — уроки и модули практикума
- `scripts/put_to_raw.py` — скрипт для раскладывания CSV в RAW
