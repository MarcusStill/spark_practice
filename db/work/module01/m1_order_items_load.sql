-- 1. Буфер
drop table if exists stg._order_items_load;

create table stg._order_items_load (
  order_id            varchar,
  order_item_id       int,
  product_id          varchar,
  seller_id           varchar,
  shipping_limit_date timestamp,
  price               numeric(12,2),
  freight_value       numeric(12,2)
);

-- 2. Загрузка CSV в буфер
\copy stg._order_items_load(
  order_id,
  order_item_id,
  product_id,
  seller_id,
  shipping_limit_date,
  price,
  freight_value
) from '/data/raw/olist/order_items/ingest_date=2025-12-03/olist_order_items_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.order_items
   where ingest_date = date '2025-12-03';

  insert into stg.order_items (
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value,
    ingest_date
  )
  select
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value,
    date '2025-12-03' as ingest_date
  from stg._order_items_load;

commit;

drop table if exists stg._order_items_load;