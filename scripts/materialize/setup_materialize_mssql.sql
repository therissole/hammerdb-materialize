-- Run this after the MSSQL TPCC schema is created and CDC is enabled.

CREATE SCHEMA IF NOT EXISTS tpcc;

DROP MATERIALIZED VIEW IF EXISTS tpcc.order_summary;
DROP VIEW IF EXISTS tpcc.order_summary;
DROP MATERIALIZED VIEW IF EXISTS tpcc.order_detail;
DROP VIEW IF EXISTS tpcc.order_detail;
DROP MATERIALIZED VIEW IF EXISTS tpcc.tpcc_orders_per_district;
DROP VIEW IF EXISTS tpcc.tpcc_orders_per_district;
DROP MATERIALIZED VIEW IF EXISTS tpcc.tpcc_open_orders;
DROP VIEW IF EXISTS tpcc.tpcc_open_orders;
DROP INDEX IF EXISTS tpcc.idx_order_summary_customer_recent;
DROP INDEX IF EXISTS tpcc.idx_order_summary_district;
DROP INDEX IF EXISTS tpcc.idx_order_detail_order;
DROP INDEX IF EXISTS tpcc.idx_tpcc_orders_per_district_count;
DROP INDEX IF EXISTS tpcc.idx_tpcc_open_orders_lookup;
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
FOR TABLES (
    dbo.warehouse,
    dbo.district,
    dbo.customer,
    dbo.history,
    dbo.new_order,
    dbo.orders,
    dbo.order_line,
    dbo.item,
    dbo.stock
);

CREATE VIEW tpcc.order_summary AS
SELECT
    od.o_id,
    od.o_w_id,
    od.o_d_id,
    od.o_c_id,
    od.o_ol_cnt,
    od.o_entry_d,
    wa.w_id,
    wa.w_name,
    cu.c_first,
    cu.c_last,
    cu.c_state,
    cu.c_street_1,
    cu.c_street_2,
    cu.c_phone,
    (
        SELECT sum(ol.ol_amount)
        FROM tpcc.order_line ol
        WHERE ol.ol_o_id = od.o_id
          AND ol.ol_d_id = od.o_d_id
          AND ol.ol_w_id = od.o_w_id
    ) AS o_total
FROM tpcc.orders od
JOIN tpcc.customer cu
    ON od.o_c_id = cu.c_id
   AND od.o_d_id = cu.c_d_id
   AND od.o_w_id = cu.c_w_id
JOIN tpcc.warehouse wa
    ON od.o_w_id = wa.w_id;

CREATE INDEX idx_order_summary_customer_recent
ON tpcc.order_summary (o_w_id, o_d_id, o_c_id, o_entry_d, o_id);

CREATE INDEX idx_order_summary_district
ON tpcc.order_summary (o_d_id);

CREATE VIEW tpcc.order_detail AS
SELECT
    ol.ol_o_id,
    ol.ol_d_id,
    ol.ol_w_id,
    ol.ol_number,
    ol.ol_i_id,
    i.i_name,
    i.i_price,
    ol.ol_delivery_d,
    ol.ol_amount,
    ol.ol_supply_w_id,
    w.w_name,
    w.w_state,
    ol.ol_quantity
FROM tpcc.order_line ol
JOIN tpcc.item i
    ON ol.ol_i_id = i.i_id
JOIN tpcc.warehouse w
    ON ol.ol_supply_w_id = w.w_id;

CREATE INDEX idx_order_detail_order
ON tpcc.order_detail (ol_w_id, ol_d_id, ol_o_id, ol_number);

CREATE VIEW tpcc.tpcc_orders_per_district AS
SELECT
    o_w_id,
    o_d_id,
    count(*) AS order_count
FROM tpcc.orders
GROUP BY o_w_id, o_d_id;

CREATE INDEX idx_tpcc_orders_per_district_count
ON tpcc.tpcc_orders_per_district (order_count);

CREATE VIEW tpcc.tpcc_open_orders AS
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

CREATE INDEX idx_tpcc_open_orders_lookup
ON tpcc.tpcc_open_orders (warehouse_id, district_id, order_id);
