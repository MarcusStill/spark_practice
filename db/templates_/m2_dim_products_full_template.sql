-- создаём схему core, если её ещё нет
create schema if not exists core;


-- измерение товаров: SCD1
create table if not exists core.dim_product (
    product_sk                  bigserial primary key,  -- surrogate key в CORE

    -- бизнес-ключ и атрибуты товара (перенесены из stg.products)
    product_id                  varchar not null,
    product_category_name       varchar,
    product_name_lenght         int,
    product_description_lenght  int,
    product_photos_qty          int,
    product_weight_g            int,
    product_length_cm           int,
    product_height_cm           int,
    product_width_cm            int,

    -- технические поля CORE
    src_ingest_date             date,           -- откуда взяли (ingest в STG)
    load_dttm                   timestamptz default now()  -- когда загрузили в CORE
);

-- уникальность по бизнес-ключу (одна строка на product_id в SCD1)
create unique index if not exists ux_dim_product_product_id
    on core.dim_product(product_id);



select column_name, data_type
from information_schema.columns
where table_schema = 'core'
  and table_name   = 'dim_product'
order by ordinal_position;

select distinct ingest_date
from stg.products
order by ingest_date;



with max_ingest as (
    select max(ingest_date) as max_ingest_date
    from stg.products
)
select *
from stg.products p
join max_ingest m
  on p.ingest_date = m.max_ingest_date
limit 5;


truncate table core.dim_product restart identity;




-- Full-load для core.dim_product из stg.products (последний ingest_date)

truncate table core.dim_product restart identity;

with max_ingest as (
    select max(ingest_date) as max_ingest_date
    from stg.products
)
insert into core.dim_product (
    product_id                  ,
    product_category_name       ,
    product_name_lenght         ,
    product_description_lenght  ,
    product_photos_qty          ,
    product_weight_g            ,
    product_length_cm           ,
    product_height_cm           ,
    product_width_cm            ,
    src_ingest_date             ,
    load_dttm
)
select
    p.product_id                  ,
    p.product_category_name       ,
    p.product_name_lenght         ,
    p.product_description_lenght  ,
    p.product_photos_qty          ,
    p.product_weight_g            ,
    p.product_length_cm           ,
    p.product_height_cm           ,
    p.product_width_cm            ,
    p.ingest_date         as src_ingest_date,
    now()                 as load_dttm
from stg.products p
join max_ingest m
  on p.ingest_date = m.max_ingest_date;

---



