-- =========================================================================================
-- SQL Server Metadata-Driven Archiving/Purging Script
-- =========================================================================================
-- Purpose: 
-- Instead of hardcoding table names in scripts, this approach uses a configuration table.
-- You just add a row to [ArchiveConfig], and the script automatically handles the rest.
-- =========================================================================================

USE testa;
GO

-- 1. Create the Metadata Table
IF OBJECT_ID('dbo.ArchiveConfig', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ArchiveConfig (
        ConfigID INT IDENTITY(1,1) PRIMARY KEY,
        SourceSchema NVARCHAR(50) DEFAULT 'dbo',
        SourceTable NVARCHAR(100),
        DateColumn NVARCHAR(100),
        RetentionDays INT,
        TargetDatabase NVARCHAR(50) DEFAULT 'archive',
        TargetSchema NVARCHAR(50) DEFAULT 'dbo',
        TargetTable NVARCHAR(100),
        BatchSize INT DEFAULT 5000,
        IsEnabled BIT DEFAULT 1,
        ProcessingOrder INT DEFAULT 1 -- Lower runs first (Parent before Child for Archiving)
    );
END
GO

-- 2. Populate Metadata (Example Config)
-- Clear usage for demo
TRUNCATE TABLE dbo.ArchiveConfig;

-- Config for Orders (Parent) - Archive data older than 30 days
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ProcessingOrder)
VALUES ('Orders', 'OrderDate', 30, 'Orders_Archive', 10);

-- Config for OrderDetails (Child) - Archive data older than 30 days
-- Note: We rely on OrderDetails having its own 'CreatedDate' or similar for this simple pattern
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ProcessingOrder)
VALUES ('OrderDetails', 'CreatedDate', 30, 'OrderDetails_Archive', 20);

-- Config for AuditLog (Standalone)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ProcessingOrder)
VALUES ('AuditLog', 'ActionDate', 30, 'AuditLog_Archive', 50);

GO

-- =========================================================================================
-- 3. The Dynamic Execution Engine
-- =========================================================================================

DECLARE @SourceSchema NVARCHAR(50), @SourceTable NVARCHAR(100), @DateColumn NVARCHAR(100);
DECLARE @TargetDatabase NVARCHAR(50), @TargetSchema NVARCHAR(50), @TargetTable NVARCHAR(100);
DECLARE @RetentionDays INT, @BatchSize INT;
DECLARE @SQL NVARCHAR(MAX);
DECLARE @CutoffDate NVARCHAR(20); -- String for Dynamic SQL

-- CURSOR: Iterate through active configs
-- Ordered by ProcessingOrder so we handle Parents/Dependencies correctly if needed
-- NOTE: For simple purging, we might want DESC order (Child first), but for Copy-Archive we want ASC.
DECLARE ArchiveCursor CURSOR FOR 
SELECT SourceSchema, SourceTable, DateColumn, RetentionDays, TargetDatabase, TargetSchema, TargetTable, BatchSize 
FROM dbo.ArchiveConfig 
WHERE IsEnabled = 1
ORDER BY ProcessingOrder ASC;

OPEN ArchiveCursor;
FETCH NEXT FROM ArchiveCursor INTO @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '-----------------------------------------------------------------';
    PRINT 'Processing Table: ' + @SourceTable;

    -- Calculate Cutoff Date relative to NOW
    SET @CutoffDate = CONVERT(NVARCHAR(20), DATEADD(DAY, -@RetentionDays, GETDATE()), 120);
    PRINT 'Cutoff Date: ' + @CutoffDate;

    -- Dynamic SQL Construction
    -- Loop Logic: Insert Batch -> Delete Batch -> Repeat
    SET @SQL = N'
    DECLARE @RowsAffected INT = 1;
    
    WHILE @RowsAffected > 0
    BEGIN
        BEGIN TRANSACTION;
        
        -- 1. Copy to Archive
        INSERT INTO ' + QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable) + '
        SELECT TOP (' + CAST(@BatchSize AS NVARCHAR) + ') * 
        FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
        WHERE ' + QUOTENAME(@DateColumn) + ' < ''' + @CutoffDate + ''';
        
        -- 2. Delete from Source
        -- Note: We use the same WHERE clause. 
        -- In a real production scenario, you might delete based on IDs captured in step 1 to avoid "phantom" row issues.
        DELETE TOP (' + CAST(@BatchSize AS NVARCHAR) + ') 
        FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
        WHERE ' + QUOTENAME(@DateColumn) + ' < ''' + @CutoffDate + ''';

        SET @RowsAffected = @@ROWCOUNT;
        
        COMMIT TRANSACTION;
        
        -- Optional throttle
        WAITFOR DELAY ''00:00:00.100'';
    END';

    PRINT 'Executing Dynamic SQL...';
    -- EXEC sp_executesql @SQL; -- Uncomment to actually run
    PRINT @SQL; -- For demonstration, we print the generated script

    FETCH NEXT FROM ArchiveCursor INTO @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize;
END

CLOSE ArchiveCursor;
DEALLOCATE ArchiveCursor;
GO
