/*
=========================================================================================
REMOTE ARCHIVING SETUP & JOB CREATION (14 Remote.sql)
=========================================================================================
Context:
This script demonstrates how to configure the Metadata-Driven Archiving Process to:
1. Push data to a REMOTE SQL Server using Linked Servers.
2. Handle PARENT/CHILD dependencies (e.g., SalesOrderHeader -> SalesOrderDetail).
3. Automate the process using a SQL Server Agent Job.

Prerequisites:
- A Linked Server must be configured (e.g., 'REMOTE_SRV').
- MSDTC (Microsoft Distributed Transaction Coordinator) must be active for cross-server transactions.
- The target database/table must exist on the remote server.
=========================================================================================
*/

USE testa;
GO

-- =========================================================================================
-- STEP 1: INSTALL THE ARCHIVING ENGINE (Stored Procedure)
-- =========================================================================================
-- We wrap the logic from "newprocessv3.sql" into a Stored Procedure for the Job to call.

IF OBJECT_ID('dbo.usp_RunArchiving', 'P') IS NULL EXEC('CREATE PROCEDURE dbo.usp_RunArchiving AS RETURN 0');
GO

ALTER PROCEDURE dbo.usp_RunArchiving
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON; -- Vital for Distributed Transactions

    DECLARE @CurrentBatchNumber INT;
    SELECT @CurrentBatchNumber = ISNULL(MAX(BatchNumber), 0) + 1 FROM dbo.ProcessingLog;
    
    DECLARE @ConfigID INT, @SourceSchema NVARCHAR(50), @SourceTable NVARCHAR(100), @DateColumn NVARCHAR(100);
    DECLARE @RetentionDays INT, @TargetLinkedServer NVARCHAR(100), @TargetDatabase NVARCHAR(50), @TargetSchema NVARCHAR(50), @TargetTable NVARCHAR(100);
    DECLARE @BatchSize INT, @ActionType NVARCHAR(10), @TestMode BIT;
    DECLARE @CutoffDate DATETIME;

    -- Cursor to fetch active configurations in PROCESSING ORDER
    DECLARE ConfigCursor CURSOR FOR 
    SELECT ConfigID, SourceSchema, SourceTable, DateColumn, RetentionDays, TargetLinkedServer, TargetDatabase, TargetSchema, TargetTable, BatchSize, ActionType, TestMode
    FROM dbo.ArchiveConfig 
    WHERE IsEnabled = 1
    ORDER BY ProcessingOrder ASC; -- CRITICAL: Ensures Parents handled before Children for Archive, etc.

    OPEN ConfigCursor;
    FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetLinkedServer, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @StartTime DATETIME = GETDATE();
        DECLARE @LogActionType NVARCHAR(50) = @ActionType;
        SET @CutoffDate = DATEADD(DAY, -@RetentionDays, GETDATE());

        BEGIN TRY
            -- Construct Target Name (Handle Linked Server)
            DECLARE @TargetFullName NVARCHAR(400);
            IF @TargetLinkedServer IS NOT NULL AND @TargetTable IS NOT NULL
                 SET @TargetFullName = QUOTENAME(@TargetLinkedServer) + '.' + QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable);
            ELSE IF @TargetTable IS NOT NULL
                 SET @TargetFullName = QUOTENAME(@TargetDatabase) + '.' + QUOTENAME(@TargetSchema) + '.' + QUOTENAME(@TargetTable);

            DECLARE @SQL NVARCHAR(MAX);
            DECLARE @TotalRowsAffected INT;

            -- DYNAMIC SQL GENERATION
            IF @TestMode = 1
            BEGIN
                SET @LogActionType = 'TEST-' + @ActionType;
                DECLARE @CountSQL NVARCHAR(MAX) = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@SourceSchema) + '.' + QUOTENAME(@SourceTable) + ' WHERE ' + QUOTENAME(@DateColumn) + ' < @CutoffDate';
                EXEC sp_executesql @CountSQL, N'@CutoffDate DATETIME, @Cnt INT OUTPUT', @CutoffDate, @Cnt = @TotalRowsAffected OUTPUT;
            END
            ELSE
            BEGIN
                -- BATCH LOOP LOGIC
                SET @SQL = N'
                SET XACT_ABORT ON;
                DECLARE @RowsAffected INT = 1;
                DECLARE @Total INT = 0;
                
                WHILE @RowsAffected > 0
                BEGIN
                    -- Start Distributed Transaction if Linked Server is involved
                    BEGIN DISTRIBUTED TRANSACTION;
                    
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
                    -- Small delay to let Transaction Log catch up / prevent blocking
                    IF @RowsAffected > 0 WAITFOR DELAY ''00:00:00.100'';
                END
                SET @RowsOut = @Total;
                ';

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
            
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        END CATCH

        FETCH NEXT FROM ConfigCursor INTO @ConfigID, @SourceSchema, @SourceTable, @DateColumn, @RetentionDays, @TargetLinkedServer, @TargetDatabase, @TargetSchema, @TargetTable, @BatchSize, @ActionType, @TestMode;
    END

    CLOSE ConfigCursor;
    DEALLOCATE ConfigCursor;
END
GO

-- =========================================================================================
-- STEP 2: CONFIGURE DEPENDENCIES (Parent/Child Example)
-- =========================================================================================
-- Scenario: Archive 'SalesOrderHeader' (Parent) and 'SalesOrderDetail' (Child) to 'REMOTE_SRV'.
-- NOTE: We must order the operations carefully to avoid Foreign Key violations.

TRUNCATE TABLE dbo.ArchiveConfig; -- Clear for demo

-- 2a. ARCHIVE: MUST Archive PARENT first, then CHILD (so FK on Remote is satisfied)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, TargetLinkedServer, TargetTable, ActionType, ProcessingOrder, Notes)
VALUES 
('SalesOrderHeader', 'OrderDate', 365, 'REMOTE_SRV', 'SalesOrderHeader_Arch', 'ARCHIVE', 10, 'Remote: Parent First'),
('SalesOrderDetail', 'ModifiedDate', 365, 'REMOTE_SRV', 'SalesOrderDetail_Arch', 'ARCHIVE', 20, 'Remote: Child Second');

-- 2b. PURGE: MUST Delete CHILD first, then PARENT (so FK on Local is satisfied)
INSERT INTO dbo.ArchiveConfig (SourceTable, DateColumn, RetentionDays, ActionType, ProcessingOrder, Notes)
VALUES 
('SalesOrderDetail', 'ModifiedDate', 365, NULL, NULL, 'DELETE', 30, 'Purge: Child First'),
('SalesOrderHeader', 'OrderDate', 365, NULL, NULL, 'DELETE', 40, 'Purge: Parent Second');

GO

-- =========================================================================================
-- STEP 3: CREATE THE SQL AGENT JOB
-- =========================================================================================

USE [msdb]
GO

IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs_view WHERE name = N'Daily_Archiving_Remote')
    EXEC sp_delete_job @job_name = N'Daily_Archiving_Remote', @delete_unused_schedule=1
GO

BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

-- 3a. Add Category
IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N'Database Maintenance' AND category_class=1)
BEGIN
    EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N'JOB', @type=N'LOCAL', @name=N'Database Maintenance'
    IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback
END

-- 3b. Add Job
DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'Daily_Archiving_Remote', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Executes dbo.usp_RunArchiving to move data to Remote Server.', 
		@category_name=N'Database Maintenance', 
		@owner_login_name=N'sa', 
		@job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- 3c. Add Job Step (Calls the Stored Procedure)
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Run Archiving Procedure', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'EXEC dbo.usp_RunArchiving;', 
		@database_name=N'testa', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- 3d. Add Schedule (e.g., Daily at 2 AM)
EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N'Daily At 2AM', 
		@enabled=1, 
		@freq_type=4, -- Daily
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20240101, 
		@active_end_date=99991231, 
		@active_start_time=20000, -- 02:00:00
		@active_end_time=235959
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

-- 3e. Attach to Server
EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave

QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO
