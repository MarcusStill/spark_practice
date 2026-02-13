-- Demo table for SCD2 dim_customer
create schema if not exists demo;

drop table if exists demo.dim_customer_scd2_demo;

create table demo.dim_customer_scd2_demo (
    customer_sk              bigserial primary key,
    customer_unique_id       varchar not null,
    customer_zip_code_prefix int,
    customer_city            varchar,
    customer_state           varchar,
    effective_from           date      not null,
    effective_to             date      not null,
    is_current               boolean   not null,
    src_ingest_date          date,
    load_dttm                timestamptz default now()
);

insert into demo.dim_customer_scd2_demo (
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    effective_from,
    effective_to,
    is_current,
    src_ingest_date
)
values
    -- U111: Moscow -> SPb
    ('U111', 10100, 'Moscow', 'RU-MOW', date '2025-11-11', date '2025-12-10', false, date '2025-11-11'),
    ('U111', 19300, 'SPb',    'RU-SPE', date '2025-12-11', date '9999-12-31', true,  date '2025-12-11'),

    -- U222: stays in one city (одна версия)
    ('U222', 22000, 'Kazan',  'RU-TA',  date '2025-11-11', date '9999-12-31', true,  date '2025-11-11'),

    -- U333: Ekb -> Novosibirsk -> Ekb
    ('U333', 62000, 'Ekaterinburg', 'RU-SVE', date '2025-11-11', date '2025-11-30', false, date '2025-11-11'),
    ('U333', 63000, 'Novosibirsk',  'RU-NVS', date '2025-12-01', date '2026-01-31', false, date '2025-12-01'),
    ('U333', 62000, 'Ekaterinburg', 'RU-SVE', date '2026-02-01', date '9999-12-31', true,  date '2026-02-01'),

    -- U444: только индекс меняется (город/штат те же, но всё равно новая версия)
    ('U444', 40000, 'Rostov-na-Donu', 'RU-ROS', date '2025-11-11', date '2025-12-31', false, date '2025-11-11'),
    ('U444', 40010, 'Rostov-na-Donu', 'RU-ROS', date '2026-01-01', date '9999-12-31', true,  date '2026-01-01'),

    -- U555: два города в одном штате
    ('U555', 11500, 'Moscow',   'RU-MOW', date '2025-11-11', date '2025-12-20', false, date '2025-11-11'),
    ('U555', 14000, 'Podolsk',  'RU-MOW', date '2025-12-21', date '9999-12-31', true,  date '2025-12-21'),

    -- U666: только одна текущая версия
    ('U666', 35000, 'Krasnodar', 'RU-KDA', date '2025-11-11', date '9999-12-31', true, date '2025-11-11');

-- Примеры запросов:
-- 1) История по одному клиенту
--    select * from demo.dim_customer_scd2_demo
--    where customer_unique_id = 'U333'
--    order by effective_from;
--
-- 2) Только текущие версии
--    select * from demo.dim_customer_scd2_demo
--    where is_current;
--
-- 3) Срез клиентов на произвольную дату
--    select *
--    from demo.dim_customer_scd2_demo
--    where date '2025-12-15' between effective_from and effective_to;
