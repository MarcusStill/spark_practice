# Урок 3.2 — Базовые трансформации в Spark (DataFrame API + Spark SQL)

## Цели урока

Cделать одну и ту же «маленькую аналитику» двумя способами:

- через **DataFrame API**
- через **Spark SQL**


## Источник данных 

- файл: `olist_orders_dataset.csv`
- путь в стенде: `/data/olist_orders_dataset.csv`

Правило путей в стенде:

- **читаем** исходники из `/data`
- **пишем** результаты урока в `/workspace`

В этом уроке записываем результаты в каталог:

- `/workspace/lesson03_02/...`


## Как Spark «думает» на базовом уровне

### DataFrame — это не «таблица в памяти»

В Spark DataFrame — это **описание вычислений** над данными. Когда мы пишем:

```python
df2 = df.select(...).filter(...)
```

Spark строит план, но **не обязан** сразу всё считать.

### Transformation vs Action

**Трансформации** (transformations) — строят план:

- `select`
- `withColumn`
- `filter`
- `orderBy`
- `groupBy`
- `distinct`
- и т.д.

**Действия** (actions) — реально запускают вычисления:

- `show()`
- `count()`
- `collect()`
- запись: `.write...`

Это и есть «ленивость» Spark: пока нет action — Spark может ничего не вычислять.

---

## Мини-набор inspect-проверок

Когда только прочитали данные, лучше не прыгать сразу в сложные пайплайны.  
Сначала — 4 короткие проверки:

1) Список колонок

```python
df.columns
```

2) Схема (типы данных)

```python
df.printSchema()
```

3) Несколько строк

```python
df.show(5, truncate=False)
```

4) Объём данных

```python
df.count()
```

Почему это важно:
- сразу видно, **какие типы** у колонок (особенно даты/таймстемпы);
- возможность поймать «кривую» загрузку до того, как построили 20 шагов.


## Базовые операции DataFrame API из урока

### 1) `select` — выбрать колонки

```python
df.select("order_id", "customer_id", "order_status")
```

Фишка: `select` **не меняет** исходный df — он возвращает новый DataFrame.

---

### 2) `withColumn` — добавить или переопределить колонку

Типичный кейс: получить дату без времени из timestamp.

```python
from pyspark.sql import functions as F

df2 = df.withColumn("order_purchase_date", F.to_date("order_purchase_timestamp"))
```

---

### 3) `filter` — фильтрация строк

```python
df_delivered = df.filter(F.col("order_status") == "delivered")
```

Фильтр по набору значений — через `isin`:

```python
df_active = df.filter(F.col("order_status").isin(["delivered", "shipped", "processing"]))
```

---

### 4) `orderBy` — сортировка

```python
df.orderBy(F.col("order_purchase_timestamp").desc())
```

Важно помнить: **после записи и чтения** порядок строк обычно не гарантирован.  
Если порядок важен — сортируйте **перед show()**, **и/или** прямо перед проверкой результата.

---

### 5) `distinct` — уникальные значения

```python
df.select("order_status").distinct()
```

---

### 6) `groupBy` + `agg` — агрегирование

```python
df_status = (
    df.groupBy("order_status")
      .agg(F.count("*").alias("cnt"))
      .orderBy(F.col("cnt").desc(), F.col("order_status").asc())
)
```

---

## «Контракт данных»

В уроке мы собираем «рабочую» таблицу заказов — минимальный набор полей.

Контракт — это:
- **какие колонки** должны быть в результате,
- **какие типы** в этих колонках (date vs timestamp),
- базовые ожидания по качеству (например, не терять строки).

Пример контракта в уроке:

- `order_id`
- `customer_id`
- `order_status`
- `order_purchase_timestamp`
- `order_delivered_customer_date`
- `order_purchase_date` (date без времени)

Почему это полезно:
- мы не читаем полный набор атрибутов,
- появляется явная точка контроля: *«вот что мы хотим получить»*.


## Spark SQL: тот же смысл, другой интерфейс

Очень важный приём: **зарегистрировать DataFrame как temp view**, а потом писать SQL.

```python
df_orders.createOrReplaceTempView("orders")
```

Дальше:

```python
df_contract_sql = spark.sql("""
SELECT
    order_id,
    customer_id,
    order_status,
    order_purchase_timestamp,
    order_delivered_customer_date,
    to_date(order_purchase_timestamp) AS order_purchase_date
FROM orders
""")
```

### Как выбирать между DataFrame API и SQL

- DataFrame API удобен, когда вы мыслите «шагами» и хотите читать код как пайплайн.
- SQL удобен, когда задача естественно выражается запросом (агрегации, фильтры, простые витрины).

Важно: это **одна и та же вычислительная система**.  
Меняется только способ описать вычисления.

---

## Validate: простые проверки, которые должны войти в привычку

После трансформаций держите желательно проводить следующие проверки:

### 1) Не потеряли строки там, где не должны

Например, при сборке контракта количество строк должно остаться тем же:

```python
df_orders.count(), df_contract.count()
```

### 2) Понять диапазон дат

```python
df_contract.select(
    F.min("order_purchase_date").alias("min_dt"),
    F.max("order_purchase_date").alias("max_dt"),
).show()
```

### 3) Уникальность там, где ожидается уникальность

Например, если мы построили «первую покупку клиента», `customer_id` должен быть уникален:

```python
df_first.count() == df_first.select("customer_id").distinct().count()
```

---

## Write: как Spark пишет результаты и почему это «папка, а не файл»

Когда Spark пишет результат, он пишет **в директорию** и создаёт набор `part-...` файлов. Это нормально: Spark распределённый.

### CSV

```python
(df.write
   .mode("overwrite")
   .option("header", True)
   .csv("/workspace/lesson03_02/orders_contract_csv"))
```

### Parquet

```python
(df.write
   .mode("overwrite")
   .parquet("/workspace/lesson03_02/orders_contract_parquet"))
```

### Зачем нужен `reset_dir(...)`

Если мы много раз перезапускаем ноутбук, у нас не должно оставаться «хвостов» от старых запусков.  
Идемпотентность = можно запускать снова и снова и получать одинаковый результат.


### `coalesce(1)` — когда можно, а когда нельзя

Если результат **маленький** (например, агрегированная таблица на 6–10 строк), можно сделать один файл:

```python
df_small.coalesce(1).write.mode("overwrite").parquet(path)
```

Но на больших данных это плохо:
- создаёт «узкое горлышко» (всё стягивается в один partition),
- может быть очень медленно и даже падать по памяти.

Правило простое:
- **учебные маленькие результаты** — можно `coalesce(1)`;
- **всё остальное** — оставляйте как есть.


## Read-back: запись без чтения — не считается

После записи всегда делаем «прочитал обратно и сравнил объём»:

```python
back = spark.read.parquet(path)
back.count(), df.count()
```

Это базовая инженерная страховка:
- убедились, что запись реально произошла,
- убедились, что данные читаются обратно,
- убедились, что не потеряли строки.


## Частые ошибки

1) **Сравнение дат как строк**  
Обычно работает, но лучше держать колонку именно `date`/`timestamp` и сравнивать с `lit(...)`.

2) **Ожидание, что порядок строк сохранится после записи**  
Не сохранится. Если важен порядок — сортируйте явно.

3) **Слепая вера в `inferSchema`**  
Для обучения ок, для продакшена — нет. В проде схему фиксируют.

4) **Слишком ранний `coalesce(1)`**  
Это удобно «как файл», но плохо как распределённое вычисление.
