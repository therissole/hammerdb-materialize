-- Run this after TPCC schema is created and publication mz_tpcc_pub exists in Postgres.

CREATE SCHEMA IF NOT EXISTS tpcc;

DROP MATERIALIZED VIEW IF EXISTS tpcc.tpcc_orders_per_district;
DROP SOURCE IF EXISTS tpcc.tpcc_src CASCADE;
DROP CONNECTION IF EXISTS tpcc.pg_tpcc;
DROP SECRET IF EXISTS tpcc.pgpass;

CREATE SECRET tpcc.pgpass AS :'mz_pg_password';

CREATE CONNECTION tpcc.pg_tpcc
TO POSTGRES (
    HOST :'mz_pg_host',
    PORT :mz_pg_port,
    DATABASE :'mz_pg_db',
    USER :'mz_pg_user',
    PASSWORD SECRET tpcc.pgpass,
    SSL MODE :'mz_pg_sslmode'
);

CREATE SOURCE tpcc.tpcc_src
FROM POSTGRES CONNECTION tpcc.pg_tpcc (PUBLICATION 'mz_tpcc_pub')
FOR ALL TABLES;

CREATE MATERIALIZED VIEW tpcc.tpcc_orders_per_district AS
SELECT
    o_w_id,
    o_d_id,
    count(*) AS order_count
FROM tpcc.orders
GROUP BY o_w_id, o_d_id;
