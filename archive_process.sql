-- =========================================================================================
-- SQL Server Archiving Process Script
-- =========================================================================================
-- This script:
-- 1. Creates Archive tables if they don't exist (Orders_Archive, OrderDetails_Archive, AuditLog_Archive)
-- 2. Moves data older than 1 month from Operational tables to Archive tables
-- 3. Deletes the archived data from Operational tables
-- =========================================================================================

USE testa;
GO

-- =========================================================================================
-- 1. SETUP ARCHIVE DATABASE & TABLES
-- =========================================================================================

-- Create Archive Database
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'archive')
BEGIN
    CREATE DATABASE archive;
END
GO

-- Create Orders_Archive in 'archive' DB
IF OBJECT_ID('archive.dbo.Orders_Archive', 'U') IS NULL
BEGIN
    -- Structure matches dbo.Orders but without FKs usually, or with looser constraints
    CREATE TABLE archive.dbo.Orders_Archive (
        OrderID INT PRIMARY KEY, -- Keep original ID
        CustomerID INT,
        OrderDate DATETIME,
        TotalAmount DECIMAL(10, 2),
        CreatedDate DATETIME,
        UpdatedDate DATETIME,
        ArchivedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create OrderDetails_Archive in 'archive' DB
IF OBJECT_ID('archive.dbo.OrderDetails_Archive', 'U') IS NULL
BEGIN
    CREATE TABLE archive.dbo.OrderDetails_Archive (
        OrderDetailID INT PRIMARY KEY,
        OrderID INT,
        ProductName NVARCHAR(100),
        Quantity INT,
        UnitPrice DECIMAL(10, 2),
        CreatedDate DATETIME,
        UpdatedDate DATETIME,
        ArchivedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- Create AuditLog_Archive in 'archive' DB
IF OBJECT_ID('archive.dbo.AuditLog_Archive', 'U') IS NULL
BEGIN
    CREATE TABLE archive.dbo.AuditLog_Archive (
        LogID INT PRIMARY KEY,
        ActionType NVARCHAR(50),
        TableName NVARCHAR(50),
        RecordID INT,
        ActionDate DATETIME,
        Details NVARCHAR(MAX),
        ArchivedDate DATETIME DEFAULT GETDATE()
    );
END
GO

-- =========================================================================================
-- 2. ARCHIVING PROCESS (TRANSACTIONAL)
-- =========================================================================================

BEGIN TRANSACTION;

BEGIN TRY
    -- -------------------------------------------------------------------------------------
    -- Archive AuditLog (Simple Single Table)
    -- -------------------------------------------------------------------------------------
    DECLARE @AuditCutoffDate DATETIME = DATEADD(MONTH, -1, GETDATE());

    -- 1. Insert into Archive DB
    INSERT INTO archive.dbo.AuditLog_Archive (LogID, ActionType, TableName, RecordID, ActionDate, Details)
    SELECT LogID, ActionType, TableName, RecordID, ActionDate, Details
    FROM dbo.AuditLog
    WHERE ActionDate < @AuditCutoffDate;

    -- 2. Delete from Operational
    DELETE FROM dbo.AuditLog
    WHERE ActionDate < @AuditCutoffDate;

    PRINT 'Archived AuditLog records.';

    -- -------------------------------------------------------------------------------------
    -- Archive Orders & OrderDetails (Parent-Child Relationship)
    -- -------------------------------------------------------------------------------------
    DECLARE @OrderCutoffDate DATETIME = DATEADD(MONTH, -1, GETDATE());

    -- We need to identify which Orders are ready to handle both Parent and Child
    -- Using a temp table or table variable to hold IDs guarantees consistent processing
    DECLARE @OrdersToArchive TABLE (OrderID INT);

    INSERT INTO @OrdersToArchive (OrderID)
    SELECT OrderID
    FROM dbo.Orders
    WHERE OrderDate < @OrderCutoffDate;

    -- 1. Insert OrderDetails (Children) First -> To Archive DB
    INSERT INTO archive.dbo.OrderDetails_Archive (OrderDetailID, OrderID, ProductName, Quantity, UnitPrice, CreatedDate, UpdatedDate)
    SELECT OrderDetailID, OrderID, ProductName, Quantity, UnitPrice, CreatedDate, UpdatedDate
    FROM dbo.OrderDetails
    WHERE OrderID IN (SELECT OrderID FROM @OrdersToArchive);

    -- 2. Insert Orders (Parent) -> To Archive DB
    INSERT INTO archive.dbo.Orders_Archive (OrderID, CustomerID, OrderDate, TotalAmount, CreatedDate, UpdatedDate)
    SELECT OrderID, CustomerID, OrderDate, TotalAmount, CreatedDate, UpdatedDate
    FROM dbo.Orders
    WHERE OrderID IN (SELECT OrderID FROM @OrdersToArchive);

    -- 3. Delete OrderDetails (Children)
    DELETE FROM dbo.OrderDetails
    WHERE OrderID IN (SELECT OrderID FROM @OrdersToArchive);

    -- 4. Delete Orders (Parent)
    DELETE FROM dbo.Orders
    WHERE OrderID IN (SELECT OrderID FROM @OrdersToArchive);

    PRINT 'Archived Orders and OrderDetails records.';

    COMMIT TRANSACTION;
    PRINT 'Archiving process completed successfully.';

END TRY
BEGIN CATCH
    ROLLBACK TRANSACTION;
    PRINT 'Error during archiving. Transaction rolled back.';
    PRINT ERROR_MESSAGE();
END CATCH;
GO
