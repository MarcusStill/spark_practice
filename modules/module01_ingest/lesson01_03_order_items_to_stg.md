# Урок 3. `order_items` и проверки связности

## Цель урока

- загрузить таблицу `stg.order_items`;
- проверить связность данных: все ли `order_items.order_id` существуют в `stg.orders`;
- сформировать первый простой DQ-чек для отчётности.

## Контекст

Финансы и аналитики часто считают выручку на уровне **позиции заказа**:
- какой товар продаётся чаще;
- какова средняя корзина;
- какие категории дают больше денег.

Если в таблице позиций (`order_items`) будут строки без «шапки» (`orders`), отчёты начнут врать.

С точки зрения архитектуры хранилища это базовая **DQ-проверка связности факта продажи с таблицей товаров**:
- факт — позиции заказа (`order_items`),
- «шапка» — сам заказ (`orders`),
- слой — STG, где мы перед CORE уже ловим такие инциденты.

## 2. Создаём рабочий файл загрузки

Выполняем в терминале:

```bash
mkdir -p db/work

cp db/templates/m1_order_items_load_template.sql    db/work/m1_order_items_load.sql
```

## 3. Дописываем загрузку `order_items`

```sql
--- 1. Буфер уже создаётся в шаблоне:
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

-- 2. Загрузка CSV в буфер
copy stg._order_items_load(
  order_id,
  order_item_id,
  product_id,
  seller_id,
  shipping_limit_date,
  price,
  freight_value
) from '/data/raw/olist/order_items/ingest_date=2025-12-03/olist_order_items_dataset.csv'
CSV HEADER ENCODING 'UTF8';

-- 3. Replace-by-date в целевой таблице
begin;

  delete from stg.order_items
   where ingest_date = date '2025-12-03';

  insert into stg.order_items (
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value,
    ingest_date
  )
  select
    order_id,
    order_item_id,
    product_id,
    seller_id,
    shipping_limit_date,
    price,
    freight_value,
    date '2025-12-03' as ingest_date
  from stg._order_items_load;

commit;

drop table if exists stg._order_items_load;
```

## 4. Запускаем загрузку `order_items`

Выполняем скрип по блокам:
- `drop/create`;
- `COPY/\copy`;
- `begin; delete+insert; commit;`;
- `drop table ...`.

## 5. Проверяем результат загрузки

Количество строк по ingest_date:

```sql
select ingest_date, count(*) 
from stg.order_items
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|count |
-----------+------+
 2025-12-03|112650|
```

Проверка связности `orders` ↔ `order_items`

```sql
select count(*) as orphan_items
from stg.order_items oi
left join stg.orders o
  on oi.order_id    = o.order_id
 and oi.ingest_date = o.ingest_date
where oi.ingest_date = date '2025-12-03'
  and o.order_id is null;
```

Результат
```text
orphan_items|
------------+
           0|
```

Интерпретация результата:
- `orphan_items = 0` — все позиции нашли свой `order_id` в `stg.orders` для этого `ING`;
- `orphan_items > 0` — в слое STG есть строки, у которых нет «шапки» заказа.

Распределение количества позиций на заказ:

```sql
select
  oi.ingest_date,
  count(*)                                    as items_cnt,
  count(distinct oi.order_id)                 as orders_cnt,
  round(count(*)::numeric / count(distinct oi.order_id), 2) as avg_items_per_order
from stg.order_items oi
where oi.ingest_date = date '2025-12-03'
group by oi.ingest_date;
```

Результат
```text
ingest_date|items_cnt|orders_cnt|avg_items_per_order|
-----------+---------+----------+-------------------+
 2025-12-03|   112650|     98666|               1.14|
```
