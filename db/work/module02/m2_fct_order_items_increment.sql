-- Инкрементальная загрузка core.fct_order_items по src_ingest_date с защитой от дублей

with last_loaded as (
    -- Определяем последнюю загруженную дату ингреста
    select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
    from core.fct_order_items
),
new_data as (
    -- Все новые записи из стейджинга
    select distinct on (oi.order_id, oi.order_item_id)
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        oi.shipping_limit_date,
        oi.price,
        oi.freight_value,
        oi.ingest_date as src_ingest_date,
        o.order_approved_at,
        o.customer_id
    from (
        -- Дедупликация order_items
        select
            oi.*,
            row_number() over (
                partition by oi.order_id, oi.order_item_id
                order by oi.ingest_date desc
            ) as rn_oi
        from stg.order_items oi
        where oi.ingest_date > (select last_ingest_date from last_loaded)
            and o.ingest_date > (select last_ingest_date from last_loaded)
        order by oi.order_id, oi.order_item_id, oi.ingest_date desc
    ) oi
    join (
        -- Дедупликация orders
        select
            o.order_id,
            o.customer_id,
            o.order_approved_at,
            row_number() over (
                partition by o.order_id
                order by o.ingest_date desc
            ) as rn_o
        from stg.orders o
        where o.ingest_date > (select last_ingest_date from last_loaded)
    ) o on oi.order_id = o.order_id and o.rn_o = 1
    where oi.rn_oi = 1
),
cust as (
    -- Актуальные customer_id -> customer_unique_id
    select
        customer_id,
        customer_unique_id
    from (
        select
            c.*,
            row_number() over (
                partition by c.customer_id
                order by c.ingest_date desc
            ) as rn
        from stg.customers c
        where c.ingest_date <= (select max(src_ingest_date) from new_data)  -- оптимизация
    ) t
    where rn = 1
),
dc as (
    -- Актуальные ключи измерений customer
    select
        d.customer_sk,
        d.customer_unique_id
    from core.dim_customer d
    where d.is_current
),
p as (
    -- Актуальные ключи измерений product
    select
        dp.product_sk,
        dp.product_id
    from core.dim_product dp
),
s as (
    -- Актуальные ключи измерений seller
    select
        ds.seller_sk,
        ds.seller_id
    from core.dim_seller ds
)
insert into core.fct_order_items (
    order_id,
    order_item_id,
    customer_sk,
    product_sk,
    seller_sk,
    order_approved_at,
    shipping_limit_date,
    price,
    freight_value,
    src_ingest_date,
    load_dttm
)
select
    nd.order_id,
    nd.order_item_id,
    dc.customer_sk,
    p.product_sk,
    s.seller_sk,
    nd.order_approved_at,
    nd.shipping_limit_date,
    nd.price,
    nd.freight_value,
    nd.src_ingest_date,
    now()
from new_data nd
left join cust on nd.customer_id = cust.customer_id
left join dc on cust.customer_unique_id = dc.customer_unique_id
left join p on nd.product_id = p.product_id
left join s on nd.seller_id = s.seller_id
-- Проверка на дубликаты
where not exists (
    select 1
    from core.fct_order_items f
    where f.order_id = nd.order_id
      and f.order_item_id = nd.order_item_id
);