# Remote Archiving Testing Guide (Loopback Method)

This guide explains how to test the Remote Archiving logic on a single SQL Server instance using a **Loopback Linked Server**.

## What is a Loopback Server?
A "Linked Server" usually points to a completely different physical machine. A **Loopback Server** is a trick where we define a Linked Server that actually points back to *your own local machine* (using `@@SERVERNAME`).

This allows us to write code like:
```sql
INSERT INTO REMOTE_SRV.Database.dbo.Table ...
```
And it works just like a real remote transfer, even though the data stays on your laptop.

## Prerequisites

1.  **SQL Server**: Installed and running.
2.  **MSDTC Service**: The "Distributed Transaction Coordinator" service must be running.
    -   Type `services.msc` in your Windows Start menu.
    -   Find **Distributed Transaction Coordinator**.
    -   Right-click > **Start** (if not running).
    -   *Why?* The archiving script uses `BEGIN DISTRIBUTED TRANSACTION`. Even for loopback, SQL Server treats it as a distributed network transaction.

## Setup Instructions

### 1. Run the Setup Script
Open and execute `15 LoopbackSetup.sql`.
*   **What it does**:
    *   Creates a Linked Server named `REMOTE_SRV`.
    *   Creates a new database `testa_remote`.
    *   Creates destination tables `SalesOrderHeader_Arch` and `SalesOrderDetail_Arch`.

### 2. Configure the Archiving Job
Open and execute `14 Remote.sql` (if you haven't already).
*   **Check Step 2 (Configuration)**:
    *   Ensure the `TargetLinkedServer` is set to `'REMOTE_SRV'`.
    *   Ensure `TargetDatabase` values match `testa_remote` (if you modified the script to use that specific DB name) or `testa` (if you are just archiving back to the same DB).
    *   *Note*: The default setup in `15 LoopbackSetup.sql` creates `testa_remote`, so update your `ArchiveConfig` in `14 Remote.sql` to point to `testa_remote` if you want a clean separation.

    ```sql
    -- Example Config Update
    UPDATE dbo.ArchiveConfig
    SET TargetDatabase = 'testa_remote'
    WHERE TargetLinkedServer = 'REMOTE_SRV';
    ```

### 3. Run the Test
You can run the stored procedure manually to see the output:

```sql
EXEC dbo.usp_RunArchiving;
```

### 4. Verify Results
Check that data moved from your source tables to the "remote" tables:

```sql
SELECT * FROM testa_remote.dbo.SalesOrderHeader_Arch;
SELECT * FROM testa_remote.dbo.SalesOrderDetail_Arch;
```

## Troubleshooting
*   **"The partner transaction manager has disabled its support for remote/network transactions"**: 
    *   This is an MSDTC issue. ensure the service is running. You may need to enable "Network DTC Access" in Component Services if you are on a corporate network, though local-only usually works with default settings.
*   **"Server is not configured for RPC"**:
    *   Run the `sp_serveroption ... 'rpc out', 'true'` lines from `15 LoopbackSetup.sql` again.
