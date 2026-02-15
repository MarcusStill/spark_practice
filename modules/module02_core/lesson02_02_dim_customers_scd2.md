# Урок 2.1 - `core.dim_customer` как SCD2: история адресов клиента

## Цели урока

- описываем DDL для `core.dim_customer` как SCD2-измерения;
- делаем первый init-load из `stg.customers` в `core.dim_customer` по всем батчам;
- дописываем инкрементальный загрузчик.

## 1. Готовим историю в `stg.customers`: три батча

Чтобы `core.dim_customer` как SCD2 было **интересно смотреть**, в `stg.customers` должна быть история:

- **первый батч** — исходный снимок клиентов;
- **второй батч** — часть клиентов переехала;
- **третий батч** — кто‑то переехал ещё раз, плюс новые клиенты.

В репозитории есть три CSV для `customers`:

1. `data/csv/olist_customers_dataset.csv` — базовый снимок (использовали его в модуле 1).
2. `data/csv2/olist_customers_dataset_v2.csv` — вторая версия (часть клиентов переехала).
3. `data/csv2/olist_customers_dataset_v3.csv` — третья версия (ещё переезды).

### 1.1. Какие `ingest_date` использовать

Я буду опираться на такие даты (можешь взять свои, если сильно хочется):

- **ING1** — первый батч: `2025-12-03` (`data/raw/olist/customers/ingest_date=2025-12-03/olist_customers_dataset.csv`);
- **ING2** — второй батч: `2025-12-10`;
- **ING3** — третий батч: `2025-12-20`.

Важно только одно: `ING2` и `ING3` должны быть **строго больше** `ING1`, и между собой отличаться.

Можно проверить, какой `ingest_date` у нас уже есть в STG:

```sql
select ingest_date, count(*) as rows_cnt
from stg.customers
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|rows_cnt|
-----------+--------+
 2025-12-03|   99441|
```

### 1.2. Складываем v2 и v3 в RAW

Для `ING1` уже всё сделано в модуле 1:  
`data/raw/olist/customers/ingest_date=ING1/olist_customers_dataset.csv`.

Для новых батчей сделаем так:

1. Создадим папку для второго батча (ING2):

```bash
mkdir -p data/raw/olist/customers/ingest_date=2025-12-10
```

2. Скопируем туда файл v2 **с переименованием** в базовое имя:

```bash
cp data/csv2/olist_customers_dataset_v2.csv data/raw/olist/customers/ingest_date=2025-12-10/olist_customers_dataset.csv
```

3. Аналогично для третьего батча (ING3):

```bash
mkdir -p data/raw/olist/customers/ingest_date=2025-12-20

cp data/csv2/olist_customers_dataset_v3.csv data/raw/olist/customers/ingest_date=2025-12-20/olist_customers_dataset.csv
```
Здесь я использую те же даты, что и выше: ING2 = `2025-12-10`, ING3 = `2025-12-20`.

Почему так:
- скрипт загрузки `customers` в STG у нас уже написан в модуле 1;
- он ожидает путь вида  
  `/data/raw/olist/customers/ingest_date=<ING>/olist_customers_dataset.csv`;
- мы не ломаем шаблон: просто кладём туда другие версии файла (`v2`, `v3`) с тем же именем.


### 1.3. Грузим v2 и v3 в STG тем же скриптом, что и в модуле 1


В модуле 1 было подобное:

```sql
delete from stg.customers
 where ingest_date = date '2025-11-11';

\copy stg._customers_load (...) from '/data/raw/olist/customers/ingest_date=2025-11-11/olist_customers_dataset.csv' csv header

insert into stg.customers (..., ingest_date)
select ..., date '2025-11-11'
from stg._customers_load;
```

Для второго и третьего батча:

* Сделаем новый скрипт

```text
db/work/module02/m2_customers_load.sql
```

* Во всех местах, где у записана дата `2025-11-11`, подставляем:

  - для ING2:  
    `date '2025-12-10'`  
    и путь `.../ingest_date=2025-12-10/olist_customers_dataset.csv`;

  - для ING3:  
    `date '2025-12-20'`  
    и путь `.../ingest_date=2025-12-20/olist_customers_dataset.csv`.

* Запускаем такой файл отдельно для ING2 и затем для ING3.


Паттерн остаётся тем же: **буфер → \copy → delete+insert по ingest_date.**

После двух дополнительных прогонов в `stg.customers` должны быть минимум три `ingest_date`:

```sql
select ingest_date, count(*) as rows_cnt
from stg.customers
group by ingest_date
order by ingest_date;
```

Результат:
```text
ingest_date|rows_cnt|
-----------+--------+
 2025-12-03|   99441|
 2025-12-10|  100941|
 2025-12-20|  102941|
```

Теперь история для SCD2 подготовлена.

## 2. Дизайн `core.dim_customer` как SCD2-измерения

Теперь, когда `stg.customers` хранит несколько снимков клиентов, можно спроектировать SCD2-таблицу в CORE.

### 2.1. Какие поля нам нужны

Разложим структуру на группы.

**Ключи и атрибуты клиента:**

- `customer_sk` — `bigserial`, surrogate key, primary key;
- `customer_unique_id` — бизнес-ключ, по нему мы склеиваем историю;
- `customer_zip_code_prefix` — индекс (по желанию);
- `customer_city` — город клиента;
- `customer_state` — регион/штат.

**Поля «жизни версии» (SCD2):**

- `effective_from` — с какой даты версия актуальна;
- `effective_to`   — по какую дату включительно версия актуальна;
- `is_current`     — флаг текущей версии (true/false).

**Технические поля CORE:**

- `src_ingest_date` — из какого `ingest_date` из STG мы получили эту версию;
- `load_dttm`       — когда строка была загружена в CORE.

> В бою обычно `effective_from` привязывают к **бизнес-событию** (`address_changed_at`), а `ingest_date` используют как тех.дату загрузки.  
> В учебном стенде Olist мы честно признаём: event time нет, поэтому берём `ingest_date`.

### 2.2. DDL для `core.dim_customer`

Создаем новый файл:

```text
db/work/module02/m2_dim_customers_scd2.sql
```

Со следующей структурой:

```sql
-- SCD2-измерение клиентов
create table if not exists core.dim_customer (
    customer_sk              bigserial primary key,        -- surrogate key в CORE

    -- бизнес-ключ и атрибуты клиента
    customer_unique_id       varchar not null,
    customer_zip_code_prefix varchar,
    customer_city            varchar,
    customer_state           varchar,

    -- SCD2-поля "жизни версии"
    effective_from           date      not null,           -- с этой даты версия актуальна
    effective_to             date      not null,           -- по эту дату включительно
    is_current               boolean   not null,

    -- технические поля CORE
    src_ingest_date          date,                         -- ingest_date из STG
    load_dttm                timestamptz default now()
);

-- одна и только одна текущая версия на бизнес-ключ
create unique index if not exists ux_dim_customer_current
    on core.dim_customer (customer_unique_id)
    where is_current;

-- уникальность исторических версий (business key + effective_from)
create unique index if not exists ux_dim_customer_hist
    on core.dim_customer (customer_unique_id, effective_from);
```

Проверяем, что таблица создалась:

```sql
select column_name, data_type
from information_schema.columns
where table_schema = 'core'
  and table_name   = 'dim_customer'
order by ordinal_position;
```

Результат:
```text
column_name             |data_type               |
------------------------+------------------------+
customer_sk             |bigint                  |
customer_unique_id      |character varying       |
customer_zip_code_prefix|character varying       |
customer_city           |character varying       |
customer_state          |character varying       |
effective_from          |date                    |
effective_to            |date                    |
is_current              |boolean                 |
src_ingest_date         |date                    |
load_dttm               |timestamp with time zone|
```


## 3. Делаем init-load SCD2 из `stg.customers`

Теперь сделаем **первую загрузку**:

- читаем все строки из `stg.customers` по всем `ingest_date`;
- удаляем возможные дубли в рамках одного (`customer_unique_id`, `ingest_date`);
- для каждого клиента сортируем версии по времени;
- считаем `effective_from`, `effective_to`, `is_current`;
- вставляем данные в `core.dim_customer`.

### 3.1. Чистим таблицу перед init-load

В файле `m2_dim_customers_scd2.sql` в самом верху:

```sql
-- 0. очищаем таблицу перед первой загрузкой
truncate table core.dim_customer restart identity;
```

### 3.2. Смотрим на данные в STG глазами SCD2

Посмотрим, как выглядят версии клиентов по `ingest_date`:

```sql
select
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    ingest_date
from stg.customers
order by customer_unique_id, ingest_date
limit 30;
```

Результат:
```text
customer_unique_id              |customer_zip_code_prefix|customer_city|customer_state|ingest_date|
--------------------------------+------------------------+-------------+--------------+-----------+
0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            | 2025-12-03|
0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            | 2025-12-10|
0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            | 2025-12-20|
0000b849f77a49e4a4ce2b2a4ca5be3f|6053                    |osasco       |SP            | 2025-12-03|
0000b849f77a49e4a4ce2b2a4ca5be3f|6053                    |osasco       |SP            | 2025-12-10|
0000b849f77a49e4a4ce2b2a4ca5be3f|6053                    |osasco       |SP            | 2025-12-20|
0000f46a3911fa3c0805444483337064|88115                   |sao jose     |SC            | 2025-12-03|
0000f46a3911fa3c0805444483337064|88115                   |sao jose     |SC            | 2025-12-10|
0000f46a3911fa3c0805444483337064|88115                   |sao jose     |SC            | 2025-12-20|
0000f6ccb0745a6a4b88665a16c9f078|66812                   |belem        |PA            | 2025-12-03|
0000f6ccb0745a6a4b88665a16c9f078|66812                   |belem        |PA            | 2025-12-10|
0000f6ccb0745a6a4b88665a16c9f078|66812                   |belem        |PA            | 2025-12-20|
0004aac84e0df4da2b147fca70cf8255|18040                   |sorocaba     |SP            | 2025-12-03|
0004aac84e0df4da2b147fca70cf8255|18040                   |sorocaba     |SP            | 2025-12-10|
0004aac84e0df4da2b147fca70cf8255|18040                   |sorocaba     |SP            | 2025-12-20|
0004bd2a26a76fe21f786e4fbd80607f|5036                    |sao paulo    |SP            | 2025-12-03|
0004bd2a26a76fe21f786e4fbd80607f|5036                    |sao paulo    |SP            | 2025-12-10|
0004bd2a26a76fe21f786e4fbd80607f|5036                    |sao paulo    |SP            | 2025-12-20|
00050ab1314c0e55a6ca13cf7181fecf|13084                   |campinas     |SP            | 2025-12-03|
00050ab1314c0e55a6ca13cf7181fecf|13084                   |campinas     |SP            | 2025-12-10|
00050ab1314c0e55a6ca13cf7181fecf|13084                   |campinas     |SP            | 2025-12-20|
00053a61a98854899e70ed204dd4bafe|80410                   |curitiba     |PR            | 2025-12-03|
00053a61a98854899e70ed204dd4bafe|80410                   |curitiba     |PR            | 2025-12-10|
00053a61a98854899e70ed204dd4bafe|80410                   |curitiba     |PR            | 2025-12-20|
0005e1862207bf6ccc02e4228effd9a0|25966                   |teresopolis  |RJ            | 2025-12-03|
0005e1862207bf6ccc02e4228effd9a0|25966                   |teresopolis  |RJ            | 2025-12-10|
0005e1862207bf6ccc02e4228effd9a0|25966                   |teresopolis  |RJ            | 2025-12-20|
0005ef4cd20d2893f0d9fbd94d3c0d97|65060                   |sao luis     |MA            | 2025-12-03|
0005ef4cd20d2893f0d9fbd94d3c0d97|65060                   |sao luis     |MA            | 2025-12-10|
0005ef4cd20d2893f0d9fbd94d3c0d97|65060                   |sao luis     |MA            | 2025-12-20|
```

Если всё сделали в предыдущем шаге, у части клиентов появятся **несколько строк** с разными `ingest_date` — это будущие версии.

Теперь соберём CTE, который по шагам превращает «сырые снимки по ingest_date» в аккуратные версии:

1. в `src` помечаем строки внутри одного (`customer_unique_id`, `ingest_date`) порядковым номером;
2. в `dedup` оставляем только `rn = 1` (одна строка на клиента и ingest-день — защита от дублей);
3. в `versions` считаем `effective_from` и `next_effective_from` с помощью `lead()`.


```sql
with src as (
    select
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state,
        ingest_date,
        row_number() over (
            partition by customer_unique_id, ingest_date
            order by customer_id  -- произвольный стабильный порядок
        ) as rn
    from stg.customers
),
dedup as (
    select *
    from src
    where rn = 1
),
versions as (
    select
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state,
        ingest_date                 as effective_from,
        lead(ingest_date) over (
            partition by customer_unique_id
            order by ingest_date
        )                           as next_effective_from
    from dedup
)
select
    customer_unique_id,
    customer_city,
    customer_state,
    effective_from,
    next_effective_from,
    case
        when next_effective_from is null
            then date '9999-12-31'
        else next_effective_from - interval '1 day'
    end                            as effective_to,
    (next_effective_from is null)  as is_current
from versions
order by customer_unique_id, effective_from
limit 30;
```

Результат:
```text
customer_unique_id              |customer_city|customer_state|effective_from|next_effective_from|effective_to           |is_current|
--------------------------------+-------------+--------------+--------------+-------------------+-----------------------+----------+
0000366f3b9a7992bf8c76cfdf3221e2|cajamar      |SP            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0000366f3b9a7992bf8c76cfdf3221e2|cajamar      |SP            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0000366f3b9a7992bf8c76cfdf3221e2|cajamar      |SP            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0000b849f77a49e4a4ce2b2a4ca5be3f|osasco       |SP            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0000b849f77a49e4a4ce2b2a4ca5be3f|osasco       |SP            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0000b849f77a49e4a4ce2b2a4ca5be3f|osasco       |SP            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0000f46a3911fa3c0805444483337064|sao jose     |SC            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0000f46a3911fa3c0805444483337064|sao jose     |SC            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0000f46a3911fa3c0805444483337064|sao jose     |SC            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0000f6ccb0745a6a4b88665a16c9f078|belem        |PA            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0000f6ccb0745a6a4b88665a16c9f078|belem        |PA            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0000f6ccb0745a6a4b88665a16c9f078|belem        |PA            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0004aac84e0df4da2b147fca70cf8255|sorocaba     |SP            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0004aac84e0df4da2b147fca70cf8255|sorocaba     |SP            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0004aac84e0df4da2b147fca70cf8255|sorocaba     |SP            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0004bd2a26a76fe21f786e4fbd80607f|sao paulo    |SP            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0004bd2a26a76fe21f786e4fbd80607f|sao paulo    |SP            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0004bd2a26a76fe21f786e4fbd80607f|sao paulo    |SP            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
00050ab1314c0e55a6ca13cf7181fecf|campinas     |SP            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
00050ab1314c0e55a6ca13cf7181fecf|campinas     |SP            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
00050ab1314c0e55a6ca13cf7181fecf|campinas     |SP            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
00053a61a98854899e70ed204dd4bafe|curitiba     |PR            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
00053a61a98854899e70ed204dd4bafe|curitiba     |PR            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
00053a61a98854899e70ed204dd4bafe|curitiba     |PR            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0005e1862207bf6ccc02e4228effd9a0|teresopolis  |RJ            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0005e1862207bf6ccc02e4228effd9a0|teresopolis  |RJ            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0005e1862207bf6ccc02e4228effd9a0|teresopolis  |RJ            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
0005ef4cd20d2893f0d9fbd94d3c0d97|sao luis     |MA            |    2025-12-03|         2025-12-10|2025-12-09 00:00:00.000|false     |
0005ef4cd20d2893f0d9fbd94d3c0d97|sao luis     |MA            |    2025-12-10|         2025-12-20|2025-12-19 00:00:00.000|false     |
0005ef4cd20d2893f0d9fbd94d3c0d97|sao luis     |MA            |    2025-12-20|                   |9999-12-31 00:00:00.000|true      |
```

У клиентов с несколькими `ingest_date` появились аккуратные интервалы по времени.

### 3.3. Записываем данные в `core.dim_customer`

Теперь завернём CTE в `insert`:

```sql
-- 1. init-load SCD2-измерения клиентов из stg.customers

truncate table core.dim_customer restart identity;

with src as (
    select
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state,
        ingest_date,
        row_number() over (
            partition by customer_unique_id, ingest_date
            order by customer_id
        ) as rn
    from stg.customers
),
dedup as (
    select *
    from src
    where rn = 1
),
versions as (
    select
        customer_unique_id,
        customer_zip_code_prefix,
        customer_city,
        customer_state,
        ingest_date                 as effective_from,
        lead(ingest_date) over (
            partition by customer_unique_id
            order by ingest_date
        )                           as next_effective_from
    from dedup
)
insert into core.dim_customer (
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    effective_from,
    effective_to,
    is_current,
    src_ingest_date,
    load_dttm
)
select
    v.customer_unique_id,
    v.customer_zip_code_prefix,
    v.customer_city,
    v.customer_state,
    v.effective_from,
    case
        when v.next_effective_from is null
            then date '9999-12-31'
        else (v.next_effective_from - interval '1 day')::date
    end                             as effective_to,
    (v.next_effective_from is null) as is_current,
    v.effective_from                as src_ingest_date,
    now()                           as load_dttm
from versions v;
```

### 3.4. Проверяем себя

1. Проверяем количество строк в `dim_customer`?

```sql
select count(*) from core.dim_customer;
```

Результат:

```text
count |
------+
293288|
```

2. Есть ли по каждому `customer_unique_id` только **одна текущая версия**?

```sql
select customer_unique_id, count(*) as cnt
from core.dim_customer
where is_current
group by customer_unique_id
having count(*) > 1;
```

Результат:

```text
customer_unique_id|cnt|
------------------+---+
```

Запрос ничего не вернул — всё ок.

3. Как выглядит история одного конкретного клиента?

```sql
select *
from core.dim_customer
where customer_unique_id = '0000366f3b9a7992bf8c76cfdf3221e2'
order by effective_from;
```

Результат:

```text
customer_sk|customer_unique_id              |customer_zip_code_prefix|customer_city|customer_state|effective_from|effective_to|is_current|src_ingest_date|load_dttm                    |
-----------+--------------------------------+------------------------+-------------+--------------+--------------+------------+----------+---------------+-----------------------------+
          1|0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            |    2025-12-03|  2025-12-09|false     |     2025-12-03|2026-02-14 12:24:11.871 +0300|
          2|0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            |    2025-12-10|  2025-12-19|false     |     2025-12-10|2026-02-14 12:24:11.871 +0300|
          3|0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar      |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
```

4. Как выглядит «срез на дату»?

```sql
select *
from core.dim_customer
where date '2025-12-20' between effective_from and effective_to
order by customer_unique_id
limit 30;
```

Результат:

```text
customer_sk|customer_unique_id              |customer_zip_code_prefix|customer_city        |customer_state|effective_from|effective_to|is_current|src_ingest_date|load_dttm                    |
-----------+--------------------------------+------------------------+---------------------+--------------+--------------+------------+----------+---------------+-----------------------------+
          3|0000366f3b9a7992bf8c76cfdf3221e2|7787                    |cajamar              |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
          6|0000b849f77a49e4a4ce2b2a4ca5be3f|6053                    |osasco               |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
          9|0000f46a3911fa3c0805444483337064|88115                   |sao jose             |SC            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         12|0000f6ccb0745a6a4b88665a16c9f078|66812                   |belem                |PA            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         15|0004aac84e0df4da2b147fca70cf8255|18040                   |sorocaba             |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         18|0004bd2a26a76fe21f786e4fbd80607f|5036                    |sao paulo            |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         21|00050ab1314c0e55a6ca13cf7181fecf|13084                   |campinas             |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         24|00053a61a98854899e70ed204dd4bafe|80410                   |curitiba             |PR            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         27|0005e1862207bf6ccc02e4228effd9a0|25966                   |teresopolis          |RJ            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         30|0005ef4cd20d2893f0d9fbd94d3c0d97|65060                   |sao luis             |MA            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         33|0006fdc98a402fceb4eb0ee528f6a8d4|29400                   |mimoso do sul        |ES            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         36|00082cbe03e478190aadbea78542e933|18400                   |itapeva              |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         39|00090324bbad0e9342388303bb71ba0a|13054                   |campinas             |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         42|000949456b182f53c18b68d6babc79c1|9613                    |sao bernardo do campo|SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         45|000a5ad9c4601d2bbdd9ed765d5213b3|90560                   |porto alegre         |RS            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         48|000bfa1d2f1a41876493be685390d6d3|11095                   |santos               |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         51|000c8bdb58a29e7115cfc257230fb21b|31555                   |belo horizonte       |MG            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         54|000d460961d6dbfa3ec6c9f5805769e1|1206                    |sao paulo            |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         57|000de6019bb59f34c099a907c151d855|11612                   |sao sebastiao        |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         60|000e309254ab1fc5ba99dd469d36bdb4|72872                   |valparaiso de goias  |GO            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         63|000ec5bff359e1c0ad76a81a45cb598f|18160                   |salto de pirapora    |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         66|000ed48ceeb6f4bf8ad021a10a3c7b43|1303                    |sao paulo            |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         69|000fbf0473c10fc1ab6f8d2d286ce20c|13330                   |indaiatuba           |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         72|0010a452c6d13139e50b57f19f52e04e|95611                   |taquara              |RS            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         75|0010fb34b966d44409382af9e8fd5b77|4321                    |sao paulo            |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         78|001147e649a7b1afd577e873841632dd|87020                   |maringa              |PR            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         81|00115fc7123b5310cf6d3a3aa932699e|71015                   |brasilia             |DF            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         84|0011805441c0d1b68b48002f1d005526|68639                   |goianesia do para    |PA            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         87|0011857aff0e5871ce5eb429f21cdaf5|9070                    |santo andre          |SP            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
         90|0011c98589159d6149979563c504cb21|38970                   |campos altos         |MG            |    2025-12-20|  9999-12-31|true      |     2025-12-20|2026-02-14 12:24:11.871 +0300|
```

## 4. Инкрементальный SCD2-загрузчик

### 4.1. Общий алгоритм

1. Определить, **какие `ingest_date` уже загружены** в `core.dim_customer`:

```sql
select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
from core.dim_customer;
```

Результат:

```text
last_ingest_date|
----------------+
      2025-12-20|
```

2. Взять из `stg.customers` только **новые строки**:

```sql
select *
from stg.customers s
where s.ingest_date > (
   select coalesce(max(src_ingest_date), date '1900-01-01')
   from core.dim_customer
);
```

3. Для каждой новой строки по `customer_unique_id`:

- найти текущую версию в `core.dim_customer` (`is_current = true`);
- сравнить атрибуты (`city`, `state`, `zip`):
  - если ничего не изменилось → **ничего не делаем** (этот батч для этого клиента можно пропустить);
  - если есть изменения →  
    а) **закрываем старую версию** (`effective_to`, `is_current = false`);  
    б) **вставляем новую версию** с `effective_from = новый ingest_date`.

4. Для новых клиентов (которых ещё нет в `dim_customer`) сразу создаём первую версию  
   (`effective_from = ingest_date`, `effective_to = '9999-12-31'`, `is_current = true`).

### 4.2. Скелет инкрементального скрипта

Создадим инкрементальный скрипт `m2_dim_customers_scd2_increment.sql`.  

Вот его каркас:

```sql
-- Инкрементальная загрузка SCD2 для core.dim_customer

with last_loaded as (
    select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
    from core.dim_customer
),
new_src as (
    -- 1. берём только новые ingest_date
    select
        s.customer_unique_id,
        s.customer_zip_code_prefix,
        s.customer_city,
        s.customer_state,
        s.ingest_date,
        row_number() over (
            partition by s.customer_unique_id, s.ingest_date
            order by s.customer_id
        ) as rn
    from stg.customers s
    join last_loaded l
      on s.ingest_date > l.last_ingest_date
),
dedup as (
    select *
    from new_src
    where rn = 1
),
with_current as (
    -- 2. присоединяем текущую версию клиента (если есть)
    select
        d.customer_sk           as current_sk,
        d.customer_unique_id    as current_unique_id,
        d.customer_city         as current_city,
        d.customer_state        as current_state,
        d.effective_from        as current_effective_from,
        d.effective_to          as current_effective_to,
        d.is_current            as current_is_current,

        s.customer_unique_id,
        s.customer_zip_code_prefix,
        s.customer_city,
        s.customer_state,
        s.ingest_date           as new_effective_from
    from dedup s
    left join core.dim_customer d
      on d.customer_unique_id = s.customer_unique_id
     and d.is_current = true
),
changed as (
    -- 3. отфильтровать только тех, у кого реально изменились атрибуты
    select *
    from with_current
    where
        current_sk is null
        or coalesce(current_city,  '') <> coalesce(customer_city,  '')
        or coalesce(current_state, '') <> coalesce(customer_state, '')
)
select *
from changed;
```

### 4.3. Сделаем имитацию изменения данных

#### 4.3.1. Выберем произвольную запись из таблицы stg.customers

```sql
select *
from stg.customers
order by ingest_date desc;
```

#### 4.3.2. Выбирем запись

```sql
select *
from stg.customers
where customer_id = '06b8999e2fba1a1fbc88172c00ba8bc7'
```

Результат:
```text
customer_id                     |customer_unique_id              |customer_zip_code_prefix|customer_city|customer_state|ingest_date|
--------------------------------+--------------------------------+------------------------+-------------+--------------+-----------+
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca       |SP            | 2025-12-10|
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca       |SP            | 2025-12-20|
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca       |SP            | 2025-12-03|
```

#### 4.3.3. Изменяем атрибуты

```sql
UPDATE stg.customers 
SET ingest_date='2025-12-25', customer_city='new_franca', customer_state='SPN'
WHERE customer_id='06b8999e2fba1a1fbc88172c00ba8bc7' AND ingest_date='2025-12-25';
```

#### 4.3.4. Проверяем работу инкрементального скрипта

Результат:
```text
current_sk|current_unique_id               |current_city|current_state|current_effective_from|current_effective_to|current_is_current|customer_unique_id              |customer_zip_code_prefix|customer_city|customer_state|new_effective_from|
----------+--------------------------------+------------+-------------+----------------------+--------------------+------------------+--------------------------------+------------------------+-------------+--------------+------------------+
    151191|861eff4711a542e4b93843c6dd7febb0|franca      |SP           |            2025-12-20|          9999-12-31|true              |861eff4711a542e4b93843c6dd7febb0|14409                   |new_franca   |SPN           |        2025-12-25|
```

### 4.4. Изменяем инкрементальный скрипт

#### 4.4.1. Изменяем инкрементальный скрипт

Дописываем `update`:

```sql
update core.dim_customer d
 set effective_to = (c.new_effective_from - interval '1 day')::date,
     is_current  = false
from changed c
where d.customer_sk = c.current_sk
 and c.current_sk is not null;
```

Добавляем `insert`:

```sql
insert into core.dim_customer (
  customer_unique_id,
  customer_zip_code_prefix,
  customer_city,
  customer_state,
  effective_from,
  effective_to,
  is_current,
  src_ingest_date,
  load_dttm
)
select
  c.customer_unique_id,
  c.customer_zip_code_prefix,
  c.customer_city,
  c.customer_state,
  c.new_effective_from                           as effective_from,
  date '9999-12-31'                              as effective_to,
  true                                           as is_current,
  c.new_effective_from                           as src_ingest_date,
  now()                                          as load_dttm
from changed c;
```

#### 4.4.2. Финальная версия

```sql
-- Инкрементальная загрузка SCD2 для core.dim_customer

with last_loaded as (
    select coalesce(max(src_ingest_date), date '1900-01-01') as last_ingest_date
    from core.dim_customer
),
new_src as (
    -- 1. берём только новые ingest_date
    select
        s.customer_unique_id,
        s.customer_zip_code_prefix,
        s.customer_city,
        s.customer_state,
        s.ingest_date,
        row_number() over (
            partition by s.customer_unique_id, s.ingest_date
            order by s.customer_id
        ) as rn
    from stg.customers s
    join last_loaded l
      on s.ingest_date > l.last_ingest_date
),
dedup as (
    select *
    from new_src
    where rn = 1
),
with_current as (
    -- 2. присоединяем текущую версию клиента (если есть)
    select
        d.customer_sk           as current_sk,
        d.customer_unique_id    as current_unique_id,
        d.customer_city         as current_city,
        d.customer_state        as current_state,
        d.effective_from        as current_effective_from,
        d.effective_to          as current_effective_to,
        d.is_current            as current_is_current,

        s.customer_unique_id,
        s.customer_zip_code_prefix,
        s.customer_city,
        s.customer_state,
        s.ingest_date           as new_effective_from
    from dedup s
    left join core.dim_customer d
      on d.customer_unique_id = s.customer_unique_id
     and d.is_current = true
),
changed as (
    -- 3. отфильтровать только тех, у кого реально изменились атрибуты
    select *
    from with_current
    where
        current_sk is null
        or coalesce(current_city,  '') <> coalesce(customer_city,  '')
        or coalesce(current_state, '') <> coalesce(customer_state, '')
),
-- вносим изменения
updated AS (
--   а) update core.dim_customer для закрытия старых версий;
	update core.dim_customer d
	   set effective_to = (c.new_effective_from - interval '1 day')::date,
	       is_current  = false
	  from changed c
	 where d.customer_sk = c.current_sk
	   and c.current_sk is not null
	 RETURNING d.customer_sk, d.effective_to, d.is_current
),
--   б) insert новых версий.
inserted AS (
		insert into core.dim_customer (
	    customer_unique_id,
	    customer_zip_code_prefix,
	    customer_city,
	    customer_state,
	    effective_from,
	    effective_to,
	    is_current,
	    src_ingest_date,
	    load_dttm
	)
	select
	    c.customer_unique_id,
	    c.customer_zip_code_prefix,
	    c.customer_city,
	    c.customer_state,
	    c.new_effective_from                           as effective_from,
	    date '9999-12-31'                              as effective_to,
	    true                                           as is_current,
	    c.new_effective_from                           as src_ingest_date,
	    now()                                          as load_dttm
	from changed c
	RETURNING customer_sk
)
-- Финальный select для просмотра результатов
select 
    'Updated' as operation, 
    count(*) 
from updated
union all
select 
    'Inserted', 
    count(*) 
from inserted;
```

Результат работы:
```text
operation|count|
---------+-----+
Updated  |    1|
Inserted |    1|
```

#### 4.4.3. Проверка результата 

```sql
select *
from stg.customers
where customer_id = '06b8999e2fba1a1fbc88172c00ba8bc7'
```

Результат:
```text
customer_id                     |customer_unique_id              |customer_zip_code_prefix|customer_city|customer_state|ingest_date|
--------------------------------+--------------------------------+------------------------+-------------+--------------+-----------+
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca       |SP            | 2025-12-10|
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |new_franca   |SPN           | 2025-12-25|
06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca       |SP1           | 2025-12-03|
```
