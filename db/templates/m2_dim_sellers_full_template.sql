-- Full-load для core.dim_seller из stg.sellers

-- 1. очистка таблицы
-- TODO: truncate

-- 2. вставка актуальных записей
with max_ingest as (
    -- TODO: взять max(ingest_date) из stg.sellers
)
insert into core.dim_seller (
    -- TODO: перечисли поля
)
select
    -- TODO: выбери нужные колонки из stg.sellers
from stg.sellers s
join max_ingest m
  on s.ingest_date = m.max_ingest_date;