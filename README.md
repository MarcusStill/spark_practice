# spark_practice

Мини-стенд DE: **Docker + Postgres + Spark + Jupyter + MinIO + Airflow**.

Задача — пройти путь от сырых CSV до слоя STG, а дальше — к core и витринам.

---

## Сервисы

- JupyterLab: http://localhost:8890
- Spark Master UI: http://localhost:18080
- Spark Workers UI: http://localhost:8081, http://localhost:8082
- Airflow UI: http://localhost:8085
- MinIO Console: http://localhost:9001
- MinIO API (S3): http://localhost:9000

Postgres (для DBeaver и psql):
- host: 127.0.0.1
- port: 5433 (на хосте) -> 5432 (в контейнере)
- db: dwh
- user: app
- password: см. `.env`

---

## Быстрый старт

```bash
git clone url-репозитория spark_01
cd spark_01
```

Проверка:
```bash
ls -la docker-compose.yml
```


### 1) Создайте `.env` (один раз)

Linux/Mac/Git Bash:
```bash
cp .env_template .env
```

Windows PowerShell:
```powershell
Copy-Item .env_template .env
```

Сгенерируйте и вставьте в `.env`:

Fernet key (для Airflow):
```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Webserver secret key:
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```


### 2) Скачайте JAR’ы (рекомендую сделать сразу)

Эти JAR’ы нужны:
- для работы Spark с MinIO (`s3a://...`)
- для чтения из Postgres через JDBC

Мы не храним их в репозитории, поэтому скачиваем локально в `./jars`.

Должно получиться так:
- `jars/hadoop-aws-3.3.4.jar`
- `jars/aws-java-sdk-bundle-1.12.262.jar`
- `jars/postgresql-42.7.4.jar`

Linux / Mac:
```bash
mkdir -p jars

curl -L -o jars/hadoop-aws-3.3.4.jar   https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar
curl -L -o jars/aws-java-sdk-bundle-1.12.262.jar   https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar
curl -L -o jars/postgresql-42.7.4.jar https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar

ls -la jars
```

Windows (PowerShell):
```powershell
New-Item -ItemType Directory -Force -Path jars | Out-Null

Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar" `
  -OutFile "jars\hadoop-aws-3.3.4.jar"

Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar" `
  -OutFile "jars\aws-java-sdk-bundle-1.12.262.jar"

Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar" `
  -OutFile "jars\postgresql-42.7.4.jar"

Get-ChildItem jars
```

Важно:
- JAR’ы подключаются как volume (`./jars:/jars`). Пересборка образов не нужна.
- Если вы скачали JAR’ы, когда контейнеры уже запущены, обычно хватает рестарта:

```bash
docker compose restart jupyter spark-master spark-worker-1 spark-worker-2
```

Проверка, что JAR’ы видны внутри контейнеров:
```bash
docker compose exec jupyter ls -la /jars
docker compose exec spark-master ls -la /jars
```

Windows + Git Bash: если видите ошибку вида `C:/Program Files/Git/jars`, это MSYS path-conversion.
Либо используйте PowerShell, либо так:
```bash
MSYS_NO_PATHCONV=1 docker compose exec jupyter ls -la /jars
MSYS_NO_PATHCONV=1 docker compose exec spark-master ls -la /jars
```

### 3) Поднимите стек

Первый раз (или после изменения Dockerfile/compose):
```bash
docker compose up -d --build
```

Обычно:
```bash
docker compose up -d
```

Проверка:
```bash
docker compose ps
```

### 4) Откройте UI

- Jupyter: http://localhost:8890
- Spark Master: http://localhost:18080
- Airflow: http://localhost:8085
- MinIO Console: http://localhost:9001

### 5) Быстрые smoke-checks

Postgres:
```bash
docker compose exec postgres psql -U app -d dwh -c "select 1 as ok;"
```

Если подключаетесь из DBeaver, используйте:
- Host: 127.0.0.1
- Port: 5433
- Database: dwh
- User: app
- Password: из `.env`

Jupyter:
- открывается `http://localhost:8890`
- в ноутбуке можно выполнить:

```python
import os, sys, glob
print("python:", sys.executable)
print("cwd:", os.getcwd())
print("/jars exists:", os.path.exists("/jars"))
print("/jars glob:", glob.glob("/jars/*.jar"))
```

Ожидаемо: `/jars exists: True` и список jar.

## Структура проекта

```
spark_01/                 # корень проекта
  dags/                   # Airflow DAG’и
  data/
    csv/                  # исходные CSV
    parquet/              # parquet (для Spark/MinIO)
    raw/                  # сырые данные (Olist, другие источники)
    ...
  db/
    demo/                 # скрипт с демо-таблицей для теста SCD2
    postgres/
      init/
        001_schemas.sql   # схемы и базовые объекты
        002_stg_ddl.sql   # таблицы STG
        003_core_ddl.sql  # таблицы CORE
    solutions/
    templates/            # шаблоны SQL
    tmp/
    work/                 # рабочие sql-скрипты
  docker/
  files/
  jars/                   # JAR’ы для Spark (s3a и JDBC)
  md/                     # подробные разъяснения к отдельным проблемам/разделам
  modules/
    module01_ingest/      # уроки модуля 1 (RAW → STG)
    module02_core/        # уроки модуля 2 (CORE)
    ...
  notebooks/
    m1_raw_and_jdbc_template.ipynb   # шаблон ноутбука
    ...
  scripts/
    put_to_raw.py         # скрипт для раскладки CSV в RAW
    ...
  spark/
  
  docker-compose.yml      # описание docker-стенда
  jupyter.Dockerfile
  README.md               # общее описание проекта
  requirements.txt
  troubleshooting.md      # диагностика проблем
  worker.Dockerfile
```
