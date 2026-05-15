DO
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tpcc') THEN
        CREATE ROLE tpcc LOGIN PASSWORD 'tpcc';
    END IF;
END
$$;

GRANT ALL PRIVILEGES ON DATABASE tpcc TO tpcc;
