<#
Runs one end-to-end HammerDB TPROC-C cycle against the Dockerized PostgreSQL or SQL Server service.

What this script does:
1) Stops all containers and removes data volumes (fresh environment each run).
2) Starts the stack and waits for the selected RDBMS to be ready.
3) Builds the TPCC schema using HammerDB.
4) Verifies the TPCC schema exists and is valid.
5) Prepares the selected database for Materialize ingestion.
6) Creates/updates Materialize tpcc schema and source for all TPCC tables.
7) Executes the TPROC-C timed workload/profile script.

How to use:
- Run from the project root (or anywhere): ./scripts/ops/run_tprocc_cycle.ps1
- The script manages the Docker stack lifecycle automatically.

Configuration:
- `RDBMS` selects the upstream database: `PGSQL` or `MSSQL`.
- Values come from .env (for example TPROC_C_DURATION, TPROC_C_RAMPUP, TPROC_C_PROFILEID).
- Optional HAMMERDB_CLI can override the default binary path in the container.

Notes:
- The script executes HammerDB inside the hammerdb container.
- Workload output files are written under ./tmp (mounted as /work/tmp in the container).
#>

param(
    [string]$autorun = ''
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root

function Import-DotEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }

        $index = $line.IndexOf('=')
        if ($index -lt 1) {
            continue
        }

        $name = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [Environment]::GetEnvironmentVariable($name)) {
            [Environment]::SetEnvironmentVariable($name, $value)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

Import-DotEnv -Path (Join-Path $root '.env')

$hammerdbCli = if ($env:HAMMERDB_CLI) { $env:HAMMERDB_CLI } else { '/home/HammerDB-5.0/hammerdbcli' }
$rdbmsMode = if ($env:RDBMS) { $env:RDBMS } else { 'PGSQL' }
$rdbmsMode = $rdbmsMode.Trim().ToUpperInvariant()

function Invoke-HammerDbScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    docker compose exec -T hammerdb bash -lc "mkdir -p /work/tmp; $hammerdbCli auto $ScriptPath"
}

function Test-IsTrueString {
    param(
        [string]$Value
    )

    if (-not $Value) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    return ($normalized -eq 'y' -or $normalized -eq 'yes' -or $normalized -eq 'true')
}

function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Default
    )

    $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -ne $item -and $item.Value) {
        $value = $item.Value.Trim()
        if ($value) {
            return $value
        }
    }

    return $Default
}

function Wait-ComposeService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName,
        [Parameter(Mandatory = $true)]
        [string]$CheckCommand
    )

    $maxAttempts = 30
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $isReady = $false

        try {
            & docker compose exec -T $ServiceName bash -lc $CheckCommand *> $null
            if ($LASTEXITCODE -eq 0) {
                $isReady = $true
            }
        }
        catch {
            # Readiness probes are expected to fail until the service finishes starting.
            $isReady = $false
        }

        if ($isReady) {
            return
        }

        if ($attempt -eq $maxAttempts) {
            throw "$ServiceName did not become ready in time"
        }

        Start-Sleep -Seconds 2
    }
}

switch ($rdbmsMode) {
    { $_ -in @('PG', 'PGSQL', 'POSTGRES', 'POSTGRESQL') } {
        $rdbmsMode = 'PGSQL'
        $composeProfile = 'pgsql'
        $dbService = 'postgres'
        $hammerdbBuildScript = '/work/scripts/hammerdb/custom/pg_tprocc_buildschema_docker.tcl'
        $hammerdbCheckScript = '/work/scripts/hammerdb/custom/pg_tprocc_checkschema_docker.tcl'
        $hammerdbRunScript = '/work/scripts/hammerdb/custom/pg_tprocc_run_profile_docker.tcl'
        $prepSql = '/work/scripts/materialize/prepare_postgres_for_materialize.sql'
        $setupSql = '/work/scripts/materialize/setup_materialize.sql'
        $pgHost = Get-EnvOrDefault -Name 'PGHOST' -Default 'postgres'
        $pgPort = Get-EnvOrDefault -Name 'POSTGRES_PORT' -Default '5432'
        $pgDb = Get-EnvOrDefault -Name 'POSTGRES_DB' -Default 'tpcc'
        $pgUser = Get-EnvOrDefault -Name 'POSTGRES_USER' -Default 'postgres'
        $pgPassword = Get-EnvOrDefault -Name 'POSTGRES_PASSWORD' -Default 'postgres'
        $pgSslmode = Get-EnvOrDefault -Name 'PG_SSLMODE' -Default 'prefer'
        $mzPgSslmode = if ($pgSslmode -eq 'prefer') { 'disable' } else { $pgSslmode }
        $materializeArgs = @(
            '-v', 'ON_ERROR_STOP=1',
            '-v', "mz_pg_host=$pgHost",
            '-v', "mz_pg_port=$pgPort",
            '-v', "mz_pg_db=$pgDb",
            '-v', "mz_pg_user=$pgUser",
            '-v', "mz_pg_password=$pgPassword",
            '-v', "mz_pg_sslmode=$mzPgSslmode"
        )
    }
    { $_ -in @('MSSQL', 'MSSQLS', 'SQLSERVER') } {
        $rdbmsMode = 'MSSQL'
        $composeProfile = 'mssql'
        $dbService = 'mssql'
        $hammerdbBuildScript = '/work/scripts/hammerdb/custom/mssqls_tprocc_buildschema_docker.tcl'
        $hammerdbCheckScript = '/work/scripts/hammerdb/custom/mssqls_tprocc_checkschema_docker.tcl'
        $hammerdbRunScript = '/work/scripts/hammerdb/custom/mssqls_tprocc_run_profile_docker.tcl'
        $prepSql = '/work/scripts/materialize/prepare_mssql_for_materialize.sql'
        $setupSql = '/work/scripts/materialize/setup_materialize_mssql.sql'
        $mssqlHost = Get-EnvOrDefault -Name 'MSSQL_HOST' -Default 'mssql'
        $mssqlPort = Get-EnvOrDefault -Name 'MSSQL_PORT' -Default '1433'
        $mssqlDb = Get-EnvOrDefault -Name 'MSSQL_DB' -Default 'tpcc'
        $mssqlUser = Get-EnvOrDefault -Name 'MSSQL_USER' -Default 'sa'
        $mssqlPassword = Get-EnvOrDefault -Name 'MSSQL_SA_PASSWORD' -Default 'YourStrong!Passw0rd'
        $materializeArgs = @(
            '-v', 'ON_ERROR_STOP=1',
            '-v', "mz_mssql_host=$mssqlHost",
            '-v', "mz_mssql_port=$mssqlPort",
            '-v', "mz_mssql_db=$mssqlDb",
            '-v', "mz_mssql_user=$mssqlUser",
            '-v', "mz_mssql_password=$mssqlPassword",
            '-v', 'mz_mssql_sslmode=required'
        )
    }
    default {
        throw "Unsupported RDBMS '$rdbmsMode'. Use PGSQL or MSSQL."
    }
}

Write-Host 'Stopping containers and removing data volumes'
& docker compose --profile pgsql --profile mssql down -v --remove-orphans

Write-Host 'Starting containers'
& docker compose --profile $composeProfile up -d

Write-Host "Waiting for $rdbmsMode to be ready"
if ($rdbmsMode -eq 'PGSQL') {
    Wait-ComposeService -ServiceName $dbService -CheckCommand "pg_isready -U `"$pgUser`" -d `"$pgDb`""
}
else {
    Wait-ComposeService -ServiceName $dbService -CheckCommand 'if command -v /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b >/dev/null 2>&1; elif command -v /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b >/dev/null 2>&1; else exit 1; fi'
}

Write-Host "Building TPROC-C schema in $rdbmsMode via HammerDB"
Invoke-HammerDbScript -ScriptPath $hammerdbBuildScript

Write-Host 'Checking TPCC schema'
Invoke-HammerDbScript -ScriptPath $hammerdbCheckScript

if ($rdbmsMode -eq 'PGSQL') {
    Write-Host 'Preparing Postgres logical publication for Materialize'
    & docker compose exec -T postgres psql -U $pgUser -d $pgDb -v ON_ERROR_STOP=1 -v "mz_pg_host=$pgHost" -v "mz_pg_port=$pgPort" -v "mz_pg_db=$pgDb" -v "mz_pg_user=$pgUser" -v "mz_pg_password=$pgPassword" -v "mz_pg_sslmode=$mzPgSslmode" -f $prepSql

    Write-Host 'Setting up Materialize source in schema tpcc (all publication tables)'
    & docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize @materializeArgs -f $setupSql
}
else {
    Write-Host 'Preparing SQL Server CDC for Materialize'
    & docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $mssqlPassword -C -b -i /work/scripts/materialize/prepare_mssql_for_materialize.sql -v "mssql_db=$mssqlDb"

    Write-Host 'Setting up Materialize source in schema tpcc (all CDC tables)'
    & docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize @materializeArgs -f $setupSql
}

if (Test-IsTrueString -Value $autorun) {
    Write-Host "Autorun enabled (autorun=$autorun). Proceeding directly to TPCC workload run."
}
else {
    [void](Read-Host 'Setup complete, ready to proceed with run? Press Enter to continue')
}

Write-Host 'Running TPCC workload'
Invoke-HammerDbScript -ScriptPath $hammerdbRunScript

Write-Host 'Cycle complete. HammerDB output files are in ./tmp'
