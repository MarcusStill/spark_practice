"""
DAG: olist_customers_raw_to_stg

Самый простой вариант:
- 1 задача
- выполняет SQL-скрипт в Postgres
- берёт CSV из /data/raw/... (ВАЖНО: этот путь должен быть доступен ВНУТРИ контейнера postgres)
"""

from __future__ import annotations

from datetime import datetime

from airflow import DAG
from airflow.providers.postgres.operators.postgres import PostgresOperator

INGEST_DATE = "2025-11-11"
CSV_PATH = f"/data/raw/olist/customers/ingest_date={INGEST_DATE}/olist_customers_dataset.csv"

SQL = f"""
-- 0) (опционально) на всякий случай
create schema if not exists stg;

-- 1) temp-load table
drop table if exists stg._customers_load;

create table stg._customers_load (
  customer_id              varchar,
  customer_unique_id       varchar,
  customer_zip_code_prefix int,
  customer_city            varchar,
  customer_state           varchar
);

-- 2) load CSV into temp table
COPY stg._customers_load (
  customer_id,
  customer_unique_id,
  customer_zip_code_prefix,
  customer_city,
  customer_state
)
FROM '{CSV_PATH}'
CSV HEADER ENCODING 'UTF8';

-- 3) idempotent load into target
begin;

  delete from stg.customers
   where ingest_date = date '{INGEST_DATE}';

  insert into stg.customers (
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    ingest_date
  )
  select
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    date '{INGEST_DATE}' as ingest_date
  from stg._customers_load;

commit;

-- 4) cleanup
drop table if exists stg._customers_load;
"""

with DAG(
    dag_id="olist_customers_raw_to_stg",
    description="Load Olist customers CSV from /data/raw into stg.customers (idempotent by ingest_date).",
    start_date=datetime(2025, 1, 1),
    schedule=None,  # запуск вручную
    catchup=False,
    tags=["olist", "raw->stg", "postgres"],
) as dag:
    load_customers = PostgresOperator(
        task_id="load_customers",
        postgres_conn_id="postgres_dwh",  # создай коннект в Airflow UI (или через env)
        sql=SQL,
    )
