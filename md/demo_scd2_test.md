# SCD2 на тестовом примере (демо-таблица)

Перед тем как трогать **реальный Olist**, удобнее посмотреть на маленькую демо-таблицу.

### 1. Содаем демо-таблицу `demo.dim_customer_scd2_demo`

В репозитории есть скрипт:

```text
db/demo/demo_dim_customer_scd2.sql
```

Запусти его в DBeaver / psql:

```sql
\i db/demo/demo_dim_customer_scd2.sql
```

Скрипт создаёт схему и таблицу:

```sql
create schema if not exists demo;

create table if not exists demo.dim_customer_scd2_demo (
    customer_sk              bigserial primary key,
    customer_unique_id       varchar not null,
    customer_zip_code_prefix varchar,
    customer_city            varchar,
    customer_state           varchar,
    effective_from           date      not null,
    effective_to             date      not null,
    is_current               boolean   not null,
    src_ingest_date          date,
    load_dttm                timestamptz default now()
);
```

…и наполняет её несколькими клиентами с разным поведением:

- кто-то переезжал один раз;
- кто-то несколько раз туда‑сюда;
- у кого-то менялся только индекс;
- у кого-то вообще одна версия на всю жизнь.

### 2. SCD1 vs SCD2 на одном клиенте

Представь клиента **U111**, который сначала жил в Москве, а потом переехал в СПб.

**SCD1**: храним только текущее состояние (история потерялась):

```text
customer_unique_id | customer_city | customer_state
--------------------+--------------+---------------
U111                | SPb          | RU-SPE
```

**SCD2**: храним версии с датами действия:

```text
customer_unique_id | customer_city | customer_state | effective_from | effective_to   | is_current
--------------------+--------------+----------------+----------------+----------------+-----------
U111                | Moscow       | RU-MOW         | 2024-01-10     | 2024-06-01     | false
U111                | SPb          | RU-SPE         | 2024-06-01     | 9999-12-31     | true
```

Прямо в демо-таблице:

```sql
select
    customer_unique_id,
    customer_city,
    customer_state,
    effective_from,
    effective_to,
    is_current
from demo.dim_customer_scd2_demo
where customer_unique_id = 'U111'
order by effective_from;
```

Попробуй несколько клиентов из демо-таблицы и **прочитай строки словами**:

> «С такой-то даты по такую-то клиент считался московским,  
> затем с такой-то даты стал питерским и так далее…».

### 3. Event time vs ingest time

Чуть усложним картинку. Представь, что:

- клиент переехал **01.06** (реальное событие);
- но отчёт из CRM в наш DWH приехал только **05.06**.

Тогда у нас два времени:

- **event time** — когда событие реально произошло (01.06);
- **ingest time** — когда мы это узнали и забрали в STG (05.06).

В идеальном мире в источнике есть поле типа `address_changed_at`,  
и мы можем в SCD2 использовать именно **event time** (для `effective_from`).

В Olist всё проще: у нас есть только `ingest_date`.  
В этом учебном стенде мы считаем:

> `effective_from` ≈ `ingest_date`  
> (момент, когда данные попали к нам в STG).

Важно это проговорить, чтобы в голове разделялись две идеи,  
даже если физически у нас сейчас только одна дата.

### 4. Как читать SCD2-таблицу

На демо-таблице поиграйся с такими запросами:

```sql
-- История конкретного клиента
select *
from demo.dim_customer_scd2_demo
where customer_unique_id = 'U222'
order by effective_from;

-- Только текущие версии
select *
from demo.dim_customer_scd2_demo
where is_current;

-- Состояние клиентов "на дату" (as of date)
select *
from demo.dim_customer_scd2_demo
where date '2024-06-15' between effective_from and effective_to;
```