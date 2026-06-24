SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[RDS_CommandExecute]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[RDS_CommandExecute] AS'
END
GO
ALTER PROCEDURE [dbo].[RDS_CommandExecute]

@DatabaseContext nvarchar(max),
@Command nvarchar(max),
@CommandType nvarchar(max),
@Mode int,
@Comment nvarchar(max) = NULL,
@DatabaseName nvarchar(max) = NULL,
@SchemaName nvarchar(max) = NULL,
@ObjectName nvarchar(max) = NULL,
@ObjectType nvarchar(max) = NULL,
@IndexName nvarchar(max) = NULL,
@IndexType int = NULL,
@StatisticsName nvarchar(max) = NULL,
@PartitionNumber int = NULL,
@ExtendedInfo xml = NULL,
@LockMessageSeverity int = 16,
@ExecuteAsUser nvarchar(max) = NULL,
@LogToTable nvarchar(max),
@Execute nvarchar(max)

AS

BEGIN

  ----------------------------------------------------------------------------------------------------
  --// Source:  https://ola.hallengren.com                                                        //--
  --// License: https://ola.hallengren.com/license.html                                           //--
  --// GitHub:  https://github.com/olahallengren/sql-server-maintenance-solution                  //--
  --// Version: 2025-02-19 21:12:35                                                               //--
  --//                                                                                            //--
  --// Forked Changes https://github.com/amazon-contributing/aws-sql-server-maintenance-solution  //--
  --// Version: 2024-12-30 12:58                                                                  //--
  ----------------------------------------------------------------------------------------------------

  SET NOCOUNT ON

  DECLARE @StartMessage nvarchar(max)
  DECLARE @EndMessage nvarchar(max)
  DECLARE @ErrorMessage nvarchar(max)
  DECLARE @ErrorMessageOriginal nvarchar(max)
  DECLARE @Severity int

  DECLARE @Errors TABLE (ID int IDENTITY PRIMARY KEY,
                         [Message] nvarchar(max) NOT NULL,
                         Severity int NOT NULL,
                         [State] int)

  DECLARE @CurrentMessage nvarchar(max)
  DECLARE @CurrentSeverity int
  DECLARE @CurrentState int

  DECLARE @sp_executesql nvarchar(max) = QUOTENAME(@DatabaseContext) + '.sys.sp_executesql'

  DECLARE @StartTime datetime2
  DECLARE @EndTime datetime2

  DECLARE @ID int

  DECLARE @Error int = 0
  DECLARE @ReturnCode int = 0

  DECLARE @EmptyLine nvarchar(max) = CHAR(9)

  DECLARE @RevertCommand nvarchar(max)

  ----------------------------------------------------------------------------------------------------
  --// Original Copyright 2024 Ola Hallengren. Licensed under the MIT License.                    //-- 
  --// Modifications Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.           //-- 
  DECLARE @AmazonRDS bit = CASE WHEN DB_ID('rdsadmin') IS NOT NULL AND SUSER_SNAME(0x01) = 'rdsa' THEN 1 ELSE 0 END
  DECLARE @task_id INT

  DECLARE @RDSQueue TABLE ([task_id] INT,
							[task_type] nvarchar(max),
							[database_name] nvarchar(max),
							[% complete] nvarchar(max),
							[duration (mins)] nvarchar(max),
							[lifecycle] nvarchar(max),
							[task_info] nvarchar(max),
							[last_updated] nvarchar(max),
							[created_at] nvarchar(max),
							[S3_object_arn] nvarchar(max),
							[overwrite_s3_backup_file] nvarchar(max),
							[KMS_master_key_arn] nvarchar(max),
							[filepath] nvarchar(max),
							[overwrite_file] BIT)
  ----------------------------------------------------------------------------------------------------

  ----------------------------------------------------------------------------------------------------
  --// Check core requirements                                                                    //--
  ----------------------------------------------------------------------------------------------------

  IF NOT (SELECT [compatibility_level] FROM sys.databases WHERE [name] = DB_NAME()) >= 90
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The database ' + QUOTENAME(DB_NAME()) + ' has to be in compatibility level 90 or higher.', 16, 1
  END

  IF NOT (SELECT uses_ansi_nulls FROM sys.sql_modules WHERE [object_id] = @@PROCID) = 1
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'ANSI_NULLS has to be set to ON for the stored procedure.', 16, 1
  END

  IF NOT (SELECT uses_quoted_identifier FROM sys.sql_modules WHERE [object_id] = @@PROCID) = 1
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'QUOTED_IDENTIFIER has to be set to ON for the stored procedure.', 16, 1
  END

  IF @LogToTable = 'Y' AND NOT EXISTS (SELECT * FROM sys.objects objects INNER JOIN sys.schemas schemas ON objects.[schema_id] = schemas.[schema_id] WHERE objects.[type] = 'U' AND schemas.[name] = 'dbo' AND objects.[name] = 'RDS_CommandLog')
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The table RDS_CommandLog is missing. Download https://ola.hallengren.com/scripts/RDS_CommandLog.sql.', 16, 1
  END

  ----------------------------------------------------------------------------------------------------
  --// Check input parameters                                                                     //--
  ----------------------------------------------------------------------------------------------------

  IF @DatabaseContext IS NULL OR NOT EXISTS (SELECT * FROM sys.databases WHERE name = @DatabaseContext)
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @DatabaseContext is not supported.', 16, 1
  END

  IF @Command IS NULL OR @Command = ''
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @Command is not supported.', 16, 1
  END

  IF @CommandType IS NULL OR @CommandType = '' OR LEN(@CommandType) > 60
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @CommandType is not supported.', 16, 1
  END

  IF @Mode NOT IN(1,2) OR @Mode IS NULL
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @Mode is not supported.', 16, 1
  END

  IF @LockMessageSeverity NOT IN(10,16) OR @LockMessageSeverity IS NULL
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @LockMessageSeverity is not supported.', 16, 1
  END

  IF LEN(@ExecuteAsUser) > 128
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @ExecuteAsUser is not supported.', 16, 1
  END

  IF @LogToTable NOT IN('Y','N') OR @LogToTable IS NULL
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @LogToTable is not supported.', 16, 1
  END

  IF @Execute NOT IN('Y','N') OR @Execute IS NULL
  BEGIN
    INSERT INTO @Errors ([Message], Severity, [State])
    SELECT 'The value for the parameter @Execute is not supported.', 16, 1
  END

  ----------------------------------------------------------------------------------------------------
  --// Raise errors                                                                               //--
  ----------------------------------------------------------------------------------------------------

  DECLARE ErrorCursor CURSOR FAST_FORWARD FOR SELECT [Message], Severity, [State] FROM @Errors ORDER BY [ID] ASC

  OPEN ErrorCursor

  FETCH ErrorCursor INTO @CurrentMessage, @CurrentSeverity, @CurrentState

  WHILE @@FETCH_STATUS = 0
  BEGIN
    RAISERROR('%s', @CurrentSeverity, @CurrentState, @CurrentMessage) WITH NOWAIT
    RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT

    FETCH NEXT FROM ErrorCursor INTO @CurrentMessage, @CurrentSeverity, @CurrentState
  END

  CLOSE ErrorCursor

  DEALLOCATE ErrorCursor

  IF EXISTS (SELECT * FROM @Errors WHERE Severity >= 16)
  BEGIN
    SET @ReturnCode = 50000
    GOTO ReturnCode
  END

  ----------------------------------------------------------------------------------------------------
  --// Execute as user                                                                            //--
  ----------------------------------------------------------------------------------------------------

  IF @ExecuteAsUser IS NOT NULL
  BEGIN
    SET @Command = 'EXECUTE AS USER = ''' + REPLACE(@ExecuteAsUser,'''','''''') + '''; ' + @Command + '; REVERT;'

    SET @RevertCommand = 'REVERT'
  END

  ----------------------------------------------------------------------------------------------------
  --// Log initial information                                                                    //--
  ----------------------------------------------------------------------------------------------------

  SET @StartTime = SYSDATETIME()

  SET @StartMessage = 'Date and time: ' + CONVERT(nvarchar,@StartTime,120)
  RAISERROR('%s',10,1,@StartMessage) WITH NOWAIT

  SET @StartMessage = 'Database context: ' + QUOTENAME(@DatabaseContext)
  RAISERROR('%s',10,1,@StartMessage) WITH NOWAIT

  SET @StartMessage = 'Command: ' + @Command
  RAISERROR('%s',10,1,@StartMessage) WITH NOWAIT

  IF @Comment IS NOT NULL
  BEGIN
    SET @StartMessage = 'Comment: ' + @Comment
    RAISERROR('%s',10,1,@StartMessage) WITH NOWAIT
  END

  IF @LogToTable = 'Y'
  BEGIN
    INSERT INTO dbo.RDS_CommandLog (DatabaseName, SchemaName, ObjectName, ObjectType, IndexName, IndexType, StatisticsName, PartitionNumber, ExtendedInfo, CommandType, Command, StartTime)
    VALUES (@DatabaseName, @SchemaName, @ObjectName, @ObjectType, @IndexName, @IndexType, @StatisticsName, @PartitionNumber, @ExtendedInfo, @CommandType, @Command, @StartTime)
  END

  SET @ID = SCOPE_IDENTITY()

  ----------------------------------------------------------------------------------------------------
  --// Execute command                                                                            //--
  ----------------------------------------------------------------------------------------------------

  IF @Mode = 1 AND @Execute = 'Y'
  BEGIN
  ----------------------------------------------------------------------------------------------------
  --// Original Copyright 2024 Ola Hallengren. Licensed under the MIT License.                    //-- 
  --// Modifications Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.           //-- 
    IF @AmazonRDS = 1
    BEGIN
      -- Introduce a loop variable for retries
      DECLARE @TaskSuccess BIT = 0;
      
      WHILE @TaskSuccess = 0
      BEGIN
        BEGIN TRY
          -- 1. Attempt to execute the backup command
          EXECUTE @sp_executesql @stmt = @Command;
          
          -- 2. Retrieve created task status
          DELETE FROM @RDSQueue;
          INSERT INTO @RDSQueue exec msdb..rds_task_status @db_name=@DatabaseName;
          SELECT TOP 1 @task_id=task_id from @RDSQueue ORDER BY task_id DESC;
          INSERT INTO dbo.RDS_BackupLog (ID, task_id, [Status]) VALUES (@ID, @task_id, 'CREATED');

          -- 3. Wait loop for sequential execution
          DECLARE @TaskLifecycle nvarchar(max) = 'CREATED';
          WHILE @TaskLifecycle IN ('CREATED', 'IN_PROGRESS')
          BEGIN
              WAITFOR DELAY '00:01:00'; -- Check task status every 60 seconds
              DELETE FROM @RDSQueue;
              INSERT INTO @RDSQueue EXEC msdb.dbo.rds_task_status @task_id = @task_id;
              SELECT TOP 1 @TaskLifecycle = [lifecycle] FROM @RDSQueue WHERE [task_id] = @task_id;
          END

          -- 4. Update BackupLog with final status
          UPDATE dbo.RDS_BackupLog SET [Status] = @TaskLifecycle WHERE ID = @ID AND task_id = @task_id;

          -- 5. Raise Error if task did not succeed
          IF @TaskLifecycle IN ('ERROR', 'CANCELLED')
          BEGIN
              DECLARE @TaskError nvarchar(max);
              SELECT TOP 1 @TaskError = [task_info] FROM @RDSQueue WHERE [task_id] = @task_id;
              SET @ErrorMessageOriginal = 'RDS Task ' + CAST(@task_id AS nvarchar) + ' ' + @TaskLifecycle + '. Info: ' + ISNULL(@TaskError, '');
              RAISERROR('%s', 16, 1, @ErrorMessageOriginal) WITH LOG;
          END

          -- 6. If we reached this point without hitting the CATCH block, the task succeeded.
          -- Clear any previous retry errors so they are NOT logged to dbo.RDS_CommandLog
          SET @Error = 0;
          SET @ErrorMessageOriginal = NULL;

          -- Set the flag to 1 to exit the WHILE loop.
          SET @TaskSuccess = 1;

        END TRY
        BEGIN CATCH
          SET @Error = ERROR_NUMBER();
          SET @ErrorMessageOriginal = ISNULL(ERROR_MESSAGE(), '');
          
          -- Check if the error is the concurrency error
          IF @ErrorMessageOriginal LIKE '%A task has already been issued for database:%' 
          BEGIN
            -- Log a gentle warning and wait 60 seconds before the loop retries
            DECLARE @RetryMsg nvarchar(max) = 'RDS Task currently running for ' + QUOTENAME(@DatabaseName) + '. Waiting 60 seconds before retrying...';
            RAISERROR('%s', 10, 1, @RetryMsg) WITH NOWAIT;
            
            WAITFOR DELAY '00:01:00';
            -- @TaskSuccess remains 0, so the WHILE loop will execute the TRY block again.
          END
          ELSE
          BEGIN
            -- It is a legitimate, different error. Log it and break out of the loop.
            SET @ErrorMessage = 'RDS:Msg ' + CAST(@Error AS nvarchar) + ', ' + @ErrorMessageOriginal;
            SET @Severity = CASE WHEN @Error IN(1205,1222) THEN @LockMessageSeverity ELSE 16 END;
            RAISERROR('%s', @Severity, 1, @ErrorMessage) WITH LOG;
            
            -- Set to 1 to break the loop so it doesn't retry an unfixable error infinitely
            SET @TaskSuccess = 1; 
          END
        END CATCH
      END
    END
    ELSE
    BEGIN
      EXECUTE @sp_executesql @stmt = @Command
      SET @Error = @@ERROR
      SET @ReturnCode = @Error
    END  
  ----------------------------------------------------------------------------------------------------  
  END

  IF @Mode = 2 AND @Execute = 'Y'
  BEGIN
    BEGIN TRY
      EXECUTE @sp_executesql @stmt = @Command
    END TRY
    BEGIN CATCH
      SET @Error = ERROR_NUMBER()
      SET @ErrorMessageOriginal = ERROR_MESSAGE()

      SET @ErrorMessage = 'Msg ' + CAST(ERROR_NUMBER() AS nvarchar) + ', ' + ISNULL(ERROR_MESSAGE(),'')
      SET @Severity = CASE WHEN ERROR_NUMBER() IN(1205,1222) THEN @LockMessageSeverity ELSE 16 END
      RAISERROR('%s',@Severity,1,@ErrorMessage) WITH NOWAIT

      IF NOT (ERROR_NUMBER() IN(1205,1222) AND @LockMessageSeverity = 10)
      BEGIN
        SET @ReturnCode = ERROR_NUMBER()
      END

      IF @ExecuteAsUser IS NOT NULL
      BEGIN
        EXECUTE @sp_executesql @RevertCommand
      END
    END CATCH
  END

  ----------------------------------------------------------------------------------------------------
  --// Log completing information                                                                 //--
  ----------------------------------------------------------------------------------------------------

  SET @EndTime = SYSDATETIME()

  SET @EndMessage = 'Outcome: ' + CASE WHEN @Execute = 'N' THEN 'Not Executed' WHEN @Error = 0 THEN 'Succeeded' ELSE 'Failed' END
  RAISERROR('%s',10,1,@EndMessage) WITH NOWAIT

  SET @EndMessage = 'Duration: ' + CASE WHEN (DATEDIFF(SECOND,@StartTime,@EndTime) / (24 * 3600)) > 0 THEN CAST((DATEDIFF(SECOND,@StartTime,@EndTime) / (24 * 3600)) AS nvarchar) + '.' ELSE '' END + CONVERT(nvarchar,DATEADD(SECOND,DATEDIFF(SECOND,@StartTime,@EndTime),'1900-01-01'),108)
  RAISERROR('%s',10,1,@EndMessage) WITH NOWAIT

  SET @EndMessage = 'Date and time: ' + CONVERT(nvarchar,@EndTime,120)
  RAISERROR('%s',10,1,@EndMessage) WITH NOWAIT

  RAISERROR(@EmptyLine,10,1) WITH NOWAIT

  IF @LogToTable = 'Y'
  BEGIN
    UPDATE dbo.RDS_CommandLog
    SET EndTime = @EndTime,
        ErrorNumber = CASE WHEN @Execute = 'N' THEN NULL ELSE @Error END,
        ErrorMessage = @ErrorMessageOriginal
    WHERE ID = @ID
  END

  ReturnCode:
  IF @ReturnCode <> 0
  BEGIN
    RETURN @ReturnCode
  END

  ----------------------------------------------------------------------------------------------------

END
GO
