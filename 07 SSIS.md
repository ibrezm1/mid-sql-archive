# Creating an SSIS Archiving Job (The Hybrid Approach)

This guide documents how to build an SSIS package that acts as an **Orchestrator** for your archiving process. It focuses on executing T-SQL logic (Stored Procedures) rather than moving data through the SSIS pipeline, as this is more efficient for same-server operations.

## 1. Prerequisites
*   **Visual Studio (VS):** 2019 or 2022.
*   **Extension:** SQL Server Integration Services Projects (install via VS Extensions menu).
*   **Target:** SQL Server with SSIS Catalog (`SSISDB`) enabled.

## 2. Project Setup
1.  Open Visual Studio -> **Create New Project** -> **Integration Services Project**.
2.  Name it `ArchiveOrchestration`.
3.  In the **Solution Explorer**, right-click **Connection Managers** -> **New Connection Manager** -> `OLEDB`.
    *   Create `Conn_Operational` (points to `testa`).
    *   Create `Conn_Archive` (points to `archive`).

## 3. Designing the Control Flow
We will use the **Execute SQL Task** to run our T-SQL batching logic.

### A. The Simple Approach (Single Script)
If you have one main script (`archive_process.sql`):
1.  Drag an **Execute SQL Task** to the Control Flow surface.
2.  **Name:** `Task_RunArchiving`.
3.  **Connection:** `Conn_Operational`.
4.  **SQLStatement:** Paste the T-SQL script (or call a Stored Procedure like `EXEC dbo.sp_RunArchiving`).
    *   *Tip:* Using a Stored Procedure is cleaner than pasting 100 lines of SQL into SSIS.

### B. The Loop Approach (100+ Tables)
If you need to iterate through many tables:
1.  **Execute SQL Task (Get Tables):**
    *   SQL: `SELECT TableName FROM Config.ArchiveList WHERE IsActive = 1`
    *   ResultSet: `Full Result Set` -> Map to variable `User::TableList` (Object type).
2.  **Foreach Loop Container:**
    *   Collection: `Foreach ADO Enumerator`.
    *   Source Variable: `User::TableList`.
    *   Variable Mapping: Map column 0 to `User::CurrentTable`.
3.  **Execute SQL Task (Inside Loop):**
    *   Name: `Archive_CurrentTable`.
    *   Connection: `Conn_Operational`.
    *   SQLStatement: `EXEC dbo.sp_ArchiveTable @TableName = ?`
    *   Parameter Mapping: Map `User::CurrentTable` to Parameter 0.

## 4. Error Handling & Logging
SSIS excels here.
1.  **Logging:** Go to **SSIS Menu** -> **Logging**. Enable logging for "Text File" or "SQL Server". Select events like `OnError` and `OnWarning`.
2.  **Failure Path:** Drag the **Red Arrow** from your Archive Task to a **Send Mail Task** or **Execute SQL Task** (Log Error) to notify admins immediately if a specific table fails.

## 5. Deployment
1.  Right-click Project -> **Deploy**.
2.  **Deployment Wizard:**
    *   Server Name: `(local)` or your server.
    *   Path: `/SSISDB/ArchiveFolder/ArchiveProject`.
3.  **Configure:** Important! Configure your Connection Strings (Production vs Test) in the Catalog Environment Variables so you don't hardcode them.

## 6. Scheduling (SQL Agent)
1.  Open SSMS -> **SQL Server Agent** -> **Jobs** -> **New Job**.
2.  **Name:** `Maintenance_DailyArchiving`.
3.  **Steps:** Add New Step -> Type: **SQL Server Integration Services Package**.
    *   Source: `SSIS Catalog`.
    *   Server: `(local)`.
    *   Package: Select your deployed `ArchiveOrchestration.dtsx`.
4.  **Schedule:** Set to run daily at off-peak hours (e.g., 2:00 AM).
5.  **Notifications:** Set up Email On Failure.
