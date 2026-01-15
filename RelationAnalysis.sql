-- =========================================================================================
-- SQL Server Relationship Analysis Script
-- =========================================================================================
-- Purpose: 
-- This script maps out the dependencies between tables by listing all Foreign Key constraints.
-- It helps visually identify Parent-Child relationships, which is critical for:
-- 1. Understanding the Data Model (Schema Diagram)
-- 2. Determining Deletion Order (Child first, then Parent)
-- 3. Troubleshooting Foreign Key violations
-- =========================================================================================

SELECT 
    fk.name AS [Constraint Name],
    
    -- Parent (Referenced)
    s_parent.name AS [Parent Schema],
    t_parent.name AS [Parent Table],
    c_parent.name AS [Parent Column],

    ' ---> ' AS [Direction],

    -- Child (Referencing)
    s_child.name AS [Child Schema],
    t_child.name AS [Child Table],
    c_child.name AS [Child Column],

    -- Rules
    fk.delete_referential_action_desc AS [On Delete],
    fk.update_referential_action_desc AS [On Update]

FROM 
    sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
    
    -- Parent Table & Column
    INNER JOIN sys.tables t_parent ON fk.referenced_object_id = t_parent.object_id
    INNER JOIN sys.schemas s_parent ON t_parent.schema_id = s_parent.schema_id
    INNER JOIN sys.columns c_parent ON fkc.referenced_object_id = c_parent.object_id AND fkc.referenced_column_id = c_parent.column_id

    -- Child Table & Column
    INNER JOIN sys.tables t_child ON fk.parent_object_id = t_child.object_id
    INNER JOIN sys.schemas s_child ON t_child.schema_id = s_child.schema_id
    INNER JOIN sys.columns c_child ON fkc.parent_object_id = c_child.object_id AND fkc.parent_column_id = c_child.column_id

ORDER BY 
    [Parent Table], 
    [Child Table];
GO
