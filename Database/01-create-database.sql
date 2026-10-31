USE [master];
GO

CREATE DATABASE [PassBy]
ON PRIMARY
(
    NAME = N'PassBy_Data',
    FILENAME = N'/var/opt/mssql/data/PassBy.mdf',
    SIZE = 64MB,
    FILEGROWTH = 64MB
)
LOG ON
(
    NAME = N'PassBy_Log',
    FILENAME = N'/var/opt/mssql/data/PassBy_log.ldf',
    SIZE = 32MB,
    FILEGROWTH = 32MB
)
COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

ALTER DATABASE [PassBy]
    SET RECOVERY SIMPLE;

ALTER DATABASE [PassBy]
    SET AUTO_CLOSE OFF;

ALTER DATABASE [PassBy]
    SET AUTO_SHRINK OFF;

ALTER DATABASE [PassBy]
    SET COMPATIBILITY_LEVEL = 170;
GO

SELECT
    d.name AS DatabaseName,
    d.collation_name AS Collation,
    d.recovery_model_desc AS RecoveryModel,
    d.compatibility_level AS CompatibilityLevel,
    d.is_auto_close_on AS AutoCloseOn,
    d.is_auto_shrink_on AS AutoShrinkOn,
    mf.type_desc AS FileType,
    mf.name AS LogicalFileName,
    mf.physical_name AS PhysicalPath,
    mf.size / 128.0 AS SizeMB,
    mf.growth / 128.0 AS FileGrowthMB
FROM sys.databases AS d
JOIN sys.master_files AS mf
    ON d.database_id = mf.database_id
WHERE d.name = N'PassBy'
ORDER BY mf.type;