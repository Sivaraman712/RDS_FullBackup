CREATE PROCEDURE RDS_BackupStatusReport
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ReportDate DATE = CAST(GETDATE() AS DATE);
    DECLARE @Html NVARCHAR(MAX);
    DECLARE @Rows NVARCHAR(MAX);
    DECLARE @Summary NVARCHAR(MAX);

    ------------------------------------------------------------
    -- Temp tables
    ------------------------------------------------------------
    IF OBJECT_ID('tempdb..#TaskList')   IS NOT NULL DROP TABLE #TaskList;
    IF OBJECT_ID('tempdb..#TaskStatus') IS NOT NULL DROP TABLE #TaskStatus;
    IF OBJECT_ID('tempdb..#Report')     IS NOT NULL DROP TABLE #Report;

    ------------------------------------------------------------
    -- 1. Collect backup tasks
    ------------------------------------------------------------
    CREATE TABLE #TaskList
    (
        CommandLogID INT,
        DatabaseName SYSNAME,
        StartTime DATETIME,
        EndTime DATETIME,
        TaskID INT
    );

    INSERT INTO #TaskList
    SELECT 
        cl.ID,
        cl.DatabaseName,
        cl.StartTime,
        cl.EndTime,
        bl.task_id
    FROM dbo.RDS_CommandLog cl
    JOIN dbo.RDS_BackupLog bl ON cl.ID = bl.ID
    WHERE cl.CommandType = 'BACKUP_DATABASE'
    AND CAST(cl.StartTime AS DATE) = @ReportDate;

    ------------------------------------------------------------
    -- 2. Get Task Status
    ------------------------------------------------------------
    CREATE TABLE #TaskStatus (
        task_id INT,
        lifecycle NVARCHAR(50),
        percent_complete INT,
        last_updated DATETIME,
        S3_object_arn NVARCHAR(MAX),
        task_info NVARCHAR(MAX)
    );

    DECLARE @TaskID INT;

    DECLARE curTask CURSOR FOR
        SELECT TaskID FROM #TaskList;

    OPEN curTask;
    FETCH NEXT FROM curTask INTO @TaskID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO #TaskStatus
        EXEC msdb.dbo.rds_task_status @task_id = @TaskID;

        FETCH NEXT FROM curTask INTO @TaskID;
    END

    CLOSE curTask;
    DEALLOCATE curTask;

    ------------------------------------------------------------
    -- 3. Build report
    ------------------------------------------------------------
    SELECT 
        tl.DatabaseName,
        tl.TaskID,
        tl.StartTime,
        tl.EndTime,
        DATEDIFF(MINUTE, tl.StartTime, tl.EndTime) DurationMinutes,
        ts.lifecycle,
        ts.percent_complete,
        ts.S3_object_arn,
        ts.task_info
    INTO #Report
    FROM #TaskList tl
    LEFT JOIN #TaskStatus ts ON tl.TaskID = ts.task_id;

    ------------------------------------------------------------
    -- 4. Summary
    ------------------------------------------------------------
    DECLARE @Success INT = (SELECT COUNT(*) FROM #Report WHERE lifecycle = 'SUCCESS');
    DECLARE @Error INT   = (SELECT COUNT(*) FROM #Report WHERE lifecycle = 'ERROR');
    DECLARE @Total INT   = (SELECT COUNT(*) FROM #Report);

    SET @Summary = '
    <table border="1" cellpadding="5" cellspacing="0">
        <tr><th colspan="2">Backup Summary</th></tr>
        <tr><td>Date</td><td>' + CONVERT(NVARCHAR, @ReportDate, 106) + '</td></tr>
        <tr><td>Success</td><td>' + CAST(@Success AS NVARCHAR) + '</td></tr>
        <tr><td>Failed</td><td>' + CAST(@Error AS NVARCHAR) + '</td></tr>
        <tr><td>Total</td><td>' + CAST(@Total AS NVARCHAR) + '</td></tr>
    </table><br/>';

    ------------------------------------------------------------
    -- 5. Detail rows
    ------------------------------------------------------------
    SELECT @Rows =
    (
        SELECT
        CASE 
            WHEN lifecycle = 'SUCCESS' THEN '<tr style="background-color:#d4edda">'
            WHEN lifecycle = 'ERROR' THEN '<tr style="background-color:#f8d7da">'
            ELSE '<tr style="background-color:#fff3cd">'
        END +

        '<td>' + ISNULL(DatabaseName,'') + '</td>' +
        '<td>' + CAST(TaskID AS NVARCHAR) + '</td>' +
        '<td>' + CONVERT(NVARCHAR, StartTime, 120) + '</td>' +
        '<td>' + CONVERT(NVARCHAR, EndTime, 120) + '</td>' +
        '<td>' + CAST(DurationMinutes AS NVARCHAR) + '</td>' +
        '<td>' + ISNULL(lifecycle,'') + '</td>' +
        '<td>' + ISNULL(CAST(percent_complete AS NVARCHAR),'') + '%</td>' +
        '<td>' + ISNULL(S3_object_arn,'') + '</td>' +
        '</tr>'
        FROM #Report
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)');

    ------------------------------------------------------------
    -- 6. Final HTML
    ------------------------------------------------------------
    SET @Html = '
    <html>
    <body style="font-family:Arial;font-size:12px;">
    <h2>RDS SQL Server Backup Report</h2>

    ' + @Summary + '

    <table border="1" cellspacing="0" cellpadding="5">
        <tr style="background-color:#1e3a5f;color:white;">
            <th>Database</th>
            <th>Task ID</th>
            <th>Start Time</th>
            <th>End Time</th>
            <th>Duration</th>
            <th>Status</th>
            <th>% Done</th>
            <th>S3 Path</th>
        </tr>
        ' + ISNULL(@Rows,'') + '
    </table>

    </body>
    </html>';

    ------------------------------------------------------------
    -- 7. Send Mail
    ------------------------------------------------------------
    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'YOUR_PROFILE',
        @recipients = 'yourmail@company.com',
        @subject = 'RDS Backup Report - ' + CONVERT(VARCHAR, @ReportDate, 106),
        @body = @Html,
        @body_format = 'HTML';

END
GO
