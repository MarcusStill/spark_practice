# Урок 1.1. RAW и `ingest_date`

## Цель урока

Подготовить слой **RAW** для датасета Olist:
- разложить CSV-файлы по папкам `ingest_date=YYYY-MM-DD`;
- убедиться, что структура RAW удобна для дальнейших инкрементов и загрузки в STG.

---
## Два варианта прохождения урока

### 1. RAW на локальном диске (по умолчанию)
Раскладываем CSV в папку проекта:

```text
data/raw/olist/...
```

Делаем это утилитой `scripts/put_to_raw.py`.

### 2. RAW в S3 (MinIO) через Spark
Ты складываешь RAW в MinIO (S3 compatible):

```text
s3a://raw/olist/...
```

Вся логика (S3A конфиги + загрузка батча) лежит в ноутбуке:  
`notebooks/module01/templates/lesson01_01_raw_to_s3.ipynb`

> Важно: в S3-варианте Spark пишет **part-файлы** (например, `part-0000...csv`) внутри папки `ingest_date=...` — это нормально.

---

## Описание

Источник данных - интернет‑магазин. Выгрузки из операционной системы приходят каждый день пачкой CSV.  
Через год маркетинг спрашивает: «А что у нас было в данных **2025‑11‑15**, до всех исправлений?»

```text
Исходные системы → RAW → STG → CORE → MARTS
```

Если хранить только «последнюю версию», воспроизвести состояние невозможно. Поэтому:

- **не трогаем исходные файлы**, складываем их в RAW;
- помечаем партии с помощью `ingest_date` — даты, когда батч попал в хранилище.

Дальше любые расчёты (CORE, витрины, модели) можно пересобирать, не трогая RAW.

### 1. Источник данных

Работа построена с датасетом **Olist** с Kaggle.  

```markdown
Коротко:
- Kaggle — платформа с публичными датасетами и соревнованиями по ML.
- Olist — бразильский маркетплейс; на Kaggle выложен анонимизированный датасет его заказов.
```

В рамках практикума Olist — это «интернет-магазин», для которого настраивается мини-хранилище: слои RAW → STG → CORE → витрины.

Пример содержимого каталога с данными:
- `olist_orders_dataset.csv`
- `olist_order_items_dataset.csv`
- `olist_customers_dataset.csv`
- `olist_order_payments_dataset.csv`
- `olist_products_dataset.csv`
- `olist_sellers_dataset.csv`
- `olist_order_reviews_dataset.csv`
- `product_category_name_translation.csv`


### 2. Зачем нам `ingest_date`

> `ingest_date` — это **дата загрузки партии в DWH**, а не дата события.

Примеры:
- `order_purchase_timestamp` — когда клиент сделал заказ;
- `order_delivered_customer_date` — когда заказ доставили;
- `ingest_date` — когда CSV с этими событиями попал к нам в хранилище.

Предназначение:
- можно пересобрать CORE / витрины для любой даты загрузки, не перекладывая RAW;
- можно сделать откат: «собери витрины так, как будто мы ещё не загружали данные после `2025‑11‑11`»;
- при ошибке загрузки достаточно повторно прогнать нужную `ingest_date`.

В этом модуле `ingest_date` будет **ключом батча** как для RAW, так и для STG.

### 3. Ожидаемая структура RAW

### 3.1. Локальный RAW

Цель — получить такую структуру:

```bash
data/raw/olist/
  orders/ingest_date=YYYY-MM-DD/olist_orders_dataset.csv
  order_items/ingest_date=YYYY-MM-DD/olist_order_items_dataset.csv
  customers/ingest_date=YYYY-MM-DD/olist_customers_dataset.csv
  order_payments/ingest_date=YYYY-MM-DD/olist_order_payments_dataset.csv
  products/ingest_date=YYYY-MM-DD/olist_products_dataset.csv
  sellers/ingest_date=YYYY-MM-DD/olist_sellers_dataset.csv
  geolocation/ingest_date=YYYY-MM-DD/olist_geolocation_dataset.csv
  reviews/ingest_date=YYYY-MM-DD/olist_order_reviews_dataset.csv
  category_translation/ingest_date=YYYY-MM-DD/product_category_name_translation.csv
```

Папки `ingest_date=...` будут использоваться как «ключ батча» в STG и выше.

### 3.2. RAW в S3 / MinIO

Логика та же, только “корень” — S3:

```bash
s3a://raw/olist/
  orders/ingest_date=YYYY-MM-DD/...
  order_items/ingest_date=YYYY-MM-DD/...
  ...
```

> Внутри `ingest_date=...` ты увидишь `part-*.csv`. Это нормально: так пишет Spark.  
> В ноутбуке стоит `coalesce(1)`, чтобы на каждый датасет был один part-файл (удобнее для ручной проверки).

### 4. Скрипт для раскладки CSV в RAW

В проекте есть утилита, которая создаёт нужные папки и копирует (или переносит) файлы:

```bash
python scripts/put_to_raw.py --src "<каталог с Olist>" --dst data/raw/olist
```

Дополнительные опции:
- `--ingest-date 2025-11-11` — задаёт `ingest_date` (по умолчанию берётся текущая дата);
- `--move` — вместо копирования **перемещает** файлы из `--src` в RAW.

#### 4.1. Примеры для Windows (PowerShell / CMD)

```powershell
# 1. переходим в корень проекта (где docker-compose.yml)
cd "D:\de_lab\spark_01\spark_01"   # у вас свой путь

# 2. запускаем раскладку в RAW
python scripts\put_to_raw.py --src data\csv --dst data\raw\olist --ingest-date 2025-11-11
```

Можно без --ingest-date, тогда скрипт возьмёт сегодняшнюю дату:

```powershell
python scripts\put_to_raw.py --src data\csv --dst data\raw\olist
```

#### 4.2. Примеры для macOS / Linux / WSL

```bash
cd ~/de_lab/spark_01/spark_01   # также, у вас свой путь корня проекта

python scripts/put_to_raw.py --src data/csv --dst data/raw/olist --ingest-date 2025-11-11
# или без даты:
# python scripts/put_to_raw.py --src data/csv --dst data/raw/olist
```

Запускать команду ИМЕННО из корня репозитория – тогда `scripts/…`, `data/...` будут корректными относительными путями.

### 4.2. Загрузка батча в S3 (MinIO) через Spark (ноутбук)

Здесь без подробных команд — всё уже собрано в ноутбуке.

- Открой `notebooks/module01/templates/lesson01_01_raw_to_s3.ipynb`
- **Желательно** создать копию ноутбука в директории `/module01/work/`:

Что нужно сделать в ноутбуке:
1) поменять `ingest_date`  
2) запустить ячейки сверху вниз  
3) убедиться, что записи появились в `s3a://raw/olist/...`

Проверка руками:
- зайди в MinIO Console → бакет `raw` → `olist` → выбери датасет → `ingest_date=...` → увидишь `part-*.csv`

### 5. Проверка результата

#### 5.1. Локальная версия 

После выполнения скрипта формируется структура, похожая на:

```text
data/raw/olist/
  orders/
    ingest_date=2025-11-11/
      olist_orders_dataset.csv
  order_items/
    ingest_date=2025-11-11/
      olist_order_items_dataset.csv
  ...
```

Проверить ее можно:
- через файловый менеджер;
- через терминал (macOS / Linux / WSL):

```bash
tree data/raw/olist /A /F
```

### 5.2. S3 / MinIO

Проверить можно двумя способами:
- в MinIO Console (самый простой): `raw/olist/.../ingest_date=.../`
- в ноутбуке: в конце есть ячейка “Быстрая проверка”, которая читает данные обратно из `s3a://...`

Результат:
```text
files sample: ['s3a://raw/olist/customers/ingest_date=2025-12-03/part-00000-bca687be-60f5-49f0-931a-e693aba83186-c000.csv']
rows: 99441
+--------------------------------+--------------------------------+------------------------+---------------------+--------------+
|customer_id                     |customer_unique_id              |customer_zip_code_prefix|customer_city        |customer_state|
+--------------------------------+--------------------------------+------------------------+---------------------+--------------+
|06b8999e2fba1a1fbc88172c00ba8bc7|861eff4711a542e4b93843c6dd7febb0|14409                   |franca               |SP            |
|18955e83d337fd6b2def6b18a428ac77|290c77bc529b7ac935b93aa66c333dc3|09790                   |sao bernardo do campo|SP            |
|4e7b3e00288586ebd08712fdd0374a03|060e732b5b29e8181a18229c7b0b2b5e|01151                   |sao paulo            |SP            |
|b2b6027bc5c5109e529d4dc6358b12c3|259dac757896d24d7702b9acbbff3f3c|08775                   |mogi das cruzes      |SP            |
|4f2d8ab171c80ec8364f7c12e35b23ad|345ecd01c38d18a9036ed96c73b8d066|13056                   |campinas             |SP            |
+--------------------------------+--------------------------------+------------------------+---------------------+--------------+
only showing top 5 rows
```