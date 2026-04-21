-- создаём таблицу wide
create table if not exists marts.fct_order_items_wide (
    -- grain / keys
    order_item_sk         bigint primary key,
    order_id              varchar not null,
    order_item_id         int     not null,

    -- fk to dims (SK)
    customer_sk           bigint,
    product_sk            bigint,
    seller_sk             bigint,

    -- fact fields
    order_approved_at     timestamp,
    order_date            date,
    shipping_limit_date   timestamp,
    price                 numeric,
    freight_value         numeric,

    -- dim fields (минимальный MVP)
    product_category_name varchar,
    seller_city           varchar,
    seller_state          varchar,
    customer_city         varchar,
    customer_state        varchar,

    -- tech
    src_ingest_date       date,
    load_dttm             timestamptz default now()
);

create unique index if not exists ux_marts_wide_grain
    on marts.fct_order_items_wide(order_id, order_item_id);

create index if not exists ix_marts_wide_order_date
    on marts.fct_order_items_wide(order_date);

create index if not exists ix_marts_wide_category
    on marts.fct_order_items_wide(product_category_name);

begin;

-- Собираем wide-витрину (full refresh)
truncate table marts.fct_order_items_wide;

insert into marts.fct_order_items_wide (
    order_item_sk,
    order_id,
    order_item_id,

    customer_sk,
    product_sk,
    seller_sk,

    order_approved_at,
    order_date,
    shipping_limit_date,
    price,
    freight_value,

    product_category_name,
    seller_city,
    seller_state,
    customer_city,
    customer_state,

    src_ingest_date,
    load_dttm
)
select
    f.order_item_sk,
    f.order_id,
    f.order_item_id,

    f.customer_sk,
    f.product_sk,
    f.seller_sk,

    f.order_approved_at,
    f.order_approved_at::date as order_date,
    f.shipping_limit_date,
    f.price,
    f.freight_value,

    p.product_category_name,
    s.seller_city,
    s.seller_state,
    c.customer_city,
    c.customer_state,

    '2025-12-03'::date as src_ingest_date,
    now() as load_dttm
from core.fct_order_items f
left join core.dim_product p
       on p.product_sk = f.product_sk
left join core.dim_seller s
       on s.seller_sk = f.seller_sk
left join core.dim_customer c
       on c.customer_sk = f.customer_sk;

commit;


-- Проверка 1. Количество строк wide совпадает с фактом
select
  (select count(*) from core.fct_order_items)          as core_cnt,
  (select count(*) from marts.fct_order_items_wide)    as wide_cnt;