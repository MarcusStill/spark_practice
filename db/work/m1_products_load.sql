-- 1. Буфер
drop table if exists stg._products_load;

create table stg._products_load (
  product_id                 varchar,
  product_category_name      varchar,
  product_name_lenght        int,
  product_description_lenght int,
  product_photos_qty         int,
  product_weight_g           int,
  product_length_cm          int,
  product_height_cm          int,
  product_width_cm           int
);

-- 2. Загрузка CSV в буфер
COPY stg._products_load (
  product_id,
  product_category_name,
  product_name_lenght,
  product_description_lenght,
  product_photos_qty,
  product_weight_g,
  product_length_cm,
  product_height_cm,
  product_width_cm
)
FROM '/data/raw/olist/products/ingest_date=2025-12-03/olist_products_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.products
   where ingest_date = date '2025-12-03';

  insert into stg.products (
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm,
    ingest_date
  )
  select
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm,
    date '2025-12-03' as ingest_date
  from stg._products_load;

commit;

drop table if exists stg._products_load;