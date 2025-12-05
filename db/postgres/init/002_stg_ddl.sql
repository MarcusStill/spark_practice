-- STG. Таблицы приёмника для Olist

create table if not exists stg.orders (
  order_id                      varchar,
  customer_id                   varchar,
  order_status                  varchar,
  order_purchase_ts             timestamp,
  order_approved_at             timestamp,
  order_delivered_carrier_date  timestamp,
  order_delivered_customer_date timestamp,
  order_estimated_delivery_date date,
  ingest_date                   date not null,
  primary key (order_id, ingest_date)
);


create table if not exists stg.order_items (
  order_id            varchar,
  order_item_id       int,
  product_id          varchar,
  seller_id           varchar,
  shipping_limit_date timestamp,
  price               numeric(12,2),
  freight_value       numeric(12,2),
  ingest_date         date not null,
  primary key (order_id, order_item_id, ingest_date)
);

create index if not exists ix_stg_oi_prod   on stg.order_items(product_id);
create index if not exists ix_stg_oi_seller on stg.order_items(seller_id);

create table if not exists stg.order_payments (
  order_id            varchar,
  payment_sequential  int,
  payment_type        varchar,
  payment_installments int,
  payment_value       numeric(12,2),
  ingest_date         date not null,
  primary key (order_id, payment_sequential, ingest_date)
);

create table if not exists stg.customers (
  customer_id              varchar,
  customer_unique_id       varchar,
  customer_zip_code_prefix varchar,
  customer_city            varchar,
  customer_state           varchar,
  ingest_date              date not null,
  primary key (customer_id, ingest_date)
);

create table if not exists stg.products (
  product_id                  varchar,
  product_category_name       varchar,
  product_name_lenght         int,
  product_description_lenght  int,
  product_photos_qty          int,
  product_weight_g            int,
  product_length_cm           int,
  product_height_cm           int,
  product_width_cm            int,
  ingest_date                 date not null,
  primary key (product_id, ingest_date)
);

create table if not exists stg.sellers (
  seller_id              varchar,
  seller_zip_code_prefix varchar,
  seller_city            varchar,
  seller_state           varchar,
  ingest_date            date not null,
  primary key (seller_id, ingest_date)
);

create table if not exists stg.product_category_name_translation (
  product_category_name         varchar,
  product_category_name_english varchar,
  ingest_date                   date not null,
  primary key (product_category_name, ingest_date)
);
