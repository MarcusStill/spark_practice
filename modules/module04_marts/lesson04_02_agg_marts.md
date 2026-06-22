# Урок 4.2 — Агрегатная витрина `marts.sales_daily`: дневные продажи (Postgres)

В этом уроке поверх витрины `marts.fct_order_items_wide` собираем первую агрегатную витрину — **дневные продажи**.

## Цели урока

- зафиксировать контракт и grain витрины `marts.sales_daily`;
- построить `marts.sales_daily` в Postgres (вариант по умолчанию);
- сделать минимальные sanity-чеки: дубли по ключам, сверка количества строк, reconcile по выручке и быстрый top-N.

## Контракт витрины `marts.sales_daily`

### Grain

**1 строка = 1 день + 1 категория товара + 1 штат клиента**

Ключ витрины (PK):

- `sales_date`
- `product_category_name`
- `customer_state`

### Поля

Ключи (grain):

- `sales_date` — дата продаж (из `wide.order_date`)
- `product_category_name` — категория товара (из wide, через `coalesce → 'unknown'`)
- `customer_state` — штат клиента (из wide, через `coalesce → 'unknown'`)

Метрики:

- `orders_cnt` — число заказов (`count(distinct order_id)`)
- `items_cnt` — число позиций (`count(*)`)
- `items_revenue` — `sum(price)`
- `freight_revenue` — `sum(freight_value)`
- `total_revenue` — `sum(price + freight_value)`
- `uniq_customers_cnt` — `count(distinct customer_sk)`
- `uniq_sellers_cnt` — `count(distinct seller_sk)`

Технические поля:

- `src_ingest_date` — batch id расчёта витрины (в модуле 4 руками, в модуле 7 параметром `ingest_date`)
- `load_dttm` — timestamp построения витрины

---

## Что сделаем

1) Создадим таблицу `marts.sales_daily` (DDL + индексы).  
2) Заполним витрину full refresh (truncate + insert) **в транзакции**.  
3) Прогони sanity-чеки и одну аналитическую выборку.

---

## Задание (шаги)

### Шаг 1. Готовим рабочий файл

```text
db/work/m4_02_build_sales_daily.sql
```

### Шаг 2. DDL: таблица витрины

```sql
create schema if not exists marts;

create table if not exists marts.sales_daily (
    -- grain keys
    sales_date             date        not null,
    product_category_name  varchar     not null,
    customer_state         varchar     not null,

    -- metrics
    orders_cnt             bigint      not null,
    items_cnt              bigint      not null,
    items_revenue          numeric     not null,
    freight_revenue        numeric     not null,
    total_revenue          numeric     not null,
    uniq_customers_cnt     bigint      not null,
    uniq_sellers_cnt       bigint      not null,

    -- tech
    src_ingest_date        date,
    load_dttm              timestamptz default now(),

    constraint pk_sales_daily primary key (sales_date, product_category_name, customer_state)
);

create index if not exists ix_sales_daily_date
    on marts.sales_daily (sales_date);

create index if not exists ix_sales_daily_state
    on marts.sales_daily (customer_state);

create index if not exists ix_sales_daily_revenue
    on marts.sales_daily (total_revenue);
```

### Шаг 3. Загрузка витрины (full refresh, атомарно)

```sql
begin;

truncate table marts.sales_daily;

insert into marts.sales_daily (
    sales_date,
    product_category_name,
    customer_state,
    orders_cnt,
    items_cnt,
    items_revenue,
    freight_revenue,
    total_revenue,
    uniq_customers_cnt,
    uniq_sellers_cnt,
    src_ingest_date,
    load_dttm
)
select
    w.order_date                                         as sales_date,
    coalesce(w.product_category_name, 'unknown')         as product_category_name,
    coalesce(w.customer_state, 'unknown')                as customer_state,

    count(distinct w.order_id)                           as orders_cnt,
    count(*)                                             as items_cnt,

    coalesce(sum(coalesce(w.price, 0)), 0)               as items_revenue,
    coalesce(sum(coalesce(w.freight_value, 0)), 0)       as freight_revenue,
    coalesce(sum(coalesce(w.price, 0) + coalesce(w.freight_value, 0)), 0) as total_revenue,

    count(distinct w.customer_sk)                        as uniq_customers_cnt,
    count(distinct w.seller_sk)                          as uniq_sellers_cnt,

    '2025-12-03'::date                               as src_ingest_date,
    now()                                                as load_dttm
from marts.fct_order_items_wide w
where w.order_date is not null
group by
    w.order_date,
    coalesce(w.product_category_name, 'unknown'),
    coalesce(w.customer_state, 'unknown');

commit;
```

## Sanity-чеки (минимальный DQ-набор)

### Чек 1: нет дублей по ключам

```sql
select
  count(*) as total_rows,
  count(distinct (sales_date, product_category_name, customer_state)) as distinct_keys
from marts.sales_daily;
```

Результат:
```text
total_rows|distinct_keys|
----------+-------------+
     56302|        56302|
```

Верно: `total_rows == distinct_keys`.


### Чек 2: “сошлось” количество позиций

Сумма `items_cnt` по агрегату должна совпадать с количеством строк в wide (после фильтра `order_date is not null`).

```sql
select
  (select count(*) from marts.fct_order_items_wide where order_date is not null) as wide_rows,
  (select sum(items_cnt) from marts.sales_daily)                                 as agg_items_cnt_sum;
```

Результат:
```text
wide_rows|sum   |
---------+------+
   112635|112635|
```

Верно: `wide_rows == agg_items_cnt_sum`.

### Чек 3: reconcile по выручке

```sql
with wide_sum as (
  select coalesce(sum(coalesce(price,0) + coalesce(freight_value,0)), 0) as wide_rev
  from marts.fct_order_items_wide
  where order_date is not null
    and src_ingest_date = '2025-12-03'::date
),
daily_sum as (
  select coalesce(sum(total_revenue), 0) as daily_rev
  from marts.sales_daily
  where src_ingest_date = '2025-12-03'::date
)
select wide_rev, daily_rev, (wide_rev - daily_rev) as diff
from wide_sum cross join daily_sum;
```

Результат:
```text
wide_rev   |daily_rev  |diff|
-----------+-----------+----+
15841598.64|15841598.64|0.00|
```

### Чек 4: batch id витрины должен быть один

```sql
select src_ingest_date, count(*) as rows_cnt
from marts.sales_daily
group by 1
order by 1;
```

Результат:
```text
src_ingest_date|rows_cnt|
---------------+--------+
     2025-12-03|   56302|
```

Верно: ровно одна строка и дата = `2025-12-03`.

### Чек 5: сколько у нас `unknown` категории и штата

```sql
select
  sum(items_cnt)     as unknown_items_cnt,
  sum(total_revenue) as unknown_revenue
from marts.sales_daily
where product_category_name = 'unknown'
   or customer_state = 'unknown';
```

Результат:
```text
unknown_items_cnt|unknown_revenue|
-----------------+---------------+
             1602|      207639.57|
```

### Чек 6: топ-10 дней по выручке

```sql
select
  sales_date,
  sum(total_revenue) as total_revenue
from marts.sales_daily
group by sales_date
order by total_revenue desc
limit 10;
```

Результат:
```text
sales_date|total_revenue|
----------+-------------+
2018-04-24|    155507.67|
2017-11-24|    122337.78|
2018-07-05|    111908.21|
2017-11-25|    111116.59|
2017-11-28|     76242.36|
2018-05-08|     69380.68|
2018-08-20|     68490.20|
2018-08-07|     66378.29|
2018-05-18|     66373.75|
2018-07-24|     64922.92|
```

## Spark-вариант

### Шаг 1. Пересозданим таблицу
```sql
drop table if exists marts.sales_daily cascade;
create table if not exists marts.sales_daily (
    -- grain keys
    sales_date             date        not null,
    product_category_name  varchar     not null,
    customer_state         varchar     not null,

    -- metrics
    orders_cnt             bigint      not null,
    items_cnt              bigint      not null,
    items_revenue          numeric     not null,
    freight_revenue        numeric     not null,
    total_revenue          numeric     not null,
    uniq_customers_cnt     bigint      not null,
    uniq_sellers_cnt       bigint      not null,

    -- tech
    src_ingest_date        date,
    load_dttm              timestamptz default now(),

    constraint pk_sales_daily primary key (sales_date, product_category_name, customer_state)
);

create index if not exists ix_sales_daily_date
    on marts.sales_daily (sales_date);

create index if not exists ix_sales_daily_state
    on marts.sales_daily (customer_state);

create index if not exists ix_sales_daily_revenue
    on marts.sales_daily (total_revenue);
```

### Шаг 2. Создадим файл .ipynb

```text
db/work/m4_02_build_sales_daily.sql
```

### Шаг 3. Чтение wide из Postgres (JDBC)

```python
import os
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

spark = (
    SparkSession.builder
    .appName("m4_02_sales_daily")
    .getOrCreate()
)

JDBC_URL = (
    f"jdbc:postgresql://{os.getenv('PGHOST','postgres')}:{os.getenv('PGPORT','5432')}/"
    f"{os.getenv('PGDATABASE','dwh')}"
)

wide = (
    spark.read.format("jdbc")
    .option("url", JDBC_URL)
    .option("dbtable", "marts.fct_order_items_wide")
    .option("user", os.getenv("PGUSER","app"))
    .option("password", os.getenv("PGPASSWORD","app"))
    .option("driver", "org.postgresql.Driver")
    .load()
)
```

### 2) Агрегация в Spark

```python
INGEST_DATE = "2025-12-03"

sales_daily_df = (
    wide
    .filter(F.col("order_date").isNotNull())
    .withColumn("product_category_name", F.coalesce(F.col("product_category_name"), F.lit("unknown")))
    .withColumn("customer_state", F.coalesce(F.col("customer_state"), F.lit("unknown")))
    .groupBy(
        F.col("order_date").alias("sales_date"),
        F.col("product_category_name"),
        F.col("customer_state"),
    )
    .agg(
        F.countDistinct("order_id").alias("orders_cnt"),
        F.count(F.lit(1)).alias("items_cnt"),
        F.coalesce(F.sum("price"), F.lit(0)).alias("items_revenue"),
        F.coalesce(F.sum("freight_value"), F.lit(0)).alias("freight_revenue"),
        F.coalesce(F.sum(F.col("price") + F.col("freight_value")), F.lit(0)).alias("total_revenue"),
        F.countDistinct("customer_sk").alias("uniq_customers_cnt"),
        F.countDistinct("seller_sk").alias("uniq_sellers_cnt"),
    )
    .withColumn("src_ingest_date", F.lit(INGEST_DATE).cast("date"))
    .withColumn("load_dttm", F.current_timestamp())
)
```

### 3) Запись в Postgres

```python
# в Postgres перед записью:
# begin; truncate table marts.sales_daily; commit;

(
    sales_daily_df
    .write
    .mode("append")
    .format("jdbc")
    .option("url", JDBC_URL)
    .option("dbtable", "marts.sales_daily")
    .option("user", os.getenv("PGUSER","app"))
    .option("password", os.getenv("PGPASSWORD","app"))
    .option("driver", "org.postgresql.Driver")
    .save()
)
```

Результат:
```text
+-------------+--------------------------------+-------------+-----------+----------+---------+-------------------+----------+-------------------+----------------------+---------------------+---------------------+---------------------+------------+-------------+--------------+---------------+-------------------------+
|order_item_sk|order_id                        |order_item_id|customer_sk|product_sk|seller_sk|order_approved_at  |order_date|shipping_limit_date|price                 |freight_value        |product_category_name|seller_city          |seller_state|customer_city|customer_state|src_ingest_date|load_dttm                |
+-------------+--------------------------------+-------------+-----------+----------+---------+-------------------+----------+-------------------+----------------------+---------------------+---------------------+---------------------+------------+-------------+--------------+---------------+-------------------------+
|11           |263ba12390d0fbce329dd16da8cd20f8|1            |110115     |12858     |1874     |2018-06-20 10:21:32|2018-06-20|2018-06-22 10:21:32|134.900000000000000000|12.430000000000000000|cama_mesa_banho      |piracicaba           |SP          |sao paulo    |SP            |2025-12-03     |2026-04-20 13:50:24.47621|
|13           |728416b0db65935dbf78a0cc03e8d6f8|2            |24036      |4601      |475      |2018-02-08 07:49:51|2018-02-08|2018-02-14 07:49:51|49.900000000000000000 |17.600000000000000000|ferramentas_jardim   |sao jose do rio preto|SP          |novo hamburgo|RS            |2025-12-03     |2026-04-20 13:50:24.47621|
|14           |728416b0db65935dbf78a0cc03e8d6f8|1            |24036      |4601      |475      |2018-02-08 07:49:51|2018-02-08|2018-02-14 07:49:51|49.900000000000000000 |17.600000000000000000|ferramentas_jardim   |sao jose do rio preto|SP          |novo hamburgo|RS            |2025-12-03     |2026-04-20 13:50:24.47621|
|15           |728416b0db65935dbf78a0cc03e8d6f8|4            |24036      |4601      |475      |2018-02-08 07:49:51|2018-02-08|2018-02-14 07:49:51|49.900000000000000000 |17.600000000000000000|ferramentas_jardim   |sao jose do rio preto|SP          |novo hamburgo|RS            |2025-12-03     |2026-04-20 13:50:24.47621|
|16           |728416b0db65935dbf78a0cc03e8d6f8|3            |24036      |4601      |475      |2018-02-08 07:49:51|2018-02-08|2018-02-14 07:49:51|49.900000000000000000 |17.600000000000000000|ferramentas_jardim   |sao jose do rio preto|SP          |novo hamburgo|RS            |2025-12-03     |2026-04-20 13:50:24.47621|
|19           |bc3e295306ee4d3eba91aca49b0bb539|2            |31515      |28576     |2063     |2017-10-11 07:56:17|2017-10-11|2017-10-18 08:56:17|15.000000000000000000 |7.780000000000000000 |moveis_decoracao     |sao paulo            |SP          |jacarei      |SP            |2025-12-03     |2026-04-20 13:50:24.47621|
|20           |bc3e295306ee4d3eba91aca49b0bb539|1            |31515      |28576     |2063     |2017-10-11 07:56:17|2017-10-11|2017-10-18 08:56:17|15.000000000000000000 |7.780000000000000000 |moveis_decoracao     |sao paulo            |SP          |jacarei      |SP            |2025-12-03     |2026-04-20 13:50:24.47621|
|26           |9974509c32cb0fbfa567244ba1c29a64|1            |114522     |24964     |2997     |2018-01-14 20:38:23|2018-01-14|2018-01-18 20:38:23|83.990000000000000000 |16.350000000000000000|cama_mesa_banho      |ibitinga             |SP          |uberlandia   |MG            |2025-12-03     |2026-04-20 13:50:24.47621|
|31           |e4606fed871d036cbc9acbbd4e3282f1|1            |7653       |31828     |1581     |2018-01-08 02:47:54|2018-01-08|2018-01-12 02:47:54|149.900000000000000000|12.250000000000000000|esporte_lazer        |sao paulo - sp       |SP          |sao paulo    |SP            |2025-12-03     |2026-04-20 13:50:24.47621|
|32           |4ed7a5d31f58c9c3b20a61e3927db6d9|1            |57981      |25        |1816     |2018-05-08 21:11:37|2018-05-08|2018-05-13 21:11:37|79.900000000000000000 |12.700000000000000000|moveis_decoracao     |curitiba             |PR          |sao paulo    |SP            |2025-12-03     |2026-04-20 13:50:24.47621|
+-------------+--------------------------------+-------------+-----------+----------+---------+-------------------+----------+-------------------+----------------------+---------------------+---------------------+---------------------+------------+-------------+--------------+---------------+-------------------------+
only showing top 10 rows
```
