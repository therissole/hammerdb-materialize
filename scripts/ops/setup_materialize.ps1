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

$rdbms = (Get-EnvOrDefault -Name 'RDBMS' -Default 'PGSQL').ToUpperInvariant()

switch ($rdbms) {
	{ $_ -in @('PG', 'PGSQL', 'POSTGRES', 'POSTGRESQL') } {
		$pgHost = Get-EnvOrDefault -Name 'PGHOST' -Default 'postgres'
		$pgPort = Get-EnvOrDefault -Name 'POSTGRES_PORT' -Default '5432'
		$pgDb = Get-EnvOrDefault -Name 'POSTGRES_DB' -Default 'tpcc'
		$pgUser = Get-EnvOrDefault -Name 'POSTGRES_USER' -Default 'postgres'
		$pgPassword = Get-EnvOrDefault -Name 'POSTGRES_PASSWORD' -Default 'postgres'
		$pgSslmode = Get-EnvOrDefault -Name 'PG_SSLMODE' -Default 'prefer'
		$mzPgSslmode = if ($pgSslmode -eq 'prefer') { 'disable' } else { $pgSslmode }
		$prepSql = '/work/scripts/materialize/prepare_postgres_for_materialize.sql'
		$setupSql = '/work/scripts/materialize/setup_materialize.sql'
		$args = @(
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
		$mssqlHost = Get-EnvOrDefault -Name 'MSSQL_HOST' -Default 'mssql'
		$mssqlPort = Get-EnvOrDefault -Name 'MSSQL_PORT' -Default '1433'
		$mssqlDb = Get-EnvOrDefault -Name 'MSSQL_DB' -Default 'tpcc'
		$mssqlUser = Get-EnvOrDefault -Name 'MSSQL_USER' -Default 'sa'
		$mssqlPassword = Get-EnvOrDefault -Name 'MSSQL_SA_PASSWORD' -Default 'YourStrong!Passw0rd'
		$prepSql = '/work/scripts/materialize/prepare_mssql_for_materialize.sql'
		$setupSql = '/work/scripts/materialize/setup_materialize_mssql.sql'
		$args = @(
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
		throw "Unsupported RDBMS '$rdbms'. Use PGSQL or MSSQL."
	}
}

if ($rdbms -in @('PG', 'PGSQL', 'POSTGRES', 'POSTGRESQL')) {
	Write-Host 'Preparing Postgres logical publication for Materialize'
	& docker compose exec -T postgres psql -U $pgUser -d $pgDb -v ON_ERROR_STOP=1 -v "mz_pg_host=$pgHost" -v "mz_pg_port=$pgPort" -v "mz_pg_db=$pgDb" -v "mz_pg_user=$pgUser" -v "mz_pg_password=$pgPassword" -v "mz_pg_sslmode=$mzPgSslmode" -f $prepSql
}
else {
	Write-Host 'Preparing SQL Server CDC for Materialize'
	& docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $mssqlPassword -C -b -i $prepSql -v "mssql_db=$mssqlDb"
}

Write-Host 'Applying Materialize SQL setup'
& docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize @args -f $setupSql

Write-Host 'Running Materialize smoke checks'
& docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize -f /work/scripts/materialize/smokecheck.sql
