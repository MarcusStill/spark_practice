-- 1. Буфер
drop table if exists stg._product_category_name_translation_load;

create table stg._product_category_name_translation_load (
  product_category_name               varchar,
  product_category_name_english                varchar
);

-- 2. Загрузка CSV в буфер
OPY stg._product_category_name_translation_load (
  product_category_name,
  product_category_name_english
)
FROM '/data/raw/olist/category_translation/ingest_date=2025-12-03/product_category_name_translation.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.product_category_name_translation
   where ingest_date = date '2025-12-03';

  insert into stg.product_category_name_translation (
    product_category_name,
    product_category_name_english,
    ingest_date
  )
  select
    product_category_name,
    product_category_name_english,
    date '2025-12-03' as ingest_date
  from stg._product_category_name_translation_load;

commit;

drop table if exists stg._product_category_name_translation_load;