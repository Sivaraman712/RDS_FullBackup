
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[RDS_BackupLog]') AND type in (N'U'))
BEGIN
CREATE TABLE [dbo].[RDS_BackupLog](
	[ID] [int] NOT NULL,
	[task_id] [int] NOT NULL,
	[Status] [nvarchar](max) NULL,
	[task_Info] [nvarchar](max) NULL,
   CONSTRAINT [PK_RDS_BackupLog] PRIMARY KEY CLUSTERED 
(
	[ID] ASC, [task_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON)
) 
END
GO


