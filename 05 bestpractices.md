# Archiving Best Practices for Mid-to-Large Scale Systems

Archiving data effectively is critical for maintaining performance and managing costs in large-scale operational databases. This guide outlines best practices for designing an archival strategy.

## 1. Data Movement & Performance
### Batching
*   **Never archive in a single giant transaction.** Moving millions of rows at once can bloat the transaction log, block other users, and cause timeouts.
*   **Use Batches:** Process records in manageable chunks (e.g., 1,000 to 5,000 rows at a time) using a loop.
    ```sql
    WHILE 1=1
    BEGIN
        DELETE TOP (5000) FROM Orders
        OUTPUT deleted.* INTO Orders_Archive
        WHERE OrderDate < @CutoffDate;
        
        IF @@ROWCOUNT < 5000 BREAK;
        
        -- Optional: Wait to let other transactions breathe
        WAITFOR DELAY '00:00:01'; 
    END
    ```

### Indexing
*   **Archive Tables:** Index archive tables on the columns used for retrieval (often date ranges or CustomerID), but avoid over-indexing to keep write performance high during the archiving process.
*   **Source Tables:** Ensure the `WHERE` clause column (e.g., `OrderDate`) is indexed on the operational table to quickly identify rows to archive.

### Minimal Locking
*   **Isolation Levels:** Consider using `READ COMMITTED SNAPSHOT` or `WITH (NOLOCK)` (carefully) when selecting data to minimize blocking on the live system.
*   **Off-Peak Scheduling:** Schedule archiving jobs during low-traffic windows (e.g., nights or weekends).

## 2. Storage Strategy
### Table Partitioning (SQL Server Enterprise Feature)
*   **Sliding Window:** For very large tables, use partitioning. You can switch an entire partition (e.g., "January 2023") out of the main table and into an archive table efficiently as a metadata operation, taking milliseconds instead of hours.
*   **Filegroups:** Place archive data/partitions on separate, slower, cheaper storage tiers (HDD vs. SSD) to save costs ("Cold Storage").

### Compression
*   **Row/Page Compression:** Enable Data Compression (PAGE recommended) on archive tables. Historical data is rarely updated, making it a perfect candidate for high compression ratios (often saving 50-80% disk space).

## 3. Data Integrity & Consistency
### Transactional Integrity
*   Always ensure the **Copy to Archive** and **Delete from Source** happen within the same transaction (or the `OUTPUT` clause method shown above) to prevent data loss.

### Validation
*   Implement checksums or row count verification steps after the archive job runs to ensure the number of deleted rows equals the number of archived rows.

### Foreign Keys
*   **Disconnecting Relationships:** Archive tables usually should **not** enforce Foreign Keys back to the live system, as the referenced parent data might also be archived/deleted.
*   **Enforce Integrity on Insert:** Rely on the integrity of the process moving the data rather than constraints on the destination table.

## 4. Operational Considerations
### Idempotency
*   Scripts should be designed to be re-runnable. If a job fails halfway, restarting it should pick up where it left off without duplicating data or throwing errors.

### Retention Policy
*   Clearly define how long data stays in the *Operational DB* (e.g., 1 year), how long in the *Archive DB* (e.g., 7 years), and when it is permanently purged.

### Access Patterns
*   If users frequently need to query "Operational + Archive" data, consider creating a **View** that `UNION ALL`s both tables, but be aware of the performance implications.

## 5. Architectural Deployment
### Same Host vs. Different Host
*   **Same Host / Same Database:**
    *   *Pros:* Simplest to implement (just `INSERT INTO ... SELECT ...`), transactional consistency is easy (ACID), no network overhead.
    *   *Cons:* Archiving IO competes with live traffic IO. Does not reduce the storage footprint of the database backup (unless using filegroups/partial backups).
*   **Different Host (Linked Server / SSIS / ETL):**
    *   *Pros:* Offloads storage growth to cheaper hardware. archives don't slow down the main server's backup/restore times.
    *   *Cons:* Network latency/failure risk. Distributed transactions (DTC) are complex and prone to blocking.
    *   *Recommendation:* Start with **Same Host but Different Filegroups** (on slower disks) for simplicity. Move to **Different Host** only when the database size impacts RTO (Recovery Time Objective) or disk limits.

## 6. Robustness & Load Management
### Restartability (Checkpointing)
*   **Watermark Table:** Instead of just querying "older than X", maintain a `ProcessControl` table that stores the last successfully archived `OrderID` or `Date`.
*   **Logic:**
    1.  Read `LastProcessedID` from `ProcessControl`.
    2.  Archive the next batch (e.g., IDs `LastProcessedID + 1` to `LastProcessedID + 5000`).
    3.  Update `ProcessControl` in the same transaction.
*   **Benefit:** If the job is killed, the next run resumes exactly where it left off. No need to rescan millions of rows to find the starting point.

### Reducing Load & Duration
*   **Throttling:** Insert a `WAITFOR DELAY` (e.g., 500ms) between batches to let the CPU and Log Writer recover.
*   **Max Duration:** Add logic to stop the job after a set time (e.g., 2 hours).
    ```sql
    DECLARE @EndTime DATETIME = DATEADD(HOUR, 2, GETDATE());
    WHILE @MoreRows = 1 AND GETDATE() < @EndTime ...
    ```
    This ensures processing doesn't bleed into peak business hours.
*   **Log Management:** Frequent small batches prevent the Transaction Log from growing unexpectedly. Ensure log backups run frequently during the archive window.

## 7. Purging Strategies (Permanent Deletion)
Purging is the final lifecycle stage where data is permanently removed from the system (e.g., deleting data older than 7 years from the Archive DB).

### Efficient Deletion
*   **Truncate Table:** If a table is purely historical and contains *only* data to be purged (e.g., a monthly archive table), `TRUNCATE TABLE` is instantaneous and minimally logged.
*   **Partition Switching:** The "Gold Standard" for large tables.
    1.  Switch the partition containing expired data out to a staging table.
    2.  `TRUNCATE` or `DROP` the staging table.
    *   *Benefit:* Zero blocking, zero log bloat, near-instant.

### Hard Deletion Batches
*   If partitioning isn't available, apply the same **Batching** logic used for archiving.
    ```sql
    -- Efficient purging loop
    WHILE 1=1
    BEGIN
        DELETE TOP (5000) FROM dbo.AuditLog_Archive
        WHERE ActionDate < @PurgeCutoffDate;
        
        IF @@ROWCOUNT < 5000 BREAK;
        WAITFOR DELAY '00:00:00.500'; -- Throttle
    END
    ```

### Post-Purge Maintenance
*   **Defragmentation:** Heavy delete operations turn indexes into "swiss cheese" (fragmented). Always schedule an Index Rebuild or Reorganize after a significant purge job.
*   **Update Statistics:** The query optimizer needs to know the data distribution has changed. Run `UPDATE STATISTICS`.
*   **Shrink File (Use Caution):** Only shrink data files if you permanently reduced the dataset size and need to reclaim OS disk space. Avoid routine shrinking as it causes fragmentation.

## 8. Strategies for 100+ Tables (Complex Relationships)
When you have 100+ tables with complex, multi-level relationships (Parent -> Child -> Grandchild), the "best" way isn't usually a single tool, but a **coordinated strategy**.

For this scenario, **SSIS is the better orchestrator**, but the heavy lifting should be done by **Stored Procedures using Batching**. SSRS is a reporting tool and should not be used for data manipulation.

### The Recommended Architecture: "The Hybrid Approach"

| Component | Responsibility |
| --- | --- |
| **SSIS (Orchestrator)** | Handles the workflow, logging, error notifications, and the order of operations (e.g., ensure Table A finishes before Table B starts). |
| **Stored Procedures** | Contain the actual `INSERT INTO...SELECT` and `DELETE` logic. T-SQL is much faster at set-based operations than SSIS Data Flows when staying on the same server. |
| **SQL Agent** | Schedules the SSIS package to run during off-peak hours. |

### 1. The Strategy: "Bottom-Up" vs "Top-Down"
Because you have multi-relation tables, you must respect **Referential Integrity**:

* **Archiving (Moving to Archive DB):** Work **Top-Down**. Copy the Parent first, then the Children. This ensures you never have "orphan" records in your archive.
* **Purging (Deleting from Prod):** Work **Bottom-Up**. Delete the Grandchildren first, then the Children, then the Parent. If you try to delete the Parent first, the Foreign Key constraints will block you.

### 2. Implementation: The Batching Pattern
Never run a single `DELETE` or `INSERT` for millions of rows. It will bloat your transaction log and lock the tables, bringing your app to a halt. Use a **While Loop with Batching**.

**Example Pattern for one of your 100 tables:**
```sql
DECLARE @BatchSize INT = 5000;
DECLARE @RowsAffected INT = 1;

WHILE (@RowsAffected > 0)
BEGIN
    BEGIN TRANSACTION;

    -- 1. Move to Archive
    INSERT INTO ArchiveDB.dbo.ChildTable (...)
    SELECT TOP (@BatchSize) * FROM ProdDB.dbo.ChildTable
    WHERE CreateDate < DATEADD(year, -2, GETDATE());

    -- 2. Delete from Prod
    DELETE TOP (@BatchSize) FROM ProdDB.dbo.ChildTable
    WHERE CreateDate < DATEADD(year, -2, GETDATE());

    SET @RowsAffected = @@ROWCOUNT;

    COMMIT TRANSACTION;
    
    -- Optional: Wait 2 seconds to let other transactions in
    WAITFOR DELAY '00:00:02'; 
END
```

### 3. Why SSIS?
With 100 tables, managing 100 individual scripts is a nightmare. In SSIS:
* Use a **Foreach Loop Container** to loop through a metadata table containing your 100 table names.
* Use **Precedence Constraints** to handle the complex relationships (ensuring Parent archiving finishes before Child archiving).
* **Logging:** SSIS gives you built-in logging to see exactly which table failed and why.

### 4. High-Performance Alternatives
If your tables are massive (hundreds of millions of rows), consider these "Pro" methods:

1. **Partition Switching (Best for Speed):** If your tables are partitioned by date, you can "switch" an entire month of data out of the production table and into an archive table in milliseconds. This is a metadata change and generates almost zero log growth.
2. **Table Renaming:** If you are purging 90% of a table, it is often faster to:
    * `SELECT` the 10\% you want to **keep** into a new table.
    * Drop the old table.
    * Rename the new table to the original name.
    * Recreate indexes and constraints.

### Summary Checklist
1. **Disable/Drop Constraints?** Generally, no. It's safer to delete in the correct "Bottom-Up" order.
2. **Recovery Model:** If possible, switch the Archive DB to `SIMPLE` recovery to save log space.
3. **Indexes:** Ensure your "Archive Criteria" column (e.g., `CreatedDate`) is indexed, otherwise your `SELECT` statements will cause full table scans.
