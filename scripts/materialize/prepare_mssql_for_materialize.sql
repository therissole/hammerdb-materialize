-- Materialize SQL Server CDC Integration - Complete Setup Script
-- Based on: https://materialize.com/docs/ingest-data/sql-server/self-hosted/
-- This script is IDEMPOTENT and can be run multiple times safely.

SET NOCOUNT ON;
GO

-- Verify the target database exists
IF DB_ID(N'$(mssql_db)') IS NULL
BEGIN
    THROW 50000, 'Target SQL Server database does not exist. Specify a valid database name in mssql_db variable.', 1;
END;
GO

PRINT '=== Materialize SQL Server CDC Integration Setup ==='
PRINT 'Target Database: $(mssql_db)'
PRINT 'Materialize User: materialize'
GO

-- ============================================================================
-- STEP 1: Verify SQL Server Agent is running (required for CDC)
-- ============================================================================
PRINT '';
PRINT '--- Step 1: Verifying SQL Server Agent ---';
USE msdb;
GO

IF NOT EXISTS (SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status_desc = 'Running')
BEGIN
    PRINT 'WARNING: SQL Server Agent is not running. CDC requires it to be running.';
END
ELSE
BEGIN
    PRINT 'OK: SQL Server Agent is running.';
END;
GO

-- ============================================================================
-- STEP 2: Create login and principals in MASTER database
-- ============================================================================
PRINT '';
PRINT '--- Step 2: Setting up master database principals ---';
USE master;
GO

-- Create login if it doesn't exist
IF NOT EXISTS (SELECT 1 FROM sys.syslogins WHERE name = N'materialize')
BEGIN
    PRINT 'Creating login materialize...';
    DECLARE @sql NVARCHAR(1000) = N'CREATE LOGIN [materialize] WITH PASSWORD = ''' + REPLACE(N'$(materialize_password)', '''', '''''') + N''', CHECK_POLICY = OFF;';
    EXEC sp_executesql @sql;
END
ELSE
BEGIN
    PRINT 'Login materialize already exists.';
END;
GO

-- Create user for login in master if it doesn't exist
IF NOT EXISTS (SELECT 1 FROM master.sys.sysusers WHERE name = N'materialize')
BEGIN
    PRINT 'Creating user materialize in master...';
    CREATE USER [materialize] FOR LOGIN [materialize];
END
ELSE
BEGIN
    PRINT 'User materialize already exists in master.';
END;
GO

-- Grant master database permissions for INFORMATION_SCHEMA discovery
PRINT 'Granting INFORMATION_SCHEMA permissions in master...';
GRANT SELECT ON INFORMATION_SCHEMA.KEY_COLUMN_USAGE TO [materialize];
GRANT SELECT ON INFORMATION_SCHEMA.TABLE_CONSTRAINTS TO [materialize];
GO

-- Grant CDC monitoring functions (required for tracking LSN progress)
PRINT 'Granting CDC LSN function permissions...';
GRANT EXECUTE ON sys.fn_cdc_get_min_lsn TO [materialize];
GRANT EXECUTE ON sys.fn_cdc_get_max_lsn TO [materialize];
GRANT EXECUTE ON sys.fn_cdc_increment_lsn TO [materialize];
GO

-- Grant VIEW SERVER STATE for monitoring
PRINT 'Granting VIEW SERVER STATE...';
GRANT VIEW SERVER STATE TO [materialize];
GO

-- ============================================================================
-- STEP 3: Database configuration (isolation level, CDC enablement)
-- ============================================================================
PRINT '';
PRINT '--- Step 3: Configuring target database ---';

USE [$(mssql_db)];
GO

-- Enable SNAPSHOT transaction isolation
PRINT 'Enabling SNAPSHOT transaction isolation...';
ALTER DATABASE [$(mssql_db)] SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

-- Enable database-level CDC if not already enabled
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(mssql_db)' AND is_cdc_enabled = 1)
BEGIN
    PRINT 'Enabling CDC on database $(mssql_db)...';
    EXEC sys.sp_cdc_enable_db;
    WAITFOR DELAY '00:00:02';  -- Brief delay to allow CDC jobs to start
END
ELSE
BEGIN
    PRINT 'CDC already enabled on database $(mssql_db).';
END;
GO

-- ============================================================================
-- STEP 4: Create user in target database with necessary roles
-- ============================================================================
PRINT '';
PRINT '--- Step 4: Setting up database user and roles ---';

USE [$(mssql_db)];
GO

-- Create user in target database if it doesn't exist
IF NOT EXISTS (SELECT 1 FROM sys.sysusers WHERE name = N'materialize')
BEGIN
    PRINT 'Creating user materialize in $(mssql_db)...';
    CREATE USER [materialize] FOR LOGIN [materialize];
END
ELSE
BEGIN
    PRINT 'User materialize already exists in $(mssql_db).';
END;
GO

-- Add user to db_datareader role for SELECT on all tables
IF NOT EXISTS (
    SELECT 1 FROM sys.database_role_members rm
    JOIN sys.database_principals user_p ON rm.member_principal_id = user_p.principal_id
    JOIN sys.database_principals role_p ON rm.role_principal_id = role_p.principal_id
    WHERE user_p.name = 'materialize' AND role_p.name = 'db_datareader'
)
BEGIN
    PRINT 'Adding materialize to db_datareader role in $(mssql_db)...';
    ALTER ROLE [db_datareader] ADD MEMBER [materialize];
END
ELSE
BEGIN
    PRINT 'User materialize already member of db_datareader.';
END;
GO

-- ============================================================================
-- STEP 5: Enable CDC on all user tables
-- ============================================================================
PRINT '';
PRINT '--- Step 5: Enabling CDC on tables ---';

USE [$(mssql_db)];
GO

DECLARE @table_name sysname;
DECLARE @source_schema sysname;
DECLARE table_cursor CURSOR FAST_FORWARD FOR
    SELECT schema_name(schema_id) AS schema_name, name
    FROM sys.tables
    WHERE is_ms_shipped = 0
        AND type = 'U'
    ORDER BY schema_name(schema_id), name;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @source_schema, @table_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.tables
        WHERE schema_id = SCHEMA_ID(@source_schema)
          AND name = @table_name
          AND is_tracked_by_cdc = 1
    )
    BEGIN
        PRINT 'Enabling CDC on table ' + @source_schema + '.' + @table_name + '...';
        BEGIN TRY
            EXEC sys.sp_cdc_enable_table
                @source_schema = @source_schema,
                @source_name = @table_name,
                @role_name = NULL;
        END TRY
        BEGIN CATCH
            PRINT 'Warning: Could not enable CDC on ' + @source_schema + '.' + @table_name + '. Error: ' + ERROR_MESSAGE();
        END CATCH;
    END
    ELSE
    BEGIN
        PRINT 'CDC already enabled on table ' + @source_schema + '.' + @table_name + '.';
    END;

    FETCH NEXT FROM table_cursor INTO @source_schema, @table_name;
END;

CLOSE table_cursor;
DEALLOCATE table_cursor;
GO

-- ============================================================================
-- STEP 6: Verify setup
-- ============================================================================
PRINT '';
PRINT '--- Step 6: Verifying setup ---';

USE [$(mssql_db)];
GO

PRINT '';
PRINT 'Database CDC Status:';
SELECT name, is_cdc_enabled FROM sys.databases WHERE name = N'$(mssql_db)';

PRINT '';
PRINT 'Tables with CDC Enabled:';
SELECT schema_name(schema_id) AS schema_name, name FROM sys.tables WHERE is_tracked_by_cdc = 1 ORDER BY schema_name(schema_id), name;

PRINT '';
PRINT 'Materialize User Permissions:';
SELECT DISTINCT role_p.name AS assigned_role
FROM sys.database_role_members rm
JOIN sys.database_principals user_p ON rm.member_principal_id = user_p.principal_id
JOIN sys.database_principals role_p ON rm.role_principal_id = role_p.principal_id
WHERE user_p.name = 'materialize'
ORDER BY role_p.name;

PRINT '';
PRINT '=== Setup Complete ==='
PRINT ''
PRINT 'Verification Checklist:'
PRINT '  [X] Database CDC Status should show is_cdc_enabled = 1'
PRINT '  [X] Tables with CDC Enabled should list all TPCC tables'
PRINT '  [X] Materialize user has db_datareader role'
PRINT ''
PRINT 'Next Steps in Materialize:'
PRINT '  1. Set psql variables (\set commands)'
PRINT '  2. Run setup_materialize_mssql.sql to create cluster, connection, and source'
PRINT ''
GO
