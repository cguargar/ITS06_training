/*
===============================================================================
 PostPatch-HealthCheck.sql
 Purpose : Quick post-patch validation for a SQL Server instance.
 Usage   : Run manually in SSMS, or invoke via sqlcmd from the PowerShell
           wrapper (Run-PostPatchHealthCheck.ps1) for multi-server automation.
===============================================================================
*/

SET NOCOUNT ON;

------------------------------------------------------------------------------
-- 1. Instance-level info: version, patch level, uptime
------------------------------------------------------------------------------
SELECT
    @@SERVERNAME                              AS ServerName,
    SERVERPROPERTY('ProductVersion')          AS ProductVersion,
    SERVERPROPERTY('ProductLevel')             AS ProductLevel,     -- e.g. RTM, SP, CU
    SERVERPROPERTY('ProductUpdateLevel')       AS ProductUpdateLevel,
    SERVERPROPERTY('Edition')                  AS Edition,
    create_date                                AS LastServiceRestart,
    DATEDIFF(MINUTE, create_date, GETDATE())   AS UptimeMinutes
FROM sys.databases
WHERE name = 'tempdb';   -- tempdb recreated on every restart, good uptime proxy

------------------------------------------------------------------------------
-- 2. Database state check - flag anything not ONLINE
------------------------------------------------------------------------------
SELECT
    name          AS DatabaseName,
    state_desc    AS State,
    recovery_model_desc AS RecoveryModel,
    is_read_only  AS ReadOnly,
    CASE WHEN state_desc <> 'ONLINE' THEN 'FAIL' ELSE 'OK' END AS CheckResult
FROM sys.databases
ORDER BY CASE WHEN state_desc <> 'ONLINE' THEN 0 ELSE 1 END, name;

------------------------------------------------------------------------------
-- 3. Suspect / inaccessible pages (data corruption indicator)
------------------------------------------------------------------------------
SELECT
    database_id,
    DB_NAME(database_id) AS DatabaseName,
    file_id,
    page_id,
    event_type,
    error_count,
    last_update_date,
    'FAIL - investigate immediately' AS CheckResult
FROM msdb.dbo.suspect_pages;
-- Empty result set = pass (no known suspect pages)

------------------------------------------------------------------------------
-- 4. SQL Server Agent job failures since patch/restart
------------------------------------------------------------------------------
SELECT
    j.name                                  AS JobName,
    h.run_date,
    h.run_time,
    CASE h.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
        ELSE 'Unknown'
    END                                      AS RunStatus,
    h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.run_status = 0   -- failures only
  AND msdb.dbo.agent_datetime(h.run_date, h.run_time) >= DATEADD(HOUR, -24, GETDATE())
ORDER BY h.run_date DESC, h.run_time DESC;

------------------------------------------------------------------------------
-- 5. Always On Availability Group health (skip if not used)
------------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = 'dm_hadr_availability_replica_states')
BEGIN
    SELECT
        ag.name                                   AS AGName,
        ar.replica_server_name                    AS ReplicaServer,
        rs.role_desc                              AS Role,
        rs.connected_state_desc                   AS ConnectionState,
        rs.synchronization_health_desc            AS SyncHealth,
        CASE WHEN rs.synchronization_health_desc <> 'HEALTHY' THEN 'FAIL' ELSE 'OK' END AS CheckResult
    FROM sys.dm_hadr_availability_replica_states rs
    JOIN sys.availability_replicas ar ON ar.replica_id = rs.replica_id
    JOIN sys.availability_groups ag ON ag.group_id = ar.group_id;
END

------------------------------------------------------------------------------
-- 6. Disk space for data/log drives (via xp_fixeddrives)
------------------------------------------------------------------------------
CREATE TABLE #DriveSpace (Drive CHAR(1), FreeMB INT);
INSERT INTO #DriveSpace EXEC xp_fixeddrives;

SELECT
    Drive,
    FreeMB,
    CASE WHEN FreeMB < 5120 THEN 'WARN - under 5GB free' ELSE 'OK' END AS CheckResult
FROM #DriveSpace
ORDER BY FreeMB ASC;

DROP TABLE #DriveSpace;

------------------------------------------------------------------------------
-- 7. Recent error log entries (severity 16+) since restart
------------------------------------------------------------------------------
CREATE TABLE #ErrorLog (
    LogDate DATETIME,
    ProcessInfo NVARCHAR(50),
    [Text] NVARCHAR(MAX)
);

INSERT INTO #ErrorLog
EXEC xp_readerrorlog 0, 1, N'Error';

SELECT TOP 50 *
FROM #ErrorLog
ORDER BY LogDate DESC;

DROP TABLE #ErrorLog;

------------------------------------------------------------------------------
-- 8. Last successful backup per database (should not be stale post-patch)
------------------------------------------------------------------------------
SELECT
    d.name AS DatabaseName,
    MAX(b.backup_finish_date) AS LastFullBackup,
    DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) AS HoursSinceBackup,
    CASE
        WHEN MAX(b.backup_finish_date) IS NULL THEN 'FAIL - no backup found'
        WHEN DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) > 24 THEN 'WARN - backup stale'
        ELSE 'OK'
    END AS CheckResult
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
    ON b.database_name = d.name AND b.type = 'D'
WHERE d.database_id > 4  -- exclude system DBs
GROUP BY d.name
ORDER BY CheckResult DESC, DatabaseName;
