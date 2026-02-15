-- создаем таблицу
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

-- init-load SCD2-измерения клиентов из stg.customers

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