-- 1. Буфер
drop table if exists stg._order_payments_load;

create table stg._order_payments_load (
  order_id                       varchar,
  payment_sequential             int,
  payment_type                   varchar,
  payment_installments           int,
  payment_value                  numeric(12,2)
);

-- 2. Загрузка CSV в буфер
COPY stg._order_payments_load (
  order_id,
  payment_sequential,
  payment_type,
  payment_installments,
  payment_value
)
FROM '/data/raw/olist/payments/ingest_date=2025-12-03/olist_order_payments_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.order_payments
   where ingest_date = date '2025-12-03';

  insert into stg.order_payments (
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value,
    ingest_date
  )
  select
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value,
    date '2025-12-03' as ingest_date
  from stg._order_payments_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._order_payments_load;