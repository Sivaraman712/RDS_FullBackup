-- ================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:        Sivaraman
-- Create date:   June 18, 2026
-- Description:   RDS Database backup to s3 report 
-- =============================================
ALTER PROCEDURE RDS_BackupStatusReport
    
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
        ISNULL(tit.TaskActualStart, tl.StartTime) AS StartTime,
        ISNULL(tit.TaskActualEnd, tl.EndTime) AS EndTime,
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

    SELECT @TotalCount      = COUNT(*)                                  FROM #Report;
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
    <table class="summary" border="1" cellpadding="8" cellspacing="0">
      <tr>
        <th colspan="2">Backup Run Summary</th>
      </tr>
      <tr><td>Report Date</td>
          <td><strong>' + CONVERT(NVARCHAR(30), @ReportDate, 106) + N'</strong></td></tr>
      <tr>
        <td>DB Backup Completed</td>
        <td><span class="badge badge-success">'    + CAST(@SuccessCount   AS NVARCHAR(10)) + N'</span></td>
      </tr>
      <tr>
        <td>Failed</td>
        <td><span class="badge badge-error">'      + CAST(@ErrorCount     AS NVARCHAR(10)) + N'</span></td>
      </tr>
      <tr>
        <td>Total Backup Duration</td>
        <td>' + CAST(ISNULL(@TotalDuration, 0) AS NVARCHAR(10)) + N' minutes</td>
      </tr>
    </table><br/>';

    ------------------------------------------------------------
    -- 7) Detailed rows HTML 
    ------------------------------------------------------------
    SELECT @Rows =
    (
        SELECT
            N'<tr class="' + CASE
                WHEN r.lifecycle = 'SUCCESS'    THEN 'row-success'
                WHEN r.lifecycle = 'ERROR'      THEN 'row-error'
                WHEN r.lifecycle IN ('IN_PROGRESS','CREATED') THEN 'row-progress'
                WHEN r.lifecycle IN ('CANCELLED','CANCEL_REQUESTED') THEN 'row-cancelled'
                ELSE 'row-other'
            END + N'">'

          -- Database
          + N'<td><strong>'
                + ISNULL(REPLACE(REPLACE(REPLACE(r.DatabaseName,'&','&amp;'),'<','&lt;'),'>','&gt;'), '')
          + N'</strong></td>'

          -- Task ID
          + N'<td style="text-align:center;">'
                + ISNULL(CAST(r.TaskID AS NVARCHAR(20)), '')
          + N'</td>'

          -- Start Time
          + N'<td>' + ISNULL(CONVERT(NVARCHAR(19), r.StartTime, 120), '') + N'</td>'

          -- End Time
          + N'<td>' + ISNULL(CONVERT(NVARCHAR(19), r.EndTime, 120), '') + N'</td>'

          -- Duration
          + N'<td style="text-align:center;">'
                + ISNULL(CAST(r.DurationMinutes AS NVARCHAR(20)), '&mdash;')
          + N' min</td>'

          -- Lifecycle badge
          + N'<td style="text-align:center;">'
                + CASE r.lifecycle
                    WHEN 'SUCCESS'          THEN N'<span class="badge badge-success">SUCCESS</span>'
                    WHEN 'ERROR'            THEN N'<span class="badge badge-error">ERROR</span>'
                    WHEN 'IN_PROGRESS'      THEN N'<span class="badge badge-progress">IN PROGRESS</span>'
                    WHEN 'CREATED'          THEN N'<span class="badge badge-created">CREATED</span>'
                    WHEN 'CANCELLED'        THEN N'<span class="badge badge-cancelled">CANCELLED</span>'
                    WHEN 'CANCEL_REQUESTED' THEN N'<span class="badge badge-cancelled">CANCEL REQUESTED</span>'
                    ELSE ISNULL(REPLACE(REPLACE(REPLACE(r.lifecycle,'&','&amp;'),'<','&lt;'),'>','&gt;'), 'N/A')
                  END
          + N'</td>'

          -- % Complete
          + N'<td style="text-align:center;">'
                + ISNULL(CAST(r.percent_complete AS NVARCHAR(10)) + '%', '&mdash;')
          + N'</td>'

          -- S3 Path
          + N'<td style="word-break:break-all;font-size:11px;">'
                + ISNULL(REPLACE(REPLACE(REPLACE(r.S3_object_arn,'&','&amp;'),'<','&lt;'),'>','&gt;'), '&mdash;')
          + N'</td>'

          -- Task Info
          + N'<td style="font-size:11px;color:#555;">'
                + ISNULL(
                    REPLACE(REPLACE(REPLACE(
                        REPLACE(REPLACE(r.task_info,'&','&amp;'),'<','&lt;'),'>','&gt;'),
                        CHAR(13),''),
                        CHAR(10),'<br/>'),
                    '&mdash;')
          + N'</td>'

          + N'</tr>'
        FROM #Report r
        ORDER BY r.StartTime, r.DatabaseName
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)');

    ------------------------------------------------------------
    -- 8) Assemble final HTML
    ------------------------------------------------------------
    SET @Html = N'
    <html>
    <head>
    <style>
      body {
          font-family: "Segoe UI", Arial, Helvetica, sans-serif;
          font-size: 13px;
          color: #1a1a1a;
          margin: 0;
          padding: 10px;
          background-color: #ffffff;
      }

      .title {
          font-size: 22px;
          font-weight: bold;
          color: #1e3a5f;
          margin: 0 0 16px 0;
          padding: 0 0 8px 0;
          border-bottom: 2px solid #1e3a5f;
      }

      .section-header {
          background-color: #1e3a5f;
          color: #ffffff;
          font-size: 14px;
          font-weight: bold;
          padding: 8px 12px;
          margin: 20px 0 0 0;
          border-radius: 4px 4px 0 0;
      }

      table {
          border-collapse: collapse;
          border-spacing: 0;
          mso-table-lspace: 0pt;
          mso-table-rspace: 0pt;
          width: 100%;
      }

      table.summary {
          width: 450px;
          border: 1px solid #d0d7de;
          margin-bottom: 16px;
      }

      table.summary th {
          background-color: #f6f8fa;
          color: #24292f;
          padding: 8px 12px;
          font-size: 14px;
          text-align: left;
          border-bottom: 1px solid #d0d7de;
      }

      table.summary td {
          padding: 8px 12px;
          color: #333333;
          border: 1px solid #d0d7de;
      }

      table.detail {
          border: 1px solid #d0d7de;
      }

      table.detail th {
          background-color: #f6f8fa;
          color: #24292f;
          padding: 10px 8px;
          font-size: 12px;
          text-align: left;
          border: 1px solid #d0d7de;
          white-space: nowrap;
      }

      table.detail td {
          padding: 8px;
          border: 1px solid #d0d7de;
          vertical-align: top;
      }

      tr.row-success td {
          background-color: #ffffff;
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
          padding: 3px 8px;
          font-size: 11px;
          font-weight: bold;
          border-radius: 12px;
          border: 1px solid #cccccc;
          color: #000000;
          background-color: #f2f2f2;
          text-align: center;
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
    </style>
    </head>
    <body>

    <div class="title">RDS SQL Server Backup Status Report</div>

    ' + @Summary + N'

    <div class="section-header">Monthly Database Backup Logs</div>

    <table class="detail" border="1" cellpadding="8" cellspacing="0" style="border-collapse: collapse; width: 100%;">
      <tr>
        <th>Database</th>
        <th>Task ID</th>
        <th>Start Time</th>
        <th>End Time</th>
        <th>Duration</th>
        <th>Status</th>
        <th>% Done</th>
        <th>S3 Object ARN</th>
        <th>Task Info</th>
       </tr>
      ' + ISNULL(@Rows, N'<tr><td colspan="9" style="text-align:center;color:#888;">No backup records found for today.</td></tr>') + N'
    </table>

    </body>
    </html>';

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
