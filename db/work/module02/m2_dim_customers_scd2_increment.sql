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