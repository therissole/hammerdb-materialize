SET NOCOUNT ON;
GO

IF DB_ID(N'$(mssql_db)') IS NULL
BEGIN
    THROW 50000, 'Target SQL Server database does not exist.', 1;
END;
GO

USE [$(mssql_db)];
GO

ALTER DATABASE [$(mssql_db)] SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE [$(mssql_db)] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'$(mssql_db)' AND is_cdc_enabled = 1)
BEGIN
    EXEC sys.sp_cdc_enable_db;
END;
GO

DECLARE @table sysname;
DECLARE table_cursor CURSOR FAST_FORWARD FOR
    SELECT name
    FROM sys.tables
        WHERE schema_id = SCHEMA_ID(N'dbo')
            AND is_ms_shipped = 0;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM sys.tables
        WHERE schema_id = SCHEMA_ID(N'dbo')
          AND name = @table
                    AND is_ms_shipped = 0
          AND is_tracked_by_cdc = 1
    )
    BEGIN
        EXEC sys.sp_cdc_enable_table
            @source_schema = N'dbo',
            @source_name = @table,
            @role_name = NULL;
    END;

    FETCH NEXT FROM table_cursor INTO @table;
END;

CLOSE table_cursor;
DEALLOCATE table_cursor;
GO
