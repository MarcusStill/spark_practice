create schema if not exists core;

create table if not exists core.dim_customers (
  customer_id           varchar primary key,
  customer_unique_id    varchar,
  customer_city         varchar,
  customer_state        varchar
);

create table if not exists core.dim_products (
  product_id             varchar primary key,
  product_category_name  varchar
);

create table if not exists core.fact_orders (
  order_id              varchar primary key,
  customer_id           varchar,
  order_purchase_date   date,
  order_status          varchar,

  items_cnt             int,
  items_gross           numeric(12,2),
  freight_sum           numeric(12,2),

  payments_sum          numeric(12,2),
  main_payment_type     varchar,
  max_installments      int
);
