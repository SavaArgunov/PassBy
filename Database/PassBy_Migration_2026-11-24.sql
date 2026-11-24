/*
PassBy | 2026-11-24 | RawIntent removal + CollaborativeDeal lifecycle
ONE-TIME migration for the pre-refactor Sprint 2 schema (2026-11-20).
Run as dbo in PassBy, on a backup/test copy first. Do not run on the
already migrated Azure database. No test fixtures or credentials included.

Sources: successful scripts supplied by the user and the final DB audit.
Sections 1-2 are reconstructed because the original scripts were missing.
The 11 subsequent SQL module bodies match the final audit after
whitespace and CREATE/ALTER header normalization.
Permissions and documentation are from the supplied successful scripts,
with transaction guards adapted for one outer atomic transaction.
Known limitations remain unchanged, including P2P_CREDIT ownership.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N'PassBy'
    THROW 52200, N'Incorrect target database.', 1;
IF @@TRANCOUNT <> 0
    THROW 52201, N'An existing transaction is active.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Preflight: fail closed rather than deleting or inventing existing deal data.
    IF OBJECT_ID(N'dbo.CollaborativeDeal', N'U') IS NULL
        OR COL_LENGTH(N'dbo.CollaborativeDeal', N'pickupConfirmationTokenHash') IS NULL
        OR COL_LENGTH(N'dbo.CollaborativeDeal', N'deliveryConfirmationTokenHash') IS NULL
        OR COL_LENGTH(N'dbo.CollaborativeDeal', N'lastProposedByUserId') IS NOT NULL
        OR COL_LENGTH(N'dbo.CollaborativeDeal', N'agreedAtUtc') IS NOT NULL
        OR OBJECT_ID(N'dbo.CollaborativeDealHistory') IS NOT NULL
        OR NOT EXISTS (
            SELECT 1 FROM sys.tables
            WHERE object_id = OBJECT_ID(N'dbo.CollaborativeDeal') AND temporal_type = 0
        )
        THROW 52202, N'Expected pre-refactor CollaborativeDeal schema not found.', 1;

    IF DATABASE_PRINCIPAL_ID(N'passby_backend') IS NULL
        THROW 52203, N'Expected backend database user not found.', 1;

    IF EXISTS (SELECT 1 FROM dbo.CollaborativeDeal WITH (TABLOCKX, HOLDLOCK))
        OR EXISTS (SELECT 1 FROM dbo.PaymentOperationAttempt WITH (TABLOCKX, HOLDLOCK))
        THROW 52204, N'Existing deals or payment attempts require a separate data migration.', 1;

    -- 1. RawIntent removal (reconstructed from final audit).
    EXEC sys.sp_executesql N'IF EXISTS (SELECT 1 FROM dbo.DelivererIntent WHERE orderStatusCode = ''RawIntent'')
    OR EXISTS (SELECT 1 FROM dbo.DeliveryRequesterIntent WHERE orderStatusCode = ''RawIntent'')
    OR EXISTS (SELECT 1 FROM dbo.DelivererIntentHistory WHERE orderStatusCode = ''RawIntent'')
    OR EXISTS (SELECT 1 FROM dbo.DeliveryRequesterIntentHistory WHERE orderStatusCode = ''RawIntent'')
    THROW 52205, N''RawIntent data exists; manual migration is required.'', 1;

DELETE FROM dbo.OrderStatus WHERE orderStatusCode = ''RawIntent'';
UPDATE dbo.OrderStatus
SET statusDescription = N''Сформований неопублікований Order.''
WHERE orderStatusCode = ''Private'';
IF @@ROWCOUNT <> 1
    THROW 52206, N''Expected Private status not found.'', 1;';
    EXEC sys.sp_executesql N'ALTER PROCEDURE dbo.CreateInteractionContext
@RequestInitiatorCode VARCHAR(64),
@InitiatorUserId BIGINT,
@TargetOrderId BIGINT,
@InitiatorOrderId BIGINT
AS
BEGIN
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @RequestInitiatorCode IS NULL
OR @RequestInitiatorCode NOT IN
(''Deliverer'', ''DeliveryRequester'')
THROW 51020, N''Invalid initiator role.'', 1;
IF @InitiatorUserId IS NULL
OR @TargetOrderId IS NULL
OR @InitiatorOrderId IS NULL
THROW 51021,
N''Initiator and both Orders are required.'',
1;
DECLARE @DelivererIntentId BIGINT;
DECLARE @DeliveryRequesterIntentId BIGINT;
DECLARE @InteractionContextId BIGINT;
DECLARE @LockResult INT;
IF @RequestInitiatorCode = ''Deliverer''
BEGIN
SET @DelivererIntentId = @InitiatorOrderId;
SET @DeliveryRequesterIntentId = @TargetOrderId;
END
ELSE
BEGIN
SET @DelivererIntentId = @TargetOrderId;
SET @DeliveryRequesterIntentId = @InitiatorOrderId;
END;
DECLARE @DResource NVARCHAR(255) = CONCAT(
N''PassBy:Intent:D:'',
CONVERT(NVARCHAR(20), @DelivererIntentId)
);
DECLARE @RResource NVARCHAR(255) = CONCAT(
N''PassBy:Intent:R:'',
CONVERT(NVARCHAR(20), @DeliveryRequesterIntentId)
);
BEGIN TRY
BEGIN TRANSACTION;
/* Єдиний порядок блокування: D -> R. */
EXEC @LockResult = sys.sp_getapplock
@Resource = @DResource,
@LockMode = ''Exclusive'',
@LockOwner = ''Transaction'',
@DbPrincipal = ''public'',
@LockTimeout = 10000;
IF @LockResult < 0
THROW 51030, N''Failed to lock Order.'', 1;
EXEC @LockResult = sys.sp_getapplock
@Resource = @RResource,
@LockMode = ''Exclusive'',
@LockOwner = ''Transaction'',
@DbPrincipal = ''public'',
@LockTimeout = 10000;
IF @LockResult < 0
THROW 51031, N''Failed to lock second Order.'', 1;
/* Ініціатор: кур''єр. */
IF @RequestInitiatorCode = ''Deliverer''
BEGIN
IF NOT EXISTS (
SELECT 1
FROM dbo.DeliveryRequesterIntent
WITH (UPDLOCK, HOLDLOCK)
WHERE deliveryRequesterIntentId = @TargetOrderId
AND orderStatusCode = ''Published''
)
THROW 51023,
N''Target Order is not published.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.vDeliveryRequesterIntentDetails
WHERE deliveryRequesterIntentId = @TargetOrderId
AND isAvailableAsTarget = 1
)
THROW 51024,
N''Target Order is unavailable.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.DelivererIntent
WITH (UPDLOCK, HOLDLOCK)
WHERE delivererIntentId = @InitiatorOrderId
AND authorDelivererUserId = @InitiatorUserId
AND orderStatusCode IN (''Private'', ''Published'')
)
THROW 51025, N''Invalid initiator Order.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.vDelivererIntentDetails
WHERE delivererIntentId = @InitiatorOrderId
AND isAvailableAsInitiator = 1
)
THROW 51026,
N''Initiator Order is unavailable.'', 1;
END
/* Ініціатор: замовник перевезення. */
ELSE
BEGIN
IF NOT EXISTS (
SELECT 1
FROM dbo.DelivererIntent
WITH (UPDLOCK, HOLDLOCK)
WHERE delivererIntentId = @TargetOrderId
AND orderStatusCode = ''Published''
)
THROW 51028,
N''Target Order is not published.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.vDelivererIntentDetails
WHERE delivererIntentId = @TargetOrderId
AND isAvailableAsTarget = 1
)
THROW 51029,
N''Target Order is unavailable.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.DeliveryRequesterIntent
WITH (UPDLOCK, HOLDLOCK)
WHERE deliveryRequesterIntentId = @InitiatorOrderId
AND authorDeliveryRequesterUserId = @InitiatorUserId
AND orderStatusCode IN (''Private'', ''Published'')
)
THROW 51032, N''Invalid initiator Order.'', 1;
IF NOT EXISTS (
SELECT 1
FROM dbo.vDeliveryRequesterIntentDetails
WHERE deliveryRequesterIntentId = @InitiatorOrderId
AND isAvailableAsInitiator = 1
)
THROW 51033,
N''Initiator Order is unavailable.'', 1;
END;
/* Заборона взаємодії із самим собою. */
IF EXISTS (
SELECT 1
FROM dbo.DelivererIntent AS d
INNER JOIN dbo.DeliveryRequesterIntent AS r
ON r.deliveryRequesterIntentId =
@DeliveryRequesterIntentId
WHERE d.delivererIntentId = @DelivererIntentId
AND d.authorDelivererUserId =
r.authorDeliveryRequesterUserId
)
THROW 51035,
N''Self-interaction is not allowed.'', 1;
/* Створення взаємодії. */
INSERT INTO dbo.InteractionContext
(
delivererIntentId,
deliveryRequesterIntentId,
requestInitiatorCode,
interactionStatusCode
)
VALUES
(
@DelivererIntentId,
@DeliveryRequesterIntentId,
@RequestInitiatorCode,
''Unilateral''
);
SET @InteractionContextId =
CAST(SCOPE_IDENTITY() AS BIGINT);
COMMIT TRANSACTION;
SELECT
@InteractionContextId AS interactionContextId,
@DelivererIntentId AS delivererIntentId,
@DeliveryRequesterIntentId
AS deliveryRequesterIntentId,
''Unilateral'' AS interactionStatusCode;
END TRY
BEGIN CATCH
IF XACT_STATE() <> 0
ROLLBACK TRANSACTION;
THROW;
END CATCH;
END;';
    EXEC sys.sp_executesql N'ALTER TRIGGER dbo.TR_DelivererIntent_ImmutableFinalStates
ON dbo.DelivererIntent
AFTER UPDATE, DELETE
AS
BEGIN
SET NOCOUNT ON;
/* Виконані Order незмінні. */
IF EXISTS (
SELECT 1
FROM deleted AS d
INNER JOIN dbo.InteractionContext AS ic
ON ic.delivererIntentId = d.delivererIntentId
INNER JOIN dbo.CollaborativeDeal AS cd
ON cd.interactionContextId = ic.interactionContextId
WHERE cd.dealExecutionStatusCode = ''Fulfilled''
)
THROW 51160,
N''DelivererIntent: fulfilled Order is immutable.'',
1;
END;';
    EXEC sys.sp_executesql N'ALTER TRIGGER dbo.TR_DeliveryRequesterIntent_ImmutableFinalStates
ON dbo.DeliveryRequesterIntent
AFTER UPDATE, DELETE
AS
BEGIN
SET NOCOUNT ON;
/* Виконані Order незмінні. */
IF EXISTS (
SELECT 1
FROM deleted AS r
INNER JOIN dbo.InteractionContext AS ic
ON ic.deliveryRequesterIntentId =
r.deliveryRequesterIntentId
INNER JOIN dbo.CollaborativeDeal AS cd
ON cd.interactionContextId = ic.interactionContextId
WHERE cd.dealExecutionStatusCode = ''Fulfilled''
)
THROW 51161,
N''DeliveryRequesterIntent: fulfilled Order is immutable.'',
1;
END;';

    -- 2. CollaborativeDeal schema (reconstructed from final audit).
    INSERT INTO dbo.DealExecutionStatus (dealExecutionStatusCode, statusDescription)
    VALUES ('Draft', N'Чернетка угоди. Умови формуються та погоджуються сторонами. Пов’язані Order зарезервовано.');

    EXEC sys.sp_rename
        @objname = N'dbo.CollaborativeDeal.pickupConfirmationTokenHash',
        @newname = N'pickupConfirmationTokenEncrypted',
        @objtype = N'COLUMN';
    EXEC sys.sp_rename
        @objname = N'dbo.CollaborativeDeal.deliveryConfirmationTokenHash',
        @newname = N'deliveryConfirmationTokenEncrypted',
        @objtype = N'COLUMN';

    EXEC sys.sp_executesql N'ALTER TABLE dbo.CollaborativeDeal ALTER COLUMN pickupConfirmationTokenEncrypted VARBINARY(MAX) NULL;
ALTER TABLE dbo.CollaborativeDeal ALTER COLUMN deliveryConfirmationTokenEncrypted VARBINARY(MAX) NULL;
ALTER TABLE dbo.CollaborativeDeal ADD
    lastProposedByUserId BIGINT NOT NULL,
    agreedAtUtc DATETIME2(7) NULL;';
    EXEC sys.sp_executesql N'ALTER TABLE dbo.CollaborativeDeal WITH CHECK ADD
    CONSTRAINT FK_CollaborativeDeal_LastProposedBy
        FOREIGN KEY (lastProposedByUserId) REFERENCES dbo.UserAccount(userId),
    CONSTRAINT CK_CollaborativeDeal_AgreementConsistency CHECK ([agreedAtUtc] IS NULL AND [pickupConfirmationTokenEncrypted] IS NULL AND [deliveryConfirmationTokenEncrypted] IS NULL AND ([dealExecutionStatusCode]=''Failed'' OR [dealExecutionStatusCode]=''Draft'') OR [agreedAtUtc] IS NOT NULL AND [pickupConfirmationTokenEncrypted] IS NOT NULL AND [deliveryConfirmationTokenEncrypted] IS NOT NULL AND datalength([pickupConfirmationTokenEncrypted])>(0) AND datalength([deliveryConfirmationTokenEncrypted])>(0) AND ([dealExecutionStatusCode]=''Failed'' OR [dealExecutionStatusCode]=''Fulfilled'' OR [dealExecutionStatusCode]=''AwaitingPayout'' OR [dealExecutionStatusCode]=''InTransit'' OR [dealExecutionStatusCode]=''AwaitingHandover'')),
    CONSTRAINT CK_CollaborativeDeal_AgreedAtUtc CHECK ([agreedAtUtc] IS NULL OR [agreedAtUtc]>=[createdAtUtc]);

ALTER TABLE dbo.CollaborativeDeal ADD
    validFrom DATETIME2(7) GENERATED ALWAYS AS ROW START NOT NULL
        CONSTRAINT DF_CollaborativeDeal_ValidFrom DEFAULT SYSUTCDATETIME(),
    validTo DATETIME2(7) GENERATED ALWAYS AS ROW END NOT NULL
        CONSTRAINT DF_CollaborativeDeal_ValidTo DEFAULT CONVERT(DATETIME2(7), ''9999-12-31T23:59:59.9999999''),
    PERIOD FOR SYSTEM_TIME (validFrom, validTo);';
    EXEC sys.sp_executesql N'ALTER TABLE dbo.CollaborativeDeal SET
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.CollaborativeDealHistory,
        DATA_CONSISTENCY_CHECK = ON,
        HISTORY_RETENTION_PERIOD = INFINITE
    )
);';

    -- 3. Domain SQL modules (from supplied successful scripts).

    -- CreateCollaborativeDeal
    EXEC sys.sp_executesql N'
    ALTER PROCEDURE dbo.CreateCollaborativeDeal
        @InteractionContextId BIGINT,
        @ActorUserId BIGINT,

        @ReceivingLatitude FLOAT,
        @ReceivingLongitude FLOAT,
        @DestinationLatitude FLOAT,
        @DestinationLongitude FLOAT,

        @FinalPriceWithoutCommission DECIMAL(18,2),

        @SenderUserId BIGINT,
        @ReceiverUserId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        /*
            Створення чернетки CollaborativeDeal.

            Правила:
            1. InteractionContext повинен бути Mutual.
            2. ActorUserId повинен бути автором
               одного з пов''язаних намірів.
            3. Target Order повинен бути Published.
            4. Initiator Order: Private або Published.
            5. Draft резервує обидва Order.
            6. Наявність активної або Fulfilled-угоди
               забороняє створення чернетки.
            7. Failed дозволяє повторне використання Order.
            8. Автор пропозиції погоджується з її умовами.
            9. Секрети та дата погодження відсутні
               до остаточного укладання угоди.
            10. Створення атомарне.
        */


        --------------------------------------------------
        -- 1. Валідація обов''язкових параметрів
        --------------------------------------------------

        IF @InteractionContextId IS NULL
           OR @ActorUserId IS NULL
           OR @SenderUserId IS NULL
           OR @ReceiverUserId IS NULL
           OR @FinalPriceWithoutCommission IS NULL
           OR @FinalPriceWithoutCommission < 0
            THROW 51110,
                N''Invalid deal parameters.'',
                1;


        --------------------------------------------------
        -- 2. Валідація координат
        --------------------------------------------------

        IF @ReceivingLatitude IS NULL
           OR @ReceivingLongitude IS NULL
           OR @DestinationLatitude IS NULL
           OR @DestinationLongitude IS NULL
           OR @ReceivingLatitude NOT BETWEEN -90 AND 90
           OR @DestinationLatitude NOT BETWEEN -90 AND 90
           OR @ReceivingLongitude NOT BETWEEN -180 AND 180
           OR @DestinationLongitude NOT BETWEEN -180 AND 180
            THROW 51112,
                N''Invalid deal coordinates.'',
                1;


        --------------------------------------------------
        -- 3. Локальні змінні
        --------------------------------------------------

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);

        DECLARE @DStatus VARCHAR(64);
        DECLARE @RStatus VARCHAR(64);

        DECLARE @DelivererUserId BIGINT;
        DECLARE @RequesterUserId BIGINT;

        DECLARE @CreatedDealId BIGINT;


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 4. Конкурентне блокування обох Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId = @InteractionContextId,
                @DelivererIntentId = @DId OUTPUT,
                @DeliveryRequesterIntentId = @RId OUTPUT,
                @RequestInitiatorCode = @InitiatorCode OUTPUT,
                @InteractionStatusCode = @InteractionStatus OUTPUT;


            --------------------------------------------------
            -- 5. Перевірка стану взаємодії
            --------------------------------------------------

            IF @InteractionStatus <> ''Mutual''
                THROW 51113,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- 6. Отримання актуальних намірів
            --------------------------------------------------

            SELECT
                @DStatus = d.orderStatusCode,
                @DelivererUserId = d.authorDelivererUserId
            FROM dbo.DelivererIntent AS d
                WITH (UPDLOCK, HOLDLOCK)
            WHERE d.delivererIntentId = @DId;

            SELECT
                @RStatus = r.orderStatusCode,
                @RequesterUserId =
                    r.authorDeliveryRequesterUserId
            FROM dbo.DeliveryRequesterIntent AS r
                WITH (UPDLOCK, HOLDLOCK)
            WHERE r.deliveryRequesterIntentId = @RId;

            IF @DelivererUserId IS NULL
               OR @RequesterUserId IS NULL
                THROW 51114,
                    N''Linked intents not found.'',
                    1;


            --------------------------------------------------
            -- 7. Перевірка автора пропозиції
            --------------------------------------------------

            IF @ActorUserId NOT IN
                (@DelivererUserId, @RequesterUserId)
                THROW 51115,
                    N''Actor does not participate in the interaction.'',
                    1;


            --------------------------------------------------
            -- 8. Перевірка статусів Order
            --------------------------------------------------

            IF @InitiatorCode = ''Deliverer''
            BEGIN

                IF @RStatus <> ''Published''
                   OR @DStatus NOT IN
                       (''Private'', ''Published'')
                    THROW 51116,
                        N''Intents are not eligible for a deal.'',
                        1;

            END

            ELSE IF @InitiatorCode = ''DeliveryRequester''
            BEGIN

                IF @DStatus <> ''Published''
                   OR @RStatus NOT IN
                       (''Private'', ''Published'')
                    THROW 51117,
                        N''Intents are not eligible for a deal.'',
                        1;

            END

            ELSE
                THROW 51118,
                    N''Invalid interaction initiator.'',
                    1;


            --------------------------------------------------
            -- 9. Перевірка остаточно виконаних Order
            --------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.InteractionContext AS ic
                INNER JOIN dbo.CollaborativeDeal AS cd
                    WITH (UPDLOCK, HOLDLOCK)
                    ON cd.interactionContextId =
                       ic.interactionContextId
                WHERE
                    (
                        ic.delivererIntentId = @DId
                        OR
                        ic.deliveryRequesterIntentId = @RId
                    )
                    AND cd.dealExecutionStatusCode =
                        ''Fulfilled''
            )
                THROW 51120,
                    N''At least one intent has a fulfilled deal.'',
                    1;


            --------------------------------------------------
            -- 10. Перевірка активних угод
            --
            -- Draft також є активною угодою,
            -- оскільки резервує обидва Order.
            --------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.InteractionContext AS ic
                INNER JOIN dbo.CollaborativeDeal AS cd
                    WITH (UPDLOCK, HOLDLOCK)
                    ON cd.interactionContextId =
                       ic.interactionContextId
                WHERE
                    (
                        ic.delivererIntentId = @DId
                        OR
                        ic.deliveryRequesterIntentId = @RId
                    )
                    AND cd.dealExecutionStatusCode
                        NOT IN (''Fulfilled'', ''Failed'')
            )
                THROW 51119,
                    N''At least one intent has an active deal.'',
                    1;


            --------------------------------------------------
            -- 11. Створення чернетки
            --------------------------------------------------

            INSERT INTO dbo.CollaborativeDeal
            (
                receivingCoordinates,
                destinationCoordinates,

                finalPriceWithoutCommission,

                pickupConfirmationTokenEncrypted,
                deliveryConfirmationTokenEncrypted,

                agreedAtUtc,
                dealExecutionStatusCode,

                senderUserId,
                receiverUserId,

                lastProposedByUserId,
                interactionContextId
            )
            VALUES
            (
                geography::Point(
                    @ReceivingLatitude,
                    @ReceivingLongitude,
                    4326
                ),

                geography::Point(
                    @DestinationLatitude,
                    @DestinationLongitude,
                    4326
                ),

                @FinalPriceWithoutCommission,

                NULL,
                NULL,

                NULL,
                ''Draft'',

                @SenderUserId,
                @ReceiverUserId,

                @ActorUserId,
                @InteractionContextId
            );

            SET @CreatedDealId =
                CAST(SCOPE_IDENTITY() AS BIGINT);


            --------------------------------------------------
            -- 12. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CreatedDealId AS collaborativeDealId,
                ''Draft'' AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- UpdateCollaborativeDealDraft
    EXEC sys.sp_executesql N'
    CREATE PROCEDURE dbo.UpdateCollaborativeDealDraft
        @CollaborativeDealId BIGINT,
        @ActorUserId BIGINT,
        @ExpectedTermsRevision BIGINT,

        @ReceivingLatitude FLOAT,
        @ReceivingLongitude FLOAT,
        @DestinationLatitude FLOAT,
        @DestinationLongitude FLOAT,

        @FinalPriceWithoutCommission DECIMAL(18,2),

        @SenderUserId BIGINT,
        @ReceiverUserId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
           OR @ActorUserId IS NULL
           OR @ExpectedTermsRevision IS NULL
           OR @ExpectedTermsRevision < 1
           OR @SenderUserId IS NULL
           OR @ReceiverUserId IS NULL
           OR @FinalPriceWithoutCommission IS NULL
           OR @FinalPriceWithoutCommission < 0
            THROW 51422,
                N''Invalid draft parameters.'',
                1;


        IF @ReceivingLatitude IS NULL
           OR @ReceivingLongitude IS NULL
           OR @DestinationLatitude IS NULL
           OR @DestinationLongitude IS NULL
           OR @ReceivingLatitude NOT BETWEEN -90 AND 90
           OR @DestinationLatitude NOT BETWEEN -90 AND 90
           OR @ReceivingLongitude NOT BETWEEN -180 AND 180
           OR @DestinationLongitude NOT BETWEEN -180 AND 180
            THROW 51423,
                N''Invalid deal coordinates.'',
                1;


        --------------------------------------------------
        -- 2. Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);
        DECLARE @DealStatus VARCHAR(64);

        DECLARE @DelivererUserId BIGINT;
        DECLARE @RequesterUserId BIGINT;

        DECLARE @CurrentTermsRevision BIGINT;
        DECLARE @NewTermsRevision BIGINT;

        DECLARE @CurrentReceiving GEOGRAPHY;
        DECLARE @CurrentDestination GEOGRAPHY;

        DECLARE @CurrentPrice DECIMAL(18,2);
        DECLARE @CurrentSenderUserId BIGINT;
        DECLARE @CurrentReceiverUserId BIGINT;


        DECLARE @NewReceiving GEOGRAPHY =
            geography::Point(
                @ReceivingLatitude,
                @ReceivingLongitude,
                4326
            );

        DECLARE @NewDestination GEOGRAPHY =
            geography::Point(
                @DestinationLatitude,
                @DestinationLongitude,
                4326
            );


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 3. Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId
            FROM dbo.CollaborativeDeal
            WHERE collaborativeDealId =
                @CollaborativeDealId;

            IF @InteractionContextId IS NULL
                THROW 51424,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- 4. Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            IF @InteractionStatus <> ''Mutual''
                THROW 51425,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- 5. Визначення учасників взаємодії
            --------------------------------------------------

            SELECT
                @DelivererUserId =
                    authorDelivererUserId
            FROM dbo.DelivererIntent
                WITH (UPDLOCK, HOLDLOCK)
            WHERE delivererIntentId = @DId;


            SELECT
                @RequesterUserId =
                    authorDeliveryRequesterUserId
            FROM dbo.DeliveryRequesterIntent
                WITH (UPDLOCK, HOLDLOCK)
            WHERE deliveryRequesterIntentId = @RId;


            IF @DelivererUserId IS NULL
               OR @RequesterUserId IS NULL
                THROW 51426,
                    N''Linked intents not found.'',
                    1;


            IF @ActorUserId NOT IN
                (@DelivererUserId, @RequesterUserId)
                THROW 51427,
                    N''Actor does not participate in the interaction.'',
                    1;


            --------------------------------------------------
            -- 6. Блокування та читання актуальної угоди
            --------------------------------------------------

            SELECT
                @DealStatus =
                    dealExecutionStatusCode,

                @CurrentReceiving =
                    receivingCoordinates,

                @CurrentDestination =
                    destinationCoordinates,

                @CurrentPrice =
                    finalPriceWithoutCommission,

                @CurrentSenderUserId =
                    senderUserId,

                @CurrentReceiverUserId =
                    receiverUserId

            FROM dbo.CollaborativeDeal
                WITH (UPDLOCK, HOLDLOCK)

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND interactionContextId =
                    @InteractionContextId;


            IF @DealStatus IS NULL
                THROW 51428,
                    N''CollaborativeDeal changed or disappeared.'',
                    1;


            IF @DealStatus <> ''Draft''
                THROW 51429,
                    N''Only draft deals can be edited.'',
                    1;


            --------------------------------------------------
            -- 7. Обчислення поточної редакції умов
            --------------------------------------------------

            SELECT
                @CurrentTermsRevision =
                    COUNT_BIG(*) + 1

            FROM dbo.CollaborativeDealHistory

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @ExpectedTermsRevision <>
               @CurrentTermsRevision

                THROW 51430,
                    N''Terms revision is outdated.'',
                    1;


            --------------------------------------------------
            -- 8. Заборона порожніх змін
            --
            -- Нова редакція повинна містити
            -- хоча б одну зміну умов.
            --------------------------------------------------

            IF @CurrentReceiving.STEquals(
                    @NewReceiving
               ) = 1

               AND @CurrentDestination.STEquals(
                    @NewDestination
               ) = 1

               AND @CurrentPrice =
                    @FinalPriceWithoutCommission

               AND @CurrentSenderUserId =
                    @SenderUserId

               AND @CurrentReceiverUserId =
                    @ReceiverUserId

                THROW 51431,
                    N''Draft terms have not changed.'',
                    1;


            --------------------------------------------------
            -- 9. Оновлення умов чернетки
            --
            -- Попередня версія автоматично
            -- переноситься до History Table.
            --------------------------------------------------

            UPDATE dbo.CollaborativeDeal
            SET
                receivingCoordinates =
                    @NewReceiving,

                destinationCoordinates =
                    @NewDestination,

                finalPriceWithoutCommission =
                    @FinalPriceWithoutCommission,

                senderUserId =
                    @SenderUserId,

                receiverUserId =
                    @ReceiverUserId,

                lastProposedByUserId =
                    @ActorUserId

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @@ROWCOUNT <> 1
                THROW 51432,
                    N''Draft update failed.'',
                    1;


            --------------------------------------------------
            -- 10. Перевірка нової редакції
            --------------------------------------------------

            SELECT
                @NewTermsRevision =
                    COUNT_BIG(*) + 1

            FROM dbo.CollaborativeDealHistory

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @NewTermsRevision <>
               @CurrentTermsRevision + 1

                THROW 51433,
                    N''Unexpected temporal revision change.'',
                    1;


            --------------------------------------------------
            -- 11. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                @ActorUserId
                    AS lastProposedByUserId,

                @NewTermsRevision
                    AS termsRevision,

                ''Draft''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- AcceptCollaborativeDeal
    EXEC sys.sp_executesql N'
    CREATE PROCEDURE dbo.AcceptCollaborativeDeal
        @CollaborativeDealId BIGINT,
        @ActorUserId BIGINT,
        @ExpectedTermsRevision BIGINT,

        @PickupConfirmationTokenEncrypted VARBINARY(MAX),
        @DeliveryConfirmationTokenEncrypted VARBINARY(MAX)
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
           OR @ActorUserId IS NULL
           OR @ExpectedTermsRevision IS NULL
           OR @ExpectedTermsRevision < 1

            THROW 51442,
                N''Invalid agreement parameters.'',
                1;


        IF @PickupConfirmationTokenEncrypted IS NULL
           OR @DeliveryConfirmationTokenEncrypted IS NULL
           OR DATALENGTH(
                @PickupConfirmationTokenEncrypted
              ) = 0
           OR DATALENGTH(
                @DeliveryConfirmationTokenEncrypted
              ) = 0

            THROW 51443,
                N''Both encrypted confirmation tokens are required.'',
                1;


        IF @PickupConfirmationTokenEncrypted =
           @DeliveryConfirmationTokenEncrypted

            THROW 51444,
                N''Encrypted confirmation tokens must be different.'',
                1;


        --------------------------------------------------
        -- 2. Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);
        DECLARE @DealStatus VARCHAR(64);

        DECLARE @DelivererUserId BIGINT;
        DECLARE @RequesterUserId BIGINT;

        DECLARE @LastProposedByUserId BIGINT;

        DECLARE @CurrentTermsRevision BIGINT;
        DECLARE @FinalTermsRevision BIGINT;

        DECLARE @AgreedAtUtc DATETIME2(7);


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 3. Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId

            FROM dbo.CollaborativeDeal

            WHERE collaborativeDealId =
                @CollaborativeDealId;


            IF @InteractionContextId IS NULL

                THROW 51445,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- 4. Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            IF @InteractionStatus <> ''Mutual''

                THROW 51446,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- 5. Визначення учасників взаємодії
            --------------------------------------------------

            SELECT
                @DelivererUserId =
                    authorDelivererUserId

            FROM dbo.DelivererIntent
                WITH (UPDLOCK, HOLDLOCK)

            WHERE delivererIntentId = @DId;


            SELECT
                @RequesterUserId =
                    authorDeliveryRequesterUserId

            FROM dbo.DeliveryRequesterIntent
                WITH (UPDLOCK, HOLDLOCK)

            WHERE deliveryRequesterIntentId = @RId;


            IF @DelivererUserId IS NULL
               OR @RequesterUserId IS NULL

                THROW 51447,
                    N''Linked intents not found.'',
                    1;


            IF @ActorUserId NOT IN
                (@DelivererUserId, @RequesterUserId)

                THROW 51448,
                    N''Actor does not participate in the interaction.'',
                    1;


            --------------------------------------------------
            -- 6. Блокування та читання актуальної угоди
            --------------------------------------------------

            SELECT
                @DealStatus =
                    dealExecutionStatusCode,

                @LastProposedByUserId =
                    lastProposedByUserId

            FROM dbo.CollaborativeDeal
                WITH (UPDLOCK, HOLDLOCK)

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND interactionContextId =
                    @InteractionContextId;


            IF @DealStatus IS NULL

                THROW 51449,
                    N''CollaborativeDeal changed or disappeared.'',
                    1;


            IF @DealStatus <> ''Draft''

                THROW 51450,
                    N''Only draft deals can be accepted.'',
                    1;


            --------------------------------------------------
            -- 7. Перевірка сторін погодження
            --------------------------------------------------

            IF @LastProposedByUserId NOT IN
                (@DelivererUserId, @RequesterUserId)

                THROW 51451,
                    N''Invalid proposal author.'',
                    1;


            IF @ActorUserId = @LastProposedByUserId

                THROW 51452,
                    N''A user cannot accept their own proposal.'',
                    1;


            --------------------------------------------------
            -- 8. Перевірка актуальності редакції
            --------------------------------------------------

            SELECT
                @CurrentTermsRevision =
                    COUNT_BIG(*) + 1

            FROM dbo.CollaborativeDealHistory

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @ExpectedTermsRevision <>
               @CurrentTermsRevision

                THROW 51453,
                    N''Terms revision is outdated.'',
                    1;


            --------------------------------------------------
            -- 9. Перевірка відсутності конфліктних угод
            --
            -- Поточна чернетка вже резервує Order,
            -- тому виключаємо її з перевірки.
            --------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.InteractionContext AS ic

                INNER JOIN dbo.CollaborativeDeal AS cd
                    WITH (UPDLOCK, HOLDLOCK)

                    ON cd.interactionContextId =
                       ic.interactionContextId

                WHERE
                    (
                        ic.delivererIntentId = @DId
                        OR
                        ic.deliveryRequesterIntentId = @RId
                    )

                    AND cd.collaborativeDealId <>
                        @CollaborativeDealId

                    AND cd.dealExecutionStatusCode <> ''Failed''
            )

                THROW 51454,
                    N''At least one intent has a conflicting deal.'',
                    1;


            --------------------------------------------------
            -- 10. Остаточне укладання угоди
            --------------------------------------------------

            SET @AgreedAtUtc = SYSUTCDATETIME();


            UPDATE dbo.CollaborativeDeal
            SET
                pickupConfirmationTokenEncrypted =
                    @PickupConfirmationTokenEncrypted,

                deliveryConfirmationTokenEncrypted =
                    @DeliveryConfirmationTokenEncrypted,

                agreedAtUtc =
                    @AgreedAtUtc,

                dealExecutionStatusCode =
                    ''AwaitingHandover''

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @@ROWCOUNT <> 1

                THROW 51455,
                    N''Deal acceptance failed.'',
                    1;


            --------------------------------------------------
            -- 11. Перевірка збереження редакції
            --
            -- Актуальна версія більше не є Draft.
            -- Усі редакції умов тепер містяться
            -- в історичній таблиці.
            --------------------------------------------------

            SELECT
                @FinalTermsRevision =
                    COUNT_BIG(*)

            FROM dbo.CollaborativeDealHistory

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND dealExecutionStatusCode = ''Draft'';


            IF @FinalTermsRevision <>
               @CurrentTermsRevision

                THROW 51456,
                    N''Unexpected final terms revision.'',
                    1;


            --------------------------------------------------
            -- 12. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                @FinalTermsRevision
                    AS termsRevision,

                @LastProposedByUserId
                    AS lastProposedByUserId,

                @AgreedAtUtc
                    AS agreedAtUtc,

                ''AwaitingHandover''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- FailCollaborativeDeal
    EXEC sys.sp_executesql N'
    CREATE PROCEDURE dbo.FailCollaborativeDeal
        @CollaborativeDealId BIGINT,
        @ActorUserId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
           OR @ActorUserId IS NULL
            THROW 51462,
                N''Invalid failure parameters.'',
                1;


        --------------------------------------------------
        -- 2. Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);
        DECLARE @DealStatus VARCHAR(64);

        DECLARE @DelivererUserId BIGINT;
        DECLARE @RequesterUserId BIGINT;

        DECLARE @CurrentTermsRevision BIGINT;
        DECLARE @FinalTermsRevision BIGINT;


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 3. Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId
            FROM dbo.CollaborativeDeal
            WHERE collaborativeDealId =
                @CollaborativeDealId;

            IF @InteractionContextId IS NULL
                THROW 51463,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- 4. Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            --------------------------------------------------
            -- 5. Визначення учасників взаємодії
            --------------------------------------------------

            SELECT
                @DelivererUserId =
                    authorDelivererUserId
            FROM dbo.DelivererIntent
                WITH (UPDLOCK, HOLDLOCK)
            WHERE delivererIntentId = @DId;


            SELECT
                @RequesterUserId =
                    authorDeliveryRequesterUserId
            FROM dbo.DeliveryRequesterIntent
                WITH (UPDLOCK, HOLDLOCK)
            WHERE deliveryRequesterIntentId = @RId;


            IF @DelivererUserId IS NULL
               OR @RequesterUserId IS NULL
                THROW 51464,
                    N''Linked intents not found.'',
                    1;


            IF @ActorUserId NOT IN
                (@DelivererUserId, @RequesterUserId)
                THROW 51465,
                    N''Actor does not participate in the interaction.'',
                    1;


            --------------------------------------------------
            -- 6. Блокування та перевірка стану угоди
            --------------------------------------------------

            SELECT
                @DealStatus =
                    dealExecutionStatusCode
            FROM dbo.CollaborativeDeal
                WITH (UPDLOCK, HOLDLOCK)
            WHERE collaborativeDealId =
                    @CollaborativeDealId
              AND interactionContextId =
                    @InteractionContextId;


            IF @DealStatus IS NULL
                THROW 51466,
                    N''CollaborativeDeal changed or disappeared.'',
                    1;


            IF @DealStatus <> ''Draft''
                THROW 51467,
                    N''Only draft cancellation is currently supported.'',
                    1;


            --------------------------------------------------
            -- 7. Поточна редакція умов
            --------------------------------------------------

            SELECT
                @CurrentTermsRevision =
                    COUNT_BIG(*) + 1
            FROM dbo.CollaborativeDealHistory
            WHERE collaborativeDealId =
                    @CollaborativeDealId
              AND dealExecutionStatusCode = ''Draft'';


            --------------------------------------------------
            -- 8. Скасування чернетки
            --------------------------------------------------

            UPDATE dbo.CollaborativeDeal
            SET
                dealExecutionStatusCode = ''Failed''
            WHERE collaborativeDealId =
                    @CollaborativeDealId
              AND dealExecutionStatusCode = ''Draft'';


            IF @@ROWCOUNT <> 1
                THROW 51468,
                    N''Draft cancellation failed.'',
                    1;


            --------------------------------------------------
            -- 9. Перевірка збереження редакції
            --------------------------------------------------

            SELECT
                @FinalTermsRevision =
                    COUNT_BIG(*)
            FROM dbo.CollaborativeDealHistory
            WHERE collaborativeDealId =
                    @CollaborativeDealId
              AND dealExecutionStatusCode = ''Draft'';


            IF @FinalTermsRevision <>
               @CurrentTermsRevision
                THROW 51469,
                    N''Unexpected temporal revision change.'',
                    1;


            --------------------------------------------------
            -- 10. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                @FinalTermsRevision
                    AS termsRevision,

                ''Failed''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- vCollaborativeDealDetails
    EXEC sys.sp_executesql N'
    CREATE VIEW dbo.vCollaborativeDealDetails
    AS

    SELECT

        --------------------------------------------------
        -- 1. Основні атрибути угоди
        --------------------------------------------------

        cd.collaborativeDealId,

        cd.receivingCoordinates,
        cd.destinationCoordinates,
        cd.finalPriceWithoutCommission,

        cd.createdAtUtc,
        cd.agreedAtUtc,

        cd.dealExecutionStatusCode,

        cd.senderUserId,
        cd.receiverUserId,
        cd.lastProposedByUserId,

        cd.interactionContextId,

        cd.validFrom,
        cd.validTo,


        --------------------------------------------------
        -- 2. Пов''язані наміри та їхні автори
        --------------------------------------------------

        ic.delivererIntentId,
        ic.deliveryRequesterIntentId,

        d.authorDelivererUserId
            AS delivererUserId,

        r.authorDeliveryRequesterUserId
            AS deliveryRequesterUserId,


        --------------------------------------------------
        -- 3. Похідна редакція умов
        --------------------------------------------------

        revisions.historicalDraftCount
        +
        CASE
            WHEN cd.dealExecutionStatusCode = ''Draft''
                THEN 1
            ELSE 0
        END
            AS termsRevision,


        --------------------------------------------------
        -- 4. Погодження кур''єром
        --------------------------------------------------

        CAST(
            CASE
                WHEN cd.agreedAtUtc IS NOT NULL
                    THEN 1

                WHEN cd.lastProposedByUserId =
                     d.authorDelivererUserId
                    THEN 1

                ELSE 0
            END
            AS BIT
        ) AS delivererAccepted,


        --------------------------------------------------
        -- 5. Погодження замовником
        --------------------------------------------------

        CAST(
            CASE
                WHEN cd.agreedAtUtc IS NOT NULL
                    THEN 1

                WHEN cd.lastProposedByUserId =
                     r.authorDeliveryRequesterUserId
                    THEN 1

                ELSE 0
            END
            AS BIT
        ) AS deliveryRequesterAccepted,


        --------------------------------------------------
        -- 6. Факт остаточного погодження
        --------------------------------------------------

        CAST(
            CASE
                WHEN cd.agreedAtUtc IS NOT NULL
                    THEN 1
                ELSE 0
            END
            AS BIT
        ) AS isAgreed,


        --------------------------------------------------
        -- 7. Активність угоди
        --------------------------------------------------

        CAST(
            CASE
                WHEN cd.dealExecutionStatusCode
                    NOT IN (''Fulfilled'', ''Failed'')
                    THEN 1
                ELSE 0
            END
            AS BIT
        ) AS isActive,


        --------------------------------------------------
        -- 8. Остаточний стан угоди
        --------------------------------------------------

        CAST(
            CASE
                WHEN cd.dealExecutionStatusCode
                    IN (''Fulfilled'', ''Failed'')
                    THEN 1
                ELSE 0
            END
            AS BIT
        ) AS isFinalized


    FROM dbo.CollaborativeDeal AS cd

    INNER JOIN dbo.InteractionContext AS ic
        ON ic.interactionContextId =
           cd.interactionContextId

    INNER JOIN dbo.DelivererIntent AS d
        ON d.delivererIntentId =
           ic.delivererIntentId

    INNER JOIN dbo.DeliveryRequesterIntent AS r
        ON r.deliveryRequesterIntentId =
           ic.deliveryRequesterIntentId

    CROSS APPLY
    (
        SELECT
            COUNT_BIG(*) AS historicalDraftCount

        FROM dbo.CollaborativeDealHistory AS h

        WHERE h.collaborativeDealId =
              cd.collaborativeDealId

          AND h.dealExecutionStatusCode = ''Draft''

    ) AS revisions;
';

    -- TR_CollaborativeDeal_ImmutableFinalStates
    EXEC sys.sp_executesql N'
    ALTER TRIGGER dbo.TR_CollaborativeDeal_ImmutableFinalStates
    ON dbo.CollaborativeDeal
    AFTER UPDATE, DELETE
    AS
    BEGIN
        SET NOCOUNT ON;


        --------------------------------------------------
        -- 1. Заборона фізичного видалення угод
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM deleted AS d
            LEFT JOIN inserted AS i
                ON i.collaborativeDealId =
                   d.collaborativeDealId
            WHERE i.collaborativeDealId IS NULL
        )
            THROW 51482,
                N''CollaborativeDeal cannot be deleted.'',
                1;


        --------------------------------------------------
        -- 2. Незмінність фінальних станів
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM deleted
            WHERE dealExecutionStatusCode
                IN (''Fulfilled'', ''Failed'')
        )
            THROW 51483,
                N''Finalized deals are immutable.'',
                1;


        --------------------------------------------------
        -- 3. Незмінність системних атрибутів
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i
            INNER JOIN deleted AS d
                ON d.collaborativeDealId =
                   i.collaborativeDealId
            WHERE
                i.interactionContextId <>
                    d.interactionContextId
                OR
                i.createdAtUtc <>
                    d.createdAtUtc
        )
            THROW 51484,
                N''Deal identity attributes are immutable.'',
                1;


        --------------------------------------------------
        -- 4. Допустимі переходи станів
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i
            INNER JOIN deleted AS d
                ON d.collaborativeDealId =
                   i.collaborativeDealId

            WHERE NOT
            (
                (
                    d.dealExecutionStatusCode = ''Draft''
                    AND i.dealExecutionStatusCode IN
                    (
                        ''Draft'',
                        ''AwaitingHandover'',
                        ''Failed''
                    )
                )

                OR

                (
                    d.dealExecutionStatusCode =
                        ''AwaitingHandover''
                    AND i.dealExecutionStatusCode =
                        ''InTransit''
                )

                OR

                (
                    d.dealExecutionStatusCode =
                        ''InTransit''
                    AND i.dealExecutionStatusCode =
                        ''AwaitingPayout''
                )

                OR

                (
                    d.dealExecutionStatusCode =
                        ''AwaitingPayout''
                    AND i.dealExecutionStatusCode =
                        ''Fulfilled''
                )
            )
        )
            THROW 51485,
                N''Invalid deal state transition.'',
                1;


        --------------------------------------------------
        -- 5. Перевірка автора пропозиції
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i

            INNER JOIN dbo.InteractionContext AS ic
                ON ic.interactionContextId =
                   i.interactionContextId

            INNER JOIN dbo.DelivererIntent AS di
                ON di.delivererIntentId =
                   ic.delivererIntentId

            INNER JOIN dbo.DeliveryRequesterIntent AS ri
                ON ri.deliveryRequesterIntentId =
                   ic.deliveryRequesterIntentId

            WHERE i.lastProposedByUserId NOT IN
            (
                di.authorDelivererUserId,
                ri.authorDeliveryRequesterUserId
            )
        )
            THROW 51486,
                N''Invalid deal proposal author.'',
                1;


        --------------------------------------------------
        -- 6. Заборона порожніх редакцій чернетки
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i
            INNER JOIN deleted AS d
                ON d.collaborativeDealId =
                   i.collaborativeDealId

            WHERE d.dealExecutionStatusCode = ''Draft''
              AND i.dealExecutionStatusCode = ''Draft''

              AND ISNULL(
                    i.receivingCoordinates.STEquals(
                        d.receivingCoordinates
                    ), 0
                  ) = 1

              AND ISNULL(
                    i.destinationCoordinates.STEquals(
                        d.destinationCoordinates
                    ), 0
                  ) = 1

              AND i.finalPriceWithoutCommission =
                  d.finalPriceWithoutCommission

              AND i.senderUserId =
                  d.senderUserId

              AND i.receiverUserId =
                  d.receiverUserId
        )
            THROW 51487,
                N''Draft update must change its terms.'',
                1;


        --------------------------------------------------
        -- 7. Незмінність умов поза редагуванням Draft
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i
            INNER JOIN deleted AS d
                ON d.collaborativeDealId =
                   i.collaborativeDealId

            WHERE NOT
            (
                d.dealExecutionStatusCode = ''Draft''
                AND
                i.dealExecutionStatusCode = ''Draft''
            )

            AND
            (
                ISNULL(
                    i.receivingCoordinates.STEquals(
                        d.receivingCoordinates
                    ), 0
                ) <> 1

                OR

                ISNULL(
                    i.destinationCoordinates.STEquals(
                        d.destinationCoordinates
                    ), 0
                ) <> 1

                OR

                i.finalPriceWithoutCommission <>
                    d.finalPriceWithoutCommission

                OR

                i.senderUserId <> d.senderUserId

                OR

                i.receiverUserId <> d.receiverUserId

                OR

                i.lastProposedByUserId <>
                    d.lastProposedByUserId
            )
        )
            THROW 51488,
                N''Deal terms cannot be changed outside draft editing.'',
                1;


        --------------------------------------------------
        -- 8. Незмінність факту погодження та секретів
        --
        -- Єдиний виняток:
        -- Draft -> AwaitingHandover.
        --
        -- EXCEPT забезпечує порівняння
        -- з урахуванням NULL.
        --------------------------------------------------

        IF EXISTS
        (
            SELECT 1
            FROM inserted AS i
            INNER JOIN deleted AS d
                ON d.collaborativeDealId =
                   i.collaborativeDealId

            WHERE NOT
            (
                d.dealExecutionStatusCode = ''Draft''
                AND
                i.dealExecutionStatusCode =
                    ''AwaitingHandover''
            )

            AND EXISTS
            (
                SELECT
                    i.agreedAtUtc,

                    i.pickupConfirmationTokenEncrypted,
                    DATALENGTH(
                        i.pickupConfirmationTokenEncrypted
                    ),

                    i.deliveryConfirmationTokenEncrypted,
                    DATALENGTH(
                        i.deliveryConfirmationTokenEncrypted
                    )

                EXCEPT

                SELECT
                    d.agreedAtUtc,

                    d.pickupConfirmationTokenEncrypted,
                    DATALENGTH(
                        d.pickupConfirmationTokenEncrypted
                    ),

                    d.deliveryConfirmationTokenEncrypted,
                    DATALENGTH(
                        d.deliveryConfirmationTokenEncrypted
                    )
            )
        )
            THROW 51489,
                N''Agreement timestamp and tokens are immutable.'',
                1;

    END;
';

    -- SendUserMessage
    EXEC sys.sp_executesql N'
    ALTER PROCEDURE dbo.SendUserMessage
        @InteractionContextId BIGINT,
        @AuthorUserId BIGINT,
        @MessageText NVARCHAR(MAX)
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @InteractionContextId IS NULL
           OR @AuthorUserId IS NULL
           OR @MessageText IS NULL

            THROW 51040,
                N''Invalid message parameters.'',
                1;


        --------------------------------------------------
        -- 2. Локальні змінні
        --------------------------------------------------

        DECLARE
            @InteractionStatusCode VARCHAR(64),
            @InteractionStartAtUtc DATETIME2(7),

            @DelivererIntentId BIGINT,
            @DeliveryRequesterIntentId BIGINT,

            @DelivererUserId BIGINT,
            @DeliveryRequesterUserId BIGINT,

            @SenderUserId BIGINT,
            @ReceiverUserId BIGINT,
            @AdditionalParticipantUserId BIGINT,

            @MaxNumberMessages INT,
            @PolicyFound BIT = 0,

            @MessageCount BIGINT,
            @NewMessageId BIGINT;


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 3. Отримання та блокування взаємодії
            --------------------------------------------------

            SELECT
                @InteractionStatusCode =
                    ic.interactionStatusCode,

                @InteractionStartAtUtc =
                    ic.interactionStartAtUtc,

                @DelivererIntentId =
                    ic.delivererIntentId,

                @DeliveryRequesterIntentId =
                    ic.deliveryRequesterIntentId,

                @DelivererUserId =
                    d.authorDelivererUserId,

                @DeliveryRequesterUserId =
                    r.authorDeliveryRequesterUserId

            FROM dbo.InteractionContext AS ic
                WITH (UPDLOCK, HOLDLOCK)

            INNER JOIN dbo.DelivererIntent AS d
                ON d.delivererIntentId =
                   ic.delivererIntentId

            INNER JOIN dbo.DeliveryRequesterIntent AS r
                ON r.deliveryRequesterIntentId =
                   ic.deliveryRequesterIntentId

            WHERE ic.interactionContextId =
                @InteractionContextId;


            IF @InteractionStatusCode IS NULL

                THROW 51041,
                    N''Interaction context not found.'',
                    1;


            --------------------------------------------------
            -- 4. Отримання останньої укладеної угоди
            --
            -- Draft та Failed до погодження
            -- не впливають на склад учасників чату.
            --------------------------------------------------

            SELECT TOP (1)

                @SenderUserId =
                    cd.senderUserId,

                @ReceiverUserId =
                    cd.receiverUserId

            FROM dbo.CollaborativeDeal AS cd

            WHERE cd.interactionContextId =
                    @InteractionContextId

              AND cd.agreedAtUtc IS NOT NULL

            ORDER BY
                cd.createdAtUtc DESC,
                cd.collaborativeDealId DESC;


            --------------------------------------------------
            -- 5. Визначення третього учасника
            --
            -- Замовник є однією зі сторін
            -- передачі посилки.
            --------------------------------------------------

            SET @AdditionalParticipantUserId =
                CASE

                    WHEN @SenderUserId =
                         @DeliveryRequesterUserId

                        THEN @ReceiverUserId

                    WHEN @ReceiverUserId =
                         @DeliveryRequesterUserId

                        THEN @SenderUserId

                    ELSE NULL

                END;


            --------------------------------------------------
            -- 6. Перевірка належності до чату
            --------------------------------------------------

            IF @AuthorUserId <> @DelivererUserId

               AND @AuthorUserId <>
                   @DeliveryRequesterUserId

               AND
               (
                   @AdditionalParticipantUserId IS NULL

                   OR @AuthorUserId <>
                      @AdditionalParticipantUserId
               )

                THROW 51042,
                    N''User is not a participant of this chat.'',
                    1;


            --------------------------------------------------
            -- 7. Перевірка архівності взаємодії
            --
            -- Fulfilled в іншій взаємодії
            -- блокує надсилання повідомлень.
            --------------------------------------------------

            IF EXISTS
            (
                SELECT 1

                FROM dbo.InteractionContext AS related

                INNER JOIN dbo.CollaborativeDeal AS cd
                    WITH (HOLDLOCK)

                    ON cd.interactionContextId =
                       related.interactionContextId

                WHERE related.interactionContextId <>
                        @InteractionContextId

                  AND
                  (
                      related.delivererIntentId =
                          @DelivererIntentId

                      OR

                      related.deliveryRequesterIntentId =
                          @DeliveryRequesterIntentId
                  )

                  AND cd.dealExecutionStatusCode =
                      ''Fulfilled''
            )

                THROW 51045,
                    N''Cannot send messages to an archived interaction.'',
                    1;


            --------------------------------------------------
            -- 8. Отримання історичної політики чату
            --------------------------------------------------

            SELECT
                @MaxNumberMessages =
                    p.maxNumberMessages,

                @PolicyFound = 1

            FROM dbo.ChatAccessPolicy
                FOR SYSTEM_TIME ALL AS p

            WHERE p.interactionStatusCode =
                    @InteractionStatusCode

              AND @InteractionStartAtUtc >= p.validFrom
              AND @InteractionStartAtUtc < p.validTo;


            IF @PolicyFound = 0

                THROW 51043,
                    N''Chat access policy not found.'',
                    1;


            --------------------------------------------------
            -- 9. Перевірка ліміту повідомлень
            --------------------------------------------------

            IF @MaxNumberMessages IS NOT NULL
            BEGIN

                SELECT
                    @MessageCount = COUNT_BIG(*)

                FROM dbo.UserMessage

                WHERE interactionContextId =
                    @InteractionContextId;


                IF @MessageCount >= @MaxNumberMessages

                    THROW 51044,
                        N''Chat message limit exceeded.'',
                        1;

            END;


            --------------------------------------------------
            -- 10. Створення повідомлення
            --------------------------------------------------

            INSERT INTO dbo.UserMessage
            (
                userMessageText,
                interactionContextId,
                authorUserId
            )
            VALUES
            (
                @MessageText,
                @InteractionContextId,
                @AuthorUserId
            );


            SET @NewMessageId =
                CAST(SCOPE_IDENTITY() AS BIGINT);


            --------------------------------------------------
            -- 11. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @NewMessageId
                    AS userMessageId,

                @InteractionContextId
                    AS interactionContextId,

                @AuthorUserId
                    AS authorUserId;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- CreatePaymentOperationAttempt
    EXEC sys.sp_executesql N'
    ALTER PROCEDURE dbo.CreatePaymentOperationAttempt
        @CollaborativeDealId BIGINT,
        @OperationType VARCHAR(24),
        @Amount DECIMAL(18,2),
        @Currency CHAR(3),
        @OrderReference NVARCHAR(100),
        @AttemptStatusCode VARCHAR(64),

        @PaymentMethodId BIGINT = NULL,
        @ProviderStatus VARCHAR(50) = NULL,
        @ReasonCode INT = NULL
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
           OR @OperationType IS NULL
           OR @Amount IS NULL
           OR @Currency IS NULL
           OR @OrderReference IS NULL
           OR @AttemptStatusCode IS NULL

            THROW 51220,
                N''Invalid payment attempt parameters.'',
                1;


        --------------------------------------------------
        -- 2. Локальні змінні
        --------------------------------------------------

        DECLARE
            @ExpectedPayerUserId BIGINT,
            @AgreedAtUtc DATETIME2(7),
            @NewAttemptId BIGINT;


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- 3. Отримання угоди та її замовника
            --------------------------------------------------

            SELECT

                @ExpectedPayerUserId =
                    r.authorDeliveryRequesterUserId,

                @AgreedAtUtc =
                    cd.agreedAtUtc

            FROM dbo.CollaborativeDeal AS cd
                WITH (UPDLOCK, HOLDLOCK)

            INNER JOIN dbo.InteractionContext AS ic
                ON ic.interactionContextId =
                   cd.interactionContextId

            INNER JOIN dbo.DeliveryRequesterIntent AS r
                ON r.deliveryRequesterIntentId =
                   ic.deliveryRequesterIntentId

            WHERE cd.collaborativeDealId =
                @CollaborativeDealId;


            IF @ExpectedPayerUserId IS NULL

                THROW 51221,
                    N''Collaborative deal not found.'',
                    1;


            --------------------------------------------------
            -- 4. Перевірка факту укладання угоди
            --
            -- Неукладені угоди не можуть мати
            -- платіжних операцій.
            --------------------------------------------------

            IF @AgreedAtUtc IS NULL

                THROW 51512,
                    N''Payment attempts require an agreed deal.'',
                    1;


            --------------------------------------------------
            -- 5. Перевірка власника платіжного методу
            --
            -- disabledAtUtc навмисно не враховується:
            -- процедура реєструє історичну спробу.
            --------------------------------------------------

            IF @PaymentMethodId IS NOT NULL
            BEGIN

                IF NOT EXISTS
                (
                    SELECT 1

                    FROM dbo.UserPaymentMethod AS pm
                        WITH (UPDLOCK, HOLDLOCK)

                    WHERE pm.paymentMethodId =
                            @PaymentMethodId

                      AND pm.userId =
                            @ExpectedPayerUserId
                )

                    THROW 51222,
                        N''Payment method does not belong to the delivery requester.'',
                        1;

            END;


            --------------------------------------------------
            -- 6. Створення запису платіжної спроби
            --------------------------------------------------

            INSERT INTO dbo.PaymentOperationAttempt
            (
                operationType,
                amount,
                currency,
                orderReference,
                providerStatus,
                reasonCode,
                attemptStatusCode,
                paymentMethodId,
                collaborativeDealId
            )
            VALUES
            (
                @OperationType,
                @Amount,
                @Currency,
                @OrderReference,
                @ProviderStatus,
                @ReasonCode,
                @AttemptStatusCode,
                @PaymentMethodId,
                @CollaborativeDealId
            );


            SET @NewAttemptId =
                CAST(SCOPE_IDENTITY() AS BIGINT);


            --------------------------------------------------
            -- 7. Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @NewAttemptId
                    AS attemptId,

                @CollaborativeDealId
                    AS collaborativeDealId,

                @PaymentMethodId
                    AS paymentMethodId;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- ConfirmDealHandover
    EXEC sys.sp_executesql N'

    CREATE PROCEDURE dbo.ConfirmDealHandover
        @CollaborativeDealId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
            THROW 51522,
                N''CollaborativeDealId is required.'',
                1;


        --------------------------------------------------
        -- Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId

            FROM dbo.CollaborativeDeal

            WHERE collaborativeDealId =
                @CollaborativeDealId;


            IF @InteractionContextId IS NULL
                THROW 51523,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            IF @InteractionStatus <> ''Mutual''
                THROW 51524,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- Атомарний перехід стану
            --------------------------------------------------

            UPDATE dbo.CollaborativeDeal

            SET
                dealExecutionStatusCode =
                    ''InTransit''

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND interactionContextId =
                    @InteractionContextId

              AND dealExecutionStatusCode =
                    ''AwaitingHandover'';


            IF @@ROWCOUNT <> 1
                THROW 51525,
                    N''Invalid deal state for this operation.'',
                    1;


            --------------------------------------------------
            -- Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                ''InTransit''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- ConfirmDealDelivery
    EXEC sys.sp_executesql N'

    CREATE PROCEDURE dbo.ConfirmDealDelivery
        @CollaborativeDealId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
            THROW 51522,
                N''CollaborativeDealId is required.'',
                1;


        --------------------------------------------------
        -- Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId

            FROM dbo.CollaborativeDeal

            WHERE collaborativeDealId =
                @CollaborativeDealId;


            IF @InteractionContextId IS NULL
                THROW 51523,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            IF @InteractionStatus <> ''Mutual''
                THROW 51524,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- Атомарний перехід стану
            --------------------------------------------------

            UPDATE dbo.CollaborativeDeal

            SET
                dealExecutionStatusCode =
                    ''AwaitingPayout''

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND interactionContextId =
                    @InteractionContextId

              AND dealExecutionStatusCode =
                    ''InTransit'';


            IF @@ROWCOUNT <> 1
                THROW 51525,
                    N''Invalid deal state for this operation.'',
                    1;


            --------------------------------------------------
            -- Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                ''AwaitingPayout''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- CompleteCollaborativeDeal
    EXEC sys.sp_executesql N'

    CREATE PROCEDURE dbo.CompleteCollaborativeDeal
        @CollaborativeDealId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;


        --------------------------------------------------
        -- Валідація параметрів
        --------------------------------------------------

        IF @CollaborativeDealId IS NULL
            THROW 51522,
                N''CollaborativeDealId is required.'',
                1;


        --------------------------------------------------
        -- Локальні змінні
        --------------------------------------------------

        DECLARE @InteractionContextId BIGINT;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @InteractionStatus VARCHAR(64);


        BEGIN TRY
            BEGIN TRANSACTION;


            --------------------------------------------------
            -- Визначення контексту взаємодії
            --------------------------------------------------

            SELECT
                @InteractionContextId =
                    interactionContextId

            FROM dbo.CollaborativeDeal

            WHERE collaborativeDealId =
                @CollaborativeDealId;


            IF @InteractionContextId IS NULL
                THROW 51523,
                    N''CollaborativeDeal not found.'',
                    1;


            --------------------------------------------------
            -- Блокування пов''язаних Order
            --------------------------------------------------

            EXEC dbo.AcquireInteractionIntentLocks
                @InteractionContextId =
                    @InteractionContextId,

                @DelivererIntentId =
                    @DId OUTPUT,

                @DeliveryRequesterIntentId =
                    @RId OUTPUT,

                @RequestInitiatorCode =
                    @InitiatorCode OUTPUT,

                @InteractionStatusCode =
                    @InteractionStatus OUTPUT;


            IF @InteractionStatus <> ''Mutual''
                THROW 51524,
                    N''Interaction must be Mutual.'',
                    1;


            --------------------------------------------------
            -- Атомарний перехід стану
            --------------------------------------------------

            UPDATE dbo.CollaborativeDeal

            SET
                dealExecutionStatusCode =
                    ''Fulfilled''

            WHERE collaborativeDealId =
                    @CollaborativeDealId

              AND interactionContextId =
                    @InteractionContextId

              AND dealExecutionStatusCode =
                    ''AwaitingPayout'';


            IF @@ROWCOUNT <> 1
                THROW 51525,
                    N''Invalid deal state for this operation.'',
                    1;


            --------------------------------------------------
            -- Завершення операції
            --------------------------------------------------

            COMMIT TRANSACTION;

            SELECT
                @CollaborativeDealId
                    AS collaborativeDealId,

                ''Fulfilled''
                    AS dealExecutionStatusCode;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
';

    -- 4. Backend permissions
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51530, N''Incorrect target database.'', 1;

IF @@TRANCOUNT <> 1
    THROW 51531, N''Expected outer migration transaction.'', 1;

DECLARE @IsImpersonated BIT = 0;

BEGIN TRY
    BEGIN TRANSACTION;


    --------------------------------------------------
    -- 1. Видалення старого поколоночного дозволу
    --------------------------------------------------

    REVOKE UPDATE
    ON OBJECT::dbo.CollaborativeDeal
        (dealExecutionStatusCode)
    FROM [passby_backend];


    --------------------------------------------------
    -- 2. Захист актуальної та історичної таблиць
    --------------------------------------------------

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.CollaborativeDeal
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.CollaborativeDealHistory
    TO [passby_backend];


    --------------------------------------------------
    -- 3. Представлення доступні лише для читання
    --------------------------------------------------

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.vCollaborativeDealDetails
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.vDelivererIntentDetails
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.vDeliveryRequesterIntentDetails
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.vInteractionContextDetails
    TO [passby_backend];


    --------------------------------------------------
    -- 4. Дозволи на операції формування угоди
    --------------------------------------------------

    GRANT EXECUTE
    ON OBJECT::dbo.CreateCollaborativeDeal
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.UpdateCollaborativeDealDraft
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.AcceptCollaborativeDeal
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.FailCollaborativeDeal
    TO [passby_backend];


    --------------------------------------------------
    -- 5. Дозволи на операції виконання угоди
    --------------------------------------------------

    GRANT EXECUTE
    ON OBJECT::dbo.ConfirmDealHandover
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.ConfirmDealDelivery
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.CompleteCollaborativeDeal
    TO [passby_backend];


    --------------------------------------------------
    -- 6. Захист внутрішньої допоміжної процедури
    --------------------------------------------------

    DENY EXECUTE
    ON OBJECT::dbo.AcquireInteractionIntentLocks
    TO [passby_backend];


    --------------------------------------------------
    -- 7. Формування очікуваної матриці доступу
    --------------------------------------------------

    DECLARE @PermissionChecks TABLE
    (
        objectName NVARCHAR(256) NOT NULL,
        columnName SYSNAME NULL,
        permissionName VARCHAR(32) NOT NULL,
        expectedPermission INT NOT NULL,
        actualPermission INT NULL
    );


    -- Права на таблиці та представлення.

    INSERT INTO @PermissionChecks
    (
        objectName,
        permissionName,
        expectedPermission
    )
    SELECT
        objects.objectName,
        permissions.permissionName,
        permissions.expectedPermission
    FROM
    (
        VALUES
            (N''dbo.CollaborativeDeal''),
            (N''dbo.CollaborativeDealHistory''),
            (N''dbo.vCollaborativeDealDetails''),
            (N''dbo.vDelivererIntentDetails''),
            (N''dbo.vDeliveryRequesterIntentDetails''),
            (N''dbo.vInteractionContextDetails''),
            (N''dbo.PaymentOperationAttempt''),
            (N''dbo.UserMessage'')
    ) AS objects(objectName)
    CROSS JOIN
    (
        VALUES
            (''SELECT'', 1),
            (''INSERT'', 0),
            (''UPDATE'', 0),
            (''DELETE'', 0)
    ) AS permissions
    (
        permissionName,
        expectedPermission
    );


    -- Перевірка поколоночних дозволів UPDATE.

    INSERT INTO @PermissionChecks
    (
        objectName,
        columnName,
        permissionName,
        expectedPermission
    )
    SELECT
        N''dbo.'' + o.name,
        c.name,
        ''UPDATE'',
        0
    FROM sys.columns AS c
    INNER JOIN sys.objects AS o
        ON o.object_id = c.object_id
    WHERE o.schema_id = SCHEMA_ID(N''dbo'')
      AND o.name IN
      (
          ''CollaborativeDeal'',
          ''CollaborativeDealHistory'',
          ''vCollaborativeDealDetails'',
          ''vDelivererIntentDetails'',
          ''vDeliveryRequesterIntentDetails'',
          ''vInteractionContextDetails'',
          ''PaymentOperationAttempt'',
          ''UserMessage''
      );


    -- Права на доменні процедури.

    INSERT INTO @PermissionChecks
    (
        objectName,
        permissionName,
        expectedPermission
    )
    VALUES
        (N''dbo.CreateCollaborativeDeal'', ''EXECUTE'', 1),
        (N''dbo.UpdateCollaborativeDealDraft'', ''EXECUTE'', 1),
        (N''dbo.AcceptCollaborativeDeal'', ''EXECUTE'', 1),
        (N''dbo.FailCollaborativeDeal'', ''EXECUTE'', 1),

        (N''dbo.ConfirmDealHandover'', ''EXECUTE'', 1),
        (N''dbo.ConfirmDealDelivery'', ''EXECUTE'', 1),
        (N''dbo.CompleteCollaborativeDeal'', ''EXECUTE'', 1),

        (N''dbo.SendUserMessage'', ''EXECUTE'', 1),
        (N''dbo.CreatePaymentOperationAttempt'', ''EXECUTE'', 1),

        (N''dbo.AcquireInteractionIntentLocks'', ''EXECUTE'', 0);


    -- Перевірка адміністративних дозволів.

    INSERT INTO @PermissionChecks
    (
        objectName,
        permissionName,
        expectedPermission
    )
    VALUES
        (N''dbo.CollaborativeDeal'', ''CONTROL'', 0),
        (N''dbo.CollaborativeDeal'', ''ALTER'', 0),

        (N''dbo.CollaborativeDealHistory'', ''CONTROL'', 0),
        (N''dbo.CollaborativeDealHistory'', ''ALTER'', 0);


    --------------------------------------------------
    -- 8. Перевірка від імені backend-користувача
    --------------------------------------------------

    EXECUTE AS USER = ''passby_backend'';

    SET @IsImpersonated = 1;

    UPDATE @PermissionChecks
    SET actualPermission =
        CASE
            WHEN columnName IS NULL
                THEN HAS_PERMS_BY_NAME
                (
                    objectName,
                    ''OBJECT'',
                    permissionName
                )

            ELSE HAS_PERMS_BY_NAME
                (
                    objectName,
                    ''OBJECT'',
                    permissionName,
                    columnName,
                    ''COLUMN''
                )
        END;

    REVERT;

    SET @IsImpersonated = 0;


    --------------------------------------------------
    -- 9. Перевірка системного захисту Temporal History
    --------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.tables
        WHERE object_id =
            OBJECT_ID(N''dbo.CollaborativeDeal'')

          AND temporal_type = 2

          AND history_table_id =
            OBJECT_ID(N''dbo.CollaborativeDealHistory'')
    )
        THROW 51533,
            N''CollaborativeDeal system versioning is not active.'',
            1;


    --------------------------------------------------
    -- 10. Перевірка явно встановленого DENY
    --     на історичну таблицю
    --------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM
        (
            VALUES
                (''INSERT''),
                (''UPDATE''),
                (''DELETE'')
        ) AS requiredPermissions(permissionName)

        WHERE NOT EXISTS
        (
            SELECT 1
            FROM sys.database_permissions AS dp

            WHERE dp.grantee_principal_id =
                DATABASE_PRINCIPAL_ID(N''passby_backend'')

              AND dp.class = 1

              AND dp.major_id =
                OBJECT_ID(N''dbo.CollaborativeDealHistory'')

              AND dp.minor_id = 0

              AND dp.permission_name =
                requiredPermissions.permissionName

              AND dp.state = ''D''
        )
    )
        THROW 51534,
            N''Explicit DML denial on history table not found.'',
            1;


    --------------------------------------------------
    -- 11. Особливість перевірки INSERT
    --     для Temporal History
    --------------------------------------------------

    SELECT
        objectName,
        permissionName,
        expectedPermission,
        actualPermission,

        CASE
            WHEN actualPermission = 1
                THEN N''Temporal system protection applies.''
            WHEN actualPermission = 0
                THEN N''Permission denied.''
            ELSE N''Permission check failed.''
        END AS protectionNote

    FROM @PermissionChecks

    WHERE objectName =
        N''dbo.CollaborativeDealHistory''

      AND permissionName = ''INSERT''
      AND columnName IS NULL;


    --------------------------------------------------
    -- 12. Перевірка відповідності очікуваним правам
    --
    -- Єдиний допустимий виняток:
    -- HAS_PERMS_BY_NAME повертає 1 для INSERT
    -- в активну Temporal History Table.
    --
    -- Явний DENY та SYSTEM_VERSIONING
    -- перевірені вище.
    --------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM @PermissionChecks

        WHERE
        (
            actualPermission IS NULL

            OR actualPermission <> expectedPermission
        )

        AND NOT
        (
            objectName = N''dbo.CollaborativeDealHistory''

            AND columnName IS NULL

            AND permissionName = ''INSERT''

            AND expectedPermission = 0

            AND ISNULL(actualPermission, -1) = 1
        )
    )
    BEGIN

        SELECT *
        FROM @PermissionChecks

        WHERE
        (
            actualPermission IS NULL

            OR actualPermission <> expectedPermission
        )

        AND NOT
        (
            objectName = N''dbo.CollaborativeDealHistory''

            AND columnName IS NULL

            AND permissionName = ''INSERT''

            AND expectedPermission = 0

            AND ISNULL(actualPermission, -1) = 1
        );

        THROW 51532,
            N''Backend permissions do not match the expected model.'',
            1;

    END;


    --------------------------------------------------
    -- 13. Завершення міграції
    --------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        N''Backend permissions staged (outer commit pending).''
        AS result;


    --------------------------------------------------
    -- 14. Результати перевірок
    --------------------------------------------------

    SELECT
        objectName,
        permissionName,
        expectedPermission,
        actualPermission,

        CASE
            WHEN actualPermission = expectedPermission
                THEN N''Passed''

            WHEN objectName =
                    N''dbo.CollaborativeDealHistory''
                 AND columnName IS NULL
                 AND permissionName = ''INSERT''
                 AND expectedPermission = 0
                 AND actualPermission = 1
                THEN N''Protected by system versioning''

            ELSE N''Failed''

        END AS checkResult

    FROM @PermissionChecks

    WHERE columnName IS NULL

    ORDER BY
        objectName,
        permissionName;


    SELECT
        COUNT_BIG(*) AS totalPermissionChecks,

        COUNT_BIG
        (
            CASE
                WHEN actualPermission = expectedPermission
                    THEN 1
            END
        ) AS successfulPermissionChecks,

        COUNT_BIG
        (
            CASE
                WHEN objectName =
                        N''dbo.CollaborativeDealHistory''
                     AND columnName IS NULL
                     AND permissionName = ''INSERT''
                     AND expectedPermission = 0
                     AND actualPermission = 1
                    THEN 1
            END
        ) AS temporalProtectedChecks

    FROM @PermissionChecks;

END TRY
BEGIN CATCH

    IF @IsImpersonated = 1
        REVERT;

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;
';

    -- 5. MS_Description
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 52000, N''Incorrect target database.'', 1;

IF @@TRANCOUNT <> 1
    THROW 52001, N''Expected outer migration transaction.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Documentation TABLE
    (
        objectName SYSNAME PRIMARY KEY,
        description NVARCHAR(2000) NOT NULL
    );

    INSERT INTO @Documentation
    VALUES

    --------------------------------------------------
    -- TABLES
    --------------------------------------------------

    (N''CollaborativeDeal'',
     N''Temporal-сутність угоди в межах InteractionContext.
     Зберігає координати передачі й доставки, остаточну ціну
     без комісії, відправника, отримувача, останнього автора
     пропозиції, дату погодження, зашифровані секрети та стан.
     Draft резервує обидва пов’язані Order.
     Failed звільняє Order, Fulfilled остаточно їх використовує.
     До погодження дозволено редагувати умови.
     Після погодження дозволені лише визначені переходи стану.
     Прямі зміни backend заборонені.''),

    (N''CollaborativeDealHistory'',
     N''Автоматична system-versioned історія CollaborativeDeal.
     Зберігає попередні редакції умов та стани виконання.
     Історичні Draft-записи використовуються для обчислення
     termsRevision. Для цього необхідно читати історичну
     таблицю безпосередньо, включно з версіями нульової тривалості.
     Прямий запис заборонений активним SYSTEM_VERSIONING.''),

    (N''DealExecutionStatus'',
     N''Довідник станів угоди: Draft, AwaitingHandover,
     InTransit, AwaitingPayout, Fulfilled, Failed.
     Fulfilled і Failed є фінальними станами.
     Поточна реалізація дозволяє перехід у Failed лише з Draft.
     Допустимість переходів контролюється процедурами
     та тригером CollaborativeDeal.''),

    (N''DelivererIntent'',
     N''Order кур’єра: маршрут GEOGRAPHY/SRID 4326,
     обмеження місткості, винагорода, час відправлення,
     автор і статус публікації.
     Temporal-історія зберігається у DelivererIntentHistory.
     Доступність залежить від активних та Fulfilled угод.
     Order з Fulfilled-угодою захищений від зміни та видалення.''),

    (N''DeliveryRequesterIntent'',
     N''Order замовника: координати передачі й доставки,
     ціновий діапазон без комісії, посилка, автор і статус.
     Складений FK гарантує належність посилки автору.
     Temporal-історія зберігається у DeliveryRequesterIntentHistory.
     Доступність залежить від активних та Fulfilled угод.
     Order з Fulfilled-угодою незмінний.''),

    (N''OrderStatus'',
     N''Довідник статусів Order: Draft, Private, Published.
     Статус визначає готовність та публікацію Order.
     Фактична доступність обчислюється з пов’язаних угод.''),

    (N''InteractionContext'',
     N''Контекст взаємодії одного DelivererIntent та одного
     DeliveryRequesterIntent. Зберігає момент початку,
     сторону-ініціатора та стан Unilateral, Mutual або Rejected.
     Один Order може брати участь у багатьох взаємодіях.
     Ексклюзивність забезпечується на рівні активних угод.
     Архівність є похідною ознакою.''),

    (N''UserMessage'',
     N''Історія повідомлень InteractionContext.
     До погодження угоди учасниками є автори обох Order.
     Після погодження може приєднатися третій учасник,
     визначений через senderUserId та receiverUserId.
     SendUserMessage перевіряє право надсилання,
     архівність та історичний ліміт повідомлень.
     Авторизація читання повідомлень належить backend.''),

    (N''UserSettings'',
     N''Персональні налаштування користувача.
     orderPublishingPolicy: 0 = Manual, 1 = Automatic.
     Визначає початковий статус сформованого Order:
     Private або Published. Явне створення Draft
     має пріоритет над політикою публікації.''),

    (N''PaymentOperationAttempt'',
     N''Історичний запис платіжної спроби укладеної угоди:
     AUTH, SETTLE, REFUND або P2P_CREDIT.
     Зберігає суму, валюту, посилання операції,
     відповідь провайдера, статус та необов’язковий
     paymentMethodId.
     Поточна процедура перевіряє належність зазначеного
     методу замовнику незалежно від типу операції.
     Для P2P_CREDIT на метод кур’єра потрібна адаптація.
     Послідовність платіжних операцій не контролюється.
     Прямі зміни backend заборонені.''),


    --------------------------------------------------
    -- PROCEDURES
    --------------------------------------------------

    (N''CreateInteractionContext'',
     N''Атомарно створює Unilateral InteractionContext
     між двома наявними Order різних користувачів.
     Цільовий Order має бути Published, Order ініціатора
     Private або Published. Обидва повинні бути доступними.
     Перевіряє належність Order ініціатору та використовує
     application locks для конкурентного захисту.''),

    (N''CreateCollaborativeDeal'',
     N''Атомарно створює Draft у Mutual InteractionContext.
     Виконавець повинен бути автором одного з Order.
     Перевіряє доступність Order, координати, ціну та учасників.
     Резервує обидва Order, забороняючи інші активні угоди.
     Автор створення стає lastProposedByUserId.
     Дата погодження та секрети залишаються NULL.
     Початкова редакція умов дорівнює 1.''),

    (N''UpdateCollaborativeDealDraft'',
     N''Атомарно оновлює умови Draft.
     Доступна авторам пов’язаних Order.
     Перевіряє ExpectedTermsRevision для захисту
     від редагування застарілих умов.
     Змінює координати, ціну, відправника, отримувача
     та lastProposedByUserId.
     Операція без фактичних змін відхиляється.
     Попередня редакція зберігається в Temporal History.''),

    (N''AcceptCollaborativeDeal'',
     N''Погоджує актуальну редакцію Draft.
     Виконавець повинен бути автором пов’язаного Order
     і не бути останнім автором пропозиції.
     Перевіряє ExpectedTermsRevision.
     Атомарно записує agreedAtUtc, два зашифровані
     секрети та переводить угоду в AwaitingHandover.
     Генерація й шифрування секретів належать backend.''),

    (N''FailCollaborativeDeal'',
     N''Скасовує Draft за рішенням одного з авторів
     пов’язаних Order. Переводить угоду у Failed.
     Умови, останній автор пропозиції та історія
     зберігаються. Пов’язані Order звільняються.
     Скасування вже погодженої угоди не реалізовано.''),

    (N''ConfirmDealHandover'',
     N''Атомарно переводить CollaborativeDeal
     з AwaitingHandover до InTransit.
     Використовує блокування пов’язаних Order.
     Перевірка секрету передачі та авторизація
     виконавця належать backend.''),

    (N''ConfirmDealDelivery'',
     N''Атомарно переводить CollaborativeDeal
     з InTransit до AwaitingPayout.
     Використовує блокування пов’язаних Order.
     Перевірка секрету доставки та авторизація
     виконавця належать backend.
     Метод виплати кур’єру в CollaborativeDeal
     окремо не зберігається.''),

    (N''CompleteCollaborativeDeal'',
     N''Атомарно переводить CollaborativeDeal
     з AwaitingPayout до Fulfilled.
     Пов’язані Order остаточно втрачають доступність.
     Інші взаємодії зі спільними Order стають архівними.
     Підтвердження успішної виплати належить backend.
     Сама процедура не перевіряє результат платежу.''),

    (N''SendUserMessage'',
     N''Атомарно створює повідомлення InteractionContext.
     Кур’єр та замовник завжди є учасниками чату.
     Додатковий учасник визначається через останню угоду
     з ненульовим agreedAtUtc, якщо замовник є відправником
     або отримувачем.
     Draft та неукладена Failed-угода доступу не надають.
     Перевіряє історичну політику ChatAccessPolicy,
     ліміт повідомлень та архівність.
     Виклики серіалізуються блокуванням InteractionContext.''),

    (N''CreatePaymentOperationAttempt'',
     N''Атомарно реєструє спробу платіжної операції.
     Вимагає існування CollaborativeDeal
     з ненульовим agreedAtUtc.
     Якщо PaymentMethodId задано, перевіряє його
     належність автору DeliveryRequesterIntent.
     NULL PaymentMethodId дозволено.
     Не перевіряє disabledAtUtc, послідовність платежів,
     попередні спроби чи фактичний результат виплати.
     Для P2P_CREDIT потрібна окрема перевірка методу кур’єра.''),


    --------------------------------------------------
    -- VIEWS
    --------------------------------------------------

    (N''vCollaborativeDealDetails'',
     N''Розширене представлення CollaborativeDeal.
     Містить умови угоди, пов’язані Order та їх авторів.
     termsRevision обчислюється з історичних Draft-версій
     та поточного Draft, якщо він існує.
     delivererAccepted і deliveryRequesterAccepted
     визначаються через lastProposedByUserId та agreedAtUtc.
     isAgreed, isActive та isFinalized є похідними ознаками.
     Зашифровані секрети не включено до представлення.''),

    (N''vDelivererIntentDetails'',
     N''Розширене представлення Order кур’єра.
     Містить кількість взаємодій та угод,
     останню й активну угоду, ознаки доступності.
     Draft-угода враховується як активна.
     Цільовий Order має бути Published,
     ініціатор Private або Published.
     Активна або Fulfilled-угода виключає доступність.''),

    (N''vDeliveryRequesterIntentDetails'',
     N''Розширене представлення Order замовника
     разом з поточними атрибутами посилки.
     Містить кількість взаємодій та угод,
     останню й активну угоду, ознаки доступності.
     Draft-угода резервує Order.
     Активна або Fulfilled-угода виключає доступність.''),


    --------------------------------------------------
    -- TRIGGERS
    --------------------------------------------------

    (N''TR_CollaborativeDeal_ImmutableFinalStates'',
     N''AFTER UPDATE, DELETE для CollaborativeDeal.
     Забороняє видалення угод та зміни фінальних станів.
     Захищає interactionContextId і createdAtUtc.
     Дозволяє редагування умов тільки у Draft.
     Дозволяє встановлення agreedAtUtc і секретів
     тільки при переході Draft -> AwaitingHandover.
     Контролює послідовність станів:
     Draft -> AwaitingHandover -> InTransit ->
     AwaitingPayout -> Fulfilled, або Draft -> Failed.
     Працює з множинними змінами.''),

    (N''TR_DelivererIntent_ImmutableFinalStates'',
     N''AFTER UPDATE, DELETE для DelivererIntent.
     Забороняє зміну або видалення Order кур’єра,
     пов’язаного хоча б з однією Fulfilled-угодою.
     Працює з множинними змінами.''),

    (N''TR_DeliveryRequesterIntent_ImmutableFinalStates'',
     N''AFTER UPDATE, DELETE для DeliveryRequesterIntent.
     Забороняє зміну або видалення Order замовника,
     пов’язаного хоча б з однією Fulfilled-угодою.
     Працює з множинними змінами.'');


    --------------------------------------------------
    -- UPSERT EXTENDED PROPERTIES
    --------------------------------------------------

    DECLARE
        @ObjectName SYSNAME,
        @Description NVARCHAR(2000),
        @ObjectId INT,
        @ObjectType CHAR(2),
        @Level1Type NVARCHAR(128),
        @Level1Name SYSNAME,
        @Level2Type NVARCHAR(128),
        @Level2Name SYSNAME;

    DECLARE DocumentationCursor CURSOR
        LOCAL FAST_FORWARD FOR

        SELECT objectName, description
        FROM @Documentation;

    OPEN DocumentationCursor;

    FETCH NEXT FROM DocumentationCursor
    INTO @ObjectName, @Description;

    WHILE @@FETCH_STATUS = 0
    BEGIN

        SET @ObjectId =
            OBJECT_ID(N''dbo.'' + QUOTENAME(@ObjectName));

        IF @ObjectId IS NULL
            THROW 52002,
                N''Documentation target object not found.'',
                1;

        SELECT @ObjectType = type
        FROM sys.objects
        WHERE object_id = @ObjectId;

        SET @Level1Type = NULL;
        SET @Level1Name = @ObjectName;
        SET @Level2Type = NULL;
        SET @Level2Name = NULL;

        IF @ObjectType = ''U''
            SET @Level1Type = N''TABLE'';

        ELSE IF @ObjectType = ''V''
            SET @Level1Type = N''VIEW'';

        ELSE IF @ObjectType = ''P''
            SET @Level1Type = N''PROCEDURE'';

        ELSE IF @ObjectType = ''TR''
        BEGIN
            SET @Level1Type = N''TABLE'';
            SET @Level2Type = N''TRIGGER'';
            SET @Level2Name = @ObjectName;

            SELECT
                @Level1Name = OBJECT_NAME(parent_object_id)
            FROM sys.objects
            WHERE object_id = @ObjectId;
        END;

        IF @Level1Type IS NULL
            THROW 52003,
                N''Unsupported documentation object type.'',
                1;

        IF EXISTS
        (
            SELECT 1
            FROM sys.extended_properties
            WHERE class = 1
              AND major_id = @ObjectId
              AND minor_id = 0
              AND name = N''MS_Description''
        )
        BEGIN

            EXEC sys.sp_updateextendedproperty
                @name = N''MS_Description'',
                @value = @Description,
                @level0type = N''SCHEMA'',
                @level0name = N''dbo'',
                @level1type = @Level1Type,
                @level1name = @Level1Name,
                @level2type = @Level2Type,
                @level2name = @Level2Name;

        END
        ELSE
        BEGIN

            EXEC sys.sp_addextendedproperty
                @name = N''MS_Description'',
                @value = @Description,
                @level0type = N''SCHEMA'',
                @level0name = N''dbo'',
                @level1type = @Level1Type,
                @level1name = @Level1Name,
                @level2type = @Level2Type,
                @level2name = @Level2Name;

        END;

        FETCH NEXT FROM DocumentationCursor
        INTO @ObjectName, @Description;

    END;

    CLOSE DocumentationCursor;
    DEALLOCATE DocumentationCursor;


    --------------------------------------------------
    -- VERIFICATION
    --------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM @Documentation AS d
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM sys.extended_properties AS ep
            WHERE ep.class = 1
              AND ep.major_id =
                  OBJECT_ID(N''dbo.'' + QUOTENAME(d.objectName))
              AND ep.minor_id = 0
              AND ep.name = N''MS_Description''
              AND CONVERT(NVARCHAR(2000), ep.value) =
                  d.description
        )
    )
        THROW 52004,
            N''Documentation verification failed.'',
            1;

    COMMIT TRANSACTION;

    SELECT
        N''Database documentation staged (outer commit pending).''
            AS result,

        (SELECT COUNT(*) FROM @Documentation)
            AS updatedObjects;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';

    -- 6. Final structural verification, before committing.
    IF NOT EXISTS (
        SELECT 1 FROM sys.tables
        WHERE object_id = OBJECT_ID(N'dbo.CollaborativeDeal')
          AND temporal_type = 2
          AND history_table_id = OBJECT_ID(N'dbo.CollaborativeDealHistory')
          AND history_retention_period = -1
    )
        THROW 52207, N'Unexpected temporal configuration.', 1;
    IF (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.CollaborativeDeal')) <> 15
        THROW 52208, N'Unexpected CollaborativeDeal columns.', 1;
    IF EXISTS (SELECT 1 FROM dbo.OrderStatus WHERE orderStatusCode = 'RawIntent')
        THROW 52209, N'RawIntent status remains.', 1;
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1)
       OR EXISTS (SELECT 1 FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1)
        THROW 52210, N'Disabled or untrusted constraints found.', 1;
    IF @@TRANCOUNT <> 1
        THROW 52211, N'Unexpected transaction nesting.', 1;

    COMMIT TRANSACTION;
    SELECT N'PassBy refactoring migration committed.' AS result;

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;
    THROW;
END CATCH;
