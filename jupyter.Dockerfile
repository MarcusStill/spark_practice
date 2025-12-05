FROM python:3.8-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PYSPARK_PYTHON=python3 \
    PYSPARK_DRIVER_PYTHON=python3 \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PIP_DEFAULT_TIMEOUT=120

# Утилиты + Java (default-jre-headless = 17 на Debian bookworm, Spark 3.5 ок)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      default-jre-headless curl tini ca-certificates git procps \
 && rm -rf /var/lib/apt/lists/*

# Python-пакеты
RUN python -m pip install --no-cache-dir \
      pyspark==3.5.1 \
      jupyterlab==4.* ipykernel \
      pandas pyarrow numpy findspark

# Пользователь и рабочая папка (запуск из compose как root для фикса прав)
RUN useradd -ms /bin/bash jovyan
WORKDIR /home/jovyan/work

EXPOSE 8888

CMD ["bash","-lc","jupyter lab \
 --ServerApp.ip=0.0.0.0 \
 --ServerApp.port=8888 \
 --ServerApp.token='' \
 --ServerApp.allow_remote_access=True \
 --ServerApp.disable_check_xsrf=True \
 --ServerApp.open_browser=False"]
