# Урок 3.1 — Spark с нуля: DataFrame и цикл read → inspect → transform → validate → write

## Цели урока

- берем реальный датасет;
- читаем его в Spark;
- анализируем содержимое;
- делаем пару трансформаций;
- проверяем себя и записываем результат так, чтобы его можно было воспроизвести.

Ключевой паттерн урока: **read → inspect → transform → validate → write → read-back → validate**


## Правило путей в стенде

- исходные данные читаем из `/data/csv`
- результаты уроков пишем в `/workspace`

> Spark выполняет вычисления на executors (воркеры). Если путь виден только в Jupyter-контейнере, 
> то запись/чтение упрётся в «файла нет». Поэтому в модуле мы сразу приучаемся работать через общие volume-пути.


## Мини-модель Spark

Внутри ноутбука мы пишем код в Python, но исполняется он так:

- **driver** живёт там, где ваш ноутбук (контейнер `jupyter`)
- **executors** выполняют работу на воркерах (контейнеры `spark-worker-*`)

Когда мы создаём DataFrame, то чаще всего **не «получаем таблицу в память»**, а собираем **план вычислений**.
И только когда мы делаем action — Spark реально идёт читать файлы, строить вычисление, запускать задачи на executors.

## DataFrame

В этом модуле мы будем думать о DataFrame так:

**DataFrame = (схема + набор трансформаций + ленивый план исполнения)**

Отсюда два следствия:

1) DataFrame «не меняется на месте»  

2) Если мы написали:

```python
df2 = df1.select("order_id")
```

то `df1` не «стал уже» с одной колонкой. Мы просто создали **новый** DataFrame (`df2`) с другим планом.

2) Многие операции «кажутся быстрыми», пока мы не сделали action.

Например, `select()` выглядит мгновенно — потому что это transformation. А вот `count()` — уже работа.

## Чтение CSV: `header` и `inferSchema`

В уроке чтение выглядит так:

```python
df_orders = (
    spark.read
    .option("header", True)
    .option("inferSchema", True)
    .csv("/data/olist_orders_dataset.csv")
)
```

### `header=True`
Первая строка CSV — это названия колонок. Без `header=True` Spark назовёт колонки `_c0`, `_c1`, …

### `inferSchema=True`
Spark попытается угадать типы колонок (int, timestamp, string и т.д.).

**Важно**: для обучения это удобно. В продакшене чаще делают наоборот:
- либо задают схему явно,
- либо приводят типы трансформациями после чтения,

потому что `inferSchema`:
- может быть медленнее (нужно «смотреть» на данные),
- может дать неожиданные типы, если данные грязные.

Мы сознательно выбираем такой путь потому, что это «удобно для старта».


## Inspect: как быстро понять, что прочитали

Мини-набор, который мы будем повторять постоянно:

### 1) Колонки

```python
df_orders.columns
```

### 2) Схема и типы

```python
df_orders.printSchema()
```

### 3) Первые строки

```python
df_orders.show(5, truncate=False)
```

### 4) Количество строк

```python
df_orders.count()
```

#### Почему `count()` — важная точка
`count()` — action. Он заставляет Spark реально выполнить работу.
Если есть проблемы с путями, доступом к данным, парсингом — они часто «всплывают» именно на первом action.


## Простой validate: быстрые DQ-проверки на старте

В уроке есть две мини-проверки, которые формируют правильную привычку:

### Проверка 1 — как выглядит `isNull()`

```python
df_orders.select(
    "order_id",
    F.col("order_id").isNull().alias("is_order_id_null")
).show(5, truncate=False)
```

### Проверка 2 — сколько NULL в ключевых полях

```python
df_orders.select(
    F.count("*").alias("rows"),
    F.sum(F.col("order_id").isNull().cast("int")).alias("null_order_id"),
    F.sum(F.col("customer_id").isNull().cast("int")).alias("null_customer_id"),
).show(truncate=False)
```

Это «не контроль качества данных», но это ровно то, что делает **de** в реальном пайплайне:
сначала убедиться, что ключевые поля не развалились, и только потом строить логику.


## Transform: первая полезная трансформация (и важное правило)

В ноутбуке мы собираем «учебный» DataFrame с базовыми полями и добавляем `order_purchase_date`.

### 1) Выбираем нужные колонки

```python
df_orders_basic = df_orders.select(
    "order_id",
    "customer_id",
    "order_status",
    "order_purchase_timestamp",
    "order_delivered_customer_date",
)
```

### 2) Добавляем колонку датой без времени

```python
df_orders_basic = df_orders_basic.withColumn(
    "order_purchase_date",
    F.to_date("order_purchase_timestamp")
)
```

### 3) Смотрим результат

```python
df_orders_basic.show(5, truncate=False)
```

#### Правило, которое важно закрепить
Мы не «редактируем df_orders». Мы **строим новый результат** и сохраняем его в отдельную переменную.
Это базовая дисциплина, которая дальше сильно упрощает отладку пайплайнов.

---

## Один движок — два способа описать расчёт: DataFrame API и Spark SQL

В уроке мы делаем одну и ту же агрегацию (**количество заказов по статусам**) двумя способами:

### Вариант 1 — DataFrame API

```python
df_status_dfapi = (
    df_orders
    .groupBy("order_status")
    .agg(F.count("*").alias("cnt"))
    .orderBy(F.col("cnt").desc())
)
```

### Вариант 2 — Spark SQL

1) Создаём temp view:

```python
df_orders.createOrReplaceTempView("orders")
```

2) Пишем SQL:
3) 
```python
df_status_sql = spark.sql("""
SELECT
    order_status,
    COUNT(*) AS cnt
FROM orders
GROUP BY order_status
ORDER BY cnt DESC
""")
```

Это **два разных интерфейса** к одному и тому же движку. В модуле мы будем постоянно переключаться: где удобнее — пишем SQL, где удобнее — DataFrame API.


## Write: запись результатов и почему это «папка», а не «файл»

В Spark запись почти всегда идёт **в директорию**.

### CSV

```python
(
    df_orders_basic.write
    .mode("overwrite")
    .option("header", True)
    .csv("/workspace/lesson03_01/orders_full_csv")
)
```

После записи мы увидим набор файлов вида `part-....csv`.

### Parquet

```python
(
    df_orders_basic.write
    .mode("overwrite")
    .parquet("/workspace/lesson03_01/orders_full_parquet")
)
```

Parquet — основной формат для аналитических пайплайнов: он колоночный, с типами, со сжатием и обычно читается быстрее.


## Read-back validate

Самая простая, но очень полезная проверка:

1) записали  
2) прочитали обратно  
3) сравнили `count()`

Пример (как в ноутбуке):

```python
df_csv_back = (
    spark.read
    .option("header", True)
    .option("inferSchema", True)
    .csv("/workspace/lesson03_01/orders_full_csv")
)

df_parquet_back = spark.read.parquet("/workspace/lesson03_01/orders_full_parquet")

df_orders_basic.count(), df_csv_back.count(), df_parquet_back.count()
```

### Важная оговорка про порядок строк

В распределённой системе порядок строк **не гарантирован**, если вы явно не делаете сортировку в момент вывода/проверки.  
Поэтому в модуле мы часто проверяем не «первые 5 строк совпали», а более устойчивые признаки: `count()`, набор колонок, простые агрегаты, NULL-checks.


## Практика в этом уроке

В конце ноутбука — 8 заданий. Они специально простые: цель — набить руку на цикле:

- взять `df_orders` или view `orders`
- получить результирующий DataFrame
- сделать `show(..., truncate=False)`
- записать в `/workspace/lesson03_01/...`
- прочитать обратно
- сравнить `count()` / базовые условия