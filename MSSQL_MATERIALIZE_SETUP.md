# MSSQL + Materialize CDC Integration - Setup Complete ✅

**Last Updated:** May 30, 2026  
**Status:** All Materialize documentation requirements verified and implemented

---

## Summary: What's Ready

Your SQL Server environment is now **fully prepared** for Materialize CDC ingestion following the [official Materialize documentation](https://materialize.com/docs/ingest-data/sql-server/self-hosted/).

### ✅ MSSQL Configuration Complete

| Component | Status | Details |
|-----------|--------|---------|
| SQL Server Agent | ✅ Running | Required for CDC capture jobs |
| Database CDC | ✅ Enabled | `tpcc` database CDC enabled |
| SNAPSHOT Isolation | ✅ Enabled | `ALTER DATABASE tpcc SET ALLOW_SNAPSHOT_ISOLATION ON` |
| Table CDC | ✅ Enabled | All 9 TPCC tables tracked by CDC |
| User `materialize` | ✅ Created | Login and database user established |
| INFORMATION_SCHEMA Permissions | ✅ Granted | Required for schema discovery |
| CDC LSN Functions | ✅ Granted | Required for progress tracking |
| VIEW SERVER STATE | ✅ Granted | Required for replication monitoring |
| db_datareader Role | ✅ Assigned | User has SELECT on all tables |

### 📋 CDC Enabled Tables
- `dbo.warehouse`
- `dbo.district`
- `dbo.customer`
- `dbo.history`
- `dbo.new_order`
- `dbo.orders`
- `dbo.order_line`
- `dbo.item`
- `dbo.stock`

---

## Next: Complete Materialize Setup

### 1️⃣ Connect to Materialize (via port-forward)
```bash
# Terminal 1: Establish port-forward
kubectl -n materialize-environment port-forward pod/mzy49fo679im-environmentd-1-0 6875:6875

# Terminal 2: Connect
psql -h localhost -p 6875 -U materialize -d materialize
```

### 2️⃣ Set Connection Variables
In the psql session, copy-paste this entire block:
```sql
\set mz_mssql_host 'mssql.sql-server.svc.cluster.local'
\set mz_mssql_port 1433
\set mz_mssql_db 'tpcc'
\set mz_mssql_user 'materialize'
\set mz_mssql_password '$xJA_x0Pu51e'
\set mz_mssql_sslmode 'required'
```

### 3️⃣ Execute Bootstrap SQL
```sql
\i scripts/materialize/setup_materialize_mssql.sql
```

**This will:**
- Create a dedicated `tpcc` cluster (200cc size for initial snapshot)
- Create a schema `tpcc`  
- Establish MSSQL connection using CDC
- Create source ingesting from all 9 tables
- Create 4 analytical views with indexes

### 4️⃣ Verify Everything Works
```sql
SHOW CLUSTERS;                    -- Verify 'tpcc' cluster exists
SHOW SOURCES FROM tpcc;           -- Verify source created
SHOW VIEWS FROM tpcc;             -- Verify views created
SELECT * FROM tpcc.order_summary LIMIT 5;  -- Verify data flowing
```

---

## Reference Material

### 📁 Key Files

| File | Purpose | Status |
|------|---------|--------|
| `scripts/materialize/prepare_mssql_for_materialize.sql` | MSSQL CDC setup (idempotent) | ✅ Complete |
| `scripts/materialize/setup_materialize_mssql.sql` | Materialize bootstrap | ✅ Ready |
| `.env` | Connection credentials | ✅ In sync |

### Credentials
- **MSSQL SA:** Password in .env (`MSSQL_SA_PASSWORD`)
- **Materialize User:** `materialize` / `$xJA_x0Pu51e` (from .env `MSSQL_MZ_PASSWORD`)
- **Materialize Admin:** `materialize` (default in-cluster user)

### Connection Details
```
MSSQL (in-cluster):
  Host: mssql.sql-server.svc.cluster.local
  Port: 1433
  Database: tpcc
  User: materialize
  
Materialize (local):
  Host: localhost
  Port: 6875 (via port-forward)
  User: materialize
```

---

## Maintenance & Monitoring

### Re-run MSSQL Prep (if needed)
The script is fully idempotent and can be re-run anytime:
```bash
cd c:\Users\davidha\dev\hammerdb-materialize

# Copy to pod
kubectl cp scripts/materialize/prepare_mssql_for_materialize.sql \
  sql-server/mssql-6c46db5458-5j5p5:/var/opt/mssql/prepare.sql

# Execute
kubectl exec -n sql-server pod/mssql-6c46db5458-5j5p5 -- \
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '7kx~HN42R9EO' -C \
  -v mssql_db=tpcc materialize_password='$xJA_x0Pu51e' \
  -i /var/opt/mssql/prepare.sql
```

### Monitor MSSQL CDC Jobs
```sql
-- Check CDC job status
USE msdb;
SELECT job_name = j.name, last_run_outcome = h.run_status, last_run_time = h.run_date
FROM sysjobs j
LEFT JOIN sysjobhistory h ON j.job_id = h.job_id
WHERE j.name LIKE 'cdc.tpcc%'
ORDER BY h.run_date DESC;
```

### Monitor Materialize Ingestion
```sql
-- Check source status
SELECT 
  name,
  type,
  connector,
  size
FROM mz_sources
WHERE name = 'tpcc_src';

-- Check cluster status
SELECT 
  name,
  size,
  replicas
FROM mz_clusters
WHERE name = 'tpcc';

-- Verify views are populated
SELECT COUNT(*) FROM tpcc.order_summary;
SELECT COUNT(*) FROM tpcc.order_detail;
```

### After Initial Snapshot (~5-10 minutes)
Once snapshotting completes, downsize cluster for steady-state:
```sql
ALTER CLUSTER tpcc SET (SIZE '100cc');
SHOW CLUSTER REPLICAS WHERE cluster = 'tpcc';
```

---

## Troubleshooting

### Issue: "Connection timeout from Materialize to MSSQL"
**Check:**
1. MSSQL service is reachable:
   ```bash
   kubectl -n sql-server get svc mssql
   kubectl -n materialize-environment exec -it <pod> -- \
     nslookup mssql.sql-server.svc.cluster.local
   ```

2. Credentials are correct in `setup_materialize_mssql.sql`:
   - User: `materialize`
   - Password: `$xJA_x0Pu51e` (from .env)

3. Materialize logs for specific errors:
   ```bash
   kubectl -n materialize-environment logs -f pod/<environmentd> | grep -i "error\|sql server"
   ```

### Issue: "Snapshot taking longer than expected"
**Expected:** Up to 5 minutes for initial snapshot (due to MSSQL CDC 5-minute notification interval for inactive tables)  
**Normal:** Once HammerDB starts writing, snapshot will accelerate

### Issue: "CDC data not flowing after snapshot"
**Check:**
1. HammerDB is actively writing:
   ```sql
   USE tpcc;
   SELECT COUNT(*) FROM orders;
   -- Compare with count from 1 minute ago
   ```

2. CDC capture job is running:
   ```sql
   USE msdb;
   SELECT * FROM dbo.sysjobs WHERE name = 'cdc.tpcc_capture';
   ```

3. Materialize can read CDC changes:
   ```bash
   kubectl -n materialize-environment logs pod/<environmentd> | \
     grep -i "cdc\|capture" | tail -20
   ```

---

## Documentation References

- **[Materialize SQL Server Ingestion (Official)](https://materialize.com/docs/ingest-data/sql-server/self-hosted/)** - Main reference used for this setup
- **[Materialize CREATE SOURCE](https://materialize.com/docs/sql/create-source/sql-server/)** - Source creation syntax
- **[SQL Server CDC (Microsoft)](https://learn.microsoft.com/en-us/sql/relational-databases/track-changes/about-change-data-capture-sql-server)** - CDC documentation
- **[Materialize Clusters](https://materialize.com/docs/sql/create-cluster/)** - Cluster management

---

## Next Steps

1. **Execute Materialize bootstrap** (follow steps in "Next: Complete Materialize Setup" above)
2. **Monitor initial snapshot** in Materialize logs
3. **Once snapshot completes**, resize cluster to 100cc
4. **Verify queries work** on the 4 TPCC analytical views
5. **Start integrating** with downstream systems (BI tools, dashboards, etc.)

---

**Setup completed by:** GitHub Copilot  
**Last verified:** May 30, 2026
