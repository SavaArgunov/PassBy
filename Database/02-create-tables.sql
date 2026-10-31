SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() IN (N'master', N'model', N'msdb', N'tempdb')
BEGIN
    THROW 51000, N'Виберіть користувацьку базу даних, а не системну.', 1;
END;

-- Будь-який конфлікт назв: жодних спроб змінити або доповнити наявну схему.
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
BEGIN
    THROW 51001, N'Одна або більше цільових таблиць уже існують: жодних змін не виконано.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

    CREATE TABLE dbo.UserAccount
    (
        userId           BIGINT IDENTITY(1, 1) NOT NULL,
        emailAddress     NVARCHAR(320) NOT NULL,
        phoneNumber      NVARCHAR(32) NULL,
        registeredAtUtc  DATETIME2(7) NOT NULL,
        isBlocked        BIT NOT NULL,

        CONSTRAINT PK_UserAccount
            PRIMARY KEY (userId),

        CONSTRAINT UQ_UserAccount_EmailAddress
            UNIQUE (emailAddress)
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
            UNIQUE (code)
    );

    CREATE TABLE dbo.VerificationOutcome
    (
        verificationCode  VARCHAR(64) 
            COLLATE Latin1_General_100_BIN2 NOT NULL,
        description       NVARCHAR(1000) NOT NULL,

        CONSTRAINT PK_VerificationOutcome
            PRIMARY KEY (verificationCode)
    );

    CREATE TABLE dbo.PasswordCredential
    (
        userId        BIGINT NOT NULL,
        passwordHash  NVARCHAR(1024) NOT NULL,
        createdAtUtc  DATETIME2(7) NOT NULL
            CONSTRAINT DF_PasswordCredential_CreatedAtUtc
            DEFAULT (SYSUTCDATETIME()),
        changedAtUtc  DATETIME2(7) NOT NULL
            CONSTRAINT DF_PasswordCredential_ChangedAtUtc
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_PasswordCredential
            PRIMARY KEY (userId),

        CONSTRAINT FK_PasswordCredential_UserAccount
            FOREIGN KEY (userId)
            REFERENCES dbo.UserAccount (userId)
            ON DELETE NO ACTION
            ON UPDATE NO ACTION
    );

    CREATE TABLE dbo.Deliverer
    (
        userId           BIGINT NOT NULL,
        registeredAtUtc  DATETIME2(7) NOT NULL,
        isBlocked        BIT NOT NULL,

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
        isBlocked        BIT NOT NULL,

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
        documentReference       NVARCHAR(512) NOT NULL,
        validatedAtUtc          DATETIME2(7) NOT NULL,
        verificationProviderId  BIGINT NOT NULL,
        userId                  BIGINT NOT NULL,

        CONSTRAINT PK_ValidatedDocument
            PRIMARY KEY (documentId),

        CONSTRAINT UQ_ValidatedDocument_Provider_DocumentReference
            UNIQUE NONCLUSTERED (verificationProviderId, documentReference)

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
