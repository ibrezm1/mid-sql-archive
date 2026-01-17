/*
=========================================================================================
LOOPBACK LINKED SERVER SETUP (15 LoopbackSetup.sql)
=========================================================================================
Purpose:
Configures a "Loopback" Linked Server named 'REMOTE_SRV' that points to YOUR LOCAL machine.
This allows you to test "Remote Archiving" scripts without needing a second SQL Server instance.

Instructions:
1. Run this script once.
2. Ensure MSDTC (Distributed Transaction Coordinator) service is running on your machine.
   (Run 'services.msc' -> Find 'Distributed Transaction Coordinator' -> Start).
3. Use 'REMOTE_SRV' as the TargetLinkedServer in your ArchiveConfig.
=========================================================================================
*/

USE master;
GO

-- =========================================================================================
-- 1. CREATE LINKED SERVER 'REMOTE_SRV' -> (local)
-- =========================================================================================

IF EXISTS (SELECT srv.name FROM sys.servers srv WHERE srv.name = 'REMOTE_SRV')
BEGIN
    PRINT 'Linked Server REMOTE_SRV already exists. Dropping it to reset configuration...';
    EXEC sp_dropserver @server=N'REMOTE_SRV', @droplogins='droplogins';
END

PRINT 'Creating Loopback Linked Server: REMOTE_SRV...';
-- Connects to the local server instance
EXEC sp_addlinkedserver 
    @server     = N'REMOTE_SRV', 
    @srvproduct = N'SQL Server', 
    @provider   = N'SQLNCLI', -- Or 'SQLNCLI11' / 'MSOLEDBSQL' depending on version; often empty string works for loopback using SQL Server type
    @datasrc    = @@SERVERNAME; 
GO

-- Configure RPC (Remote Procedure Call) - Critical for Stored Proc execution and Transactions
EXEC sp_serveroption @server=N'REMOTE_SRV', @optname=N'rpc', @optvalue=N'true';
EXEC sp_serveroption @server=N'REMOTE_SRV', @optname=N'rpc out', @optvalue=N'true';
-- Enable Distributed Transactions (sometimes needed for loopback if "remote" proc promotes transaction)
EXEC sp_serveroption @server=N'REMOTE_SRV', @optname=N'remote proc transaction promotion', @optvalue=N'true'; 
GO

-- Set Login Mapping (Current User -> Current User)
EXEC sp_addlinkedsrvlogin 
    @rmtsrvname = N'REMOTE_SRV', 
    @useself    = N'True'; 
GO

PRINT 'Linked Server Created Successfully.';
GO

-- =========================================================================================
-- 2. CREATE REMOTE DESTINATION DATABASE & TABLES
-- =========================================================================================
-- We create a database 'testa_remote' to simulate the destination.

IF DB_ID('testa_remote') IS NULL
BEGIN
    PRINT 'Creating simulated remote database: testa_remote...';
    CREATE DATABASE testa_remote;
END
GO

USE testa_remote;
GO

-- Create the Target Tables (Structure mimicking Source)
-- Parent
IF OBJECT_ID('dbo.SalesOrderHeader_Arch', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SalesOrderHeader_Arch (
        SalesOrderID INT PRIMARY KEY,
        OrderDate DATETIME,
        -- Add other columns as needed...
        Status TINYINT,
        TotalDue MONEY,
        ArchivedDate DATETIME DEFAULT GETDATE()
    );
    PRINT 'Created Table: SalesOrderHeader_Arch';
END

-- Child
IF OBJECT_ID('dbo.SalesOrderDetail_Arch', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SalesOrderDetail_Arch (
        SalesOrderDetailID INT PRIMARY KEY,
        SalesOrderID INT,
        ModifiedDate DATETIME,
        -- Add other columns...
        LineTotal NUMERIC(38, 6),
        ArchivedDate DATETIME DEFAULT GETDATE(),
        -- Foreign Key is critical for testing dependency logic
        CONSTRAINT FK_Arch_Header_Detail FOREIGN KEY (SalesOrderID) 
        REFERENCES dbo.SalesOrderHeader_Arch(SalesOrderID)
    );
    PRINT 'Created Table: SalesOrderDetail_Arch';
END
GO
