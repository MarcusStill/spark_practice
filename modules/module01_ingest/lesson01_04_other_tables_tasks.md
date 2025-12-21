# Урок 4. Загрузка остальных таблиц и проверка идемпотентности

## Цель урока

- загружаем остальные таблицы Olist;
- собираем сводный отчёт по количеству строк в STG для одного `ING`;
- проверяем идемпотентность (при повторном прогоне).

### 1. Загружаем `order_items`

### 1.1. Создаём рабочий файл

Выполняем в терминале:

```bash
mkdir -p db/work

cp db/templates/m1_customers_load_template.sql    db/work/m1_customers_load.sql
```

### 1.2. Дописываем загрузку `customers`

```sql
-- 1. Буфер
drop table if exists stg._customers_load;

create table stg._customers_load (
  customer_id              varchar,
  customer_unique_id       varchar,
  customer_zip_code_prefix int,
  customer_city            varchar,
  customer_state           varchar
);

-- 2. Загрузка CSV в буфер
copy stg._customers_load(
  customer_id,
  customer_unique_id,
  customer_zip_code_prefix,
  customer_city,
  customer_state
) from RAW="/data/raw/olist/customers/ingest_date=$ING/olist_customers_dataset.csv" csv header encoding 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.customers
   where ingest_date = date '2025-12-03';

  insert into stg.customers (
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    ingest_date
  )
  select
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    date '2025-12-03' as ingest_date
  from stg._customers_load;

commit;

drop table if exists stg._customers_load;
```

## 1.3. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.order_items
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03|99441|
```

### 2. Загружаем `order_payments`

### 2.1. Создаём рабочий файл и наполняем его

```sql
-- 1. Буфер
drop table if exists stg._order_payments_load;

create table stg._order_payments_load (
  order_id                       varchar,
  payment_sequential             int,
  payment_type                   varchar,
  payment_installments           int,
  payment_value                  numeric(12,2)
);

-- 2. Загрузка CSV в буфер
COPY stg._order_payments_load (
  order_id,
  payment_sequential,
  payment_type,
  payment_installments,
  payment_value
)
FROM '/data/raw/olist/payments/ingest_date=2025-12-03/olist_order_payments_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.order_payments
   where ingest_date = date '2025-12-03';

  insert into stg.order_payments (
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value,
    ingest_date
  )
  select
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value,
    date '2025-12-03' as ingest_date
  from stg._order_payments_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._order_payments_load;
```

## 2.2. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.order_payments
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count |
-----------+------+
 2025-12-03|103886|
```

### 3. Загружаем `products`

### 3.1. Создаём рабочий файл и наполняем его

```sql
-- 1. Буфер
drop table if exists stg._products_load;

create table stg._products_load (
  product_id                 varchar,
  product_category_name      varchar,
  product_name_lenght        int,
  product_description_lenght int,
  product_photos_qty         int,
  product_weight_g           int,
  product_length_cm          int,
  product_height_cm          int,
  product_width_cm           int
);

-- 2. Загрузка CSV в буфер
COPY stg._products_load (
  product_id,
  product_category_name,
  product_name_lenght,
  product_description_lenght,
  product_photos_qty,
  product_weight_g,
  product_length_cm,
  product_height_cm,
  product_width_cm           
)
FROM '/data/raw/olist/products/ingest_date=2025-12-03/olist_products_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.products
   where ingest_date = date '2025-12-03';

  insert into stg.products (
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm,     
    ingest_date
  )
  select
    product_id,
    product_category_name,
    product_name_lenght,
    product_description_lenght,
    product_photos_qty,
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm,
    date '2025-12-03' as ingest_date
  from stg._products_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._products_load;
```

## 3.2. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.products
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03|32951|
```

### 4. Загружаем `sellers`

### 4.1. Создаём рабочий файл и наполняем его

```sql
-- 1. Буфер
drop table if exists stg._sellers_load;

create table stg._sellers_load (
  seller_id               varchar,
  seller_zip_code_prefix  varchar,
  seller_city             varchar,
  seller_state            varchar
);

-- 2. Загрузка CSV в буфер
COPY stg._sellers_load (
  seller_id,
  seller_zip_code_prefix,
  seller_city,
  seller_state          
)
FROM '/data/raw/olist/sellers/ingest_date=2025-12-03/olist_sellers_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.sellers
   where ingest_date = date '2025-12-03';

  insert into stg.sellers (
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state,     
    ingest_date
  )
  select
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state,
    date '2025-12-03' as ingest_date
  from stg._sellers_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._sellers_load;
```

## 4.2. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.sellers
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03| 3095|
```

### 5. Загружаем `reviews`

### 5.1. Создаём рабочий файл и наполняем его

```sql
-- 1. Буфер
drop table if exists stg._reviews_load;

create table stg._reviews_load (
  review_id               varchar,
  order_id                varchar,
  review_score            int,
  review_comment_title    varchar,
  review_comment_message  varchar,
  review_creation_date    timestamp,
  review_answer_timestamp timestamp
);

-- 2. Загрузка CSV в буфер
COPY stg._reviews_load (
  review_id,
  order_id,
  review_score,
  review_comment_title,
  review_comment_message,
  review_creation_date,
  review_answer_timestamp 
)
FROM '/data/raw/olist/reviews/ingest_date=2025-12-03/olist_order_reviews_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.reviews
   where ingest_date = date '2025-12-03';

  insert into stg.reviews (
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp,     
    ingest_date
  )
  select
    review_id,
    order_id,
    review_score,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp,
    date '2025-12-03' as ingest_date
  from stg._reviews_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._reviews_load;
```

## 5.2. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.reviews
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03|99224|
```

### 6. Загружаем `product_category_name_translation`

### 6.1. Создаём рабочий файл и наполняем его

```sql
-- 1. Буфер
drop table if exists stg._product_category_name_translation_load;

create table stg._product_category_name_translation_load (
  product_category_name               varchar,
  product_category_name_english                varchar
);

-- 2. Загрузка CSV в буфер
COPY stg._product_category_name_translation_load (
  product_category_name,
  product_category_name_english
)
FROM '/data/raw/olist/category_translation/ingest_date=2025-12-03/product_category_name_translation.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.product_category_name_translation
   where ingest_date = date '2025-12-03';

  insert into stg.product_category_name_translation (
    product_category_name,
    product_category_name_english,     
    ingest_date
  )
  select
    product_category_name,
    product_category_name_english,
    date '2025-12-03' as ingest_date
  from stg._product_category_name_translation_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._product_category_name_translation_load;
```

## 6.2. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.product_category_name_translation
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03|   71|
```

## 7. Сводный отчёт по количеству строк

Выполним запрос:

```sql
select 'orders'         as tbl, count(*) as rows_cnt
from stg.orders
where ingest_date = date '2025-12-03'

union all
select 'order_items',       count(*)
from stg.order_items
where ingest_date = date '2025-12-03'

union all
select 'customers',         count(*)
from stg.customers
where ingest_date = date '2025-12-03'

union all
select 'order_payments',    count(*)
from stg.order_payments
where ingest_date = date '2025-12-03'

union all
select 'products',          count(*)
from stg.products
where ingest_date = date '2025-12-03'

union all
select 'sellers',           count(*)
from stg.sellers
where ingest_date = date '2025-12-03'

union all
select 'reviews',           count(*)
from stg.reviews
where ingest_date = date '2025-12-03'

union all
select 'product_category_name_translation',           count(*)
from stg.product_category_name_translation
where ingest_date = date '2025-12-03';
```

Результат:

```text
tbl                              |rows_cnt|
---------------------------------+--------+
order_items                      |  112650|
reviews                          |   99224|
orders                           |   99441|
customers                        |   99441|
order_payments                   |  103886|
products                         |   32951|
sellers                          |    3095|
product_category_name_translation|      71|
```

## 8. Проверка идемпотентности

### 8.1. Фиксируем текущее состояние

Возьмем одну таблицу, например `stg.orders`, и выполним запрос:

```sql
select ingest_date, count(*) 
from stg.orders
where ingest_date = date :'ING'
group by ingest_date;
```

Результат
```sql
ingest_date|count|
-----------+-----+
 2025-12-03|99441|
```

### 8.2. Повторная загрузка

Повторим полную загрузку `orders` для даты `2025-12-03`

После этого прогона ещё раз выполним:

```sql
select ingest_date, count(*) 
from stg.orders
where ingest_date = date :'ING'
group by ingest_date;
```

Результат
```sql
ingest_date|count|
-----------+-----+
 2025-12-03|99441|
```

Число строк совпало `до` и `после` повторной загрузки, значит для таблицы `orders` и даты `2025-12-03` наш сценарий действительно **идемпотентен**: