-- =========================================================================================
-- SQL Server Space Analysis Script
-- =========================================================================================
-- Purpose: 
-- This script provides a report of all user tables in the database, showing:
-- 1. Schema and Table Name
-- 2. Total Row Count
-- 3. Total Reserved Space (MB)
-- 4. Used Space (MB)
-- 5. Unused Space (MB)
--
-- It aggregates data from sys.dm_db_partition_stats to handle partitioned tables correctly.
-- =========================================================================================

--- Uses performace state access 
SELECT 
    s.name AS [Schema],
    t.name AS [Table],
    SUM(ps.row_count) AS [Row Count],
    CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Total Space (MB)],
    CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Used Space (MB)],
    CAST((SUM(ps.reserved_page_count) - SUM(ps.used_page_count)) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Unused Space (MB)]
FROM 
    sys.dm_db_partition_stats ps
    INNER JOIN sys.tables t ON ps.object_id = t.object_id
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE 
    ps.index_id IN (0, 1) -- Heap (0) or Clustered Index (1) only for row counts to avoid double counting
GROUP BY 
    s.name, 
    t.name
ORDER BY 
    [Used Space (MB)] DESC, 
    [Row Count] DESC;
GO

-- without performance state access
SELECT 
    s.name AS [Schema],
    t.name AS [Table],
    p.rows AS [Row Count],
    -- Total space including all indexes
    CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Total Space (MB)], 
    
    -- Space used by the actual data (Clustered Index or Heap)
    CAST(SUM(CASE WHEN i.index_id <= 1 THEN a.used_pages ELSE 0 END) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Data Space (MB)],
    
    -- Space used by all non-clustered indexes
    CAST(SUM(CASE WHEN i.index_id > 1 THEN a.used_pages ELSE 0 END) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Index Space (MB)],
    
    -- Unused space (Allocated but empty)
    CAST(SUM(a.total_pages - a.used_pages) * 8.0 / 1024 AS DECIMAL(18, 2)) AS [Unused Space (MB)]
FROM 
    sys.tables t
INNER JOIN      
    sys.indexes i ON t.object_id = i.object_id
INNER JOIN 
    sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN 
    sys.allocation_units a ON p.partition_id = a.container_id
INNER JOIN 
    sys.schemas s ON t.schema_id = s.schema_id
WHERE 
    t.is_ms_shipped = 0
GROUP BY 
    t.name, s.name, p.rows
ORDER BY 
    [Total Space (MB)] DESC;