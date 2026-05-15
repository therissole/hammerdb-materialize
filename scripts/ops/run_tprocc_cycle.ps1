<#
Runs one end-to-end HammerDB TPROC-C cycle against the Dockerized PostgreSQL service.

What this script does:
1) Stops all containers and removes data volumes (fresh environment each run).
2) Starts the stack and waits for PostgreSQL to be ready.
3) Builds the TPCC schema using HammerDB.
4) Verifies the TPCC schema exists and is valid.
5) Prepares PostgreSQL for Materialize ingestion (role grants + publication).
6) Creates/updates Materialize tpcc schema and source for all TPCC tables.
7) Executes the TPROC-C timed workload/profile script.

How to use:
- Run from the project root (or anywhere): ./scripts/ops/run_tprocc_cycle.ps1
- The script manages the Docker stack lifecycle automatically.

Configuration:
- Values come from .env (for example TPROC_C_DURATION, TPROC_C_RAMPUP, TPROC_C_PROFILEID).
- Optional HAMMERDB_CLI can override the default binary path in the container.

Notes:
- The script executes HammerDB inside the hammerdb container.
- Workload output files are written under ./tmp (mounted as /work/tmp in the container).
#>

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root
$hammerdbCli = if ($env:HAMMERDB_CLI) { $env:HAMMERDB_CLI } else { '/home/HammerDB-5.0/hammerdbcli' }

function Invoke-HammerDbScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    docker compose exec -T hammerdb bash -lc "mkdir -p /work/tmp; $hammerdbCli auto $ScriptPath"
}

Write-Host 'Stopping containers and removing data volumes'
docker compose down -v

Write-Host 'Starting containers'
docker compose up -d

Write-Host 'Waiting for Postgres to be ready'
$maxAttempts = 30
$attempt = 0
do {
    $attempt++
    $ready = docker compose exec -T postgres pg_isready -U postgres 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -ge $maxAttempts) { throw 'Postgres did not become ready in time' }
    Start-Sleep -Seconds 2
} while ($true)

Write-Host 'Building TPCC schema in Postgres via HammerDB'
Invoke-HammerDbScript -ScriptPath '/work/scripts/hammerdb/custom/pg_tprocc_buildschema_docker.tcl'

Write-Host 'Checking TPCC schema'
Invoke-HammerDbScript -ScriptPath '/work/scripts/hammerdb/custom/pg_tprocc_checkschema_docker.tcl'

Write-Host 'Preparing Postgres logical publication for Materialize'
$pgUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'postgres' }
$pgDb = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'tpcc' }
$mzPgHost = if ($env:PGHOST) { $env:PGHOST } else { 'postgres' }
$mzPgPort = if ($env:POSTGRES_PORT) { $env:POSTGRES_PORT } else { '5432' }
$mzPgDb = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'tpcc' }
$mzPgUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'postgres' }
$mzPgPassword = if ($env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD } else { 'postgres' }
$pgSslmode = if ($env:PG_SSLMODE) { $env:PG_SSLMODE } else { 'prefer' }
$mzPgSslmode = if ($pgSslmode -eq 'prefer') { 'disable' } else { $pgSslmode }

docker compose exec -T postgres psql -U $pgUser -d $pgDb `
    -v ON_ERROR_STOP=1 `
    -v "mz_pg_host=$mzPgHost" `
    -v "mz_pg_port=$mzPgPort" `
    -v "mz_pg_db=$mzPgDb" `
    -v "mz_pg_user=$mzPgUser" `
    -v "mz_pg_password=$mzPgPassword" `
    -v "mz_pg_sslmode=$mzPgSslmode" `
    -f /work/scripts/materialize/prepare_postgres_for_materialize.sql

Write-Host 'Setting up Materialize source in schema tpcc (all publication tables)'
docker compose exec -T postgres psql -h materialized -p 6875 -U materialize -d materialize `
    -v ON_ERROR_STOP=1 `
    -v "mz_pg_host=$mzPgHost" `
    -v "mz_pg_port=$mzPgPort" `
    -v "mz_pg_db=$mzPgDb" `
    -v "mz_pg_user=$mzPgUser" `
    -v "mz_pg_password=$mzPgPassword" `
    -v "mz_pg_sslmode=$mzPgSslmode" `
    -f /work/scripts/materialize/setup_materialize.sql

Write-Host 'Running TPCC workload'
Invoke-HammerDbScript -ScriptPath '/work/scripts/hammerdb/custom/pg_tprocc_run_profile_docker.tcl'

Write-Host 'Cycle complete. HammerDB output files are in ./tmp'
