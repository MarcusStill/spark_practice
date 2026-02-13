-- 1. Буферная таблица для загрузки заказов
drop table if exists stg._orders_load;

create table stg._orders_load (
  order_id                       varchar,
  customer_id                    varchar,
  order_status                   varchar,
  order_purchase_ts              timestamp,
  order_approved_at              timestamp,
  order_delivered_carrier_date   timestamp,
  order_delivered_customer_date  timestamp,
  order_estimated_delivery_date  date
);

-- 2. Загрузка CSV в буфер
COPY stg._orders_load (
  order_id,
  customer_id,
  order_status,
  order_purchase_ts,
  order_approved_at,
  order_delivered_carrier_date,
  order_delivered_customer_date,
  order_estimated_delivery_date
)
FROM '/data/raw/olist/orders/ingest_date=2025-12-03/olist_orders_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице stg.orders
begin;

  delete from stg.orders
   where ingest_date = date '2025-12-03';

  insert into stg.orders (
    order_id,
    customer_id,
    order_status,
    order_purchase_ts,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    ingest_date
  )
  select
    order_id,
    customer_id,
    order_status,
    order_purchase_ts,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    date '2025-12-03' as ingest_date
  from stg._orders_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._orders_load;