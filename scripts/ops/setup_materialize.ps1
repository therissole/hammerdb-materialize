$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root
$mzPgHost = if ($env:PGHOST) { $env:PGHOST } else { 'postgres' }
$mzPgPort = if ($env:POSTGRES_PORT) { $env:POSTGRES_PORT } else { '5432' }
$mzPgDb = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { 'tpcc' }
$mzPgUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { 'postgres' }
$mzPgPassword = if ($env:POSTGRES_PASSWORD) { $env:POSTGRES_PASSWORD } else { 'postgres' }
$pgSslmode = if ($env:PG_SSLMODE) { $env:PG_SSLMODE } else { 'prefer' }
$mzPgSslmode = if ($pgSslmode -eq 'prefer') { 'disable' } else { $pgSslmode }

Write-Host 'Applying Materialize SQL setup'
docker compose exec -T postgres psql -h materialized -p 6875 -U materialize -d materialize `
	-v ON_ERROR_STOP=1 `
	-v "mz_pg_host=$mzPgHost" `
	-v "mz_pg_port=$mzPgPort" `
	-v "mz_pg_db=$mzPgDb" `
	-v "mz_pg_user=$mzPgUser" `
	-v "mz_pg_password=$mzPgPassword" `
	-v "mz_pg_sslmode=$mzPgSslmode" `
	-f /work/scripts/materialize/setup_materialize.sql

Write-Host 'Running Materialize smoke checks'
docker compose exec -T postgres psql -h materialized -p 6875 -U materialize -d materialize -f /work/scripts/materialize/smokecheck.sql
