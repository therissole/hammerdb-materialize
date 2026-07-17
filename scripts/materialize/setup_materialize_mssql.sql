-- Run this in Materialize after the MSSQL TPCC schema is created and CDC is enabled.
-- Before running, set these psql variables in your terminal:
--   \set mz_mssql_host 'mssql.sql-server.svc.cluster.local'
--   \set mz_mssql_port 1433
--   \set mz_mssql_db 'tpcc'
--   \set mz_mssql_user 'materialize'
--   \set mz_mssql_password 'PASSWORD_FROM_ENV_FILE'
--   \set mz_mssql_sslmode 'required'
--
-- Split topology (MZ best practice): CDC ingest and read-serving on SEPARATE
-- clusters so source maintenance doesn't starve query peeks.
--   tpcc_ingest  — hosts the SQL Server source (CDC)
--   tpcc         — serving cluster, hosts the indexed views (reads hit this)
-- Two clusters → two replica pods → autoscales to the 2nd MZ node.
-- Adjusted for self-managed v26 (no `IF NOT EXISTS` / `WITH (size=)` for clusters).
DROP CLUSTER IF EXISTS tpcc CASCADE;
DROP CLUSTER IF EXISTS tpcc_ingest CASCADE;
-- Sizes chosen to fit the 2-node E4pds_v6 pool: a 200cc replica needs a whole
-- node (4 vCPU/32 GB) and there's no free node, so serving is 100cc here. The
-- win is ISOLATION from ingest, not raw size. Bump serving to 200cc only after
-- raising the mz node pool max (mz_node_max) so a 3rd node can be added.
CREATE CLUSTER tpcc_ingest (SIZE = '100cc');
CREATE CLUSTER tpcc (SIZE = '100cc');
SET CLUSTER = tpcc;

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
    SSL MODE :'mz_mssql_sslmode'
);

CREATE SOURCE tpcc.tpcc_src
IN CLUSTER tpcc_ingest
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

-- Indexes/views below are built on the serving cluster.
SET CLUSTER = tpcc;

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

-- Key on EXACTLY the lookup columns. Appending o_entry_d/o_id (the sort cols)
-- into the key would make it a 5-col arrangement that the 3-col equality lookup
-- can't use as a point lookup (forces a district-index scan). The handful of
-- rows per customer are sorted at query time by the ORDER BY.
CREATE INDEX idx_order_summary_customer_recent
ON tpcc.order_summary (o_w_id, o_d_id, o_c_id);

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

-- Key on exactly the lookup columns (drop ol_number from the key) so the
-- 3-col equality is a true point lookup.
CREATE INDEX idx_order_detail_order
ON tpcc.order_detail (ol_w_id, ol_d_id, ol_o_id);

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

-- ── Point-lookup serving objects (load test should exercise ONLY these) ──────
-- Customer PK index: turns the "directory" query into a single-customer lookup
-- (and makes the bootstrap top-N read index-served instead of a 300k scan).
CREATE INDEX idx_customer_pk
ON tpcc.customer (c_w_id, c_d_id, c_id);

-- District totals: pre-aggregated + indexed so the dashboard is a point lookup
-- of one (warehouse, district) instead of a full GROUP BY recompute.
CREATE VIEW tpcc.district_order_totals AS
SELECT o_w_id, o_d_id, sum(o_total) AS total_amount, count(*) AS order_count
FROM tpcc.order_summary
GROUP BY o_w_id, o_d_id;

CREATE INDEX idx_district_order_totals
ON tpcc.district_order_totals (o_w_id, o_d_id);
