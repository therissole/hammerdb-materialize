-- Run this after the MSSQL TPCC schema is created and CDC is enabled.

CREATE SCHEMA IF NOT EXISTS tpcc;

DROP MATERIALIZED VIEW IF EXISTS tpcc.tpcc_orders_per_district;
DROP MATERIALIZED VIEW IF EXISTS tpcc.tpcc_open_orders;
DROP SOURCE IF EXISTS tpcc.tpcc_src CASCADE;
DROP CONNECTION IF EXISTS tpcc.mssql_connection;
DROP SECRET IF EXISTS tpcc.mssql_password;

CREATE SECRET tpcc.mssql_password AS :'mz_mssql_password';

CREATE CONNECTION tpcc.mssql_connection
TO SQL SERVER (
    HOST :'mz_mssql_host',
    PORT :mz_mssql_port,
    DATABASE :'mz_mssql_db',
    USER :'mz_mssql_user',
    PASSWORD SECRET tpcc.mssql_password,
    SSL MODE = :'mz_mssql_sslmode'
);

CREATE SOURCE tpcc.tpcc_src
FROM SQL SERVER CONNECTION tpcc.mssql_connection
FOR ALL TABLES;

CREATE MATERIALIZED VIEW tpcc.tpcc_orders_per_district AS
SELECT
    o_w_id,
    o_d_id,
    count(*) AS order_count
FROM tpcc.orders
GROUP BY o_w_id, o_d_id;

CREATE MATERIALIZED VIEW tpcc.tpcc_open_orders AS
SELECT
    o.o_w_id AS warehouse_id,
    w.w_name AS warehouse_name,
    o.o_d_id AS district_id,
    d.d_name AS district_name,
    o.o_id AS order_id,
    o.o_entry_d AS order_entry_ts,
    c.c_id AS customer_id,
    c.c_first,
    c.c_last,
    CASE
        WHEN o.o_carrier_id IS NULL THEN 'OPEN'
        ELSE 'DELIVERED'
    END AS order_status
FROM tpcc.new_order no
JOIN tpcc.orders o
    ON o.o_w_id = no.no_w_id
   AND o.o_d_id = no.no_d_id
   AND o.o_id = no.no_o_id
JOIN tpcc.customer c
    ON c.c_w_id = o.o_w_id
   AND c.c_d_id = o.o_d_id
   AND c.c_id = o.o_c_id
JOIN tpcc.warehouse w
    ON w.w_id = o.o_w_id
JOIN tpcc.district d
    ON d.d_w_id = o.o_w_id
   AND d.d_id = o.o_d_id;
