# Урок 1. RAW и `ingest_date`

## Цель урока

Подготовить слой **RAW** для датасета Olist:
- разложить CSV-файлы по папкам `ingest_date=YYYY-MM-DD`;
- убедиться, что структура RAW удобна для дальнейших инкрементов и загрузки в STG.


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

### 1. Описание источника данных

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

### 4. Скрипт для раскладки CSV в RAW

В проекте есть утилита, которая создаёт нужные папки и копирует (или переносит) файлы:

```bash
python scripts/put_to_raw.py --src "<каталог с Olist>" --dst data/raw/olist
```

Дополнительные опции:
- `--ingest-date 2025-11-11` — задаёт `ingest_date` (по умолчанию берётся текущая дата);
- `--move` — вместо копирования **перемещает** файлы из `--src` в RAW.

Можно без `--ingest-date`, тогда скрипт возьмёт текущую дату.

### 5. Проверка результата

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