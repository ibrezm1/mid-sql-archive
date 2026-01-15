-- =========================================================================================
-- SQL Server Multi-Level Relationship Analysis Script
-- =========================================================================================
-- Purpose: 
-- This script uses a Recursive Common Table Expression (CTE) to build a complete
-- dependency chain for each table. 
--
-- It answers: "If I touch Table A, what downstream tables (Children, Grandchildren) depend on it?"
--
-- Output Column: [Depencency Chain] 
-- Format: Parent -> Child -> GrandChild
-- =========================================================================================

;WITH FK_map AS (
    -- Get simplistic Parent-Child list from system tables
    SELECT 
        s_parent.name AS ParentSchema,
        t_parent.name AS ParentTable,
        s_child.name AS ChildSchema,
        t_child.name AS ChildTable
    FROM 
        sys.foreign_keys fk
        INNER JOIN sys.tables t_parent ON fk.referenced_object_id = t_parent.object_id
        INNER JOIN sys.schemas s_parent ON t_parent.schema_id = s_parent.schema_id
        INNER JOIN sys.tables t_child ON fk.parent_object_id = t_child.object_id
        INNER JOIN sys.schemas s_child ON t_child.schema_id = s_child.schema_id
),
DependencyTree AS (
    -- Anchor Member: Start with every ParentTable found in relationships
    -- We select distinct Parents to start chains from anywhere in the hierarchy
    SELECT DISTINCT
        ParentSchema,
        ParentTable,
        ParentTable AS RootTable, -- Keep track of where we started
        CAST(ParentSchema + '.' + ParentTable + ' -> ' + ChildSchema + '.' + ChildTable AS NVARCHAR(MAX)) AS DependencyChain,
        ChildSchema,
        ChildTable,
        1 AS Level
    FROM FK_map

    UNION ALL

    -- Recursive Member: Find children of the current Child
    SELECT 
        dt.ParentSchema,
        dt.ParentTable,
        dt.RootTable,
        CAST(dt.DependencyChain + ' -> ' + fk.ChildSchema + '.' + fk.ChildTable AS NVARCHAR(MAX)),
        fk.ChildSchema,
        fk.ChildTable,
        dt.Level + 1
    FROM 
        DependencyTree dt
        INNER JOIN FK_map fk ON dt.ChildSchema = fk.ParentSchema AND dt.ChildTable = fk.ParentTable
    -- Terminate recursion if we hit a cycle (max 10 levels deep generally safe for this context)
    WHERE dt.Level < 10 
)
SELECT 
    RootTable AS [Starting Table],
    DependencyChain AS [Full Dependency Path],
    Level AS [Depth]
FROM 
    DependencyTree
ORDER BY 
    [Starting Table], 
    [Depth], 
    [Full Dependency Path];
GO
