USE [PassBy];
GO

-- Local Docker setup. The shared Azure database is managed separately.
IF DB_NAME() <> N'PassBy' OR CONVERT(int, SERVERPROPERTY('EngineEdition')) NOT IN (2, 3, 4)
    THROW 51002, N'This script is for the local PassBy SQL Server database.', 1;

SET XACT_ABORT ON;
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

BEGIN TRY
    BEGIN TRANSACTION;

    IF COL_LENGTH(N'dbo.IdentityVerification', N'requestId') IS NULL
        ALTER TABLE dbo.IdentityVerification ADD requestId UNIQUEIDENTIFIER NULL;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.IdentityVerification')
          AND name = N'UX_IdentityVerification_Document_Request'
    )
        EXEC(N'CREATE UNIQUE INDEX UX_IdentityVerification_Document_Request
            ON dbo.IdentityVerification (documentId, requestId)
            WHERE requestId IS NOT NULL;');

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.VerificationProvider WITH (UPDLOCK, HOLDLOCK)
        WHERE providerCode = 'MockBank'
    )
        INSERT INTO dbo.VerificationProvider (providerCode, providerName, isEnabled)
        VALUES ('MockBank', N'Симуляція банківської перевірки', 1);

    INSERT INTO dbo.VerificationOutcome (verificationCode, outcomeDescription)
    SELECT seed.verificationCode, seed.outcomeDescription
    FROM (VALUES
        ('Succeeded', N'Особу успішно верифіковано'),
        ('IdentityMismatch', N'Особа не відповідає документу'),
        ('DocumentExpired', N'Документ прострочений'),
        ('DocumentRevoked', N'Документ відкликано'),
        ('ProviderUnavailable', N'Зовнішня система недоступна')
    ) AS seed(verificationCode, outcomeDescription)
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.VerificationOutcome AS existing WITH (UPDLOCK, HOLDLOCK)
        WHERE existing.verificationCode = seed.verificationCode COLLATE Latin1_General_100_BIN2
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
