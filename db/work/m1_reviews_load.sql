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

drop table if exists stg._reviews_load;