# SQL Server Archiving & Purging Experience Guide

## 1. Definitions
### Purging
**Definition:** Cleaning old, unnecessary data where the data is no longer important and can be deleted permanently.
*   **Goal:** Reduce table size and improve system performance.

### Archival
**Definition:** Moving historical but potentially useful data from a current table to an archive table.
*   **Goal:** Offload data not immediately needed but required for future reference.

## 2. Performance Impact of Large Tables
Large tables with millions of records and unindexed columns can significantly degrade query performance (e.g., causing full table scans). Regular purging and archiving are essential for maintaining a healthy and performant SQL Server database.

## 3. Considerations Before Purging/Archiving
Before implementing any data removal strategy, check the following factors:
1.  **Table Dependencies:** Check for Stored Procedures, Views, Triggers, Replication, and Foreign Keys that reference the table.
2.  **Indexes & Constraints:** Understand how these impact performance during data modification.
3.  **Space Reclamation:** Plan for how to reclaim space after deletion (e.g., shrinking files, rebuilding indexes).
4.  **Frequency:** Determine how often operations should run (Daily, Weekly, Monthly).
5.  **Transaction Logs:** Ensure logs can handle the volume of data changes.

## 4. Execution Strategies

### A. Purging Data (One-Stroke Delete)
**Method:** Running a single `DELETE FROM Table WHERE Date < X` statement.
*   **Disadvantages:**
    *   Locks the table for the duration of the operation.
    *   Significantly increases Transaction Log size.
    *   Can lead to timeouts and application blocking.
*   **Mitigation:** Requires shrinking the log file afterwards (not recommended as a routine practice).

### B. Batch Deletion (Smooth Purging) - *Recommended*
**Method:** Using `DELETE TOP (N)` inside a `WHILE` loop.
*   **Benefits:**
    *   Deletes data in small chunks (e.g., 5,000 rows).
    *   Less impact on server performance.
    *   Prevents rapid transaction log growth.

### C. Archival Process
**Method:** Creating a replica (archive table) and moving data transactionally.
*   **Steps:**
    1.  Create an archive table (often removing Foreign Keys/Constraints but adding an `ArchiveDate` column).
    2.  Use a `BEGIN TRY...END TRY` block with `BEGIN TRANSACTION` and `COMMIT TRANSACTION` for atomicity.
    3.  Insert data into the archive table.
    4.  Delete data from the main table.
*   **Pattern:** `INSERT INTO Archive... SELECT ...` followed by `DELETE ...` in batches.

### D. Alternative: OUTPUT Clause
**Method:** Using the `OUTPUT` clause with the `DELETE` statement.
*   **Description:** Allows deleting rows and inserting them into the archive table in a single atomic operation.
    ```sql
    DELETE TOP(5000) FROM Orders
    OUTPUT deleted.OrderID, deleted.OrderDate, ... INTO Orders_Archive
    WHERE OrderDate < @CutoffDate;
    ```
