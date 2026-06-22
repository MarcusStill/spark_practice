-- таблица витрины

create schema if not exists marts;

create table if not exists marts.sales_daily (
    -- grain keys
    sales_date             date        not null,
    product_category_name  varchar     not null,
    customer_state         varchar     not null,

    -- metrics
    orders_cnt             bigint      not null,
    items_cnt              bigint      not null,
    items_revenue          numeric     not null,
    freight_revenue        numeric     not null,
    total_revenue          numeric     not null,
    uniq_customers_cnt     bigint      not null,
    uniq_sellers_cnt       bigint      not null,

    -- tech
    src_ingest_date        date,
    load_dttm              timestamptz default now(),

    constraint pk_sales_daily primary key (sales_date, product_category_name, customer_state)
);

create index if not exists ix_sales_daily_date
    on marts.sales_daily (sales_date);

create index if not exists ix_sales_daily_state
    on marts.sales_daily (customer_state);

create index if not exists ix_sales_daily_revenue
    on marts.sales_daily (total_revenue);

-- Загрузка витрины (full refresh, атомарно)

begin;

truncate table marts.sales_daily;

insert into marts.sales_daily (
    sales_date,
    product_category_name,
    customer_state,
    orders_cnt,
    items_cnt,
    items_revenue,
    freight_revenue,
    total_revenue,
    uniq_customers_cnt,
    uniq_sellers_cnt,
    src_ingest_date,
    load_dttm
)
select
    w.order_date                                         as sales_date,
    coalesce(w.product_category_name, 'unknown')         as product_category_name,
    coalesce(w.customer_state, 'unknown')                as customer_state,

    count(distinct w.order_id)                           as orders_cnt,
    count(*)                                             as items_cnt,

    coalesce(sum(coalesce(w.price, 0)), 0)               as items_revenue,
    coalesce(sum(coalesce(w.freight_value, 0)), 0)       as freight_revenue,
    coalesce(sum(coalesce(w.price, 0) + coalesce(w.freight_value, 0)), 0) as total_revenue,

    count(distinct w.customer_sk)                        as uniq_customers_cnt,
    count(distinct w.seller_sk)                          as uniq_sellers_cnt,

    '2025-12-03'::date                               as src_ingest_date,
    now()                                                as load_dttm
from marts.fct_order_items_wide w
where w.order_date is not null
group by
    w.order_date,
    coalesce(w.product_category_name, 'unknown'),
    coalesce(w.customer_state, 'unknown');

commit;

-- Чек 1: нет дублей по ключам
select
  count(*) as total_rows,
  count(distinct (sales_date, product_category_name, customer_state)) as distinct_keys
from marts.sales_daily;

-- Чек 2: “сошлось” количество позиций
select
  (select count(*) from marts.fct_order_items_wide where order_date is not null) as wide_rows,
  (select sum(items_cnt) from marts.sales_daily)

-- Чек 3: reconcile по выручке
with wide_sum as (
  select coalesce(sum(coalesce(price,0) + coalesce(freight_value,0)), 0) as wide_rev
  from marts.fct_order_items_wide
  where order_date is not null
    and src_ingest_date = '2025-12-03'::date
),
daily_sum as (
  select coalesce(sum(total_revenue), 0) as daily_rev
  from marts.sales_daily
  where src_ingest_date = '2025-12-03'::date
)
select wide_rev, daily_rev, (wide_rev - daily_rev) as diff
from wide_sum cross join daily_sum;

-- Чек 4: batch id витрины должен быть один
select src_ingest_date, count(*) as rows_cnt
from marts.sales_daily
group by 1
order by 1;

-- Чек 5: сколько у нас `unknown` категории и штата
select
  sum(items_cnt)     as unknown_items_cnt,
  sum(total_revenue) as unknown_revenue
from marts.sales_daily
where product_category_name = 'unknown'
   or customer_state = 'unknown';

-- Чек 6: топ-10 дней по выручке
select
  sales_date,
  sum(total_revenue) as total_revenue
from marts.sales_daily
group by sales_date
order by total_revenue desc
limit 10;