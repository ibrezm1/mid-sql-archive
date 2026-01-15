-- =========================================================================================
-- SQL Server Metadata-Driven Archiving/Purging Script (Version 2)
-- =========================================================================================
-- Features:
-- 1. Single Config Table with 'ActionType' (ARCHIVE or DELETE).
-- 2. Processing Log with Batch Numbering.
-- 3. Test Mode: Reads 'TestMode' from Config to simulate runs (Count Only).
-- =========================================================================================

USE testa;
GO

-- =========================================================================================
-- 1. SETUP METADATA TABLES
-- =========================================================================================

-- A. Configuration Table
IF OBJECT_ID('dbo.ArchiveConfig', 'U') IS NOT NULL DROP TABLE dbo.ArchiveConfig;
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
    ActionType NVARCHAR(10) CHECK (ActionType IN ('ARCHIVE', 'DELETE')), 
    TestMode BIT DEFAULT 0, -- 1 = Count Only (Safe), 0 = Execute (Active)
    Notes NVARCHAR(MAX),
    ProcessingOrder INT DEFAULT 1, 
    IsEnabled BIT DEFAULT 1
);
GO

-- B. Processing Log Table
IF OBJECT_ID('dbo.ProcessingLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProcessingLog (
        LogID INT IDENTITY(1,1) PRIMARY KEY,
        BatchNumber INT,             
        ConfigID INT,
        ActionType NVARCHAR(20), -- Expanded for 'TEST-ARCHIVE'
        TableName NVARCHAR(100),
        RowsAffected INT,
        IsTestRun BIT,           -- New flag
        LogDate DATETIME DEFAULT GETDATE(),
        DurationMs INT
    );
END
GO

-- =========================================================================================
-- 2. POPULATE CONFIGURATION (SAMPLE DATA)
-- =========================================================================================
TRUNCATE TABLE dbo.ArchiveConfig;

-- 1. Archive Orders (Active)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ActionType, TestMode, ProcessingOrder, Notes)
VALUES ('Orders', 'OrderDate', 30, 'Orders_Archive', 'ARCHIVE', 0, 10, 'Copy Orders to Archive');

-- 2. Archive OrderDetails (Test Mode Example)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ActionType, TestMode, ProcessingOrder, Notes)
VALUES ('OrderDetails', 'CreatedDate', 30, 'OrderDetails_Archive', 'ARCHIVE', 1, 20, 'TEST ONLY: Copy Details');

-- 3. Delete OrderDetails (Test Mode Example)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ActionType, TestMode, ProcessingOrder, Notes)
VALUES ('OrderDetails', 'CreatedDate', 30, NULL, 'DELETE', 1, 30, 'TEST ONLY: Remove Details');

-- 4. Delete Orders (Active)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, NULL, 'DELETE', 0, 40, 'Remove Orders');

GO

-- =========================================================================================
-- 3. EXECUTION ENGINE
-- =========================================================================================

DECLARE @CurrentBatchNumber INT;
DECLARE @StartTime DATETIME;

-- 1. Assign Batch Number
SELECT @CurrentBatchNumber = ISNULL(MAX(BatchNumber), 0) + 1 FROM dbo.ProcessingLog;
PRINT 'Starting Batch Run: ' + CAST(@CurrentBatchNumber AS NVARCHAR);

-- Variables
DECLARE @ConfigID INT, @SourceSchema NVARCHAR(50), @SourceTable NVARCHAR(100), @DateColumn NVARCHAR(100);
DECLARE @RetentionDays INT, @TargetDatabase NVARCHAR(50), @TargetSchema NVARCHAR(50), @TargetTable NVARCHAR(100);
DECLARE @BatchSize INT, @ActionType NVARCHAR(10), @TestMode BIT;
DECLARE @SQL NVARCHAR(MAX);
DECLARE @CutoffDate NVARCHAR(20);

DECLARE ConfigCursor CURSOR FOR 
SELECT ConfigID, SourceSchema, SourceTable, DateColumn, RetentionDays, TargetDatabase, TargetSchema, TargetTable, BatchSize, ActionType, TestMode
FROM dbo.ArchiveConfig 
WHERE IsEnabled = 1
ORDER BY ProcessingOrder ASC;

OPEN ConfigCursor;
FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @StartTime = GETDATE();
    SET @CutoffDate = CONVERT(NVARCHAR(20), DATEADD(DAY, -@RetentionDays, GETDATE()), 120);

    PRINT '---------------------------------------------------------';
    PRINT 'Processing: ' + @SourceTable + ' | Action: ' + @ActionType + ' | TestMode: ' + CAST(@TestMode AS NVARCHAR);

    -- =========================================================================
    -- PATH A: TEST MODE (Count Only)
    -- =========================================================================
    IF @TestMode = 1
    BEGIN
        DECLARE @TestCount INT = 0;
        DECLARE @CountSQL NVARCHAR(MAX);
        
        SET @CountSQL = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + ' WHERE ' + QUOTENAME(@DateColumn) + ' < ''' + @CutoffDate + '''';
        
        EXEC sp_executesql @CountSQL, N'@Cnt INT OUTPUT', @Cnt = @TestCount OUTPUT;
        
        -- Log the "Simulated" Action
        INSERT INTO dbo.ProcessingLog (BatchNumber, ConfigID, ActionType, TableName, RowsAffected, IsTestRun, LogDate, DurationMs)
        VALUES (@CurrentBatchNumber, @ConfigID, 'TEST-' + @ActionType, @SourceTable, @TestCount, 1, GETDATE(), DATEDIFF(ms, @StartTime, GETDATE()));
        
        PRINT 'Test Mode: Found ' + CAST(@TestCount AS NVARCHAR) + ' candidate rows.';
    END
    -- =========================================================================
    -- PATH B: EXECUTE MODE (Actual INSERT/DELETE)
    -- =========================================================================
    ELSE
    BEGIN
        SET @SQL = N'
        DECLARE @RowsAffected INT = 1;
        DECLARE @TotalRows INT = 0;
        
        WHILE @RowsAffected > 0
        BEGIN
            BEGIN TRANSACTION;
            ';

        IF @ActionType = 'ARCHIVE'
        BEGIN
            SET @SQL = @SQL + N'
            INSERT INTO ' + QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable) + '
            SELECT TOP (' + CAST(@BatchSize AS NVARCHAR) + ') * 
            FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
            WHERE ' + QUOTENAME(@DateColumn) + ' < ''' + @CutoffDate + ''';';
        END
        ELSE
        BEGIN
            SET @SQL = @SQL + N'
            DELETE TOP (' + CAST(@BatchSize AS NVARCHAR) + ') 
            FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
            WHERE ' + QUOTENAME(@DateColumn) + ' < ''' + @CutoffDate + ''';';
        END

        SET @SQL = @SQL + N'
            SET @RowsAffected = @@ROWCOUNT;
            SET @TotalRows = @TotalRows + @RowsAffected;
            COMMIT TRANSACTION;
            IF @RowsAffected > 0 WAITFOR DELAY ''00:00:00.100'';
        END
        
        -- Log Actual Execution
        INSERT INTO dbo.ProcessingLog (BatchNumber, ConfigID, ActionType, TableName, RowsAffected, IsTestRun, LogDate, DurationMs)
        VALUES (' + CAST(@CurrentBatchNumber AS NVARCHAR) + ', ' + CAST(@ConfigID AS NVARCHAR) + ', ''' + @ActionType + ''', ''' + @SourceTable + ''', @TotalRows, 0, GETDATE(), DATEDIFF(ms, ''' + CONVERT(NVARCHAR(30), @StartTime, 121) + ''', GETDATE()));
        ';
        
        -- EXEC sp_executesql @SQL; -- Uncomment to run
        PRINT @SQL; 
    END

    FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;
END

CLOSE ConfigCursor;
DEALLOCATE ConfigCursor;
PRINT 'Batch Run Completed.';
GO
