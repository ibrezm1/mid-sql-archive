-- =========================================================================================
-- SQL Server Simulation Script for Student Operational Database
-- =========================================================================================
-- This script creates a simulated environment with:
-- 1. A 3-level Parent-Child-Grandchild hierarchy (Customers -> Orders -> OrderDetails)
-- 2. A 2-level Parent-Child hierarchy (Departments -> Employees)
-- 3. A Standalone table (AuditLog)
--
-- UPDATES:
-- - Added CreatedDate and UpdatedDate to all primary tables.
-- =========================================================================================

USE master;
GO

-- Create a new database for the simulation (Optional, comment out if using existing DB)
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'testa')
BEGIN
    CREATE DATABASE testa;
END
GO

USE testa;
GO

-- =========================================================================================
-- 1. PARENT - CHILD - GRANDCHILD HIERARCHY
-- =========================================================================================

-- Level 1: Parent Table (Customers)
IF OBJECT_ID('dbo.Customers', 'U') IS NOT NULL DROP TABLE dbo.Customers;
CREATE TABLE dbo.Customers (
    CustomerID INT IDENTITY(1,1) PRIMARY KEY,
    FirstName NVARCHAR(50),
    LastName NVARCHAR(50),
    Email NVARCHAR(100),
    CreatedDate DATETIME DEFAULT GETDATE(),
    UpdatedDate DATETIME NULL
);
GO

-- Level 2: Child Table (Orders)
IF OBJECT_ID('dbo.Orders', 'U') IS NOT NULL DROP TABLE dbo.Orders;
CREATE TABLE dbo.Orders (
    OrderID INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID INT NOT NULL,
    OrderDate DATETIME DEFAULT GETDATE(), -- Business date
    TotalAmount DECIMAL(10, 2),
    CreatedDate DATETIME DEFAULT GETDATE(), -- Audit date
    UpdatedDate DATETIME NULL,
    CONSTRAINT FK_Orders_Customers FOREIGN KEY (CustomerID) REFERENCES dbo.Customers(CustomerID)
);
GO

-- Level 3: Grandchild Table (OrderDetails)
IF OBJECT_ID('dbo.OrderDetails', 'U') IS NOT NULL DROP TABLE dbo.OrderDetails;
CREATE TABLE dbo.OrderDetails (
    OrderDetailID INT IDENTITY(1,1) PRIMARY KEY,
    OrderID INT NOT NULL,
    ProductName NVARCHAR(100),
    Quantity INT,
    UnitPrice DECIMAL(10, 2),
    CreatedDate DATETIME DEFAULT GETDATE(),
    UpdatedDate DATETIME NULL,
    CONSTRAINT FK_OrderDetails_Orders FOREIGN KEY (OrderID) REFERENCES dbo.Orders(OrderID)
);
GO

-- =========================================================================================
-- 2. PARENT - CHILD HIERARCHY (SIMPLE)
-- =========================================================================================

-- Level 1: Parent Table (Departments)
IF OBJECT_ID('dbo.Departments', 'U') IS NOT NULL DROP TABLE dbo.Departments;
CREATE TABLE dbo.Departments (
    DepartmentID INT IDENTITY(1,1) PRIMARY KEY,
    DepartmentName NVARCHAR(100),
    Location NVARCHAR(100),
    CreatedDate DATETIME DEFAULT GETDATE(),
    UpdatedDate DATETIME NULL
);
GO

-- Level 2: Child Table (Employees)
IF OBJECT_ID('dbo.Employees', 'U') IS NOT NULL DROP TABLE dbo.Employees;
CREATE TABLE dbo.Employees (
    EmployeeID INT IDENTITY(1,1) PRIMARY KEY,
    DepartmentID INT NOT NULL,
    FirstName NVARCHAR(50),
    LastName NVARCHAR(50),
    JobTitle NVARCHAR(50),
    HireDate DATE, -- Business date
    CreatedDate DATETIME DEFAULT GETDATE(), -- Audit date
    UpdatedDate DATETIME NULL,
    CONSTRAINT FK_Employees_Departments FOREIGN KEY (DepartmentID) REFERENCES dbo.Departments(DepartmentID)
);
GO

-- =========================================================================================
-- 3. STANDALONE TABLE (SINGLE)
-- =========================================================================================

IF OBJECT_ID('dbo.AuditLog', 'U') IS NOT NULL DROP TABLE dbo.AuditLog;
CREATE TABLE dbo.AuditLog (
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    ActionType NVARCHAR(50),
    TableName NVARCHAR(50),
    RecordID INT,
    ActionDate DATETIME DEFAULT GETDATE(),
    Details NVARCHAR(MAX)
);
GO

-- =========================================================================================
-- 4. DATA POPULATION (SAMPLE DATA)
-- =========================================================================================

-- Insert Customers
INSERT INTO dbo.Customers (FirstName, LastName, Email) VALUES 
('John', 'Doe', 'john.doe@example.com'),
('Jane', 'Smith', 'jane.smith@example.com'),
('Alice', 'Johnson', 'alice.j@example.com');

-- Insert Orders (Linked to Customers)
INSERT INTO dbo.Orders (CustomerID, OrderDate, TotalAmount) VALUES 
(1, GETDATE(), 150.00), -- John's Order
(1, GETDATE(), 200.50), -- John's 2nd Order
(2, GETDATE(), 75.25);  -- Jane's Order

-- Insert OrderDetails (Linked to Orders)
INSERT INTO dbo.OrderDetails (OrderID, ProductName, Quantity, UnitPrice) VALUES 
(1, 'Laptop Stand', 1, 50.00),
(1, 'Wireless Mouse', 1, 100.00),
(2, 'Monitor', 1, 200.50),
(3, 'USB Cable', 3, 25.00);

-- Insert Departments
INSERT INTO dbo.Departments (DepartmentName, Location) VALUES 
('HR', 'New York'),
('IT', 'San Francisco'),
('Sales', 'Chicago');

-- Insert Employees (Linked to Departments)
INSERT INTO dbo.Employees (DepartmentID, FirstName, LastName, JobTitle, HireDate) VALUES 
(1, 'Emily', 'Davis', 'HR Manager', '2023-01-15'),
(2, 'Michael', 'Brown', 'Software Engineer', '2023-02-20'),
(2, 'Sarah', 'Wilson', 'DevOps Engineer', '2023-03-10'),
(3, 'David', 'Clark', 'Sales Rep', '2023-04-05');

-- Insert AuditLog (Independent)
INSERT INTO dbo.AuditLog (ActionType, TableName, RecordID, Details, ActionDate) VALUES 
('INSERT', 'Customers', 1, 'Created new customer John Doe', GETDATE()),
('UPDATE', 'Orders', 2, 'Updated order status to shipped', GETDATE()),
('ERROR', 'System', 0, 'Database backup failed', GETDATE());

-- Insert "Old" Data for Archiving Testing (Older than 1 month)
INSERT INTO dbo.Orders (CustomerID, OrderDate, TotalAmount, CreatedDate) VALUES 
(3, DATEADD(month, -2, GETDATE()), 120.00, DATEADD(month, -2, GETDATE())), -- 2 months old
(3, DATEADD(month, -3, GETDATE()), 450.00, DATEADD(month, -3, GETDATE())); -- 3 months old

-- Get IDs for the old orders to insert details (Assuming Identity starts after previous inserts)
-- Note: In a real script we might use variables, but for simulation we assume sequential IDs
-- Old Order 1 (ID 4)
INSERT INTO dbo.OrderDetails (OrderID, ProductName, Quantity, UnitPrice, CreatedDate) VALUES 
(4, 'Old Keyboard', 1, 40.00, DATEADD(month, -2, GETDATE())),
(4, 'Old Mouse', 2, 40.00, DATEADD(month, -2, GETDATE()));

-- Old Order 2 (ID 5)
INSERT INTO dbo.OrderDetails (OrderID, ProductName, Quantity, UnitPrice, CreatedDate) VALUES 
(5, 'Old Monitor', 2, 225.00, DATEADD(month, -3, GETDATE()));

-- Insert "Old" Audit Logs 
INSERT INTO dbo.AuditLog (ActionType, TableName, RecordID, Details, ActionDate) VALUES 
('LOGIN', 'System', 0, 'User login', DATEADD(month, -2, GETDATE())),
('LOGOUT', 'System', 0, 'User logout', DATEADD(month, -2, GETDATE()));

GO

PRINT 'Database simulation created successfully.';
