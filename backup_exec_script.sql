DECLARE @RunDate        DATETIME      = GETDATE();
DECLARE @Year           CHAR(4);
DECLARE @MonthName      NVARCHAR(20);
DECLARE @Environment    NVARCHAR(10)  = N'PROD';
DECLARE @CustomDir      NVARCHAR(500);
DECLARE @CustomFileName NVARCHAR(255);
DECLARE @S3Path VARCHAR(500);

SET @Year      = CONVERT(CHAR(4), YEAR(@RunDate));


SET @MonthName = FORMAT(@RunDate, N'MMMM', N'en-US');
SET @S3Path = 'arn:aws:s3:::s3-db-backup-sql/' + @Year + '/' + @MonthName;
-- Build file name: DBNAME_FULL_YYYYMMDD_HHMMSS.bak
SET @CustomFileName = N'{DatabaseName}_{BackupType}_{Year}_{Month}_{Day}_{Hour}_{Minute}_{Second}.{FileExtension}';

-- Execute full backup
EXEC [dbo].[RDS_DatabaseBackup]
    @Databases          ='USER_DATABASES,-rdsadmin',  -- For testing, replace with one DB name
    @S3BucketArn        = @S3Path,
    @kms_master_key_arn = NULL,
    @FileName           = @CustomFileName,
    @BackupType         = 'FULL',
    @LogToTable         = 'Y',
    @execute='Y';