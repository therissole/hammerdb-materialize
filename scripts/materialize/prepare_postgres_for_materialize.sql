SELECT format(
    'CREATE ROLE %I LOGIN PASSWORD %L REPLICATION',
    :'mz_pg_user',
    :'mz_pg_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'mz_pg_user'
)
\gexec

GRANT CONNECT ON DATABASE :"mz_pg_db" TO :"mz_pg_user";
\connect :mz_pg_db

GRANT USAGE ON SCHEMA public TO :"mz_pg_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"mz_pg_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"mz_pg_user";

DO
$$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'public'
    LOOP
        EXECUTE format(
            'ALTER TABLE %I.%I REPLICA IDENTITY FULL',
            r.schemaname,
            r.tablename
        );
    END LOOP;
END
$$;

DO
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'mz_tpcc_pub') THEN
        CREATE PUBLICATION mz_tpcc_pub FOR ALL TABLES;
    END IF;
END
$$;
