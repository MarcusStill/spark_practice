-- 1. Буфер
drop table if exists stg._sellers_load;

create table stg._sellers_load (
  seller_id               varchar,
  seller_zip_code_prefix  varchar,
  seller_city             varchar,
  seller_state            varchar
);

-- 2. Загрузка CSV в буфер
COPY stg._sellers_load (
  seller_id,
  seller_zip_code_prefix,
  seller_city,
  seller_state
)
FROM '/data/raw/olist/sellers/ingest_date=2025-12-03/olist_sellers_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.sellers
   where ingest_date = date '2025-12-03';

  insert into stg.sellers (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state,
    ingest_date
  )
  select
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state,
    date '2025-12-03' as ingest_date
  from stg._sellers_load;

commit;

drop table if exists stg._sellers_load;