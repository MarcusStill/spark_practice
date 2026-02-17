# Урок 2.4 - Data Quality в CORE: что проверить в фактах и измерениях

## Цели урока

- определяем, какие основные ошибки стоит искать в CORE;
- разделяем проверки на:
  - объём и покрытие;
  - связность факт ↔ измерения;
  - специфику SCD2;
  - здравый бизнес-смысл;
- формируем свой набор SQL-чеков для `dim_*` и `fct_order_items`;
- формулируем, какие из этих проверок точно стоит **автоматизировать** в пайплайне.


## 0. Текущая схема CORE

- `core.dim_product` (SCD1)
- `core.dim_seller`  (SCD1)
- `core.dim_customer` (SCD2)
- `core.fct_order_items` — факт позиций заказа с ссылками на измерения

Плюс STG-слой:

- `stg.orders`, `stg.order_items`, `stg.customers`, `stg.products`, `stg.sellers`
- везде есть `ingest_date`.

Все проверки в этом уроке будем мысленно вешать именно на эти таблицы.

---

## 1. Что такое Data Quality в CORE

Упроще́нно, **DQ** в CORE — это ответы на несколько вопросов:

1. **Объём и полнота**
   - Дошли ли строки из STG до CORE?
   - Не потерялись ли по дороге целые батчи или части батча?

2. **Связность**
   - Все ли ключи из факта мэчатся с измерениями?
   - Нет ли «висящих» ссылок на клиентов/товары/селлеров, которых нет в `dim_*`?

3. **Корректность истории (для SCD2)**
   - Есть ли у клиента **одна текущая версия**, а не две?
   - Не пересекаются ли интервалы `effective_from/effective_to`?

4. **Здравый смысл и бизнес-логика**
   - Нет ли заказов с отрицательной выручкой?
   - Нет ли товаров с нулевым весом/размером?
   - Нет ли регионов, которых вообще не ожидали увидеть?

В реальных проектах вокруг этого строят целые DQ-платформы, алерты и дашборды.  
Здесь мы сделаем **первый ручной набор** проверок.

---

## 2. Объём и покрытие (fct ↔ STG)

Идея:

> «Если я возьму период X и посчитаю объёмы в STG и CORE — цифры должны быть сопоставимы. Если нет — надо понимать, почему».

### Какие проверки имеет смысл сделать

1. **Сравнение количества строк в факте и в STG**  
   Например: количество строк в `fct_order_items` за определённый период vs количество строк в `stg.order_items` за те же заказы/даты.

2. **Покрытие факта по заказам**
   - Сколько уникальных `order_id` есть в факте?
   - Сколько уникальных `order_id` есть в `stg.orders` за тот же период?
   - Разница объяснима?

3. **Проверка «дыр» по датам**
   - Есть ли дни (по дате заказа или по `ingest_date`), когда:
     - в STG есть строки, а в факте — нет;
     - в факте есть строки, а в STG — нет.

### 2.1. Добавим минимальную проверку 

Добавим простую проверку, которая сравниваtт количество строк `stg.order_items` и `core.fct_order_items` за месяц и показывает уведомление, если есть расхождение.

```sql
with counts as (
    select
        (select count(distinct order_id || ':' || order_item_id)
         from stg.order_items
         where ingest_date >= date_trunc('month', current_date - interval '1 month')
           and ingest_date < date_trunc('month', current_date)) as stg_count,
        
        (select count(*)
         from core.fct_order_items
         where src_ingest_date >= date_trunc('month', current_date - interval '1 month')
           and src_ingest_date < date_trunc('month', current_date)) as fct_count
)
select 
    stg_count,
    fct_count,
    stg_count - fct_count as difference,
    case 
        when stg_count > 0 
        then round(100.0 * (stg_count - fct_count) / stg_count, 2)
        else 0
    end as diff_percent,
    case 
        when stg_count = fct_count then 'OK'
        when abs(stg_count - fct_count) > stg_count * 0.02 then 'ALERT'
        else 'WARNING'
    end as status
from counts;
```

2. Определимся с **расхождениями**:
* Нормальные расхождения (допустимые):
  - дедупликация в источнике (до 1-2%): в STG могут быть дубли из-за повторных загрузок или ошибок источника;
  - технический брак/мусор (до 0.5%): например, тестовые заказы без customer_id или product_id;
  - лаги по времени (если смотрим "на лету"): данные могли частично загрузиться в STG, но ещё не попали в CORE;
* Тревожные расхождения:
  - если стабильно теряем больше 2% записей — что-то сломалось;
  - пропадают целые заказы (не отдельные позиции): в STG есть order_id, в CORE его нет совсем;
  - расхождения в ключевых метриках: сумма price/freight_value сильно отличается/количество заказов по дням не сходится;
  - асхождение растет со временем: было 0.5%, стало 1%, потом 1.5%.

## 3. Связность факт ↔ измерения

Идея:

> «Каждая строка факта должна мэпиться на клиентов, продавцов и товары. Если что-то не мэпится — значит, мы потеряли измерение или датасет отстаёт».

### Какие проверки имеет смысл сделать

1. **Простая проверка orphan-ключей по каждому измерению**  
   Для каждого измерения:

   - сколько строк факта не мэчатся по `product_id` → `dim_product`;
   - сколько — по `seller_id` → `dim_seller`;
   - сколько — по `customer_unique_id`/`customer_id` → `dim_customer`.

2. **Доля покрытых строк факта**
   - доля строк факта, где **все три измерения** найдены;
   - доля строк, где отсутствует хотя бы одно измерение.

3. **Проверка «справочников-пустышек»**
   - есть ли товары/продавцы/клиенты, которые есть в STG, но ни разу не встретились во факте;
   - насколько это ожидаемо (например, товары есть в каталоге, но ещё не продавались).

### 3.1. Добавим gроверки на orphan-ключи в фактовой таблице

1. Проверка для product

```sql
with product_orphans as (
    select
        count(*) as orphan_count,
        round(100.0 * count(*) / (select count(*) from core.fct_order_items), 2) as orphan_percent
    from core.fct_order_items f
    left join core.dim_product p on f.product_sk = p.product_sk
    where p.product_sk is null
)
select 
    'product' as dimension,
    orphan_count,
    orphan_percent,
    case 
        when orphan_percent > 5 then 'CRITICAL'
        when orphan_percent > 2 then 'WARNING'
        else 'OK'
    end as status
from product_orphans;
```

2. Проверка для seller

```sql
with seller_orphans as (
    select
        count(*) as orphan_count,
        round(100.0 * count(*) / (select count(*) from core.fct_order_items), 2) as orphan_percent
    from core.fct_order_items f
    left join core.dim_seller s on f.seller_sk = s.seller_sk
    where s.seller_sk is null
)
select 
    'seller' as dimension,
    orphan_count,
    orphan_percent,
    case 
        when orphan_percent > 5 then 'CRITICAL'
        when orphan_percent > 2 then 'WARNING'
        else 'OK'
    end as status
from seller_orphans;
```

3. Проверка для customer

```sql
with customer_orphans as (
    select
        count(*) as orphan_count,
        round(100.0 * count(*) / (select count(*) from core.fct_order_items), 2) as orphan_percent
    from core.fct_order_items f
    left join core.dim_customer c on f.customer_sk = c.customer_sk
    where c.customer_sk is null
)
select 
    'customer' as dimension,
    orphan_count,
    orphan_percent,
    case 
        when orphan_percent > 5 then 'CRITICAL'
        when orphan_percent > 2 then 'WARNING'
        else 'OK'
    end as status
from customer_orphans;
```

## 4. Специфика SCD2 (`dim_customer`)

Здесь больше логики вокруг **истории версий**.

Идея:

> «У одного клиента не должно быть двух “текущих” адресов одновременно, и версии не должны пересекаться по времени».

### Какие проверки имеет смысл сделать

1. **Одна текущая версия на клиента**
   - по каждому `customer_unique_id` число строк с `is_current = true` не больше 1.

2. **Отсутствие пересечений интервалов**
   - для одного клиента не должно быть так, что две разные версии:
     - одновременно `is_current = true`, или
     - их интервалы `[effective_from, effective_to]` пересекаются.

3. **Покрытие истории без «дыр»** (опционально, для продвинутых)
   - если смотреть по `effective_from/effective_to`, между версиями нет больших неожиданных дыр (например, история обрывается год назад, хотя в STG были новые записи).

### 4.1. Добавим дополнительную проверку

**«Две текущих версии»**: сформируем запрос, отображающий клиентов, у которых больше одной строки с `is_current = true`.

```sql
-- Клиенты с несколькими текущими версиями
with duplicate_current as (
    select 
        customer_unique_id,
        count(*) as current_versions_count,
        array_agg(customer_sk order by effective_from) as customer_sk_list,
        array_agg(effective_from order by effective_from) as effective_from_list,
        array_agg(effective_to order by effective_from) as effective_to_list,
        array_agg(src_ingest_date order by effective_from) as ingest_dates
    from core.dim_customer
    where is_current = true
    group by customer_unique_id
    having count(*) > 1
)
select 
    customer_unique_id,
    current_versions_count,
    customer_sk_list,
    effective_from_list,
    effective_to_list,
    ingest_dates
from duplicate_current
order by current_versions_count desc, customer_unique_id; 
```

План действий при обнаружении двух текущих версий
1. **Диагностика**
   - выделить всех проблемных клиентов через запрос выше
   - посмотреть на паттерн — это массовый сбой или единичные случаи?
   - проверить даты загрузки (src_ingest_date) — возможно, сбой в конкретном батче

2. Определение "правильной" версии
   - какая версия актуальнее (по effective_from, по src_ingest_date)? 
   - какая версия используется в фактах (проверить fct_order_items)? 
   - есть ли бизнес-правила для выбора (например, версия с более поздним адресом)? 
3. Исправление
   - для неправильной текущей версии выставить is_current = false
   - убедиться, что effective_to заполнен корректно (предыдущий день от новой версии)
   - проверить, что у клиента осталась ровно одна текущая версия


В витринах могут возникнуть следующие **баги**:
1. Завышенные метрики в агрегатах. При подсчете количества активных клиентов один и тот же клиент будет учтен дваждыв витринах, если у клиента будет две текущих версии;
2. Некорректные джойны с фактами. При присоединении к фактам по is_current = true могут вернуться несколько строк для одного заказа.
3. Противоречивая аналитика по изменениям. Невозможно корректно построить историю изменений клиента.
4. Ошибки в slowly changing dimensions отчетах. Отчеты "как менялись клиенты со временем" будут показывать аномалии.
   - как ты будешь чинить такие ситуации (в общих чертах).

## 5. Здравый смысл и бизнес-логика

Формальные проверки — это хорошо, но часто сильнее всего ловят баги **простые sanity-чек-витрины**:

> «Посмотрим топ-категории, города, суммы — не выглядит ли это абсурдно?»

Что имеет смысл посмотреть:

1. **Распределение сумм и количеств**
   - минимальные/максимальные/средние значения `price`, `freight_value`, количества позиций в заказе;
   - наличие отрицательных или нулевых значений там, где их быть не должно.

2. **Топ-N по категориям / продавцам / городам**
   - топ категорий по выручке;
   - топ городов клиентов;
   - топ продавцов.

3. **Редкие/подозрительные значения**
   - категории `NULL`/«None»/непонятные строки;
   - странные `state`/город, которых ты не ожидал увидеть.

### 5.1. Sanity-чеки для core.fct_order_items****

1. Проверка сумм и количеств (минимумы/максимумы/средние)

```sql
 select 
    'ЦЕНА' as метрика,
    round(min(price)::numeric, 2) as минимум,
    round(max(price)::numeric, 2) as максимум,
    round(avg(price)::numeric, 2) as среднее,
    count(*) as всего_строк,
    count(case when price <= 0 then 1 end) as бесплатных,
    count(case when price > 5000 then 1 end) как_дорого
from core.fct_order_items

union all

select 
    'ДОСТАВКА',
    round(min(freight_value)::numeric, 2),
    round(max(freight_value)::numeric, 2),
    round(avg(freight_value)::numeric, 2),
    count(*),
    count(case when freight_value <= 0 then 1 end),
    count(case when freight_value > 500 then 1 end)
from core.fct_order_items;
```

Результат:

```text
метрика |минимум|максимум|среднее|всего_строк|бесплатных|как_дорого|
--------+-------+--------+-------+-----------+----------+----------+
ДОСТАВКА|   0.00|  409.68|  19.99|     112650|       383|         0|
ЦЕНА    |   0.85| 6735.00| 120.65|     112650|         0|         3|
```

2. Проверка топ-5 категорий (что продается лучше всего)

```sql
select 
    p.product_category_name as категория,
    count(*) as сколько_продали,
    round(avg(price)::numeric, 2) as средняя_цена,
    round(sum(price)::numeric, 2) as всего_выручка
from core.fct_order_items f
join core.dim_product p on f.product_sk = p.product_sk
where p.product_category_name is not null
group by p.product_category_name
order by сколько_продали desc
limit 5;
```

Результат:

```text
категория             |сколько_продали|средняя_цена|всего_выручка|
----------------------+---------------+------------+-------------+
cama_mesa_banho       |          11115|       93.30|   1036988.68|
beleza_saude          |           9670|      130.16|   1258681.34|
esporte_lazer         |           8641|      114.34|    988048.97|
moveis_decoracao      |           8334|       87.56|    729762.49|
informatica_acessorios|           7827|      116.51|    911954.32|
```

3. Топ-5 городов (где больше всего покупают)

```sql
select 
    c.customer_city as город,
    c.customer_state as штат,
    count(*) as заказов,
    round(avg(price)::numeric, 2) as средний_чек
from core.fct_order_items f
join core.dim_customer c on f.customer_sk = c.customer_sk
where c.customer_city is not null
group by c.customer_city, c.customer_state
order by заказов desc
limit 5;
```

Результат:

```text
город         |штат|заказов|средний_чек|
--------------+----+-------+-----------+
sao paulo     |SP  |  17892|     107.55|
rio de janeiro|RJ  |   7694|     126.19|
belo horizonte|MG  |   3128|     113.20|
brasilia      |DF  |   2413|     125.86|
curitiba      |PR  |   1735|     122.39|
```

4. Редкие значения (подозрительные категории или штаты)

```sql
select 
    count(case when p.product_category_name is null then 1 end) as товаров_без_категории,
    count(case when c.customer_state is null or length(c.customer_state) != 2 then 1 end) as странных_штатов
from core.fct_order_items f
left join core.dim_product p on f.product_sk = p.product_sk
left join core.dim_customer c on f.customer_sk = c.customer_sk;
```

Результат:

```text
товаров_без_категории|странных_штатов|
---------------------+---------------+
                 1603|              1|
```

### 5.2. Типичные аномалии:

1. По ценам:
    - иногда встречаются нулевые цены — нужно проверять, это баг или фича;
    - очень редко, но бывают отрицательные freight_value (возможно, возвраты или скидки на доставку).

2. По категориям:
   - категория None или NULL — обычно 1-2% данных, допустимо;
   - в топ-категориях всегда лидируют beleza_saude, relogios_presentes — это нормально для бразильского маркетплейса.

3. По географии:
   - SP (São Paulo) всегда доминирует — это ок;
   - иногда появляются штаты с кодом из 1 буквы или цифры — явная ошибка загрузки

## 6. Черновик мини DQ-чеклиста для пайплайна

Представим, что:

> Завтра надо будет автоматизировать ежедневный пайплайн RAW → STG → CORE для Olist, а Data Quality-чек — это **обязательный шаг** DAG-а.

Разделим проверки на 2 категории:

1. **Критичные проверки**, которые ты считаешь:
   - все STG-таблицы: отсутствие дублей по бизнес-ключу в рамках одного ingest_date);
   - Проверка ссылочной целостности при загрузке CORE (core.fct_order_items → stg.orders, stg.order_items): 
     все загружаемые во факт заказы имеют соответствующие записи в orders и order_items
   - и полезными для ежедневного мониторинга.

2. Важные проверки:
   - мониторинг аномалий в объемах данных: все CORE-таблицы - анализ резкого изменения количества строк;
   - проверка заполненности критических полей в core.fct_order_items, core.fact_orders: процент NULL-значений в ключевых полях;
   - валидация бизнес-правил в core.fct_order_items: корректность сумм (price > 0, freight_value >= 0);
   - проверка последовательности дат в stg.orders: Логика временных меток (order_purchase_ts ≤ order_approved_at ≤ order_delivered_customer_date);
   - свежесть данных: проверка на то, что данные за вчерашний день присутствуют в STG

## 7. Итоги модуля

К **закрытию модуля 2** имеем следующее:

- слой STG с основными таблицами Olist и `ingest_date`;
- слой CORE:
  - `core.dim_product` и `core.dim_seller` как SCD1-измерения;
  - `core.dim_customer` как SCD2 с историей адресов;
  - `core.fct_order_items` как факт позиций заказов;
- черновик **DQ-проверок**, который в дальнейшем надо будет реализовать в пайплайне.
