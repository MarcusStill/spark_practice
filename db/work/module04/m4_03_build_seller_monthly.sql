create schema if not exists marts;

create table if not exists marts.seller_monthly (
    sale_month            date        not null,
    seller_sk             bigint      not null,

    seller_state          varchar,

    orders_cnt            bigint      not null,
    items_cnt             bigint      not null,
    items_revenue         numeric     not null,
    freight_revenue       numeric     not null,
    total_revenue         numeric     not null,

    rank_in_month         int         not null,
    prev_month_revenue    numeric,
    revenue_delta         numeric     not null,

    src_ingest_date       date,
    load_dttm             timestamptz default now(),

    constraint pk_seller_monthly primary key (sale_month, seller_sk)
);

create index if not exists ix_seller_monthly_month
    on marts.seller_monthly (sale_month);

create index if not exists ix_seller_monthly_rank
    on marts.seller_monthly (sale_month, rank_in_month);

begin;

truncate table marts.seller_monthly;

with agg as (
    select
        date_trunc('month', w.order_date)::date                      as sale_month,
        w.seller_sk                                                  as seller_sk,
        max(w.seller_state)                                          as seller_state,
        count(distinct w.order_id)                                   as orders_cnt,
        count(*)                                                     as items_cnt,
        coalesce(sum(coalesce(w.price, 0)), 0)                       as items_revenue,
        coalesce(sum(coalesce(w.freight_value, 0)), 0)               as freight_revenue,
        coalesce(sum(coalesce(w.price, 0) + coalesce(w.freight_value, 0)), 0) as total_revenue,
        '2025-12-03'::date                                      as src_ingest_date
    from marts.fct_order_items_wide w
    where w.order_date is not null
      and w.seller_sk is not null
    group by
        date_trunc('month', w.order_date)::date,
        w.seller_sk
),
enriched as (
    select
        a.*,
        row_number() over (
            partition by a.sale_month
            order by a.total_revenue desc, a.seller_sk
        ) as rank_in_month,
        lag(a.total_revenue) over (
            partition by a.seller_sk
            order by a.sale_month
        ) as prev_month_revenue
    from agg a
)
insert into marts.seller_monthly (
    sale_month,
    seller_sk,
    seller_state,
    orders_cnt,
    items_cnt,
    items_revenue,
    freight_revenue,
    total_revenue,
    rank_in_month,
    prev_month_revenue,
    revenue_delta,
    src_ingest_date,
    load_dttm
)
select
    e.sale_month,
    e.seller_sk,
    e.seller_state,
    e.orders_cnt,
    e.items_cnt,
    e.items_revenue,
    e.freight_revenue,
    e.total_revenue,
    e.rank_in_month,
    e.prev_month_revenue,
    e.total_revenue - coalesce(e.prev_month_revenue, 0)              as revenue_delta,
    e.src_ingest_date,
    now()                                                            as load_dttm
from enriched e;

commit;

create or replace view marts.top_sellers_monthly as
select *
from marts.seller_monthly
where rank_in_month <= 10;

-- Проверим витрину
create or replace view marts.top_sellers_monthly as
select count(*)
from marts.top_sellers_monthly;

-- Чек 1. Нет дублей по ключу
select
  count(*) as total_rows,
  count(distinct (sale_month, seller_sk)) as distinct_keys
from marts.seller_monthly;

-- Чек 2. Reconcile по выручке по месяцам
with wide_month as (
    select
        date_trunc('month', order_date)::date as sale_month,
        coalesce(sum(coalesce(price, 0) + coalesce(freight_value, 0)), 0) as wide_revenue
    from marts.fct_order_items_wide
    where order_date is not null
      and seller_sk is not null
    group by 1
),
seller_month as (
    select
        sale_month,
        coalesce(sum(total_revenue), 0) as seller_revenue
    from marts.seller_monthly
    group by 1
)
select
    w.sale_month,
    w.wide_revenue,
    s.seller_revenue,
    (w.wide_revenue - s.seller_revenue) as diff
from wide_month w
join seller_month s
  on s.sale_month = w.sale_month
order by w.sale_month;

-- Чек 3. Один batch id
select src_ingest_date, count(*) as rows_cnt
from marts.seller_monthly
group by 1
order by 1;

-- Чек 4. Top-10 view работает
select *
from marts.top_sellers_monthly
order by sale_month, rank_in_month
limit 10;

-- Топ-10 продавцов за каждый месяц
select *
from marts.top_sellers_monthly
order by sale_month, rank_in_month;

-- Продавцы с самым сильным ростом
select
    sale_month,
    seller_sk,
    total_revenue,
    prev_month_revenue,
    revenue_delta
from marts.seller_monthly
order by revenue_delta desc
limit 20;

-- Динамика одного продавца
select
    sale_month,
    seller_sk,
    total_revenue,
    prev_month_revenue,
    revenue_delta,
    rank_in_month
from marts.seller_monthly
where seller_sk = 123
order by sale_month;