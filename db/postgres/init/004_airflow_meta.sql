DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'airflow') THEN
    CREATE ROLE airflow LOGIN PASSWORD 'airflow';
  END IF;
END $$;

SELECT format('CREATE DATABASE %I OWNER %I', 'airflow_meta', 'airflow')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'airflow_meta')
\gexec

ALTER DATABASE airflow_meta OWNER TO airflow;
GRANT ALL PRIVILEGES ON DATABASE airflow_meta TO airflow;
