# Урок 2. Загрузка `orders` в STG через replace-by-date

## Цель урока

Выполнить следующие действия:
- создать буферную таблицу `stg._orders_load`;
- загрузить CSV из RAW через `\copy`;
- перенести данные в целевую таблицу `stg.orders` по паттерну **`delete+insert` по `ingest_date`**.

## Контекст
Команда аналитики смотрит на **заказы**: сколько штук, в каком статусе, как меняется динамика.

Каждый день мы кладём новую выгрузку в RAW. При этом:
- выгрузку за один и тот же день иногда обновляют (исправили ошибки, переложили файлы);
- мы не хотим получать **дубликаты** в STG и считать метрики по завышенным числам.

Решение: для каждого `ingest_date` используем паттерн:
> **buffer → `\copy` → `delete+insert` по `ingest_date`**

Так загрузка становится **идемпотентной**: сколько раз ни запусти сценарий для одного и того же дня — результат в `stg.orders` будет одинаковым.

### 1. Создаём рабочий файл

В терминале:
```bash
mkdir -p db/work

cp db/templates/m1_orders_load_template.sql db/work/m1_orders_load.sql
```

### 2. Наполняем его

```sql
-- 1. Буферная таблица для загрузки заказов
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

-- 2. Загрузка CSV в буфер
COPY stg._orders_load (
  order_id,
  customer_id,
  order_status,
  order_purchase_ts,
  order_approved_at,
  order_delivered_carrier_date,
  order_delivered_customer_date,
  order_estimated_delivery_date
)
FROM '/data/raw/olist/orders/ingest_date=2025-12-03/olist_orders_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице stg.orders
begin;

  delete from stg.orders
   where ingest_date = date '2025-12-03';

  insert into stg.orders (
    order_id,
    customer_id,
    order_status,
    order_purchase_ts,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    ingest_date
  )
  select
    order_id,
    customer_id,
    order_status,
    order_purchase_ts,
    order_approved_at,
    order_delivered_carrier_date,
    order_delivered_customer_date,
    order_estimated_delivery_date,
    date '2025-12-03' as ingest_date
  from stg._orders_load;

commit;

-- 4. Чистим буфер
drop table if exists stg._orders_load;
```

### 3. Выполняем скрипт **по блокам**:

   - `drop/create` буфера;
   - `COPY ... FROM ...`;
   - `begin; delete+insert; commit;`;
   - `drop table stg._orders_load`.

### 4. Проверяем результат

Количество строк по ingest_date
```sql
-- 1) Количество строк по ingest_date
select ingest_date, count(*) 
from stg.orders
group by ingest_date
order by ingest_date;

-- 2) Последние заказы по дате покупки
select order_id,
       order_status,
       order_purchase_ts,
       ingest_date
from stg.orders
order by order_purchase_ts desc
limit 5;
```

Результат:
```text
ingest_date|count|
-----------+-----+
 2025-12-03|99441|
```

Количество строк по ingest_date
```sql
select order_id,
       order_status,
       order_purchase_ts,
       ingest_date
from stg.orders
order by order_purchase_ts desc
limit 5;
```

Результат:
```text
order_id                        |order_status|order_purchase_ts      |ingest_date|
--------------------------------+------------+-----------------------+-----------+
10a045cdf6a5650c21e9cfeb60384c16|canceled    |2018-10-17 17:30:18.000| 2025-12-03|
b059ee4de278302d550a3035c4cdb740|canceled    |2018-10-16 20:16:02.000| 2025-12-03|
a2ac6dad85cf8af5b0afb510a240fe8c|canceled    |2018-10-03 18:55:29.000| 2025-12-03|
616fa7d4871b87832197b2a137a115d2|canceled    |2018-10-01 15:30:09.000| 2025-12-03|
392ed9afd714e3c74767d0c4d3e3f477|canceled    |2018-09-29 09:13:03.000| 2025-12-03|
```
