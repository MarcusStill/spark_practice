-- 1. init-load факта позиций заказов

truncate table core.fct_order_items restart identity;

with oi as (
     select
         order_id,
         order_item_id,
         product_id,
         seller_id,
         shipping_limit_date,
         price,
         freight_value,
         ingest_date as src_ingest_date
     from (
         select
             oi.*,
             row_number() over (
                 partition by oi.order_id, oi.order_item_id
                 order by oi.ingest_date desc
             ) as rn
         from stg.order_items oi
     ) t
     where rn = 1
),
o as (
 select
     order_id,
     customer_id,
     order_approved_at
 from (
     select
         o.*,
         row_number() over (
             partition by o.order_id
             order by o.ingest_date desc
         ) as rn
     from stg.orders o
 ) t
 where rn = 1
),
cust as (
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
 ) t
 where rn = 1
 ),
dc as (
    select
        d.customer_sk,
        d.customer_unique_id
    from core.dim_customer d
    where d.is_current
),
p as (
    select
        dp.product_sk,
        dp.product_id
    from core.dim_product dp
),
s as (
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
    oi.order_id,
    oi.order_item_id,
    dc.customer_sk,
    p.product_sk,
    s.seller_sk,
    o.order_approved_at,
    oi.shipping_limit_date,
    oi.price,
    oi.freight_value,
    oi.src_ingest_date as src_ingest_date,
    now()                  as load_dttm
from oi
join o     on oi.order_id   = o.order_id
left join cust on o.customer_id = cust.customer_id
left join dc   on cust.customer_unique_id = dc.customer_unique_id
left join p    on oi.product_id = p.product_id
left join s    on oi.seller_id  = s.seller_id;