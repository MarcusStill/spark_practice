# Troubleshooting: стенд `spark_01` (Postgres, DBeaver, Jupyter, JARs, MinIO)

Этот документ про две самые частые проблемы:

1) Postgres и подключения (psql, DBeaver).
2) JAR’ы, MinIO и “почему `/jars` пустой / s3a не работает”.

Если “ничего не работает” и непонятно, с чего начать, иди по дереву диагностики ниже.


## Контекст стенда

- Postgres в Docker: сервис `postgres`
- наружу: `localhost:5433` -> внутри контейнера: `postgres:5432`
- база: `dwh`
- user: `app`
- пароль: см. `.env` (если не меняли, чаще всего `app`)

Важно: команда `docker compose exec postgres psql ...` подключается изнутри контейнера. DBeaver подключается по TCP. Это разные режимы, и они по-разному “ловят” проблемы с паролем и сетью.


## 1. Быстрое дерево диагностики

### 1.1. Вы в корне проекта?

Сначала честно проверьте, что вы запускаете команды там, где лежит `docker-compose.yml`:

```bash
pwd
ls -la docker-compose.yml
```

Если `docker-compose.yml` не находится, вы не в корне проекта. Перейдите в папку проекта и только там запускайте `docker compose ...`.

Почему это важно: volume `./jars:/jars` монтируется относительно текущей папки. Если вы “случайно” запустили compose из другого места, `/jars` внутри контейнеров будет пустой, даже если на диске папка `jars` есть.


### 1.2. Контейнеры запущены?

```bash
docker compose ps
```

Ожидаемо:
- `postgres`, `jupyter`, `spark-master`, `spark-worker-*` в `running`
- `airflow-init` / `minio-init` могут быть `exited` (одноразовые init-контейнеры, это ок)

Если `postgres` / `jupyter` / `spark-master` в `exited` или `restarting`:
```bash
docker compose logs --tail=200 postgres
docker compose logs --tail=200 jupyter
docker compose logs --tail=200 spark-master
```


### 1.3. Postgres живой?

Быстро изнутри контейнера:
```bash
docker compose exec postgres psql -U app -d dwh -c "select 1 as ok;"
```

Если вернул `ok=1`, Postgres жив. Дальше проверяем TCP, как у DBeaver.

Ключевой тест “как DBeaver” (TCP):
```bash
docker compose exec postgres psql -h 127.0.0.1 -U app -d dwh -c "select current_user, current_database();"
```

- если успешно, сеть и пароль ок
- если `password authentication failed`, проблема в пароле (см. раздел B1)
- если `could not connect` / `connection refused`, проблема в порте/сети (см. раздел B5)


### 1.4. JAR’ы видны в контейнерах?

1) на хосте:
```bash
ls -la jars
```

2) внутри контейнера (Jupyter и Spark Master):
```bash
docker compose exec jupyter ls -la /jars
docker compose exec spark-master ls -la /jars
```

Если в контейнере `/jars` пусто, это почти всегда одно из двух:
- `docker compose` запускали не из корня проекта (см. A1)
- Windows + Git Bash “ломает” путь `/jars` (см. раздел C1)

Если `/jars` внутри контейнера заполнен, но ноутбук всё равно падает на assert, проверьте, в каком Jupyter/kernе вы запускаете ноутбук (см. раздел C2).


### 1.5. Ноутбук видит `/jars`?

В первой ячейке ноутбука выполните:

```python
import os, sys, glob

print("python:", sys.executable)
print("cwd:", os.getcwd())
print("/jars exists:", os.path.exists("../jars"))
print("/jars glob:", glob.glob("/jars/*.jar"))
```

Ожидаемо:
- `/jars exists: True`
- `/jars glob:` содержит 3 файла (hadoop-aws, aws-java-sdk-bundle, postgresql)

Если `glob` пустой, а в контейнере `/jars` не пустой, значит ноутбук запущен не там (см. C2).


---

## 2. Postgres и DBeaver

### 2.1. `FATAL: password authentication failed for user "app"`

Что это значит: до Postgres вы дошли, но пароль не совпал.

1) Проверьте “как DBeaver”:
```bash
docker compose exec postgres psql -h 127.0.0.1 -U app -d dwh -c "select 1;"
```

2) Если пароль не подходит, задайте пароль вручную:
```bash
docker compose exec postgres psql -U app -d dwh
```

```sql
ALTER USER app WITH PASSWORD 'app';
\q
```

После этого снова выполните TCP-тест (п.1).

Если вы меняли `POSTGRES_*` или init-скрипты и ждёте, что изменения применятся “сами”,
то не применятся. Postgres живёт в volume. Иногда нужен сброс (удалит данные БД):

```bash
docker compose down -v
docker compose up -d
```


### 2.2. `FATAL: role "postgres" does not exist`

В этом стенде роль `postgres` может отсутствовать. Используйте `app`:

```bash
docker compose exec postgres psql -U app -d dwh
```


### 2.3. `Database directory appears to contain a database; Skipping initialization`

Это не ошибка. Это означает, что volume уже инициализирован.

Проблема начинается, когда вы меняете переменные/скрипты и ждёте, что они применятся.
Тогда нужен сброс volume (см. B1).


### 2.4. `psql: ... No such file or directory`

Обычно Postgres ещё стартует или контейнер упал.

1) статусы:
```bash
docker compose ps
```

2) логи:
```bash
docker compose logs -f postgres
```

Ждём строку вида `database system is ready to accept connections`.


### 2.5. “не подключается по сети”, порт 5433 мёртвый

Симптомы:
- `psql -h 127.0.0.1 ...` -> `could not connect`
- DBeaver -> `Connection refused`

Порядок действий:
1) убедитесь, что `docker compose ps` показывает проброс порта `0.0.0.0:5433->5432/tcp`
2) на Windows проверьте порт:
```powershell
Test-NetConnection 127.0.0.1 -Port 5433
```
3) если порт занят, меняйте внешний порт в `docker-compose.yml`, например на 5435:
```yaml
ports:
  - "5435:5432"
```
и подключайтесь на 5435.


---

## 3. JAR’ы, MinIO и “почему `/jars` не виден”

### 3.1. Windows + Git Bash: `/jars` превращается в `C:\Program Files\Git\jars`

Это классика. Git Bash (MSYS) пытается “помочь” и конвертит Unix-пути в Windows-пути.
В итоге команда выглядит так, будто вы лезете в `C:/Program Files/Git/jars` и падаете с ошибкой.

Как лечить:
- лучший вариант: выполнять команды `docker compose ...` в PowerShell или обычном cmd
- если вы всё же в Git Bash, используйте префикс:

```bash
MSYS_NO_PATHCONV=1 docker compose exec jupyter ls -la /jars
MSYS_NO_PATHCONV=1 docker compose exec spark-master ls -la /jars
```

То же самое относится к любым командам, где есть аргументы с путями вида `/something`.


### 3.2. Запустили ноутбук не в Docker Jupyter (и всё “не видит” `/jars`, `/data`, `/workspace`)

Правильный сценарий для практикума:
- подняли стенд `docker compose up -d`
- открыли браузер: `http://localhost:8890`
- запускаете ноутбук в этом JupyterLab

Если запускаете через VS Code:
- вы должны подключиться к Jupyter Server из Docker, а не к локальному Python.
Иначе окружение будет “ваше локальное”, а не контейнерное, и пути `/jars` просто не существуют.

Диагностика в ноутбуке (см. A5):
- `sys.executable` должен быть из контейнера
- `/jars exists` должен быть True


### 3.3. “Я скачал JAR’ы после запуска контейнеров. Нужно ли rebuild?”

Нет, build не нужен. JAR’ы подключаются как volume (`./jars:/jars`).

Что может понадобиться:
- если SparkSession уже запущен, перезапустите kernel в ноутбуке
- иногда полезно перезапустить Spark и Jupyter контейнеры:

```bash
docker compose restart jupyter spark-master spark-worker-1 spark-worker-2
```


### 3.4. Быстрая проверка “всё ли готово для MinIO”

1) внутри контейнера Jupyter:
```bash
docker compose exec jupyter ls -la /jars
```

2) в ноутбуке:
```python
import glob
print(sorted(glob.glob("/jars/*.jar")))
```

3) если пишете в MinIO, проверьте, что бакет и объекты видны в консоли:
- MinIO Console: http://localhost:9001
