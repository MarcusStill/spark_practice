# Официальный Spark с пользователем 'spark'
FROM apache/spark:3.5.1

ENV DEBIAN_FRONTEND=noninteractive \
    PYSPARK_PYTHON=python3 \
    PYSPARK_DRIVER_PYTHON=python3 \
    LANG=C.UTF-8 LC_ALL=C.UTF-8

# Становимся root для установки Python
USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv ca-certificates tini procps \
 && ln -sf /usr/bin/python3 /usr/bin/python \
 && rm -rf /var/lib/apt/lists/*

# Лёгкая математика (не обязательно, но полезно)
RUN pip3 install --no-cache-dir numpy

# Возвращаемся к штатному пользователю образа
USER spark

# UI портов воркера (сам Spark пробросит), оставим для читаемости
EXPOSE 8081
