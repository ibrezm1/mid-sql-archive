# SQL Server Archiving & Simulation Project

This repository contains a comprehensive suite of scripts and documentation for simulating a SQL Server environment, analyzing database structures, and implementing various data archiving strategies—from simple T-SQL scripts to production-grade, metadata-driven engines.

## 📂 1. Database Simulation & Setup

### `01 student_operational_db.sql`
**Purpose:** Sets up the simulated operational database (`testa`) used for all scenarios.
*   **Schema:** Creates a mix of tables to simulate real-world complexity:
    *   **3-Level Hierarchy:** `Customers` -> `Orders` -> `OrderDetails`.
    *   **2-Level Hierarchy:** `Departments` -> `Employees`.
    *   **Standalone:** `AuditLog`.
*   **Features:**
    *   Populates tables with realistic sample data.
    *   Includes "old" records (older than 1 month) specifically to test archiving logic.
    *   Adds `CreatedDate` and `UpdatedDate` columns to all tables for audit tracking.

## 📊 2. Analysis & Monitoring Tools

### `02 SpaceAnalysis.sql`
**Purpose:** A reporting tool to monitor database growth and storage usage.
*   **Function:** Queries `sys.dm_db_partition_stats` to provide a report of Row Counts, Total Space (MB), Used Space (MB), and Unused Space (MB).
*   **Usage:** Run before and after archiving jobs to verify space reclamation.

### `03 RelationAnalysis.sql`
**Purpose:** Mappaing tool for understanding direct table dependencies.
*   **Function:** Lists all Foreign Key constraints in the database.
*   **Details:** Shows Parent Schema/Table/Column vs. Child Schema/Table/Column and the specific Delete/Update rules defined.

### `04 MultiRelationAnalysis.sql`
**Purpose:** Advanced dependency visualization.
*   **Function:** Uses a Recursive CTE (Common Table Expression) to build a full "Dependency Chain" for every table.
*   **Value:** Helps you see deep relationships (e.g., `Customers -> Orders -> OrderDetails`) in a single view, which is critical for planning Top-Down Archiving and Bottom-Up Purging.

## 📚 3. Documentation & Best Practices

### `05 bestpractices.md`
**Purpose:** The definitive guide for archiving in mid-to-large scale environments.
*   **Key Topics:**
    *   **Architecture:** Same Host vs. Different Host trade-offs.
    *   **Performance:** Batching, Indexing, and Minimizing Locking.
    *   **Robustness:** Restartability patterns and Throttling/Load Management.
    *   **Hybrid Strategy:** Recommendation to use SSIS for orchestration and Stored Procedures for heavy data movement.

### `06 experience.md`
**Purpose:** A clear summary of core concepts and "lessons learned."
*   **Key Definitions:** Distinguishes between **Purging** (Permanent Deletion) and **Archival** (Moving for reference).
*   **Insights:**
    *   Why "One-Stroke" deletes are dangerous (Log growth, Blocking).
    *   The benefits of Batch Deletion ("Smooth Purging").
    *   Using the `OUTPUT` clause for atomic moves.

### `07 SSIS.md`
**Purpose:** Implementation guide for the "Hybrid Approach."
*   **Content:** Step-by-step instructions for creating an SSIS Project that acts as an Orchestrator.
*   **Focus:** Shows how to use SSIS for Control Flow (Looping, Error Handling, Logging) while delegating the actual data operations to T-SQL Execute SQL Tasks.

## ⚙️ 4. Archiving Implementations (Evolution)

### `08 archive_process.sql` (The Baseline)
**Purpose:** A standard, static T-SQL script for archiving.
*   **Method:** Explicit, hardcoded transactions to move data from `testa` to `archive`.
*   **Logic:**
    1.  Copy `Orders` and `OrderDetails` to archive tables.
    2.  Delete them from operational tables.
    3.  Uses a Transaction to ensure data integrity.

### `09 newprocess.sql` (Metadata V1)
**Purpose:** Proof-of-Concept for a Metadata-Driven approach.
*   **Innovation:** Introduces the `ArchiveConfig` table.
*   **Function:** Instead of writing code for every table, you add a row to the configuration table. The script dynamically generates the SQL to archive/purge based on those rules.

### `10 newprocessv2.sql` (Metadata V2 - Enhanced)
**Purpose:** A more robust metadata engine with logging and testing capabilities.
*   **New Features:**
    *   **ActionType:** Explicit 'ARCHIVE' vs 'DELETE' configuration.
    *   **Processing Log:** Tracks every run with a `BatchNumber`, recording rows affected and duration.
    *   **Test Mode:** A built-in "Dry Run" feature. If enabled, it counts rows and logs a 'TEST' action without modifying data.

### `11 Reviewofv2.md`
**Purpose:** Architectural review of the V2 script.
*   **Content:** An honest critique identifying risks in V2 (e.g., Transaction safety inside dynamic SQL, lack of parameterization) which led to the development of V3.

### `12 newprocessv3.sql` (Metadata V3 - Production Grade)
**Purpose:** The hardened, production-ready archiving engine.
*   **Key Upgrades:**
    *   **Remote Archiving:** Supports archiving to Linked Servers (separate physical hosts).
    *   **Security:** Replaces string concatenation with `sp_executesql` and typed parameters to prevent injection.
    *   **Safety:** Full `TRY/CATCH` error handling wrapping key logic.
    *   **Atomicity:** implementation of `DISTRIBUTED TRANSACTION` support for cross-server consistency.

### `13 Reviewofv3.md`
**Purpose:** Architectural review of the V3 script.
*   **Content:** Final analysis of the V3 engine, highlighting its strengths in modularity and safety, and offering final tuning advice on transaction scope handling.
