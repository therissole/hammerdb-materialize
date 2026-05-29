# HammerDB + PostgreSQL/MSSQL + Materialize TPCC Lab

This project sets up a local benchmark lab to:

1. Use HammerDB's TPROC-C workload to generate transactional load against PostgreSQL or SQL Server.
2. Store TPCC data in PostgreSQL or SQL Server.
3. Ingest TPCC changes into Materialize via PostgreSQL logical replication or SQL Server CDC.
4. Validate Materialize behavior as load and data volume increase.

## What Is Included

- Docker Compose stack for PostgreSQL, SQL Server, HammerDB, and Materialize.
- Upstream HammerDB TCL scripts vendored from:
	- https://github.com/TPC-Council/HammerDB/tree/master/scripts/tcl/postgres/tprocc
	- https://github.com/TPC-Council/HammerDB/tree/master/scripts/tcl/mssqls/tprocc
- Container-aware HammerDB TCL variants for this environment.
- SQL scripts to prepare PostgreSQL publication and initialize Materialize sources/views.
- Cross-platform helper scripts for Windows PowerShell and Bash.

## Project Structure

```text
.
|-- docker-compose.yml
|-- .env.example
|-- postgres/
|   `-- init/
|       `-- 00_create_tpcc_role.sql
`-- scripts/
	 |-- hammerdb/
	 |   |-- upstream/tprocc/
	 |   |   |-- pg_tprocc_buildschema.tcl
	 |   |   |-- pg_tprocc_checkschema.tcl
	 |   |   |-- pg_tprocc_deleteschema.tcl
	 |   |   |-- pg_tprocc_profile.sh
	 |   |   |-- pg_tprocc_result.tcl
	 |   |   |-- pg_tprocc_run.tcl
	 |   |   |-- pg_tprocc_run_profile.tcl
	 |   |   `-- ...
	 |   `-- custom/
	 |       |-- pg_tprocc_buildschema_docker.tcl
	 |       |-- pg_tprocc_checkschema_docker.tcl
	 |       |-- pg_tprocc_deleteschema_docker.tcl
	 |       |-- pg_tprocc_result_docker.tcl
	 |       `-- pg_tprocc_run_profile_docker.tcl
	 |-- materialize/
	 |   |-- prepare_postgres_for_materialize.sql
	 |   |-- prepare_mssql_for_materialize.sql
	 |   |-- setup_materialize.sql
	 |   |-- setup_materialize_mssql.sql
	 |   `-- smokecheck.sql
	 `-- ops/
		  |-- run_tprocc_cycle.ps1
		  |-- run_tprocc_cycle.sh
		  |-- setup_materialize.ps1
		  `-- setup_materialize.sh
```

## Prerequisites

- Docker Desktop
- Docker Compose v2
- PowerShell (Windows) or Bash (Linux/macOS)

## Quick Start

1. Copy `.env.example` to `.env`.
2. Set `RDBMS=PGSQL` or `RDBMS=MSSQL` depending on the database you want to benchmark.
3. Start infrastructure:

	```bash
	docker compose up -d
	```

4. Run one TPCC lifecycle (build schema, validate schema, prep publication or CDC, execute workload):

	PowerShell:

	```powershell
	./scripts/ops/run_tprocc_cycle.ps1
	```

	Bash:

	```bash
	./scripts/ops/run_tprocc_cycle.sh
	```

5. Initialize Materialize source and run smoke checks:

	PowerShell:

	```powershell
	./scripts/ops/setup_materialize.ps1
	```

	Bash:

	```bash
	./scripts/ops/setup_materialize.sh
	```

6. Run the Locust read workload against Materialize:

	PowerShell or Bash:

	```bash
	docker compose --profile locust up -d --build locust
	```

	Then open http://localhost:8089.

## Tunable Workload Settings

Set these in `.env` before running the cycle script:

- `TPROC_C_WAREHOUSES`: explicit warehouse count. Empty means auto (`5 * VU`).
- `TPROC_C_VU`: virtual users. Empty means HammerDB `vcpu`.
- `TPROC_C_RAMPUP`: timed test ramp-up minutes.
- `TPROC_C_DURATION`: timed test duration minutes.
- `TPROC_C_PROFILEID`: `0` for single run, `>1` for profile run.
- `TPROC_C_UAW`: set `1`/`true` to force all-warehouse mode.

## Locust Read Load

The root-level `locust/` folder contains a direct Materialize read workload.

It uses:

- `tpcc.customer` to seed the customer pool.
- `tpcc.order_summary` to fetch recent orders.
- `tpcc.order_detail` to fetch line-item details for each order.
- `select o_d_id, sum(o_total) from order_summary group by o_d_id` for a dashboard-style aggregate.

Useful env vars:

- `LOCUST_CUSTOMER_POOL_SIZE`: number of customers to preload per worker.
- `LOCUST_RECENT_ORDERS_LIMIT`: how many orders to fetch per customer.
- `LOCUST_MIN_WAIT_SECONDS` and `LOCUST_MAX_WAIT_SECONDS`: think time between tasks.
- `MATERIALIZE_HOST`, `MATERIALIZE_PORT`, `MATERIALIZE_DATABASE`, `MATERIALIZE_USER`, `MATERIALIZE_PASSWORD`, `MATERIALIZE_SSLMODE`: Materialize connection settings.

## Notes

- `MSSQL_SA_PASSWORD`: SQL Server `sa` password used by the container and HammerDB connection.
- Upstream scripts are kept unchanged under `scripts/hammerdb/upstream/tprocc`.
- Docker-aware scripts are under `scripts/hammerdb/custom` and use environment variables.
- HammerDB output files are written under `./tmp` (mounted as `/work/tmp` in container).

## Reset

To fully reset state (containers + Postgres data volume):

```bash
docker compose down -v
```
