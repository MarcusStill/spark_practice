# Урок 2.3 - Первый факт CORE: `core.fct_order_items`

## Цели урока

- описать DDL для `core.fct_order_items`;
- сделать первый full‑load факта из STG;
- проверить корректность по количеству строк и базовым метрикам (выручка).
- набрасать инкрементальную загрузку факта с high‑watermark;
- определить, как искать и убирать дубли по бизнес‑ключу;
- сформулировать, какие витрины строятся поверх факта и измерений.

## 1. Немного теории

### 1.1. Факт

💡 **Факт‑таблица** — это «лентa событий», где каждая строка описывает **конкретное действие**: заказ, оплату, просмотр, клик, доставку и т.п.

В нашем мини‑DWH Olist в качестве первого факта берём:

> `core.fct_order_items` — **позиции заказов**  
> одна строка = один товар в составе заказа.

Почему не «одна строка = заказ»?

- У заказа может быть несколько товаров (`order_items`).
- В аналитике часто нужны **помесячные продажи по товарам**, категориям, продавцам.
- В одной строке факта удобно хранить **меры** на уровне «товар в заказе»:
  - количество штук;
  - цена за штуку;
  - выручка, доставка и т.д.

### 1.2. Grain (зерно) факта

**Grain (или Гранулярность)** — это ответ на вопрос:

> Для `fct_order_items` grain - «Одна строка = одна позиция заказа, определяемая парой (`order_id`, `order_item_id`).»

В терминах колонок это означает: grain факта — это комбинация (`order_id`, `order_item_id`), и именно под неё мы дальше подбираем поля и ограничения.

> 💡 Важно: сначала определяем grain, **потом** придумываем поля.

### 1.3. Меры и ссылки на измерения

Разложим поля будущего факта на группы:

- **Бизнес‑ключ и surrogate key:**
  - `order_item_sk` — surrogate key факта в CORE;
  - `order_id`, `order_item_id` — бизнес‑ключ позиции заказа.

- **Ссылки на измерения (foreign keys):**
  - `customer_sk` → `core.dim_customer`;
  - `product_sk`  → `core.dim_product`;
  - `seller_sk`   → `core.dim_seller`.

- **Временные поля события:**
  - `order_approved_at` — когда заказ был одобрен (event time);
  - `shipping_limit_date` — крайний срок отгрузки (из `order_items`).

- **Меры (measures):**
  - `price`        — цена товара в заказе;
  - `freight_value` — стоимость доставки (на уровне позиции);
  - в следующих уроках на основе этих полей будем считать GMV, выручку, маржу.

- **Технические поля CORE:**
  - `src_ingest_date` — из какого `ingest_date` STG мы взяли строку;
  - `load_dttm`       — когда строка попала в CORE.

## 2. Проектируем `core.fct_order_items`

### 2.1. DDL факта

Создадим рабочий файл в `db/work/module02/`:

```text
db/work/module02/m2_fct_order_items.sql
```

Со следующей структурой:

```sql
-- Факт позиций заказов
create table if not exists core.fct_order_items (
    order_item_sk        bigserial primary key,  -- surrogate key факта

    -- бизнес-ключ позиции заказа
    order_id             varchar      not null,
    order_item_id        int          not null,

    -- ссылки на измерения
    customer_sk          bigint       not null,
    product_sk           bigint       not null,
    seller_sk            bigint       not null,

    -- даты/время события
    order_approved_at    timestamp,
    shipping_limit_date  timestamp,

    -- меры
    price                numeric(10,2),
    freight_value        numeric(10,2),

    -- тех.поля CORE
    src_ingest_date      date,
    load_dttm            timestamptz default now()
);

-- уникальность на уровне бизнеса: одна строка на (order_id, order_item_id)
create unique index if not exists ux_fct_order_items_bk
    on core.fct_order_items(order_id, order_item_id);
```

### 2.2. Источник данных для факта

Чтобы наполнить факт, нам нужны:

- **строки в `stg.order_items`** — какие товары в заказе и по какой цене;
- **дополнительные поля из `stg.orders`** — время покупок (`order_approved_at`);
- **ключ клиента** из `stg.orders` → `stg.customers` → `core.dim_customer`;
- **ключ продавца и товара** из `stg.order_items` → `core.dim_seller`, `core.dim_product`.

Логика будет следующая:

```text
stg.order_items   -- что и по какой цене продали
 + stg.orders     -- когда был сделан заказ и какой клиент
 + dim_customer   -- история клиента, берём текущую версию
 + dim_product    -- измерение товара
 + dim_seller     -- измерение продавца
 = core.fct_order_items
```

## 3. Делаем init‑load факта

### 3.1. Очищаем факт перед init‑load

В рабочем файле `m2_fct_order_items.sql`:

```sql
-- 0. Инициализирующая загрузка: очищаем факт
truncate table core.fct_order_items restart identity;
```

### 3.2. Создадим предварительный запрос к источнику

```sql
with oi as (
    select
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        oi.shipping_limit_date,
        oi.price,
        oi.freight_value,
        oi.ingest_date as oi_ingest_date
    from stg.order_items oi
),
o as (
    select
        o.order_id,
        o.customer_id,
        o.order_approved_at
    from stg.orders o
),
cust as (
    -- мост между orders и dim_customer
    select
        c.customer_id,
        c.customer_unique_id
    from stg.customers c
),
dc as (
    -- текущая версия клиента в SCD2-измерении
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
    oi.oi_ingest_date as src_ingest_date
from oi
join o     on oi.order_id   = o.order_id
left join cust on o.customer_id = cust.customer_id
left join dc   on cust.customer_unique_id = dc.customer_unique_id
left join p    on oi.product_id = p.product_id
left join s    on oi.seller_id  = s.seller_id
limit 30;
```

Результат:
```text
order_id                        |order_item_id|customer_sk|product_sk|seller_sk|order_approved_at      |shipping_limit_date    |price |freight_value|src_ingest_date|
--------------------------------+-------------+-----------+----------+---------+-----------------------+-----------------------+------+-------------+---------------+
00010242fe8c5a6d1ba2dd792cb16214|            1|     152262|     25872|      514|2017-09-13 09:45:35.000|2017-09-19 09:45:35.000| 58.90|        13.29|     2025-12-03|
00010242fe8c5a6d1ba2dd792cb16214|            1|     152262|     25872|      514|2017-09-13 09:45:35.000|2017-09-19 09:45:35.000| 58.90|        13.29|     2025-12-03|
00010242fe8c5a6d1ba2dd792cb16214|            1|     152262|     25872|      514|2017-09-13 09:45:35.000|2017-09-19 09:45:35.000| 58.90|        13.29|     2025-12-03|
00018f77f2f0320c557190d7a144bdd3|            1|     265107|     27235|      472|2017-04-26 11:05:13.000|2017-05-03 11:05:13.000|239.90|        19.93|     2025-12-03|
00018f77f2f0320c557190d7a144bdd3|            1|     265107|     27235|      472|2017-04-26 11:05:13.000|2017-05-03 11:05:13.000|239.90|        19.93|     2025-12-03|
00018f77f2f0320c557190d7a144bdd3|            1|     265107|     27235|      472|2017-04-26 11:05:13.000|2017-05-03 11:05:13.000|239.90|        19.93|     2025-12-03|
000229ec398224ef6ca0657da4fc703e|            1|      63441|     22632|     1825|2018-01-14 14:48:30.000|2018-01-18 14:48:30.000|199.00|        17.87|     2025-12-03|
000229ec398224ef6ca0657da4fc703e|            1|      63441|     22632|     1825|2018-01-14 14:48:30.000|2018-01-18 14:48:30.000|199.00|        17.87|     2025-12-03|
000229ec398224ef6ca0657da4fc703e|            1|      63441|     22632|     1825|2018-01-14 14:48:30.000|2018-01-18 14:48:30.000|199.00|        17.87|     2025-12-03|
00024acbcdf0a6daa1e931b038114c75|            1|     198099|     15411|     2024|2018-08-08 10:10:18.000|2018-08-15 10:10:18.000| 12.99|        12.79|     2025-12-03|
00024acbcdf0a6daa1e931b038114c75|            1|     198099|     15411|     2024|2018-08-08 10:10:18.000|2018-08-15 10:10:18.000| 12.99|        12.79|     2025-12-03|
00024acbcdf0a6daa1e931b038114c75|            1|     198099|     15411|     2024|2018-08-08 10:10:18.000|2018-08-15 10:10:18.000| 12.99|        12.79|     2025-12-03|
00042b26cf59d7ce69dfabb4e55b4fd9|            1|     113718|      8869|     1598|2017-02-04 14:10:13.000|2017-02-13 13:57:51.000|199.90|        18.14|     2025-12-03|
00042b26cf59d7ce69dfabb4e55b4fd9|            1|     113718|      8869|     1598|2017-02-04 14:10:13.000|2017-02-13 13:57:51.000|199.90|        18.14|     2025-12-03|
00042b26cf59d7ce69dfabb4e55b4fd9|            1|     113718|      8869|     1598|2017-02-04 14:10:13.000|2017-02-13 13:57:51.000|199.90|        18.14|     2025-12-03|
00048cc3ae777c65dbb7d2a0634bc1ea|            1|     150864|      3942|      660|2017-05-17 03:55:27.000|2017-05-23 03:55:27.000| 21.90|        12.69|     2025-12-03|
00048cc3ae777c65dbb7d2a0634bc1ea|            1|     150864|      3942|      660|2017-05-17 03:55:27.000|2017-05-23 03:55:27.000| 21.90|        12.69|     2025-12-03|
00048cc3ae777c65dbb7d2a0634bc1ea|            1|     150864|      3942|      660|2017-05-17 03:55:27.000|2017-05-23 03:55:27.000| 21.90|        12.69|     2025-12-03|
00054e8431b9d7675808bcb819fb4a32|            1|     112269|     22300|     2974|2017-12-10 12:10:31.000|2017-12-14 12:10:31.000| 19.90|        11.85|     2025-12-03|
00054e8431b9d7675808bcb819fb4a32|            1|     112269|     22300|     2974|2017-12-10 12:10:31.000|2017-12-14 12:10:31.000| 19.90|        11.85|     2025-12-03|
00054e8431b9d7675808bcb819fb4a32|            1|     112269|     22300|     2974|2017-12-10 12:10:31.000|2017-12-14 12:10:31.000| 19.90|        11.85|     2025-12-03|
000576fe39319847cbb9d288c5617fa6|            1|     285594|      6978|      692|2018-07-05 16:35:48.000|2018-07-10 12:30:45.000|810.00|        70.75|     2025-12-03|
000576fe39319847cbb9d288c5617fa6|            1|     285594|      6978|      692|2018-07-05 16:35:48.000|2018-07-10 12:30:45.000|810.00|        70.75|     2025-12-03|
000576fe39319847cbb9d288c5617fa6|            1|     285594|      6978|      692|2018-07-05 16:35:48.000|2018-07-10 12:30:45.000|810.00|        70.75|     2025-12-03|
0005a1a1728c9d785b8e2b08b904576c|            1|     112554|      2714|       68|2018-03-20 18:35:21.000|2018-03-26 18:31:29.000|145.95|        11.65|     2025-12-03|
0005a1a1728c9d785b8e2b08b904576c|            1|     112554|      2714|       68|2018-03-20 18:35:21.000|2018-03-26 18:31:29.000|145.95|        11.65|     2025-12-03|
0005a1a1728c9d785b8e2b08b904576c|            1|     112554|      2714|       68|2018-03-20 18:35:21.000|2018-03-26 18:31:29.000|145.95|        11.65|     2025-12-03|
0005f50442cb953dcd1d21e1fb923495|            1|       8526|     28257|     1158|2018-07-02 14:10:56.000|2018-07-06 14:10:56.000| 53.99|        11.40|     2025-12-03|
0005f50442cb953dcd1d21e1fb923495|            1|       8526|     28257|     1158|2018-07-02 14:10:56.000|2018-07-06 14:10:56.000| 53.99|        11.40|     2025-12-03|
0005f50442cb953dcd1d21e1fb923495|            1|       8526|     28257|     1158|2018-07-02 14:10:56.000|2018-07-06 14:10:56.000| 53.99|        11.40|     2025-12-03|
```

### 3.3. Делаем insert в факт

Теперь заворачиваем `select` в `insert`:

```sql
-- 1. init-load факта позиций заказов

truncate table core.fct_order_items restart identity;

with oi as (
    select
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        oi.shipping_limit_date,
        oi.price,
        oi.freight_value,
        oi.ingest_date as oi_ingest_date
    from stg.order_items oi
),
o as (
    select
        o.order_id,
        o.customer_id,
        o.order_approved_at
    from stg.orders o
),
cust as (
    select
        c.customer_id,
        c.customer_unique_id
    from stg.customers c
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
    oi.oi_ingest_date as src_ingest_date,
    now()                  as load_dttm
from oi
join o     on oi.order_id   = o.order_id
left join cust on o.customer_id = cust.customer_id
left join dc   on cust.customer_unique_id = dc.customer_unique_id
left join p    on oi.product_id = p.product_id
left join s    on oi.seller_id  = s.seller_id;
```

> Если возникла ошибка: `duplicate key value violates unique constraint ux_fct_order_items_bk`
> — значит, в источнике для факта после JOIN’ов получаются дубли по (order_id, order_item_id).

Тут может быть несколько причин:
- в STG есть несколько версий одной бизнес-строки по ingest_date
- при join’ах без дедупликации размножаются строки и нарушается grain факта

Сделаем мини - проверку:

```sql
-- сколько строк получится в источнике на один бизнес-ключ?
with src as (
  select oi.order_id, oi.order_item_id
  from stg.order_items oi
  join stg.orders o on oi.order_id = o.order_id
  left join stg.customers c on o.customer_id = c.customer_id
)
select order_id, order_item_id, count(*) as cnt
from src
group by 1,2
having count(*) > 1
order by cnt desc
limit 20;
```

Результат:
```text
order_id                        |order_item_id|cnt|
--------------------------------+-------------+---+
00018f77f2f0320c557190d7a144bdd3|            1|  3|
000229ec398224ef6ca0657da4fc703e|            1|  3|
00024acbcdf0a6daa1e931b038114c75|            1|  3|
00042b26cf59d7ce69dfabb4e55b4fd9|            1|  3|
00048cc3ae777c65dbb7d2a0634bc1ea|            1|  3|
00054e8431b9d7675808bcb819fb4a32|            1|  3|
000576fe39319847cbb9d288c5617fa6|            1|  3|
0005a1a1728c9d785b8e2b08b904576c|            1|  3|
0005f50442cb953dcd1d21e1fb923495|            1|  3|
00061f2a7bc09da83e415a52dc8a4af1|            1|  3|
00063b381e2406b52ad429470734ebd5|            1|  3|
0006ec9db01a64e59a68b2c340bf65a7|            1|  3|
0008288aa423d2a3f00fcb17cd7d8719|            1|  3|
0008288aa423d2a3f00fcb17cd7d8719|            2|  3|
0009792311464db532ff765bf7b182ae|            1|  3|
0009c9a17f916a706d71784483a5d643|            1|  3|
000aed2e25dbad2f9ddb70584c5a2ded|            1|  3|
000c3e6612759851cc3cbb4b83257986|            1|  3|
000e562887b1f2006d75e0be9558292e|            1|  3|
00010242fe8c5a6d1ba2dd792cb16214|            1|  3|
```

Исправим загрузку, чтобы на вход факта приходила ровно одна строка на grain.

1. stg.order_items → partition by (order_id, order_item_id)
    STG: order_items (grain = (order_id, order_item_id)). 
    В stg.order_items могут быть дубли одного и того же BK, потому что загрузили несколько ingest_date. Берём самую свежую версию строки по ingest_date.
    ```sql
        oi as (
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
    ```
2. stg.orders → partition by order_id
    STG: orders (grain = order_id). Если stg.orders тоже инкрементом (несколько ingest_date), то order_id может повторяться. 
    Тоже берём последнюю версию.
    ```sql
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
    ```
3. stg.customers → partition by customer_id
    STG: customers (grain = customer_id). В stg.customers у нас 3 записи на customer_id (батчи). Берём актуальную связку 
    customer_id -> customer_unique_id.
    ```sql
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
   ```

Итоговый скрип:

```sql
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
```

### 3.4. Базовые проверки

1. **Количество строк vs STG.** В идеале количество строк в факте = количеству строк в `stg.order_items`.

```sql
select count(*) as stg_cnt
from stg.order_items;
```

Результат:
```text
stg_cnt|
-------+
 112650|
```

```sql
select count(*) as fct_cnt
from core.fct_order_items;
```

Результат:
```text
fct_cnt|
-------+
 112650|
```

2. **Сумма по выручке и доставке.**

В STG:

```sql
select
   sum(price)        as total_price,
   sum(freight_value) as total_freight
from stg.order_items;
```

Результат:
```text
total_price|total_freight|
-----------+-------------+
13591643.70|   2251909.54|
```

В CORE:
```sql
select
   sum(price)        as total_price,
   sum(freight_value) as total_freight
from core.fct_order_items;
```

Результат:
```text
total_price|total_freight|
-----------+-------------+
13591643.70|   2251909.54|
```

3. **Выборка нескольких строк с join’ами к измерениям.**

```sql
select
   f.order_id,
   f.order_item_id,
   dc.customer_city,
   dp.product_category_name,
   ds.seller_state,
   f.price,
   f.freight_value,
   f.order_approved_at
from core.fct_order_items f
join core.dim_customer dc on f.customer_sk = dc.customer_sk
join core.dim_product  dp on f.product_sk   = dp.product_sk
join core.dim_seller   ds on f.seller_sk    = ds.seller_sk
where dc.is_current
limit 20;
```

Результат:
```text
order_id                        |order_item_id|customer_city       |product_category_name      |seller_state|price  |freight_value|order_approved_at      |
--------------------------------+-------------+--------------------+---------------------------+------------+-------+-------------+-----------------------+
5f79b5b0931d63f1a42989eb65b9da6e|            1|osasco              |brinquedos                 |SP          |  89.80|        24.94|2017-11-14 16:35:32.000|
a44895d095d7e0702b6a162fa2dbeced|            1|itapecerica         |beleza_saude               |MG          |  54.90|        12.51|2017-07-16 09:55:12.000|
316a104623542e4d75189bb372bc5f8d|            1|nova venecia        |bebes                      |RJ          | 179.99|        15.43|2017-02-28 11:15:20.000|
5825ce2e88d5346438686b0bba99e5ee|            1|mendonca            |cool_stuff                 |SC          | 149.90|        29.45|2017-08-17 03:10:27.000|
0ab7fb08086d4af9141453c91878ed7a|            1|sao paulo           |cama_mesa_banho            |SP          |  93.00|        14.01|2018-04-04 03:10:19.000|
cd3558a10d854487b4f907e9b326a4fc|            1|valinhos            |esporte_lazer              |SP          |  59.99|        11.81|2017-04-12 08:50:12.000|
07f6c3baf9ac86865b60f640c4f923c6|            1|niteroi             |fashion_bolsas_e_acessorios|SP          |  34.30|        15.10|2018-03-03 14:10:38.000|
8c3d752c5c02227878fae49aeaddbfd7|            1|rio de janeiro      |brinquedos                 |RS          | 120.90|        45.69|2017-12-18 12:45:31.000|
fa906f338cee30a984d0945b3832e431|            1|ijui                |fashion_bolsas_e_acessorios|SP          |  69.99|        15.24|2017-09-17 16:15:13.000|
9b961b894e797f63622137ff7eb1c1af|            1|oliveira            |pet_shop                   |RS          |1107.00|       148.71|2018-08-11 12:25:08.000|
263ba12390d0fbce329dd16da8cd20f8|            1|sao paulo           |cama_mesa_banho            |SP          | 134.90|        12.43|2018-06-20 10:21:32.000|
c208db5638f7f1cd04d185856852f864|            1|sao paulo           |beleza_saude               |SP          |  47.99|        10.96|2017-03-15 23:44:09.000|
728416b0db65935dbf78a0cc03e8d6f8|            2|novo hamburgo       |ferramentas_jardim         |SP          |  49.90|        17.60|2018-02-08 07:49:51.000|
728416b0db65935dbf78a0cc03e8d6f8|            1|novo hamburgo       |ferramentas_jardim         |SP          |  49.90|        17.60|2018-02-08 07:49:51.000|
728416b0db65935dbf78a0cc03e8d6f8|            4|novo hamburgo       |ferramentas_jardim         |SP          |  49.90|        17.60|2018-02-08 07:49:51.000|
728416b0db65935dbf78a0cc03e8d6f8|            3|novo hamburgo       |ferramentas_jardim         |SP          |  49.90|        17.60|2018-02-08 07:49:51.000|
2346e1104a4b18a23e6dc6a87c2d1b8c|            1|vitoria da conquista|bebes                      |SP          |  89.90|        17.07|2017-09-02 02:50:58.000|
048beca6ccda094fb80bbc704d7c493d|            1|campinas            |ferramentas_jardim         |SP          | 159.90|        13.70|2017-04-28 13:45:15.000|
bc3e295306ee4d3eba91aca49b0bb539|            2|jacarei             |moveis_decoracao           |SP          |  15.00|         7.78|2017-10-11 07:56:17.000|
bc3e295306ee4d3eba91aca49b0bb539|            1|jacarei             |moveis_decoracao           |SP          |  15.00|         7.78|2017-10-11 07:56:17.000|
```

## 4. Добавим инкременты, high‑watermark, дедупликацию


### 4.1. Инкрементальная загрузка факта с high‑watermark

Идея:
- не пересобирать весь факт каждый раз;
- а брать только **новые заказы** (по времени события или по `ingest_date`).

> 💡 По-простому, high-watermark — это «последнее загруженное значение», от которого мы отталкиваемся при следующей загрузке.

Простой вариант — high‑watermark по `order_approved_at`:

```sql
-- последний загруженный заказ во факте
with last_loaded as (
    select coalesce(max(order_approved_at), timestamp '1900-01-01') as last_approved
    from core.fct_order_items
)
select *
from stg.orders o
join last_loaded l
  on o.order_approved_at > l.last_approved;
```

На основе `init-load`‑запроса надо сделать версию, которая:

- не трогает существующие строки факта;
- берёт только новые заказы (`order_approved_at > max(order_approved_at)` в факте);
- вставляет новые позиции заказов в `fct_order_items`.

Выберем watermark по `src_ingest_date` (даты батча в STG).

Скрипт модифицируется следующим образом:
```sql
-- Инкрементальная загрузка core.fct_order_items по src_ingest_date

with last_loaded as (
    -- Определяем последнюю загруженную дату ингреста
    select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
    from core.fct_order_items
),
new_data as (
    -- Все новые записи из стейджинга
    select
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
```

High-watermark по src_ingest_date:

✅ Плюсы:
1. Гарантирует загрузку всех данных из новых батчей.
2. Не пропустит обновления/исправления в старых заказах (если они приходят с новым ingest_date).
3. Проще отлаживать (знаем, какой батч загружен). 
4. Соответствует паттерну "batch processing".

❌ Минусы:
1. Может загрузить обновления старых заказов, которые уже есть в факте (нужна проверка на дубликаты)

### 4.2. Дедупликация по бизнес‑ключу

В реальном мире бывают дубль‑строки в `stg.order_items`:
- повторная загрузка без паттерна `delete+insert`;
- баг в исходной системе;
- ручные исправления.

Проверим наличие дублей:

```sql
select
    order_id,
    order_item_id,
    count(*) as cnt
from core.fct_order_items
group by order_id, order_item_id
having count(*) > 1;
```

Результат:
```text
order_id|order_item_id|cnt|
--------+-------------+---+
```

Можно предусмотреть фильтрацию по первой строке.

Если в stg.order_items есть несколько версий одного заказа (например, с ingest_date = '2024-01-01' и '2024-01-02'),
выберем только одну (последнюю по дате) еще до присоединения других таблиц.

Модифицированная версия скрипта для инкрементальной загрузки:

```sql
-- Инкрементальная загрузка core.fct_order_items по src_ingest_date с защитой от дублей

with last_loaded as (
    -- Определяем последнюю загруженную дату ингреста
    select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
    from core.fct_order_items
),
new_data as (
    select
        oi.order_id,
        oi.order_item_id,
        oi.product_id,
        oi.seller_id,
        oi.shipping_limit_date,
        oi.price,
        oi.freight_value,
        oi.ingest_date as src_ingest_date,
        o.order_approved_at,
        o.customer_id,
        row_number() over (
            partition by oi.order_id, oi.order_item_id
            order by oi.ingest_date desc
        ) as rn
    from stg.order_items oi
    join (
        -- Дедупликация orders (берем последнюю версию каждого заказа)
        select distinct on (order_id) 
            order_id,
            customer_id,
            order_approved_at,
            ingest_date
        from stg.orders
        where ingest_date > (select last_ingest_date from last_loaded)
        order by order_id, ingest_date desc
    ) o on oi.order_id = o.order_id
    where oi.ingest_date > (select last_ingest_date from last_loaded)
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
        where c.ingest_date <= (select max(src_ingest_date) from new_data)
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
where 
    nd.rn = 1  -- только последняя версия каждой позиции
    and not exists (  -- защита от повторной вставки
        select 1 
        from core.fct_order_items f 
        where f.order_id = nd.order_id 
          and f.order_item_id = nd.order_item_id
    );
```

### 4.3. Простые витрины поверх факта

### 4.3.1. **Продажи по категориям товаров за месяц:**

```sql
select
   date_trunc('month', f.order_approved_at)::date as month,
   dp.product_category_name,
   sum(f.price) as gmv
from core.fct_order_items f
join core.dim_product dp on f.product_sk = dp.product_sk
group by month, dp.product_category_name
order by month, gmv desc
limit 50;
```

Результат:
```text
month     |product_category_name        |gmv    |
----------+-----------------------------+-------+
2016-09-01|beleza_saude                 | 134.97|
2016-10-01|moveis_decoracao             |5880.78|
2016-10-01|perfumaria                   |5688.70|
2016-10-01|beleza_saude                 |4552.51|
2016-10-01|brinquedos                   |4465.09|
2016-10-01|consoles_games               |3882.26|
2016-10-01|relogios_presentes           |3360.24|
2016-10-01|esporte_lazer                |3333.64|
2016-10-01|automotivo                   |1833.25|
2016-10-01|climatizacao                 |1707.09|
2016-10-01|bebes                        |1630.16|
2016-10-01|informatica_acessorios       |1399.32|
2016-10-01|ferramentas_jardim           |1359.88|
2016-10-01|eletronicos                  |1306.99|
2016-10-01|market_place                 |1306.19|
2016-10-01|moveis_escritorio            |1300.88|
2016-10-01|utilidades_domesticas        |1287.07|
2016-10-01|cool_stuff                   |1111.00|
2016-10-01|telefonia_fixa               | 704.88|
2016-10-01|pet_shop                     | 689.68|
2016-10-01|telefonia                    | 559.58|
2016-10-01|fashion_bolsas_e_acessorios  | 508.30|
2016-10-01|cama_mesa_banho              | 478.99|
2016-10-01|industria_comercio_e_negocios| 359.60|
2016-10-01|livros_tecnicos              | 267.00|
2016-10-01|audio                        | 156.99|
2016-10-01|fraldas_higiene              | 134.90|
2016-10-01|livros_interesse_geral       | 119.50|
2016-10-01|alimentos                    |  79.90|
2016-10-01|                             |  65.89|
```

### 4.3.2. **Топ‑продавцы по выручке:**

```sql
select
   ds.seller_id,
   ds.seller_state,
   sum(f.price) as gmv
from core.fct_order_items f
join core.dim_seller ds on f.seller_sk = ds.seller_sk
group by ds.seller_id, ds.seller_state
order by gmv desc
limit 20;
```

Результат:
```text
seller_id                       |seller_state|gmv      |
--------------------------------+------------+---------+
4869f7a5dfa277a7dca6462dcf3b52b2|SP          |229472.63|
53243585a1d6dc2643021fd1853d8905|BA          |222776.05|
4a3ca9315b744ce9f8e9374361493884|SP          |200472.92|
fa1c13f2614d7b5c4749cbc52fecda94|SP          |194042.03|
7c67e1448b00f6e969d365cea6b010ab|SP          |187923.89|
7e93a43ef30c4f03f38b393420bc753a|SP          |176431.87|
da8622b14eb17ae2831f4ac5b9dab84a|SP          |160236.57|
7a67c85e85bb2ce8582c35f2203ad736|SP          |141745.53|
1025f0e2d44d7041d6cf58b6550e0bfa|SP          |138968.55|
955fee9216a65b617aa5c0531780ce60|SP          |135171.70|
46dc3b2cc0980fb8ec44634e21d2718e|RJ          |128111.19|
6560211a19b47992c3666cc44a7e94c0|SP          |123304.83|
620c87c171fb2a6dd6e8bb4dec959fc6|RJ          |114774.50|
7d13fca15225358621be4086e1eb0964|SP          |113628.97|
5dceca129747e92ff8ef7a997dc4f8ca|SP          |112155.53|
1f50f920176fa81dab994f9023523100|SP          |106939.21|
cc419e0650a3c5ba77189a1882b7556a|SP          |104288.42|
a1043bafd471dff536d0c462352beb48|MG          |101901.16|
3d871de0142ce09b7081e2b9d1733cb1|SP          | 94914.20|
edb1ef5e36e0c8cd84eb3c9b003e486d|RJ          | 79284.55|
```

### 4.3.3. **Профиль выручки по городам клиентов (текущая версия):**

```sql
select
   dc.customer_city,
   dc.customer_state,
   sum(f.price) as gmv
from core.fct_order_items f
join core.dim_customer dc on f.customer_sk = dc.customer_sk
where dc.is_current
group by dc.customer_city, dc.customer_state
order by gmv desc
limit 30;
```

Результат:
```sql
customer_city        |customer_state|gmv       |
---------------------+--------------+----------+
sao paulo            |SP            |1924221.10|
rio de janeiro       |RJ            | 970904.99|
belo horizonte       |MG            | 354081.23|
brasilia             |DF            | 303709.59|
curitiba             |PR            | 212342.95|
porto alegre         |RS            | 189346.24|
campinas             |SP            | 184218.50|
salvador             |BA            | 179596.91|
guarulhos            |SP            | 145099.05|
niteroi              |RJ            | 116523.62|
goiania              |GO            | 108620.26|
sao bernardo do campo|SP            | 103075.43|
fortaleza            |CE            |  98358.56|
santos               |SP            |  98318.58|
recife               |PE            |  91134.50|
santo andre          |SP            |  88618.68|
florianopolis        |SC            |  82643.21|
osasco               |SP            |  81851.10|
sao jose dos campos  |SP            |  78649.98|
belem                |PA            |  77269.10|
sorocaba             |SP            |  76365.91|
jundiai              |SP            |  74907.98|
ribeirao preto       |SP            |  66433.14|
juiz de fora         |MG            |  64177.17|
nova iguacu          |RJ            |  59920.93|
sao goncalo          |RJ            |  55097.10|
campo grande         |MS            |  54852.83|
piracicaba           |SP            |  52961.45|
joao pessoa          |PB            |  52793.92|
vitoria              |ES            |  52724.10|
```
