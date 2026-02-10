drop table if exists stg._orders_load;

create table stg._orders_load (
  order_id                       varchar,
  customer_id                    varchar,
  order_status                   varchar,
  order_purchase_ts              timestamp,
  order_approved_at              timestamp,
  order_delivered_carrier_date   timestamp,
  order_delivered_customer_date  timestamp,
  order_estimated_delivery_date  date
);