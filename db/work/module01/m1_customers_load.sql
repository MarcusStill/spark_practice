-- 1. Буфер
drop table if exists stg._customers_load;

create table stg._customers_load (
  customer_id              varchar,
  customer_unique_id       varchar,
  customer_zip_code_prefix int,
  customer_city            varchar,
  customer_state           varchar
);

-- 2. Загрузка CSV в буфер
copy stg._customers_load(
  customer_id,
  customer_unique_id,
  customer_zip_code_prefix,
  customer_city,
  customer_state
) from '/data/raw/olist/customers/ingest_date=2025-12-03/olist_customers_dataset.csv'
csv header encoding 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.customers
   where ingest_date = date '2025-12-03';

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
    date '2025-12-03' as ingest_date
  from stg._customers_load;

commit;

drop table if exists stg._customers_load;