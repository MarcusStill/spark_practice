drop table if exists stg._order_items_load;

create table stg._order_items_load (
  order_id            varchar,
  order_item_id       int,
  product_id          varchar,
  seller_id           varchar,
  shipping_limit_date timestamp,
  price               numeric(12,2),
  freight_value       numeric(12,2)
);


