<#
Runs one end-to-end HammerDB TPROC-C cycle against PostgreSQL or SQL Server.

Modes:
- Local mode (REMOTE_DB=false):
  - Recreates local DB container state, runs build/check/run, and performs Materialize setup.
- Remote mode (REMOTE_DB=true):
  - First pass supports MSSQL only.
    - Starts only local hammerdb container.
    - Verifies connectivity, recreates the target DB, and provisions HammerDB/Materialize SQL users.
    - Runs build/check/run against remote MSSQL.
  - Skips Materialize setup for now.
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
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            # Use .env as the source of truth for this script invocation to avoid stale session variables.
            [Environment]::SetEnvironmentVariable($name, $value)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
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

function Invoke-HammerDbScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HammerdbCli,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string]$MssqlHostOverride = ''
    )

    $maxRetries = 0
    $retryOverride = Get-Item -Path 'Env:HAMMERDB_COMM_LINK_RETRIES' -ErrorAction SilentlyContinue
    if ($retryOverride -and ($retryOverride.Value -match '^\d+$')) {
        $maxRetries = [int]$retryOverride.Value
    }

    $stepTimeoutSec = 1800
    $timeoutOverride = Get-Item -Path 'Env:HAMMERDB_STEP_TIMEOUT_SEC' -ErrorAction SilentlyContinue
    if ($timeoutOverride -and ($timeoutOverride.Value -match '^\d+$')) {
        $stepTimeoutSec = [int]$timeoutOverride.Value
    }

    # Clear stale HammerDB CLI processes from prior interrupted runs.
    $cleanupCmd = 'for p in $(pgrep -f ''^/home/HammerDB-5.0/hammerdbcli'' || true); do kill $p >/dev/null 2>&1 || true; done'
    & docker compose exec -T hammerdb bash -lc $cleanupCmd *> $null

    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        $output = @()
        $wrappedCommand = "mkdir -p /work/tmp; if command -v timeout >/dev/null 2>&1; then timeout $stepTimeoutSec $HammerdbCli auto $ScriptPath; else $HammerdbCli auto $ScriptPath; fi"
        if ($MssqlHostOverride) {
            $output = & docker compose exec -T -e "MSSQL_HOST=$MssqlHostOverride" hammerdb bash -lc $wrappedCommand 2>&1
        }
        else {
            $output = & docker compose exec -T hammerdb bash -lc $wrappedCommand 2>&1
        }

        if ($output) {
            $output | ForEach-Object { Write-Host $_ }
        }

        if ($LASTEXITCODE -ne 0) {
            if ($LASTEXITCODE -eq 124) {
                throw "HammerDB command timed out for script '$ScriptPath' after $stepTimeoutSec seconds. Set HAMMERDB_STEP_TIMEOUT_SEC to a higher value if needed."
            }
            throw "HammerDB command failed for script '$ScriptPath' with exit code $LASTEXITCODE."
        }

        $outputText = ($output | Out-String)
        if ($outputText -match 'Error in Virtual User' -or $outputText -match 'FINISHED FAILED') {
            if ($outputText -match 'Login failed for user') {
                throw "HammerDB workload failed authentication for script '$ScriptPath'. Verify MSSQL_USER and MSSQL_SA_PASSWORD (and that SQL authentication/login is enabled on the target SQL Server)."
            }

            $isCommLinkFailure = ($outputText -match 'Communication link failure' -or $outputText -match 'TCP Provider: Error code 0x2746')
            if ($isCommLinkFailure -and $attempt -lt $maxRetries) {
                Write-Host "Transient SQL connectivity failure detected during '$ScriptPath'. Retrying once ($($attempt + 1)/$maxRetries)..."
                continue
            }

            throw "HammerDB workload reported virtual user failure for script '$ScriptPath'. Check the output above and ./tmp/hammerdb.log for details."
        }

        return
    }
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
            # Readiness probes are expected to fail until startup completes.
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

function Escape-SqlLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace("'", "''")
}

function Escape-SqlIdentifier {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace(']', ']]')
}

function Invoke-SqlCmdHostQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,
        [Parameter(Mandatory = $true)]
        [string]$Port,
        [Parameter(Mandatory = $true)]
        [string]$User,
        [Parameter(Mandatory = $true)]
        [string]$Password,
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Query,
        [Parameter(Mandatory = $true)]
        [string]$OperationName
    )

    $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        throw "sqlcmd is required for remote MSSQL bootstrap but was not found on PATH. Install sqlcmd, then re-run the script."
    }

    $args = @(
        '-S', "tcp:$Server,$Port",
        '-U', $User,
        '-P', $Password,
        '-C',
        '-d', $Database,
        '-Q', $Query,
        '-b'
    )

    # With PSNativeCommandUseErrorActionPreference enabled, non-zero native exits throw
    # before we can format a useful error message. Temporarily disable this behavior.
    $restoreNativeErrorPreference = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $restoreNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $output = & $sqlcmd.Source @args 2>&1
    }
    finally {
        if ($null -ne $restoreNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $restoreNativeErrorPreference
        }
    }

    if ($output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        if (-not $details) {
            $details = 'no stderr/stdout from sqlcmd'
        }

        throw "sqlcmd failed during '$OperationName' against $Server`:$Port (database '$Database'). Details: $details"
    }
}

function Initialize-RemoteMssqlDatabaseAndUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdminHost,
        [Parameter(Mandatory = $true)]
        [string]$AdminPort,
        [Parameter(Mandatory = $true)]
        [string]$AdminUser,
        [Parameter(Mandatory = $true)]
        [string]$AdminPassword,
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$HammerDbUser,
        [Parameter(Mandatory = $true)]
        [string]$HammerDbPassword,
        [Parameter(Mandatory = $true)]
        [string]$MaterializeUser,
        [Parameter(Mandatory = $true)]
        [string]$MaterializePassword
    )

    $dbIdent = Escape-SqlIdentifier -Value $Database
    $dbLit = Escape-SqlLiteral -Value $Database
    $hammerUserIdent = Escape-SqlIdentifier -Value $HammerDbUser
    $hammerUserLit = Escape-SqlLiteral -Value $HammerDbUser
    $hammerPassLit = Escape-SqlLiteral -Value $HammerDbPassword
    $mzUserIdent = Escape-SqlIdentifier -Value $MaterializeUser
    $mzUserLit = Escape-SqlLiteral -Value $MaterializeUser
    $mzPassLit = Escape-SqlLiteral -Value $MaterializePassword

    Write-Host "Remote bootstrap: dropping and recreating database '$Database'"

    $query = @"
SET NOCOUNT ON;

IF DB_ID(N'$dbLit') IS NOT NULL
BEGIN
    ALTER DATABASE [$dbIdent] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$dbIdent];
END;

CREATE DATABASE [$dbIdent];

IF N'$hammerUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$hammerUserLit')
BEGIN
    CREATE LOGIN [$hammerUserIdent] WITH PASSWORD = N'$hammerPassLit', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END;

IF N'$mzUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'$mzUserLit')
BEGIN
    CREATE LOGIN [$mzUserIdent] WITH PASSWORD = N'$mzPassLit', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
END;

DECLARE @waitUntil datetime2 = DATEADD(SECOND, 30, SYSUTCDATETIME());
WHILE (DB_ID(N'$dbLit') IS NULL OR DATABASEPROPERTYEX(N'$dbLit', 'Status') <> 'ONLINE') AND SYSUTCDATETIME() < @waitUntil
BEGIN
    WAITFOR DELAY '00:00:01';
END;

IF DB_ID(N'$dbLit') IS NULL OR DATABASEPROPERTYEX(N'$dbLit', 'Status') <> 'ONLINE'
BEGIN
    RAISERROR('DB_CREATE_TIMEOUT', 16, 1);
END;
"@

    Invoke-SqlCmdHostQuery `
        -Server $AdminHost `
        -Port $AdminPort `
        -User $AdminUser `
        -Password $AdminPassword `
        -Database 'master' `
        -Query $query `
        -OperationName 'remote MSSQL DB/login bootstrap'

    $dbUsersQuery = @"
SET NOCOUNT ON;

IF N'$hammerUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$hammerUserLit')
BEGIN
    CREATE USER [$hammerUserIdent] FOR LOGIN [$hammerUserIdent];
END;

IF N'$hammerUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals m ON drm.member_principal_id = m.principal_id
    WHERE r.name = N'db_owner' AND m.name = N'$hammerUserLit'
)
BEGIN
    ALTER ROLE [db_owner] ADD MEMBER [$hammerUserIdent];
END;

IF N'$mzUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$mzUserLit')
BEGIN
    CREATE USER [$mzUserIdent] FOR LOGIN [$mzUserIdent];
END;

IF N'$mzUserLit' NOT IN (N'sa', N'dbo')
AND NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
    JOIN sys.database_principals m ON drm.member_principal_id = m.principal_id
    WHERE r.name = N'db_owner' AND m.name = N'$mzUserLit'
)
BEGIN
    ALTER ROLE [db_owner] ADD MEMBER [$mzUserIdent];
END;
"@

    Invoke-SqlCmdHostQuery `
        -Server $AdminHost `
        -Port $AdminPort `
        -User $AdminUser `
        -Password $AdminPassword `
        -Database $Database `
        -Query $dbUsersQuery `
        -OperationName 'remote MSSQL DB/user bootstrap'

    Write-Host "Remote bootstrap: database '$Database' recreated and users '$HammerDbUser'/'$MaterializeUser' are configured."
}

function Test-RemoteMssqlConnectivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetHost,
        [Parameter(Mandatory = $true)]
        [string]$Port,
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$User
    )

    Write-Host "Preflight: checking TCP connectivity from hammerdb to $TargetHost`:$Port"

    # With PSNativeCommandUseErrorActionPreference enabled, non-zero native exits throw
    # before we can present a meaningful connectivity error. Temporarily disable this.
    $restoreNativeErrorPreference = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $restoreNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $probeOutput = & docker compose exec -T hammerdb bash -lc "if command -v timeout >/dev/null 2>&1; then timeout 5 bash -lc '>/dev/tcp/$TargetHost/$Port'; else bash -lc '>/dev/tcp/$TargetHost/$Port'; fi" 2>&1
    }
    finally {
        if ($null -ne $restoreNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $restoreNativeErrorPreference
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $details = ($probeOutput | Out-String).Trim()
        if (-not $details) {
            $details = 'no stderr/stdout from connectivity probe'
        }

        throw "REMOTE_DB connectivity check failed before workload start. Could not open TCP connection from hammerdb container to $TargetHost`:$Port. Details: $details. Verify MSSQL_HOST/MSSQL_PORT routing, firewall rules, and any active kubectl port-forward listener."
    }

    Write-Host "Preflight: TCP connectivity OK to $TargetHost`:$Port (target DB '$Database', user '$User')."
}

function Test-RemoteMssqlAuthAndDbAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetHost,
        [Parameter(Mandatory = $true)]
        [string]$Port,
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$User,
        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    Write-Host "Preflight: checking SQL authentication and DB access to '$Database' from container context"

    $probeOutput = & docker run --rm `
        -e "SQLHOST=$TargetHost" `
        -e "SQLPORT=$Port" `
        -e "SQLUSER=$User" `
        -e "SQLPASS=$Password" `
        -e "TARGETDB=$Database" `
        mcr.microsoft.com/mssql-tools /bin/bash -lc 'if [ -x /opt/mssql-tools18/bin/sqlcmd ]; then SQLCMD=/opt/mssql-tools18/bin/sqlcmd; else SQLCMD=/opt/mssql-tools/bin/sqlcmd; fi; "$SQLCMD" -S "$SQLHOST,$SQLPORT" -U "$SQLUSER" -P "$SQLPASS" -C -d "master" -Q "SET NOCOUNT ON; IF DB_ID(''$TARGETDB'') IS NULL BEGIN RAISERROR(''DB_NOT_FOUND'',16,1); RETURN; END; IF HAS_DBACCESS(''$TARGETDB'') <> 1 BEGIN RAISERROR(''DB_NO_ACCESS'',16,1); RETURN; END; SELECT SUSER_SNAME() AS login_name, ''OK'' AS db_access;" -b' 2>&1

    if ($probeOutput) {
        $probeOutput | ForEach-Object { Write-Host $_ }
    }

    if ($LASTEXITCODE -ne 0) {
        $probeText = ($probeOutput | Out-String)

        if ($probeText -match 'Login failed for user') {
            throw "REMOTE_DB SQL auth preflight failed. Login failed for user '$User'. Verify username/password and SQL authentication settings on the remote SQL Server."
        }

        if ($probeText -match 'DB_NOT_FOUND') {
            throw "REMOTE_DB SQL preflight failed. Target database '$Database' does not exist on the remote SQL Server. Create it or set MSSQL_DB to an existing database."
        }

        if ($probeText -match 'DB_NO_ACCESS') {
            throw "REMOTE_DB SQL preflight failed. Login '$User' does not have access to database '$Database'. Grant access or use a login with the required permissions."
        }

        throw "REMOTE_DB SQL preflight failed while validating login/database access. Review output above for details."
    }

    Write-Host "Preflight: SQL authentication and DB access OK for login '$User' on database '$Database'."
}

Import-DotEnv -Path (Join-Path $root '.env')

$hammerdbCli = if ($env:HAMMERDB_CLI) { $env:HAMMERDB_CLI } else { '/home/HammerDB-5.0/hammerdbcli' }
$rdbmsMode = (Get-EnvOrDefault -Name 'RDBMS' -Default 'PGSQL').Trim().ToUpperInvariant()
$remoteDb = Test-IsTrueString -Value (Get-EnvOrDefault -Name 'REMOTE_DB' -Default 'false')

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

        $pgHost = Get-EnvOrDefault -Name 'PGHOST' -Default (Get-EnvOrDefault -Name 'POSTGRES_HOST' -Default 'postgres')
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
        $mssqlAdminUser = Get-EnvOrDefault -Name 'MSSQL_ADMIN_USER' -Default $mssqlUser
        $mssqlAdminPassword = Get-EnvOrDefault -Name 'MSSQL_ADMIN_PASSWORD' -Default $mssqlPassword
        $mssqlMaterializeUser = Get-EnvOrDefault -Name 'MSSQL_MZ_USER' -Default $mssqlUser
        $mssqlMaterializePassword = Get-EnvOrDefault -Name 'MSSQL_MZ_PASSWORD' -Default $mssqlPassword

        $materializeArgs = @(
            '-v', 'ON_ERROR_STOP=1',
            '-v', "mz_mssql_host=$mssqlHost",
            '-v', "mz_mssql_port=$mssqlPort",
            '-v', "mz_mssql_db=$mssqlDb",
            '-v', "mz_mssql_user=$mssqlMaterializeUser",
            '-v', "mz_mssql_password=$mssqlMaterializePassword",
            '-v', 'mz_mssql_sslmode=required'
        )
    }
    default {
        throw "Unsupported RDBMS '$rdbmsMode'. Use PGSQL or MSSQL."
    }
}

if ($remoteDb -and $rdbmsMode -ne 'MSSQL') {
    throw 'REMOTE_DB=true currently supports MSSQL only in this first pass. Set RDBMS=MSSQL.'
}

$effectiveMssqlHost = $mssqlHost
if ($remoteDb -and $rdbmsMode -eq 'MSSQL' -and $mssqlHost -in @('127.0.0.1', 'localhost', '::1')) {
    $effectiveMssqlHost = Get-EnvOrDefault -Name 'MSSQL_HOST_FROM_CONTAINER' -Default 'host.docker.internal'
    Write-Host "REMOTE_DB mode: MSSQL_HOST=$mssqlHost is host loopback. Using MSSQL_HOST=$effectiveMssqlHost inside hammerdb container."
}

if ($remoteDb) {
    Write-Host "REMOTE_DB mode: targeting remote MSSQL at $effectiveMssqlHost`:$mssqlPort"
    Write-Host 'Starting local hammerdb container'
    & docker compose up -d hammerdb
    Test-RemoteMssqlConnectivity -TargetHost $effectiveMssqlHost -Port $mssqlPort -Database $mssqlDb -User $mssqlUser

    Initialize-RemoteMssqlDatabaseAndUsers `
        -AdminHost $mssqlHost `
        -AdminPort $mssqlPort `
        -AdminUser $mssqlAdminUser `
        -AdminPassword $mssqlAdminPassword `
        -Database $mssqlDb `
        -HammerDbUser $mssqlUser `
        -HammerDbPassword $mssqlPassword `
        -MaterializeUser $mssqlMaterializeUser `
        -MaterializePassword $mssqlMaterializePassword

    Test-RemoteMssqlAuthAndDbAccess -TargetHost $effectiveMssqlHost -Port $mssqlPort -Database $mssqlDb -User $mssqlUser -Password $mssqlPassword

    if ($mssqlMaterializeUser -ne $mssqlUser -or $mssqlMaterializePassword -ne $mssqlPassword) {
        Test-RemoteMssqlAuthAndDbAccess -TargetHost $effectiveMssqlHost -Port $mssqlPort -Database $mssqlDb -User $mssqlMaterializeUser -Password $mssqlMaterializePassword
    }
}
else {
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
}

Write-Host "Building TPROC-C schema in $rdbmsMode via HammerDB"
Invoke-HammerDbScript -HammerdbCli $hammerdbCli -ScriptPath $hammerdbBuildScript -MssqlHostOverride $(if ($remoteDb -and $rdbmsMode -eq 'MSSQL') { $effectiveMssqlHost } else { '' })

Write-Host 'Checking TPCC schema'
Invoke-HammerDbScript -HammerdbCli $hammerdbCli -ScriptPath $hammerdbCheckScript -MssqlHostOverride $(if ($remoteDb -and $rdbmsMode -eq 'MSSQL') { $effectiveMssqlHost } else { '' })

if ($remoteDb) {
    Write-Host 'REMOTE_DB mode: skipping Materialize setup (next pass will target remote Materialize)'
}
else {
    if ($rdbmsMode -eq 'PGSQL') {
        Write-Host 'Preparing Postgres logical publication for Materialize'
        & docker compose exec -T postgres psql -U $pgUser -d $pgDb -v ON_ERROR_STOP=1 -v "mz_pg_host=$pgHost" -v "mz_pg_port=$pgPort" -v "mz_pg_db=$pgDb" -v "mz_pg_user=$pgUser" -v "mz_pg_password=$pgPassword" -v "mz_pg_sslmode=$mzPgSslmode" -f $prepSql

        Write-Host 'Setting up Materialize source in schema tpcc (all publication tables)'
        & docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize @materializeArgs -f $setupSql
    }
    else {
        Write-Host 'Preparing SQL Server CDC for Materialize'
        $mssqlSqlcmdPath = (& docker compose exec -T mssql bash -lc 'if command -v /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then echo /opt/mssql-tools18/bin/sqlcmd; elif command -v /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then echo /opt/mssql-tools/bin/sqlcmd; else exit 1; fi').Trim()
        if (-not $mssqlSqlcmdPath) {
            throw 'Could not find sqlcmd in the mssql container (/opt/mssql-tools18/bin/sqlcmd or /opt/mssql-tools/bin/sqlcmd).'
        }

        & docker compose exec -T mssql $mssqlSqlcmdPath -S localhost -U sa -P $mssqlPassword -C -b -i /work/scripts/materialize/prepare_mssql_for_materialize.sql -v "mssql_db=$mssqlDb"

        Write-Host 'Setting up Materialize source in schema tpcc (all CDC tables)'
        & docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize @materializeArgs -f $setupSql
    }
}

if (Test-IsTrueString -Value $autorun) {
    Write-Host "Autorun enabled (autorun=$autorun). Proceeding directly to TPCC workload run."
}
else {
    [void](Read-Host 'Setup complete, ready to proceed with run? Press Enter to continue')
}

Write-Host 'Running TPCC workload'
Invoke-HammerDbScript -HammerdbCli $hammerdbCli -ScriptPath $hammerdbRunScript -MssqlHostOverride $(if ($remoteDb -and $rdbmsMode -eq 'MSSQL') { $effectiveMssqlHost } else { '' })

Write-Host 'Cycle complete. HammerDB output files are in ./tmp'
