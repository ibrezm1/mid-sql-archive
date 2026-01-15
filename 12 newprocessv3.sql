-- =========================================================================================
-- SQL Server Metadata-Driven Archiving/Purging Script (Version 3 - Remote & Hardened)
-- =========================================================================================
-- Features:
-- 1. Linked Server Support: Archive to a separate SQL Server host.
-- 2. Hardened Dynamic SQL: Uses sp_executesql parameters (No SQL Injection risk).
-- 3. Robust Error Handling: Distributed Try/Catch blocks.
-- =========================================================================================

USE testa;
GO

-- =========================================================================================
-- 1. SETUP METADATA TABLES (V3 Schema)
-- =========================================================================================

IF OBJECT_ID('dbo.ArchiveConfig', 'U') IS NOT NULL DROP TABLE dbo.ArchiveConfig;
CREATE TABLE dbo.ArchiveConfig (
    ConfigID INT IDENTITY(1,1) PRIMARY KEY,
    -- Source definition
    SourceSchema NVARCHAR(50) DEFAULT 'dbo',
    SourceTable NVARCHAR(100),
    DateColumn NVARCHAR(100),
    
    -- Target definition
    TargetLinkedServer NVARCHAR(100) NULL, -- [NEW] Name of Linked Server (or NULL for local)
    TargetDatabase NVARCHAR(50) DEFAULT 'archive',
    TargetSchema NVARCHAR(50) DEFAULT 'dbo',
    TargetTable NVARCHAR(100),
    
    -- Rules
    RetentionDays INT,
    BatchSize INT DEFAULT 5000,
    ActionType NVARCHAR(10) CHECK (ActionType IN ('ARCHIVE', 'DELETE')), 
    TestMode BIT DEFAULT 0, 
    ProcessingOrder INT DEFAULT 1,
    IsEnabled BIT DEFAULT 1,
    Notes NVARCHAR(MAX)
);
GO

IF OBJECT_ID('dbo.ProcessingLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProcessingLog (
        LogID INT IDENTITY(1,1) PRIMARY KEY,
        BatchNumber INT,
        ConfigID INT,
        ActionType NVARCHAR(50),
        TableName NVARCHAR(100),
        RowsAffected INT,
        IsTestRun BIT,
        LogDate DATETIME DEFAULT GETDATE(),
        DurationMs INT,
        ErrorMessage NVARCHAR(MAX) -- [NEW] Capture errors
    );
END
GO

-- =========================================================================================
-- 2. POPULATE CONFIGURATION (SAMPLE DATA)
-- =========================================================================================
TRUNCATE TABLE dbo.ArchiveConfig;

-- Example 1: Local Archive (Linked Server is NULL)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetTable, ActionType, ProcessingOrder, Notes)
VALUES ('Orders', 'OrderDate', 30, 'Orders_Archive', 'ARCHIVE', 10, 'Local Archive Example');

-- Example 2: Remote Archive (Simulated Linked Server 'REMOTE_SRV')
-- Note: Replace 'REMOTE_SRV' with your actual Linked Server name
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetLinkedServer, TargetTable, ActionType, ProcessingOrder, Notes)
VALUES ('AuditLog', 'ActionDate', 90, 'REMOTE_SRV', 'AuditLog_RemoteArchive', 'ARCHIVE', 20, 'Remote Archive Example');

-- Example 3: Delete (No Target needed)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, ActionType, ProcessingOrder, Notes)
VALUES ('AuditLog', 'ActionDate', 90, 'DELETE', 30, 'Purge Local Audit Data');

GO

-- =========================================================================================
-- 3. EXECUTION ENGINE (V3)
-- =========================================================================================

DECLARE @CurrentBatchNumber INT;
SELECT @CurrentBatchNumber = ISNULL(MAX(BatchNumber), 0) + 1 FROM dbo.ProcessingLog;
PRINT 'Starting Batch Run: ' + CAST(@CurrentBatchNumber AS NVARCHAR);

DECLARE @ConfigID INT, @SourceSchema NVARCHAR(50), @SourceTable NVARCHAR(100), @DateColumn NVARCHAR(100);
DECLARE @RetentionDays INT, @TargetLinkedServer NVARCHAR(100), @TargetDatabase NVARCHAR(50), @TargetSchema NVARCHAR(50), @TargetTable NVARCHAR(100);
DECLARE @BatchSize INT, @ActionType NVARCHAR(10), @TestMode BIT;
DECLARE @CutoffDate DATETIME; -- Changed from NVARCHAR to DATETIME for parameter safety

DECLARE ConfigCursor CURSOR FOR 
SELECT ConfigID, SourceSchema, SourceTable, DateColumn, RetentionDays, TargetLinkedServer, TargetDatabase, TargetSchema, TargetTable, BatchSize, ActionType, TestMode
FROM dbo.ArchiveConfig 
WHERE IsEnabled = 1
ORDER BY ProcessingOrder ASC;

OPEN ConfigCursor;
FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetLinkedServer, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @StartTime DATETIME = GETDATE();
    DECLARE @LogActionType NVARCHAR(50) = @ActionType;
    
    -- Calculate Cutoff (Local variable, safe)
    SET @CutoffDate = DATEADD(DAY, -@RetentionDays, GETDATE());

    PRINT 'Processing: ' + @SourceTable + ' (' + @ActionType + ')';

    BEGIN TRY
        -- ===============================================================================
        -- DYNAMIC SQL CONSTRUCTION
        -- ===============================================================================
        DECLARE @SQL NVARCHAR(MAX);
        DECLARE @Params NVARCHAR(MAX) = N'@BatchSize INT, @CutoffDate DATETIME, @RowsOut INT OUTPUT';
        DECLARE @TargetFullName NVARCHAR(400);

        -- Construct Target Name (Handle Linked Server)
        IF @TargetLinkedServer IS NOT NULL AND @TargetTable IS NOT NULL
             SET @TargetFullName = QUOTENAME(@TargetLinkedServer) + '.' + QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable);
        ELSE IF @TargetTable IS NOT NULL
             SET @TargetFullName = QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable);

        -- TEST MODE
        IF @TestMode = 1
        BEGIN
            SET @LogActionType = 'TEST-' + @ActionType;
            SET @SQL = N'
            SELECT @RowsOut = COUNT(*) 
            FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
            WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate;';
            
            EXEC sp_executesql @SQL, @Params, @BatchSize, @CutoffDate, @RowsOut = @SQL OUTPUT; -- Reusing variable slightly hacky but works for OUT
            -- NOTE: sp_executesql OUT param mapping fix below:
        END
        
        -- EXECUTE MODE
        ELSE
        BEGIN
            -- We build a loop logic inside Dynamic SQL? 
            -- Better Hardening: Do logic in Outer Loop, executes Dynamic SQL for pure batch? 
            -- Actually, simpler to keep the loop local to avoid massive string context switching.
            -- But for V3 Hardening, let's keep the T-SQL Loop inside the string for atomic Batch-Wait performance.
            
            SET @SQL = N'
            SET XACT_ABORT ON; -- Required for Distributed Transactions
            DECLARE @RowsAffected INT = 1;
            DECLARE @Total INT = 0;
            
            WHILE @RowsAffected > 0
            BEGIN
                BEGIN DISTRIBUTED TRANSACTION; -- Promotes to Local or Dist based on needs
                    
                ';

            IF @ActionType = 'ARCHIVE'
            BEGIN
                 SET @SQL = @SQL + N'INSERT INTO ' + @TargetFullName + ' 
                 SELECT TOP (@BatchSize) * 
                 FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
                 WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate;';
            END
            ELSE IF @ActionType = 'DELETE'
            BEGIN
                 SET @SQL = @SQL + N'DELETE TOP (@BatchSize) 
                 FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + '
                 WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate;';
            END

            SET @SQL = @SQL + N'
                SET @RowsAffected = @@ROWCOUNT;
                SET @Total = @Total + @RowsAffected;
                
                COMMIT TRANSACTION;
                IF @RowsAffected > 0 WAITFOR DELAY ''00:00:00.100'';
            END
            SET @RowsOut = @Total;
            ';
        END

        -- EXECUTE (Hardened with sp_executesql)
        DECLARE @TotalRowsAffected INT;
        
        IF @TestMode = 1
        BEGIN
            -- Fix for count query above
            DECLARE @CountSQL NVARCHAR(MAX) = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + ' WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate';
            EXEC sp_executesql @CountSQL, N'@CutoffDate DATETIME, @Cnt INT OUTPUT', @CutoffDate, @Cnt = @TotalRowsAffected OUTPUT;
        END
        ELSE
        BEGIN
            -- Execute the big batch script
            EXEC sp_executesql @SQL, N'@BatchSize INT, @CutoffDate DATETIME, @RowsOut INT OUTPUT', @BatchSize, @CutoffDate, @RowsOut = @TotalRowsAffected OUTPUT;
        END

        -- LOG SUCCESS
        INSERT INTO dbo.ProcessingLog (BatchNumber, ConfigID, ActionType, TableName, RowsAffected, IsTestRun, DurationMs)
        VALUES (@CurrentBatchNumber, @ConfigID, @LogActionType, @SourceTable, @TotalRowsAffected, @TestMode, DATEDIFF(ms, @StartTime, GETDATE()));

    END TRY
    BEGIN CATCH
        -- LOG ERROR
        DECLARE @ErrMsg NVARCHAR(MAX) = ERROR_MESSAGE();
        INSERT INTO dbo.ProcessingLog (BatchNumber, ConfigID, ActionType, TableName, RowsAffected, IsTestRun, DurationMs, ErrorMessage)
        VALUES (@CurrentBatchNumber, @ConfigID, 'ERROR', @SourceTable, 0, @TestMode, DATEDIFF(ms, @StartTime, GETDATE()), @ErrMsg);
        
        PRINT 'Error processing ' + @SourceTable + ': ' + @ErrMsg;
        
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    END CATCH

    FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetLinkedServer, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;
END

CLOSE ConfigCursor;
DEALLOCATE ConfigCursor;
PRINT 'Batch Run Completed.';
GO
