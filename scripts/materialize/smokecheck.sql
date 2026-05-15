SELECT mz_version();
SET cluster = quickstart;
SHOW SCHEMAS;
SHOW SOURCES FROM tpcc;
SELECT count(*) AS warehouse_rows FROM tpcc.warehouse;
SELECT count(*) AS district_rows FROM tpcc.district;
SELECT count(*) AS customer_rows FROM tpcc.customer;
SELECT * FROM tpcc.tpcc_orders_per_district ORDER BY order_count DESC LIMIT 10;
