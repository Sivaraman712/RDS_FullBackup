-- ================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:        Sivaraman
-- Create date: June 18, 2026
-- Description:RDS    Database backup to s3 report 
-- =============================================
CREATE PROCEDURE RDS_BackupStatusReport
    
AS
BEGIN
    
    SET NOCOUNT ON;
    DECLARE @ReportDate      DATE     = CAST(GETDATE() AS DATE);
DECLARE @Html            NVARCHAR(MAX);
DECLARE @Rows            NVARCHAR(MAX);
DECLARE @Summary         NVARCHAR(MAX);

-- Polling controls
DECLARE @PollDelayMin    INT      = 5;        -- check every 5 minutes
DECLARE @LoopStart       DATETIME = GETDATE();
DECLARE @PendingCount    INT      = 1;
DECLARE @TimedOut        BIT      = 0;
DECLARE @PollCount       INT      = 0;        -- how many polls done

IF OBJECT_ID('tempdb..#TaskList')   IS NOT NULL DROP TABLE #TaskList;
IF OBJECT_ID('tempdb..#TaskStatus') IS NOT NULL DROP TABLE #TaskStatus;
IF OBJECT_ID('tempdb..#Report')     IS NOT NULL DROP TABLE #Report;

------------------------------------------------------------
-- 1) Collect backup commands + related task_id
------------------------------------------------------------
CREATE TABLE #TaskList
(
    CommandLogID   INT,
    DatabaseName   SYSNAME,
    CommandType    NVARCHAR(60),
    StartTime      DATETIME,
    EndTime        DATETIME,
    ErrorNumber    INT NULL,
    ErrorMessage   NVARCHAR(MAX) NULL,
    TaskLogID      INT,
    TaskID         INT
);

INSERT INTO #TaskList
(
    CommandLogID, DatabaseName, CommandType,
    StartTime, EndTime, ErrorNumber, ErrorMessage,
    TaskLogID, TaskID
)
SELECT
    cl.ID,
    cl.DatabaseName,
    cl.CommandType,
    cl.StartTime,
    cl.EndTime,
    cl.ErrorNumber,
    cl.ErrorMessage,
    bl.ID,
    bl.task_id
FROM dbo.RDS_CommandLog cl
INNER JOIN dbo.RDS_BackupLog bl
    ON bl.ID = cl.ID
WHERE cl.CommandType = 'BACKUP_DATABASE'
  AND CAST(cl.StartTime AS DATE) = @ReportDate
  AND bl.task_id IS NOT NULL;

------------------------------------------------------------
-- 2) Temp table for rds_task_status output
------------------------------------------------------------
CREATE TABLE #TaskStatus
(
    task_id                  INT            NULL,
    task_type                NVARCHAR(100)  NULL,
    database_name            NVARCHAR(256)  NULL,
    percent_complete         INT            NULL,
    duration_mins            INT            NULL,
    lifecycle                NVARCHAR(60)   NULL,
    task_info                NVARCHAR(MAX)  NULL,
    last_updated             DATETIME       NULL,
    created_at               DATETIME       NULL,
    S3_object_arn            NVARCHAR(4000) NULL,
    overwrite_S3_backup_file INT            NULL,
    KMS_master_key_arn       NVARCHAR(4000) NULL,
    filepath                 NVARCHAR(4000) NULL,
    overwrite_file           INT            NULL
);

------------------------------------------------------------
-- 3) Poll every 5 minutes until all tasks complete
--    CREATED / IN_PROGRESS
------------------------------------------------------------
WHILE @PendingCount > 0
BEGIN
    SET @PollCount = @PollCount + 1;

    TRUNCATE TABLE #TaskStatus;

    DECLARE @TaskID INT;
    DECLARE curTask CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT TaskID FROM #TaskList ORDER BY TaskID;

    OPEN curTask;
    FETCH NEXT FROM curTask INTO @TaskID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT INTO #TaskStatus
            EXEC msdb.dbo.rds_task_status @task_id = @TaskID;
        END TRY
        BEGIN CATCH
            INSERT INTO #TaskStatus
            (
                task_id, task_type, database_name,
                percent_complete, duration_mins, lifecycle,
                task_info, last_updated, created_at,
                S3_object_arn, overwrite_S3_backup_file,
                KMS_master_key_arn, filepath, overwrite_file
            )
            VALUES
            (
                @TaskID, NULL, NULL, NULL, NULL, 'ERROR',
                ERROR_MESSAGE(), GETDATE(), GETDATE(),
                NULL, NULL, NULL, NULL, NULL
            );
        END CATCH;

        FETCH NEXT FROM curTask INTO @TaskID;
    END

    CLOSE curTask;
    DEALLOCATE curTask;

    -- Count still-pending tasks
    SELECT @PendingCount = COUNT(*)
    FROM #TaskStatus
    WHERE lifecycle IN ('CREATED', 'IN_PROGRESS');

    -- Wait 5 minutes before next poll if tasks still pending
    IF @PendingCount > 0
    BEGIN
        DECLARE @Delay CHAR(8);
        SET @Delay = '00:0' + CAST(@PollDelayMin AS CHAR(1)) + ':00';
        WAITFOR DELAY @Delay;
    END
END



------------------------------------------------------------
-- 4) Keep latest status row per task_id
--    Parse first datetime from task_info as StartTime
--    Parse last datetime from task_info as EndTime
------------------------------------------------------------
;WITH TaskStatusLatest AS
(
    SELECT
        ts.*,
        ROW_NUMBER() OVER
        (
            PARTITION BY ts.task_id
            ORDER BY ISNULL(ts.last_updated, ts.created_at) DESC,
                     ts.task_id DESC
        ) AS rn
    FROM #TaskStatus ts
),
TaskInfoTimes AS
(
    SELECT
        tsl.task_id,

        -- First [yyyy-mm-dd hh:mm:ss.mmm]
        TRY_CAST(
            CASE
                WHEN tsl.task_info IS NOT NULL
                 AND CHARINDEX('[', tsl.task_info) > 0
                 AND CHARINDEX(']', tsl.task_info, CHARINDEX('[', tsl.task_info)) > 0
                THEN SUBSTRING(
                        tsl.task_info,
                        CHARINDEX('[', tsl.task_info) + 1,
                        CHARINDEX(']', tsl.task_info, CHARINDEX('[', tsl.task_info))
                          - CHARINDEX('[', tsl.task_info) - 1
                     )
            END AS DATETIME
        ) AS TaskActualStart,

        -- Last [yyyy-mm-dd hh:mm:ss.mmm]
        tsl.last_updated AS TaskActualEnd

    FROM TaskStatusLatest tsl
    WHERE tsl.rn = 1
)
SELECT
    tl.CommandLogID,
    tl.DatabaseName,
    tl.CommandType,

    -- Use first datetime from task_info as StartTime
    ISNULL(tit.TaskActualStart, tl.StartTime) AS StartTime,

    -- Use last datetime from task_info as EndTime
    ISNULL(tit.TaskActualEnd, tl.EndTime) AS EndTime,

    -- Duration based on parsed task_info timestamps
    DATEDIFF
    (
        MINUTE,
        ISNULL(tit.TaskActualStart, tl.StartTime),
        ISNULL(tit.TaskActualEnd, tl.EndTime)
    ) AS DurationMinutes,

    tl.ErrorNumber,
    tl.ErrorMessage,
    tl.TaskID,
    tsl.task_type,
    tsl.database_name AS task_database_name,
    tsl.percent_complete,
    tsl.duration_mins,
    tsl.lifecycle,
    tsl.task_info,
    tsl.last_updated,
    tsl.created_at,
    tsl.S3_object_arn,
    tsl.KMS_master_key_arn
INTO #Report
FROM #TaskList tl
LEFT JOIN TaskStatusLatest tsl
    ON tl.TaskID = tsl.task_id
   AND tsl.rn = 1
LEFT JOIN TaskInfoTimes tit
    ON tit.task_id = tl.TaskID;

------------------------------------------------------------
-- 5) Counts for summary
------------------------------------------------------------
DECLARE @TotalCount      INT = 0,
        @SuccessCount    INT = 0,
        @ErrorCount      INT = 0,
        @InProgressCount INT = 0,
        @CreatedCount    INT = 0,
        @CancelledCount  INT = 0,
        @OtherCount      INT = 0;

SELECT @TotalCount      = COUNT(*)                                            FROM #Report;
SELECT @SuccessCount    = COUNT(*) FROM #Report WHERE lifecycle = 'SUCCESS';
SELECT @ErrorCount      = COUNT(*) FROM #Report WHERE lifecycle = 'ERROR';
SELECT @InProgressCount = COUNT(*) FROM #Report WHERE lifecycle = 'IN_PROGRESS';
SELECT @CreatedCount    = COUNT(*) FROM #Report WHERE lifecycle = 'CREATED';
SELECT @CancelledCount  = COUNT(*) FROM #Report WHERE lifecycle IN ('CANCELLED','CANCEL_REQUESTED');
SELECT @OtherCount      = COUNT(*)
FROM #Report
WHERE ISNULL(lifecycle,'') NOT IN
      ('SUCCESS','ERROR','IN_PROGRESS','CREATED','CANCELLED','CANCEL_REQUESTED');

DECLARE @TotalDuration INT;
SELECT @TotalDuration = SUM(DurationMinutes) FROM #Report;

------------------------------------------------------------
-- 6) Summary card HTML 
------------------------------------------------------------
SET @Summary = N'
&lt;table class="summary"&gt;
  &lt;tr&gt;
    &lt;th colspan="2"&gt;Backup Run Summary&lt;/th&gt;
  &lt;/tr&gt;
  &lt;tr&gt;&lt;td&gt;Report Date&lt;/td&gt;
      &lt;td&gt;&lt;strong&gt;' + CONVERT(NVARCHAR(30), @ReportDate, 106) + N'&lt;/strong&gt;&lt;/td&gt;&lt;/tr&gt;
  &lt;tr&gt;
    &lt;td&gt;DB Backup Completed&lt;/td&gt;
    &lt;td&gt;&lt;span class="badge badge-success"&gt;'    + CAST(@SuccessCount    AS NVARCHAR(10)) + N'&lt;/span&gt;&lt;/td&gt;
  &lt;/tr&gt;
  &lt;tr&gt;
    &lt;td&gt;Failed&lt;/td&gt;
    &lt;td&gt;&lt;span class="badge badge-error"&gt;'      + CAST(@ErrorCount      AS NVARCHAR(10)) + N'&lt;/span&gt;&lt;/td&gt;
  &lt;/tr&gt;
  &lt;tr&gt;
    &lt;td&gt;Total Backup Duration&lt;/td&gt;
    &lt;td&gt;' + CAST(ISNULL(@TotalDuration, 0) AS NVARCHAR(10)) + N' minutes&lt;/td&gt;
  &lt;/tr&gt;
&lt;/table&gt;&lt;br/&gt;';

------------------------------------------------------------
-- 7) Detailed rows HTML 
------------------------------------------------------------
SELECT @Rows =
(
    SELECT
        N'&lt;tr class="' + CASE
            WHEN r.lifecycle = 'SUCCESS'    THEN 'row-success'
            WHEN r.lifecycle = 'ERROR'      THEN 'row-error'
            WHEN r.lifecycle IN ('IN_PROGRESS','CREATED') THEN 'row-progress'
            WHEN r.lifecycle IN ('CANCELLED','CANCEL_REQUESTED') THEN 'row-cancelled'
            ELSE 'row-other'
        END + N'"&gt;'

      -- Database
      + N'&lt;td&gt;&lt;strong&gt;'
            + ISNULL(REPLACE(REPLACE(REPLACE(r.DatabaseName,'&amp;','&amp;amp;'),'&lt;','&amp;lt;'),'&gt;','&amp;gt;'), '')
        + N'&lt;/strong&gt;&lt;/td&gt;'

      -- Task ID
      + N'&lt;td style="text-align:center;"&gt;'
            + ISNULL(CAST(r.TaskID AS NVARCHAR(20)), '')
        + N'&lt;/td&gt;'

      -- Start Time
      + N'&lt;td&gt;' + ISNULL(CONVERT(NVARCHAR(19), r.StartTime, 120), '') + N'&lt;/td&gt;'

      -- End Time
      + N'&lt;td&gt;' + ISNULL(CONVERT(NVARCHAR(19), r.EndTime, 120), '') + N'&lt;/td&gt;'

      -- Duration
      + N'&lt;td style="text-align:center;"&gt;'
            + ISNULL(CAST(r.DurationMinutes AS NVARCHAR(20)), '&amp;mdash;')
        + N' min&lt;/td&gt;'

      -- Lifecycle badge
      + N'&lt;td style="text-align:center;"&gt;'
            + CASE r.lifecycle
                WHEN 'SUCCESS'          THEN N'&lt;span class="badge badge-success"&gt;SUCCESS&lt;/span&gt;'
                WHEN 'ERROR'            THEN N'&lt;span class="badge badge-error"&gt;ERROR&lt;/span&gt;'
                WHEN 'IN_PROGRESS'      THEN N'&lt;span class="badge badge-progress"&gt;IN PROGRESS&lt;/span&gt;'
                WHEN 'CREATED'          THEN N'&lt;span class="badge badge-created"&gt;CREATED&lt;/span&gt;'
                WHEN 'CANCELLED'        THEN N'&lt;span class="badge badge-cancelled"&gt;CANCELLED&lt;/span&gt;'
                WHEN 'CANCEL_REQUESTED' THEN N'&lt;span class="badge badge-cancelled"&gt;CANCEL REQUESTED&lt;/span&gt;'
                ELSE ISNULL(REPLACE(REPLACE(REPLACE(r.lifecycle,'&amp;','&amp;amp;'),'&lt;','&amp;lt;'),'&gt;','&amp;gt;'), 'N/A')
              END
        + N'&lt;/td&gt;'

      -- % Complete
      + N'&lt;td style="text-align:center;"&gt;'
            + ISNULL(CAST(r.percent_complete AS NVARCHAR(10)) + '%', '&amp;mdash;')
        + N'&lt;/td&gt;'

          -- S3 Path (extract just the key after the bucket ARN for readability)
      + N'&lt;td style="word-break:break-all;font-size:11px;"&gt;'
            + ISNULL(REPLACE(REPLACE(REPLACE(r.S3_object_arn,'&amp;','&amp;amp;'),'&lt;','&amp;lt;'),'&gt;','&amp;gt;'), '&amp;mdash;')
        + N'&lt;/td&gt;'

      -- Task Info (errors only to keep it clean)
      + N'&lt;td style="font-size:11px;color:#555;"&gt;'
            + ISNULL(
                REPLACE(REPLACE(REPLACE(
                    REPLACE(REPLACE(r.task_info,'&amp;','&amp;amp;'),'&lt;','&amp;lt;'),'&gt;','&amp;gt;'),
                    CHAR(13),''),
                    CHAR(10),'&lt;br/&gt;'),
                '&amp;mdash;')
        + N'&lt;/td&gt;'

           + N'&lt;/tr&gt;'
    FROM #Report r
    ORDER BY r.StartTime, r.DatabaseName
    FOR XML PATH(''), TYPE
).value('.', 'NVARCHAR(MAX)');

------------------------------------------------------------
-- 8) Assemble final HTML
------------------------------------------------------------
SET @Html = N'
&lt;html&gt;
&lt;head&gt;
&lt;style&gt;
  body {
      font-family: Arial, Helvetica, sans-serif;
      font-size: 13px;
      color: #1a1a1a;
      margin: 0;
      padding: 0;
      background-color: #ffffff;
  }

  .title {
      font-size: 20px;
      font-weight: bold;
      color: #1e3a5f;
      margin: 0 0 12px 0;
      padding: 0 0 8px 0;
      border-bottom: 2px solid #1e3a5f;
  }

  .section-header {
      background-color: #1e3a5f;
      color: #ffffff;
      font-size: 14px;
      font-weight: bold;
      padding: 8px;
      margin: 16px 0 0 0;
  }

  table {
      border-collapse: collapse;
      border-spacing: 0;
      mso-table-lspace: 0pt;
      mso-table-rspace: 0pt;
  }

  table.summary {
      width: 420px;
      border: 1px solid #d0d7de;
      margin-bottom: 16px;
  }

  table.summary th {
      background-color: #1e3a5f;
      color: #ffffff;
      padding: 8px;
      font-size: 13px;
      text-align: left;
      border: 1px solid #d0d7de;
  }

  table.summary td {
      padding: 7px 10px;
      color: #333333;
      border: 1px solid #d0d7de;
  }

  table.detail {
      width: 100%;
      border: 1px solid #d0d7de;
  }

  table.detail th {
      background-color: #1e3a5f;
      color: #ffffff;
      padding: 8px;
      font-size: 12px;
      text-align: left;
      border: 1px solid #d0d7de;
      white-space: nowrap;
  }

  table.detail td {
      padding: 8px;
      border: 1px solid #d0d7de;
      vertical-align: top;
      background-color: #ffffff;
  }

  tr.row-success td {
      background-color: #f3fbf5;
      border-left: 4px solid #16a34a;
  }

  tr.row-error td {
      background-color: #fff5f5;
      border-left: 4px solid #dc2626;
  }

  tr.row-progress td {
      background-color: #fffaf0;
      border-left: 4px solid #d97706;
  }

  tr.row-cancelled td {
      background-color: #f5f5f5;
      border-left: 4px solid #6b7280;
  }

  tr.row-other td {
      background-color: #ffffff;
      border-left: 4px solid #9ca3af;
  }

  .badge {
      display: inline-block;
      padding: 2px 8px;
      font-size: 11px;
      font-weight: bold;
      border: 1px solid #cccccc;
      color: #000000;
      background-color: #f2f2f2;
  }

  .badge-success {
      background-color: #dcfce7;
      color: #15803d;
      border: 1px solid #b7dfc2;
  }

  .badge-error {
      background-color: #fee2e2;
      color: #b91c1c;
      border: 1px solid #efb5b5;
  }

  .badge-progress {
      background-color: #fff3cd;
      color: #8a6d3b;
      border: 1px solid #f0d58a;
  }

  .badge-created {
      background-color: #e8f0fe;
      color: #1a73e8;
      border: 1px solid #b7cef7;
  }

  .badge-cancelled {
      background-color: #eeeeee;
      color: #555555;
      border: 1px solid #cccccc;
  }
&lt;/style&gt;
&lt;/head&gt;
&lt;body&gt;

&lt;div class="title"&gt;RDS SQL Server Backup Status Report&lt;/div&gt;

' + @Summary + N'

&lt;div class="section-header"&gt;Monthly Database Backup Logs&lt;/div&gt;

&lt;table class="detail"&gt;
  &lt;tr&gt;
    &lt;th&gt;Database&lt;/th&gt;
    &lt;th&gt;Task ID&lt;/th&gt;
    &lt;th&gt;Start Time&lt;/th&gt;
    &lt;th&gt;End Time&lt;/th&gt;
    &lt;th&gt;Duration&lt;/th&gt;
    &lt;th&gt;Status&lt;/th&gt;
    &lt;th&gt;% Done&lt;/th&gt;
    &lt;th&gt;S3 Object ARN&lt;/th&gt;
    &lt;th&gt;Task Info&lt;/th&gt;
   &lt;/tr&gt;
  ' + ISNULL(@Rows, N'&lt;tr&gt;&lt;td colspan="11" style="text-align:center;color:#888;"&gt;No backup records found for today.&lt;/td&gt;&lt;/tr&gt;') + N'
&lt;/table&gt;

&lt;/body&gt;
&lt;/html&gt;';

------------------------------------------------------------
-- 9) Status Database Mail 
------------------------------------------------------------
DECLARE @OverallStatus NVARCHAR(20);
DECLARE @EmailSubject  NVARCHAR(500);

SET @OverallStatus =
    CASE
        WHEN @ErrorCount      > 0 THEN 'FAILED'
        WHEN @InProgressCount > 0
          OR @CreatedCount    > 0 THEN 'IN_PROGRESS'
        WHEN @SuccessCount = @TotalCount
         AND @TotalCount   > 0    THEN 'SUCCESS'
        ELSE 'UNKNOWN'
    END;

SET @EmailSubject =
    '[' + @OverallStatus + '] PROD Monthly Backup Report - '
    + CONVERT(VARCHAR, @ReportDate, 106)
    + '  |  Total: ' + CAST(@TotalCount   AS VARCHAR)
    + '  OK: '       + CAST(@SuccessCount AS VARCHAR)
    + '  Fail: '     + CAST(@ErrorCount   AS VARCHAR)
    + '  Pending: '  + CAST(@InProgressCount + @CreatedCount AS VARCHAR);

    if @Html is not null
    BEGIN
        EXEC msdb.dbo.sp_send_dbmail
        @profile_name = '',  -- Replace with your actual profile name
        @recipients = '',  -- Add the mail IDs
        @subject = @EmailSubject,
        @body = @html,
        @body_format = 'HTML';
    END

------------------------------------------------------------
-- 10) Cleanup
------------------------------------------------------------
DROP TABLE IF EXISTS #TaskList;
DROP TABLE IF EXISTS #TaskStatus;
DROP TABLE IF EXISTS #Report;
    
END
GO
