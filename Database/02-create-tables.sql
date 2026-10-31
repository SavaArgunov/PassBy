USE [PassBy];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'PassBy'
BEGIN;
    THROW 51000, N'Скрипт дозволено виконувати лише у PassBy.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM sys.objects
    WHERE schema_id = SCHEMA_ID(N'dbo')
      AND name IN
      (
          N'UserAccount', N'PasswordCredential',
          N'Deliverer', N'DeliveryRequester',
          N'VerificationProvider', N'VerificationOutcome',
          N'ValidatedDocument', N'IDCardData', N'IdentityVerification'
      )
)
BEGIN;
    THROW 51001, N'Одна або більше цільових таблиць уже існують: жодних змін не виконано.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    CREATE TABLE dbo.PasswordCredential
    (
        credentialId  BIGINT IDENTITY(1, 1) NOT NULL,
        passwordHash  NVARCHAR(1024) NOT NULL,
        
        createdAtUtc  DATETIME2(7) NOT NULL
            CONSTRAINT DF_PasswordCredential_CreatedAtUtc
            DEFAULT (SYSUTCDATETIME()),
        
        changedAtUtc  DATETIME2(7) NOT NULL
            CONSTRAINT DF_PasswordCredential_ChangedAtUtc
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_PasswordCredential
            PRIMARY KEY (credentialId)
    );

    CREATE TABLE dbo.UserAccount
    (
        userId           BIGINT IDENTITY(1, 1) NOT NULL,
        credentialId     BIGINT NOT NULL,
        emailAddress     NVARCHAR(320) NOT NULL,
        phoneNumber      NVARCHAR(32) NULL,
        registeredAtUtc  DATETIME2(7) NOT NULL,
        
        isBlocked BIT NOT NULL
            CONSTRAINT DF_UserAccount_IsBlocked
            DEFAULT (0),

        CONSTRAINT PK_UserAccount
            PRIMARY KEY (userId),

        CONSTRAINT UQ_UserAccount_CredentialId
            UNIQUE (credentialId),

        CONSTRAINT UQ_UserAccount_EmailAddress
            UNIQUE (emailAddress),

        CONSTRAINT FK_UserAccount_PasswordCredential
            FOREIGN KEY (credentialId)
            REFERENCES dbo.PasswordCredential (credentialId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.VerificationProvider
    (
        providerId      BIGINT IDENTITY(1, 1) NOT NULL,
        
        providerCode    VARCHAR(64) 
            COLLATE Latin1_General_100_BIN2 NOT NULL,
        
        providerName    NVARCHAR(200) NOT NULL,
        
        createdAtUtc    DATETIME2(7) NOT NULL
            CONSTRAINT DF_VerificationProvider_CreatedAtUtc
            DEFAULT (SYSUTCDATETIME()),
        
        isEnabled       BIT NOT NULL,

        CONSTRAINT PK_VerificationProvider
            PRIMARY KEY (providerId),

        CONSTRAINT UQ_VerificationProvider_Code
            UNIQUE (providerCode)
    );

    CREATE TABLE dbo.VerificationOutcome
    (
        verificationCode    VARCHAR(64) 
            COLLATE Latin1_General_100_BIN2 NOT NULL,
        outcomeDescription  NVARCHAR(1000) NOT NULL,

        CONSTRAINT PK_VerificationOutcome
            PRIMARY KEY (verificationCode)
    );

    CREATE TABLE dbo.Deliverer
    (
        userId           BIGINT NOT NULL,
        registeredAtUtc  DATETIME2(7) NOT NULL,
        
        isBlocked BIT NOT NULL
            CONSTRAINT DF_Deliverer_IsBlocked
            DEFAULT (0),

        CONSTRAINT PK_Deliverer
            PRIMARY KEY (userId),

        CONSTRAINT FK_Deliverer_UserAccount
            FOREIGN KEY (userId)
            REFERENCES dbo.UserAccount (userId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.DeliveryRequester
    (
        userId           BIGINT NOT NULL,
        registeredAtUtc  DATETIME2(7) NOT NULL,
        
        isBlocked BIT NOT NULL
            CONSTRAINT DF_DeliveryRequester_IsBlocked
            DEFAULT (0),

        CONSTRAINT PK_DeliveryRequester
            PRIMARY KEY (userId),

        CONSTRAINT FK_DeliveryRequester_UserAccount
            FOREIGN KEY (userId)
            REFERENCES dbo.UserAccount (userId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.ValidatedDocument
    (
        documentId              BIGINT IDENTITY(1, 1) NOT NULL,
        
        documentReference       NVARCHAR(512)
            COLLATE Latin1_General_100_BIN2 NOT NULL,

        validatedAtUtc          DATETIME2(7) NOT NULL,
        verificationProviderId  BIGINT NOT NULL,
        userId                  BIGINT NOT NULL,

        CONSTRAINT PK_ValidatedDocument
            PRIMARY KEY (documentId),

        CONSTRAINT UQ_ValidatedDocument_Provider_DocumentReference
            UNIQUE NONCLUSTERED (verificationProviderId, documentReference),

        CONSTRAINT FK_ValidatedDocument_VerificationProvider
            FOREIGN KEY (verificationProviderId)
            REFERENCES dbo.VerificationProvider (providerId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION,

        CONSTRAINT FK_ValidatedDocument_UserAccount
            FOREIGN KEY (userId)
            REFERENCES dbo.UserAccount (userId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.IDCardData
    (
        documentId      BIGINT NOT NULL,
        givenName       NVARCHAR(200) NOT NULL,
        familyName      NVARCHAR(200) NOT NULL,
        birthDate       DATE NOT NULL,
        expiresAt       DATE NOT NULL,
        photoReference  NVARCHAR(2048) NOT NULL,

        CONSTRAINT PK_IDCardData
            PRIMARY KEY (documentId),

        CONSTRAINT FK_IDCardData_ValidatedDocument
            FOREIGN KEY (documentId)
            REFERENCES dbo.ValidatedDocument (documentId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.IdentityVerification
    (
        verificationId    BIGINT IDENTITY(1, 1) NOT NULL,
        checkedAtUtc      DATETIME2(7) NOT NULL,
        validUntilUtc     DATETIME2(7) NULL,
        
        verificationCode  VARCHAR(64)
            COLLATE Latin1_General_100_BIN2 NOT NULL,
        
        documentId        BIGINT NOT NULL,

        CONSTRAINT PK_IdentityVerification
            PRIMARY KEY (verificationId),

        CONSTRAINT FK_IdentityVerification_VerificationOutcome
            FOREIGN KEY (verificationCode)
            REFERENCES dbo.VerificationOutcome (verificationCode)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION,

        CONSTRAINT FK_IdentityVerification_ValidatedDocument
            FOREIGN KEY (documentId)
            REFERENCES dbo.ValidatedDocument (documentId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION,

        CONSTRAINT CK_IdentityVerification_OutcomeValidity
            CHECK
            (
                (verificationCode = 'Succeeded' AND validUntilUtc IS NOT NULL)
                OR
                (verificationCode <> 'Succeeded' AND validUntilUtc IS NULL)
            )
    );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

GO

USE [PassBy];
GO

-- 1. Загальна інформація про таблиці

SELECT
    t.name AS TableName,
    t.create_date AS CreatedAt,
    (
        SELECT COUNT(*)
        FROM sys.columns AS c
        WHERE c.object_id = t.object_id
    ) AS ColumnCount,
    (
        SELECT COUNT(*)
        FROM sys.foreign_keys AS fk
        WHERE fk.parent_object_id = t.object_id
    ) AS ForeignKeyCount,
    (
        SELECT COUNT(*)
        FROM sys.key_constraints AS kc
        WHERE kc.parent_object_id = t.object_id
          AND kc.type = 'UQ'
    ) AS UniqueConstraintCount
FROM sys.tables AS t
WHERE t.schema_id = SCHEMA_ID(N'dbo')
ORDER BY t.name;


-- 2. Детальна інформація про стовпці

SELECT
    t.name AS TableName,
    c.column_id AS ColumnPosition,
    c.name AS ColumnName,
    ty.name AS DataType,
    c.max_length AS MaxLengthBytes,
    c.precision AS NumericPrecision,
    c.scale AS Scale,
    c.is_nullable AS IsNullable,
    c.is_identity AS IsIdentity,
    CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM sys.indexes AS i
            INNER JOIN sys.index_columns AS ic
                ON ic.object_id = i.object_id
               AND ic.index_id = i.index_id
            WHERE i.object_id = c.object_id
              AND i.is_primary_key = 1
              AND ic.column_id = c.column_id
        )
        THEN 1 ELSE 0
    END AS IsPrimaryKey,
    dc.definition AS DefaultValue
FROM sys.tables AS t
INNER JOIN sys.columns AS c
    ON c.object_id = t.object_id
INNER JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints AS dc
    ON dc.object_id = c.default_object_id
WHERE t.schema_id = SCHEMA_ID(N'dbo')
ORDER BY t.name, c.column_id;


-- 3. Інформація про зовнішні ключі

SELECT
    fk.name AS ForeignKeyName,
    pt.name AS ParentTable,
    pc.name AS ParentColumn,
    rt.name AS ReferencedTable,
    rc.name AS ReferencedColumn,
    fk.delete_referential_action_desc AS OnDelete,
    fk.update_referential_action_desc AS OnUpdate
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.tables AS pt
    ON pt.object_id = fk.parent_object_id
INNER JOIN sys.columns AS pc
    ON pc.object_id = fkc.parent_object_id
   AND pc.column_id = fkc.parent_column_id
INNER JOIN sys.tables AS rt
    ON rt.object_id = fkc.referenced_object_id
INNER JOIN sys.columns AS rc
    ON rc.object_id = fkc.referenced_object_id
   AND rc.column_id = fkc.referenced_column_id
WHERE pt.schema_id = SCHEMA_ID(N'dbo')
ORDER BY pt.name, fk.name, fkc.constraint_column_id;
