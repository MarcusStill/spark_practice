drop table if exists stg._customers_load;

create table stg._customers_load (
  customer_id              varchar,
  customer_unique_id       varchar,
  customer_zip_code_prefix int,
  customer_city            varchar,
  customer_state           varchar
);