/*
PassBy | Smoke tests 2026-11-25
Run AFTER migration, as dbo / principal allowed to EXECUTE AS passby_backend.
Uses the original 25 Nov fixture IDs (2,4 courier orders; users 1,2,5,8).
Run on an isolated copy of that fixture state, not while team writes to DB.
No test transaction is committed; identity counters can advance.
49 Order/interactions/deal assertions + 3 UserSettings tests, concurrency excluded.
A failure stops subsequent blocks. Repackaged suite has not been run on SQL Server.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'PassBy' THROW 51900, N'Invalid target database.',1;
IF @@TRANCOUNT <> 0 THROW 51901,N'An active transaction already exists.',1;
IF NOT EXISTS (SELECT 1 FROM dbo.DelivererIntent WHERE delivererIntentId=2 AND authorDelivererUserId=1 AND orderStatusCode='Private' AND availableMaxWeight=15)
OR NOT EXISTS (SELECT 1 FROM dbo.vDelivererIntentDetails WHERE delivererIntentId=4 AND authorDelivererUserId=1 AND orderStatusCode='Published' AND availableMaxWeight=15 AND isAvailableAsTarget=1)
OR NOT EXISTS (SELECT 1 FROM dbo.DeliveryRequester WHERE userId=8 AND isBlocked=0)
OR NOT EXISTS (SELECT 1 FROM dbo.UserAccount WHERE userId=5)
OR NOT EXISTS (SELECT 1 FROM dbo.UserAccount WHERE userId=2)
    THROW 51902,N'Original smoke-test fixtures are missing or changed.',1;
IF EXISTS (SELECT 1 FROM dbo.DeliveryRequesterShipment)
OR EXISTS (SELECT 1 FROM dbo.DeliveryRequesterIntent)
OR EXISTS (SELECT 1 FROM dbo.InteractionContext)
OR EXISTS (SELECT 1 FROM dbo.CollaborativeDeal)
    THROW 51902,N'Expected isolated fixture without requester orders or deals.',1;
BEGIN TRY

-- UserSettings (3 tests)
EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

IF @@TRANCOUNT <> 0
    THROW 51601, N''An active transaction already exists.'', 1;

DECLARE @CredentialId BIGINT;
DECLARE @UserId BIGINT;
DECLARE @Impersonated BIT = 0;

BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = ''passby_backend'';
    SET @Impersonated = 1;

    --------------------------------------------------
    -- 1. Створення тимчасових облікових даних
    --------------------------------------------------

    INSERT INTO dbo.PasswordCredential
    (
        passwordHash
    )
    VALUES
    (
        N''SMOKE_TEST_NOT_A_REAL_PASSWORD_HASH''
    );

    SET @CredentialId = CAST(SCOPE_IDENTITY() AS BIGINT);

    --------------------------------------------------
    -- 2. Створення користувача
    --------------------------------------------------

    INSERT INTO dbo.UserAccount
    (
        credentialId,
        emailAddress,
        registeredAtUtc
    )
    VALUES
    (
        @CredentialId,
        CONCAT(
            N''smoke-'',
            CONVERT(NVARCHAR(36), NEWID()),
            N''@example.invalid''
        ),
        SYSUTCDATETIME()
    );

    SET @UserId = CAST(SCOPE_IDENTITY() AS BIGINT);

    SELECT
        N''Create UserAccount'' AS test,
        ''PASS'' AS result,
        @UserId AS userId;

    --------------------------------------------------
    -- 3. Перевірка автоматичного створення налаштувань
    --------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.UserSettings
        WHERE userId = @UserId
          AND orderPublishingPolicy = 0
    )
        THROW 51613,
            N''Automatic UserSettings creation failed.'',
            1;

    SELECT
        N''Automatic UserSettings creation'' AS test,
        ''PASS'' AS result;

    --------------------------------------------------
    -- 4. Зміна політики публікації
    --------------------------------------------------

    UPDATE dbo.UserSettings
    SET orderPublishingPolicy = 1
    WHERE userId = @UserId;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.UserSettings
        WHERE userId = @UserId
          AND orderPublishingPolicy = 1
    )
        THROW 51614,
            N''UserSettings update failed.'',
            1;

    SELECT
        N''Update publishing policy'' AS test,
        ''PASS'' AS result;

    --------------------------------------------------
    -- 5. Відкат тестових даних
    --------------------------------------------------

    REVERT;
    SET @Impersonated = 0;

    ROLLBACK TRANSACTION;

    SELECT
        N''ALL USER SETTINGS SMOKE TESTS PASSED'' AS result,
        N''Test data rolled back'' AS dataState;

END TRY
BEGIN CATCH

    IF @Impersonated = 1
        REVERT;

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';
IF @@TRANCOUNT <> 0 THROW 51934,N'Unexpected open test transaction.',1;

-- Lifecycle (7 checks)
EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51900, N''Invalid target database.'', 1;

IF @@TRANCOUNT <> 0
    THROW 51901, N''An active transaction already exists.'', 1;

DECLARE @Impersonated BIT = 0;
DECLARE @HistoryBefore BIGINT;
DECLARE @HistoryAfter BIGINT;

BEGIN TRY
    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DelivererIntent
        WHERE delivererIntentId = 2
          AND authorDelivererUserId = 1
          AND orderStatusCode = ''Private''
    )
        THROW 51902, N''Unexpected initial Order state.'', 1;

    EXECUTE AS USER = ''passby_backend'';
    SET @Impersonated = 1;

    --------------------------------------------------
    -- 1. Private -> Published
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''Published'';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DelivererIntent
        WHERE delivererIntentId = 2
          AND orderStatusCode = ''Published''
    )
        THROW 51903, N''Publishing failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Private -> Published'' AS test;

    --------------------------------------------------
    -- 2. Published -> Private
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''Private'';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DelivererIntent
        WHERE delivererIntentId = 2
          AND orderStatusCode = ''Private''
    )
        THROW 51904, N''Unpublishing failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Published -> Private'' AS test;

    --------------------------------------------------
    -- 3. Private -> Private (no-op)
    --------------------------------------------------

    SELECT @HistoryBefore = COUNT_BIG(*)
    FROM dbo.DelivererIntentHistory
    WHERE delivererIntentId = 2;

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''Private'';

    SELECT @HistoryAfter = COUNT_BIG(*)
    FROM dbo.DelivererIntentHistory
    WHERE delivererIntentId = 2;

    IF @HistoryBefore <> @HistoryAfter
        THROW 51905, N''Unexpected history version.'', 1;

    SELECT ''PASS'' AS result,
           ''Private no-op without history changes'' AS test;

    --------------------------------------------------
    -- 4. Private -> Cancelled
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''Cancelled'';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.DelivererIntent
        WHERE delivererIntentId = 2
          AND orderStatusCode = ''Cancelled''
    )
        THROW 51906, N''Cancellation failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Private -> Cancelled'' AS test;

    --------------------------------------------------
    -- 5. Перевірка доступності Cancelled Order
    --------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = 2
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
        THROW 51907, N''Cancelled Order is available.'', 1;

    SELECT ''PASS'' AS result,
           ''Cancelled Order is unavailable'' AS test;

    --------------------------------------------------
    -- 6. Cancelled -> Cancelled (no-op)
    --------------------------------------------------

    SELECT @HistoryBefore = COUNT_BIG(*)
    FROM dbo.DelivererIntentHistory
    WHERE delivererIntentId = 2;

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''Cancelled'';

    SELECT @HistoryAfter = COUNT_BIG(*)
    FROM dbo.DelivererIntentHistory
    WHERE delivererIntentId = 2;

    IF @HistoryBefore <> @HistoryAfter
        THROW 51908, N''Unexpected history version.'', 1;

    SELECT ''PASS'' AS result,
           ''Cancelled no-op without history changes'' AS test;

    --------------------------------------------------
    -- 7. Відкочення всіх змін
    --------------------------------------------------

    REVERT;
    SET @Impersonated = 0;

    ROLLBACK TRANSACTION;

    SELECT
        delivererIntentId,
        orderStatusCode,
        CASE
            WHEN orderStatusCode = ''Private''
            THEN ''PASS''
            ELSE ''FAIL''
        END AS rollbackCheck
    FROM dbo.DelivererIntent
    WHERE delivererIntentId = 2;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    IF @Impersonated = 1
        REVERT;

    THROW;

END CATCH;

IF NOT EXISTS (SELECT 1 FROM dbo.DelivererIntent WHERE delivererIntentId=2 AND orderStatusCode=''Private'')
    THROW 51924,N''Order rollback check failed.'',1;';
IF @@TRANCOUNT <> 0 THROW 51934,N'Unexpected open test transaction.',1;

-- Positive integration (14 checks)
EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51900, N''Invalid target database.'', 1;

IF @@TRANCOUNT <> 0
    THROW 51901, N''An active transaction already exists.'', 1;

DECLARE @Impersonated BIT = 0;

DECLARE @DId BIGINT;
DECLARE @RId BIGINT;
DECLARE @ShipmentId BIGINT;
DECLARE @ContextId BIGINT;
DECLARE @UnilateralContextId BIGINT;
DECLARE @DealId BIGINT;

DECLARE @Departure DATETIME2(7) =
    DATEADD(DAY, 7, SYSUTCDATETIME());

DECLARE @HistoryBefore BIGINT;

DECLARE @DResult TABLE
(
    delivererIntentId BIGINT,
    orderStatusCode VARCHAR(64)
);

DECLARE @RResult TABLE
(
    participantOrderId BIGINT,
    orderStatusCode VARCHAR(64)
);

BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = ''passby_backend'';
    SET @Impersonated = 1;

    --------------------------------------------------
    -- 1. Створення тестової посилки
    --------------------------------------------------

    INSERT INTO dbo.DeliveryRequesterShipment
    (
        ownerDeliveryRequesterUserId,
        shipmentName,
        shipmentDescription,
        shipmentWeight,
        shipmentLength,
        shipmentDepth,
        shipmentHeight
    )
    VALUES
    (
        8,
        N''Smoke test shipment'',
        N''Temporary test data'',
        2,
        20,
        15,
        10
    );

    SET @ShipmentId = CAST(SCOPE_IDENTITY() AS BIGINT);

    --------------------------------------------------
    -- 2. Створення Draft Order обох типів
    --------------------------------------------------

    INSERT INTO @DResult
    EXEC dbo.CreateDelivererOrder
        @AuthorDelivererUserId = 1,
        @StartLatitude = 49.9935,
        @StartLongitude = 36.2304,
        @EndLatitude = 50.4501,
        @EndLongitude = 30.5234,
        @DepartureTimeAtUtc = @Departure,
        @AvailableMaxWeight = 15,
        @SaveAsDraft = 1;

    SELECT @DId = delivererIntentId
    FROM @DResult;

    INSERT INTO @RResult
    EXEC dbo.CreateDeliveryRequesterOrder
        @AuthorDeliveryRequesterUserId = 8,
        @DeliveryRequesterShipmentId = @ShipmentId,
        @ReceivingLatitude = 49.9935,
        @ReceivingLongitude = 36.2304,
        @DestinationLatitude = 50.4501,
        @DestinationLongitude = 30.5234,
        @SaveAsDraft = 1;

    SELECT @RId = participantOrderId
    FROM @RResult;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DelivererIntent
        WHERE delivererIntentId = @DId
          AND orderStatusCode = ''Draft''
    )
    OR NOT EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
          AND orderStatusCode = ''Draft''
    )
        THROW 51910, N''Draft creation failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Both Draft Orders created'' AS test;

    --------------------------------------------------
    -- 3. Завершення чернеток
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = @DId,
        @ActorUserId = 1,
        @NewStatusCode = ''Published'';

    EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''Private'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DelivererIntent
        WHERE delivererIntentId = @DId
          AND orderStatusCode = ''Published''
    )
    OR NOT EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
          AND orderStatusCode = ''Private''
    )
        THROW 51911, N''Draft completion failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Draft completion'' AS test;

    --------------------------------------------------
    -- 4. Публічність Order замовника
    --------------------------------------------------

    EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''Published'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
          AND orderStatusCode = ''Published''
    )
        THROW 51912, N''Requester publishing failed.'', 1;

    EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''Private'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
          AND orderStatusCode = ''Private''
    )
        THROW 51913, N''Requester unpublishing failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Requester Private <-> Published'' AS test;

    --------------------------------------------------
    -- 5. Створення і завершення Unilateral
    --
    -- Використовуємо наявний Order кур''єра №4.
    --------------------------------------------------

    EXEC dbo.CreateInteractionContext
        @RequestInitiatorCode = ''DeliveryRequester'',
        @InitiatorUserId = 8,
        @TargetOrderId = 4,
        @InitiatorOrderId = @RId;

    SELECT @UnilateralContextId = interactionContextId
    FROM dbo.InteractionContext
    WHERE delivererIntentId = 4
      AND deliveryRequesterIntentId = @RId;

    EXEC dbo.CloseInteractionContext
        @InteractionContextId = @UnilateralContextId,
        @ActorUserId = 8;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.InteractionContext
        WHERE interactionContextId = @UnilateralContextId
          AND interactionStatusCode = ''Rejected''
    )
        THROW 51914, N''Unilateral closure failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Initiator closes Unilateral interaction'' AS test;

    --------------------------------------------------
    -- 6. Створення Mutual-взаємодії
    --------------------------------------------------

    EXEC dbo.CreateInteractionContext
        @RequestInitiatorCode = ''DeliveryRequester'',
        @InitiatorUserId = 8,
        @TargetOrderId = @DId,
        @InitiatorOrderId = @RId;

    SELECT @ContextId = interactionContextId
    FROM dbo.InteractionContext
    WHERE delivererIntentId = @DId
      AND deliveryRequesterIntentId = @RId;

    EXEC dbo.AcceptInteractionContext
        @InteractionContextId = @ContextId,
        @ResponderUserId = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.InteractionContext
        WHERE interactionContextId = @ContextId
          AND interactionStatusCode = ''Mutual''
    )
        THROW 51915, N''Interaction acceptance failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Interaction becomes Mutual'' AS test;

    --------------------------------------------------
    -- 7. Зняття цільового Order з публікації
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = @DId,
        @ActorUserId = 1,
        @NewStatusCode = ''Private'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DelivererIntent
        WHERE delivererIntentId = @DId
          AND orderStatusCode = ''Private''
    )
        THROW 51916, N''Unpublishing during interaction failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Target becomes Private during Mutual interaction'' AS test;

    --------------------------------------------------
    -- 8. Створення угоди між двома Private Order
    --------------------------------------------------

    EXEC dbo.CreateCollaborativeDeal
        @InteractionContextId = @ContextId,
        @ActorUserId = 8,
        @ReceivingLatitude = 49.9935,
        @ReceivingLongitude = 36.2304,
        @DestinationLatitude = 50.4501,
        @DestinationLongitude = 30.5234,
        @FinalPriceWithoutCommission = 300,
        @SenderUserId = 8,
        @ReceiverUserId = 5;

    SELECT @DealId = collaborativeDealId
    FROM dbo.CollaborativeDeal
    WHERE interactionContextId = @ContextId;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.CollaborativeDeal
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = ''Draft''
    )
        THROW 51917, N''Deal creation failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Deal created with two Private Orders'' AS test;

    --------------------------------------------------
    -- 9. Зміна публічності під час активної угоди
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = @DId,
        @ActorUserId = 1,
        @NewStatusCode = ''Published'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = @DId
          AND orderStatusCode = ''Published''
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
        THROW 51918, N''Incorrect availability during active deal.'', 1;

    SELECT ''PASS'' AS result,
           ''Published Order remains reserved by active deal'' AS test;

    --------------------------------------------------
    -- 10. Пряме редагування під час активної угоди
    --------------------------------------------------

    UPDATE dbo.DelivererIntent
    SET availableMaxWeight = 20
    WHERE delivererIntentId = @DId;

    UPDATE dbo.DeliveryRequesterIntent
    SET maxPriceWithoutCommission = 500
    WHERE deliveryRequesterIntentId = @RId;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.DelivererIntent
        WHERE delivererIntentId = @DId
          AND availableMaxWeight = 20
    )
    OR NOT EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
          AND maxPriceWithoutCommission = 500
    )
        THROW 51919, N''Direct Order editing failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Both Orders editable during active deal'' AS test;

    --------------------------------------------------
    -- 11. Скасування чернетки угоди
    --------------------------------------------------

    EXEC dbo.FailCollaborativeDeal
        @CollaborativeDealId = @DealId,
        @ActorUserId = 8;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.CollaborativeDeal
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = ''Failed''
    )
        THROW 51920, N''Deal cancellation failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Deal becomes Failed'' AS test;

    --------------------------------------------------
    -- 12. Завершення Mutual із Failed-угодою
    --------------------------------------------------

    EXEC dbo.CloseInteractionContext
        @InteractionContextId = @ContextId,
        @ActorUserId = 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.InteractionContext
        WHERE interactionContextId = @ContextId
          AND interactionStatusCode = ''Rejected''
    )
        THROW 51921, N''Mutual closure failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Mutual interaction closed after Failed deal'' AS test;

    --------------------------------------------------
    -- 13. Скасування обох Order
    --------------------------------------------------

    EXEC dbo.SetDelivererOrderStatus
        @OrderId = @DId,
        @ActorUserId = 1,
        @NewStatusCode = ''Cancelled'';

    EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''Cancelled'';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = @DId
          AND orderStatusCode = ''Cancelled''
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
    OR NOT EXISTS
    (
        SELECT 1 FROM dbo.vDeliveryRequesterIntentDetails
        WHERE deliveryRequesterIntentId = @RId
          AND orderStatusCode = ''Cancelled''
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
        THROW 51922, N''Order cancellation failed.'', 1;

    SELECT ''PASS'' AS result,
           ''Both Orders cancelled after activities closed'' AS test;

    --------------------------------------------------
    -- 14. Ідемпотентність Cancelled замовника
    --------------------------------------------------

    SELECT @HistoryBefore = COUNT_BIG(*)
    FROM dbo.DeliveryRequesterIntentHistory
    WHERE deliveryRequesterIntentId = @RId;

    EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''Cancelled'';

    IF @HistoryBefore <>
    (
        SELECT COUNT_BIG(*)
        FROM dbo.DeliveryRequesterIntentHistory
        WHERE deliveryRequesterIntentId = @RId
    )
        THROW 51923, N''Unexpected history version.'', 1;

    SELECT ''PASS'' AS result,
           ''Requester Cancelled no-op without history changes'' AS test;

    --------------------------------------------------
    -- 15. Відкочення
    --------------------------------------------------

    REVERT;
    SET @Impersonated = 0;

    ROLLBACK TRANSACTION;

    IF EXISTS
    (
        SELECT 1 FROM dbo.DelivererIntent
        WHERE delivererIntentId = @DId
    )
    OR EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterIntentId = @RId
    )
    OR EXISTS
    (
        SELECT 1 FROM dbo.DeliveryRequesterShipment
        WHERE deliveryRequesterShipmentId = @ShipmentId
    )
    OR EXISTS
    (
        SELECT 1 FROM dbo.InteractionContext
        WHERE interactionContextId IN
              (@ContextId, @UnilateralContextId)
    )
    OR EXISTS
    (
        SELECT 1 FROM dbo.CollaborativeDeal
        WHERE collaborativeDealId = @DealId
    )
        THROW 51924, N''Test data rollback failed.'', 1;

    SELECT ''PASS'' AS result,
           ''All temporary data rolled back'' AS test;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    IF @Impersonated = 1
        REVERT;

    THROW;

END CATCH;';
IF @@TRANCOUNT <> 0 THROW 51934,N'Unexpected open test transaction.',1;

-- Negative courier (9 + 2 checks)
EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51900, N''Invalid target database.'', 1;

IF @@TRANCOUNT <> 0
    THROW 51901, N''An active transaction already exists.'', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.DelivererIntent
    WHERE delivererIntentId = 2
      AND authorDelivererUserId = 1
      AND orderStatusCode = ''Private''
)
    THROW 51902, N''Unexpected initial Order state.'', 1;

DECLARE @HistoryBefore BIGINT;

SELECT @HistoryBefore = COUNT_BIG(*)
FROM dbo.DelivererIntentHistory
WHERE delivererIntentId = 2;

--------------------------------------------------
-- 1. Визначення тестових сценаріїв
--------------------------------------------------

DECLARE @Tests TABLE
(
    testId INT PRIMARY KEY,
    testName NVARCHAR(200),
    runAsBackend BIT,
    prepareCancelled BIT,
    expectedError INT,
    alternativeError INT NULL,
    testSql NVARCHAR(MAX)
);

INSERT INTO @Tests
VALUES
(
    1,
    N''Private -> Draft forbidden'',
    1, 0, 51627, NULL,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''''Draft'''';''
),
(
    2,
    N''Foreign actor cannot change status'',
    1, 0, 51624, NULL,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 2,
        @NewStatusCode = ''''Published'''';''
),
(
    3,
    N''Unknown Order status forbidden'',
    1, 0, 51621, NULL,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''''InvalidStatus'''';''
),
(
    4,
    N''Direct status UPDATE forbidden'',
    1, 0, 229, 230,
    N''UPDATE dbo.DelivererIntent
      SET orderStatusCode = ''''Published''''
      WHERE delivererIntentId = 2;''
),
(
    5,
    N''Direct author UPDATE forbidden'',
    1, 0, 229, 230,
    N''UPDATE dbo.DelivererIntent
      SET authorDelivererUserId = 2
      WHERE delivererIntentId = 2;''
),
(
    6,
    N''Backend DELETE forbidden'',
    1, 0, 229, NULL,
    N''DELETE FROM dbo.DelivererIntent
      WHERE delivererIntentId = 2;''
),
(
    7,
    N''Privileged DELETE blocked by trigger'',
    0, 0, 51602, NULL,
    N''DELETE FROM dbo.DelivererIntent
      WHERE delivererIntentId = 2;''
),
(
    8,
    N''Cancelled Order is immutable'',
    1, 1, 51603, NULL,
    N''UPDATE dbo.DelivererIntent
      SET availableMaxWeight = 25
      WHERE delivererIntentId = 2;''
),
(
    9,
    N''Cancelled Order cannot be reopened'',
    1, 1, 51625, NULL,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 2,
        @ActorUserId = 1,
        @NewStatusCode = ''''Published'''';''
);

--------------------------------------------------
-- 2. Підготовка результатів
--------------------------------------------------

DECLARE @Results TABLE
(
    testId INT,
    testName NVARCHAR(200),
    expectedError INT,
    actualError INT NULL,
    result VARCHAR(10),
    errorMessage NVARCHAR(4000)
);

DECLARE @TestId INT = 1;
DECLARE @TestName NVARCHAR(200);
DECLARE @RunAsBackend BIT;
DECLARE @PrepareCancelled BIT;
DECLARE @ExpectedError INT;
DECLARE @AlternativeError INT;
DECLARE @TestSql NVARCHAR(MAX);

DECLARE @ActualError INT;
DECLARE @ErrorMessage NVARCHAR(4000);
DECLARE @Impersonated BIT;
DECLARE @Testing BIT;

--------------------------------------------------
-- 3. Виконання тестів
--------------------------------------------------

WHILE @TestId <= 9
BEGIN

    SELECT
        @TestName = testName,
        @RunAsBackend = runAsBackend,
        @PrepareCancelled = prepareCancelled,
        @ExpectedError = expectedError,
        @AlternativeError = alternativeError,
        @TestSql = testSql
    FROM @Tests
    WHERE testId = @TestId;

    SET @ActualError = NULL;
    SET @ErrorMessage = NULL;
    SET @Impersonated = 0;
    SET @Testing = 0;

    BEGIN TRY

        BEGIN TRANSACTION;

        IF @RunAsBackend = 1
        BEGIN
            EXECUTE AS USER = ''passby_backend'';
            SET @Impersonated = 1;
        END;

        -- Підготовка Cancelled для відповідних тестів.

        IF @PrepareCancelled = 1
        BEGIN
            EXEC dbo.SetDelivererOrderStatus
                @OrderId = 2,
                @ActorUserId = 1,
                @NewStatusCode = ''Cancelled'';

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.DelivererIntent
                WHERE delivererIntentId = 2
                  AND orderStatusCode = ''Cancelled''
            )
                THROW 51930,
                    N''Test preparation failed.'',
                    1;
        END;

        -- Початок власне негативного тесту.

        SET @Testing = 1;

        EXEC sys.sp_executesql @TestSql;

        SET @ErrorMessage =
            N''Operation unexpectedly succeeded.'';

    END TRY
    BEGIN CATCH

        SET @ActualError = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();

    END CATCH;

    --------------------------------------------------
    -- 4. Відкочення незалежно від результату
    --------------------------------------------------

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    IF @Impersonated = 1
        REVERT;

    INSERT INTO @Results
    VALUES
    (
        @TestId,
        @TestName,
        @ExpectedError,
        @ActualError,
        CASE
            WHEN @Testing = 1
             AND
             (
                 @ActualError = @ExpectedError
                 OR @ActualError = @AlternativeError
             )
            THEN ''PASS''
            ELSE ''FAIL''
        END,
        @ErrorMessage
    );

    SET @TestId += 1;

END;

--------------------------------------------------
-- 5. Результати
--------------------------------------------------

SELECT *
FROM @Results
ORDER BY testId;

SELECT
    COUNT(*) AS totalTests,
    SUM(CASE WHEN result = ''PASS'' THEN 1 ELSE 0 END)
        AS passedTests,
    SUM(CASE WHEN result = ''FAIL'' THEN 1 ELSE 0 END)
        AS failedTests
FROM @Results;

--------------------------------------------------
-- 6. Перевірка відсутності залишкових змін
--------------------------------------------------

SELECT
    delivererIntentId,
    orderStatusCode,
    authorDelivererUserId,
    availableMaxWeight,
    CASE
        WHEN orderStatusCode = ''Private''
         AND authorDelivererUserId = 1
         AND availableMaxWeight = 15
        THEN ''PASS''
        ELSE ''FAIL''
    END AS rollbackCheck
FROM dbo.DelivererIntent
WHERE delivererIntentId = 2;

SELECT
    @HistoryBefore AS historyBefore,
    COUNT_BIG(*) AS historyAfter,
    CASE
        WHEN COUNT_BIG(*) = @HistoryBefore
        THEN ''PASS''
        ELSE ''FAIL''
    END AS historyRollbackCheck
FROM dbo.DelivererIntentHistory
WHERE delivererIntentId = 2;

IF EXISTS (SELECT 1 FROM @Results WHERE result <> ''PASS'')
OR (SELECT COUNT(*) FROM @Results) <> 9
OR NOT EXISTS (SELECT 1 FROM dbo.DelivererIntent WHERE delivererIntentId=2 AND orderStatusCode=''Private'' AND authorDelivererUserId=1 AND availableMaxWeight=15)
OR (SELECT COUNT_BIG(*) FROM dbo.DelivererIntentHistory WHERE delivererIntentId=2) <> @HistoryBefore
    THROW 51932,N''Negative Order tests or rollback checks failed.'',1;';
IF @@TRANCOUNT <> 0 THROW 51934,N'Unexpected open test transaction.',1;

-- Negative requester, interaction and deal (15 + 2 checks)
EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51900, N''Invalid target database.'', 1;

IF @@TRANCOUNT <> 0
    THROW 51901, N''An active transaction already exists.'', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.vDelivererIntentDetails
    WHERE delivererIntentId = 4
      AND authorDelivererUserId = 1
      AND orderStatusCode = ''Published''
      AND isAvailableAsTarget = 1
)
    THROW 51902, N''Test Order is unavailable.'', 1;

--------------------------------------------------
-- 1. Сценарії
--
-- Stage:
-- 0 = Private Order
-- 1 = Unilateral
-- 2 = Mutual
-- 3 = Draft deal
-- 4 = Failed deal
-- 5 = Fulfilled deal
-- 6 = Cancelled Order
--------------------------------------------------

DECLARE @Tests TABLE
(
    testId INT PRIMARY KEY,
    testName NVARCHAR(200),
    stage INT,
    runAsBackend BIT,
    expectedError INT,
    testSql NVARCHAR(MAX)
);

INSERT INTO @Tests VALUES
(
    1, N''Requester direct status UPDATE'',
    0, 1, 230,
    N''UPDATE dbo.DeliveryRequesterIntent
      SET orderStatusCode = ''''Published''''
      WHERE deliveryRequesterIntentId = @RId;''
),
(
    2, N''Requester shipment reassignment forbidden'',
    0, 1, 230,
    N''UPDATE dbo.DeliveryRequesterIntent
      SET deliveryRequesterShipmentId =
          deliveryRequesterShipmentId
      WHERE deliveryRequesterIntentId = @RId;''
),
(
    3, N''Requester privileged DELETE forbidden'',
    0, 0, 51604,
    N''DELETE FROM dbo.DeliveryRequesterIntent
      WHERE deliveryRequesterIntentId = @RId;''
),
(
    4, N''Cancelled requester Order immutable'',
    6, 1, 51605,
    N''UPDATE dbo.DeliveryRequesterIntent
      SET maxPriceWithoutCommission = 500
      WHERE deliveryRequesterIntentId = @RId;''
),
(
    5, N''Cancellation blocked by Unilateral'',
    1, 1, 51629,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 4,
        @ActorUserId = 1,
        @NewStatusCode = ''''Cancelled'''';''
),
(
    6, N''Cancellation blocked by Mutual'',
    2, 1, 51629,
    N''EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''''Cancelled'''';''
),
(
    7, N''Foreign actor cannot close interaction'',
    2, 1, 51636,
    N''EXEC dbo.CloseInteractionContext
        @InteractionContextId = @ContextId,
        @ActorUserId = 5;''
),
(
    8, N''Cancellation blocked by active deal'',
    3, 1, 51628,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 4,
        @ActorUserId = 1,
        @NewStatusCode = ''''Cancelled'''';''
),
(
    9, N''Closure blocked by active deal'',
    3, 1, 51638,
    N''EXEC dbo.CloseInteractionContext
        @InteractionContextId = @ContextId,
        @ActorUserId = 1;''
),
(
    10, N''Failed deal does not close Mutual interaction'',
    4, 1, 51629,
    N''EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''''Cancelled'''';''
),
(
    11, N''Fulfilled deliverer Order immutable'',
    5, 1, 51160,
    N''UPDATE dbo.DelivererIntent
      SET availableMaxWeight = 25
      WHERE delivererIntentId = 4;''
),
(
    12, N''Fulfilled requester Order immutable'',
    5, 1, 51161,
    N''UPDATE dbo.DeliveryRequesterIntent
      SET maxPriceWithoutCommission = 500
      WHERE deliveryRequesterIntentId = @RId;''
),
(
    13, N''Fulfilled deliverer visibility immutable'',
    5, 1, 51626,
    N''EXEC dbo.SetDelivererOrderStatus
        @OrderId = 4,
        @ActorUserId = 1,
        @NewStatusCode = ''''Private'''';''
),
(
    14, N''Fulfilled requester cannot be cancelled'',
    5, 1, 51626,
    N''EXEC dbo.SetDeliveryRequesterOrderStatus
        @OrderId = @RId,
        @ActorUserId = 8,
        @NewStatusCode = ''''Cancelled'''';''
),
(
    15, N''Closure blocked by Fulfilled deal'',
    5, 1, 51638,
    N''EXEC dbo.CloseInteractionContext
        @InteractionContextId = @ContextId,
        @ActorUserId = 8;''
);

--------------------------------------------------
-- 2. Змінні та результати
--------------------------------------------------

DECLARE @Results TABLE
(
    testId INT,
    testName NVARCHAR(200),
    expectedError INT,
    actualError INT NULL,
    result VARCHAR(10),
    errorMessage NVARCHAR(4000)
);

DECLARE @TestId INT = 1;
DECLARE @TestName NVARCHAR(200);
DECLARE @Stage INT;
DECLARE @RunAsBackend BIT;
DECLARE @ExpectedError INT;
DECLARE @TestSql NVARCHAR(MAX);

DECLARE @RId BIGINT;
DECLARE @ShipmentId BIGINT;
DECLARE @ContextId BIGINT;
DECLARE @DealId BIGINT;

DECLARE @ActualError INT;
DECLARE @ErrorMessage NVARCHAR(4000);
DECLARE @Impersonated BIT;
DECLARE @Testing BIT;

DECLARE @HistoryBefore BIGINT;

SELECT @HistoryBefore = COUNT_BIG(*)
FROM dbo.DelivererIntentHistory
WHERE delivererIntentId = 4;

--------------------------------------------------
-- 3. Виконання тестів
--------------------------------------------------

WHILE @TestId <= 15
BEGIN

    SELECT
        @TestName = testName,
        @Stage = stage,
        @RunAsBackend = runAsBackend,
        @ExpectedError = expectedError,
        @TestSql = testSql
    FROM @Tests
    WHERE testId = @TestId;

    SET @RId = NULL;
    SET @ShipmentId = NULL;
    SET @ContextId = NULL;
    SET @DealId = NULL;
    SET @ActualError = NULL;
    SET @ErrorMessage = NULL;
    SET @Impersonated = 0;
    SET @Testing = 0;

    BEGIN TRY

        BEGIN TRANSACTION;

        EXECUTE AS USER = ''passby_backend'';
        SET @Impersonated = 1;

        ------------------------------------------
        -- 3.1. Посилка
        ------------------------------------------

        INSERT INTO dbo.DeliveryRequesterShipment
        (
            ownerDeliveryRequesterUserId,
            shipmentName,
            shipmentDescription,
            shipmentWeight,
            shipmentLength,
            shipmentDepth,
            shipmentHeight
        )
        VALUES
        (
            8,
            N''Negative smoke test'',
            N''Temporary test data'',
            2, 20, 15, 10
        );

        SET @ShipmentId =
            CAST(SCOPE_IDENTITY() AS BIGINT);

        ------------------------------------------
        -- 3.2. Order замовника
        ------------------------------------------

        EXEC dbo.CreateDeliveryRequesterOrder
            @AuthorDeliveryRequesterUserId = 8,
            @DeliveryRequesterShipmentId = @ShipmentId,
            @ReceivingLatitude = 49.9935,
            @ReceivingLongitude = 36.2304,
            @DestinationLatitude = 50.4501,
            @DestinationLongitude = 30.5234,
            @SaveAsDraft = 1;

        SELECT @RId = deliveryRequesterIntentId
        FROM dbo.DeliveryRequesterIntent
        WHERE deliveryRequesterShipmentId = @ShipmentId
          AND authorDeliveryRequesterUserId = 8;

        EXEC dbo.SetDeliveryRequesterOrderStatus
            @OrderId = @RId,
            @ActorUserId = 8,
            @NewStatusCode = ''Private'';

        ------------------------------------------
        -- 3.3. Unilateral
        ------------------------------------------

        IF @Stage BETWEEN 1 AND 5
        BEGIN

            EXEC dbo.CreateInteractionContext
                @RequestInitiatorCode = ''DeliveryRequester'',
                @InitiatorUserId = 8,
                @TargetOrderId = 4,
                @InitiatorOrderId = @RId;

            SELECT @ContextId = interactionContextId
            FROM dbo.InteractionContext
            WHERE delivererIntentId = 4
              AND deliveryRequesterIntentId = @RId;

        END;

        ------------------------------------------
        -- 3.4. Mutual
        ------------------------------------------

        IF @Stage BETWEEN 2 AND 5
        BEGIN

            EXEC dbo.AcceptInteractionContext
                @InteractionContextId = @ContextId,
                @ResponderUserId = 1;

        END;

        ------------------------------------------
        -- 3.5. Draft deal
        ------------------------------------------

        IF @Stage BETWEEN 3 AND 5
        BEGIN

            EXEC dbo.CreateCollaborativeDeal
                @InteractionContextId = @ContextId,
                @ActorUserId = 8,
                @ReceivingLatitude = 49.9935,
                @ReceivingLongitude = 36.2304,
                @DestinationLatitude = 50.4501,
                @DestinationLongitude = 30.5234,
                @FinalPriceWithoutCommission = 300,
                @SenderUserId = 8,
                @ReceiverUserId = 5;

            SELECT @DealId = collaborativeDealId
            FROM dbo.CollaborativeDeal
            WHERE interactionContextId = @ContextId;

        END;

        ------------------------------------------
        -- 3.6. Failed deal
        ------------------------------------------

        IF @Stage = 4
        BEGIN

            EXEC dbo.FailCollaborativeDeal
                @CollaborativeDealId = @DealId,
                @ActorUserId = 8;

        END;

        ------------------------------------------
        -- 3.7. Fulfilled deal
        ------------------------------------------

        IF @Stage = 5
        BEGIN

            EXEC dbo.AcceptCollaborativeDeal
                @CollaborativeDealId = @DealId,
                @ActorUserId = 1,
                @ExpectedTermsRevision = 1,
                @PickupConfirmationTokenEncrypted = 0x010203,
                @DeliveryConfirmationTokenEncrypted = 0x040506;

            EXEC dbo.ConfirmDealHandover
                @CollaborativeDealId = @DealId;

            EXEC dbo.ConfirmDealDelivery
                @CollaborativeDealId = @DealId;

            EXEC dbo.CompleteCollaborativeDeal
                @CollaborativeDealId = @DealId;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.CollaborativeDeal
                WHERE collaborativeDealId = @DealId
                  AND dealExecutionStatusCode = ''Fulfilled''
            )
            OR NOT EXISTS
            (
                SELECT 1
                FROM dbo.vDelivererIntentDetails
                WHERE delivererIntentId = 4
                  AND isAvailableAsTarget = 0
                  AND isAvailableAsInitiator = 0
            )
            OR NOT EXISTS
            (
                SELECT 1
                FROM dbo.vDeliveryRequesterIntentDetails
                WHERE deliveryRequesterIntentId = @RId
                  AND isAvailableAsTarget = 0
                  AND isAvailableAsInitiator = 0
            )
                THROW 51931,
                    N''Fulfilled preparation failed.'',
                    1;

        END;

        ------------------------------------------
        -- 3.8. Cancelled Order
        ------------------------------------------

        IF @Stage = 6
        BEGIN

            EXEC dbo.SetDeliveryRequesterOrderStatus
                @OrderId = @RId,
                @ActorUserId = 8,
                @NewStatusCode = ''Cancelled'';

        END;

        ------------------------------------------
        -- 3.9. Контекст прав для тесту
        ------------------------------------------

        IF @RunAsBackend = 0
        BEGIN
            REVERT;
            SET @Impersonated = 0;
        END;

        ------------------------------------------
        -- 3.10. Заборонена операція
        ------------------------------------------

        SET @Testing = 1;

        EXEC sys.sp_executesql
            @TestSql,
            N''@RId BIGINT, @ContextId BIGINT'',
            @RId = @RId,
            @ContextId = @ContextId;

        SET @ErrorMessage =
            N''Operation unexpectedly succeeded.'';

    END TRY
    BEGIN CATCH

        SET @ActualError = ERROR_NUMBER();
        SET @ErrorMessage = ERROR_MESSAGE();

    END CATCH;

    ----------------------------------------------
    -- 3.11. Відкочення
    ----------------------------------------------

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    IF @Impersonated = 1
        REVERT;

    INSERT INTO @Results
    VALUES
    (
        @TestId,
        @TestName,
        @ExpectedError,
        @ActualError,
        CASE
            WHEN @Testing = 1
             AND @ActualError = @ExpectedError
            THEN ''PASS''
            ELSE ''FAIL''
        END,
        CASE
            WHEN @Testing = 0
            THEN CONCAT(
                N''Test preparation failed: '',
                @ErrorMessage
            )
            ELSE @ErrorMessage
        END
    );

    SET @TestId += 1;

END;

--------------------------------------------------
-- 4. Результати
--------------------------------------------------

SELECT *
FROM @Results
ORDER BY testId;

SELECT
    COUNT(*) AS totalTests,
    SUM(CASE WHEN result = ''PASS'' THEN 1 ELSE 0 END)
        AS passedTests,
    SUM(CASE WHEN result = ''FAIL'' THEN 1 ELSE 0 END)
        AS failedTests
FROM @Results;

--------------------------------------------------
-- 5. Перевірка відкочення
--------------------------------------------------

SELECT
    delivererIntentId,
    orderStatusCode,
    availableMaxWeight,
    CASE
        WHEN orderStatusCode = ''Published''
         AND availableMaxWeight = 15
        THEN ''PASS''
        ELSE ''FAIL''
    END AS rollbackCheck
FROM dbo.DelivererIntent
WHERE delivererIntentId = 4;

SELECT
    @HistoryBefore AS historyBefore,
    COUNT_BIG(*) AS historyAfter,
    CASE
        WHEN COUNT_BIG(*) = @HistoryBefore
        THEN ''PASS''
        ELSE ''FAIL''
    END AS historyRollbackCheck
FROM dbo.DelivererIntentHistory
WHERE delivererIntentId = 4;

SELECT
    (SELECT COUNT_BIG(*)
     FROM dbo.DeliveryRequesterShipment) AS shipments,

    (SELECT COUNT_BIG(*)
     FROM dbo.DeliveryRequesterIntent) AS requesterOrders,

    (SELECT COUNT_BIG(*)
     FROM dbo.InteractionContext) AS interactions,

    (SELECT COUNT_BIG(*)
     FROM dbo.CollaborativeDeal) AS deals;

IF EXISTS (SELECT 1 FROM @Results WHERE result <> ''PASS'')
OR (SELECT COUNT(*) FROM @Results) <> 15
OR NOT EXISTS (SELECT 1 FROM dbo.DelivererIntent WHERE delivererIntentId=4 AND orderStatusCode=''Published'' AND availableMaxWeight=15)
OR (SELECT COUNT_BIG(*) FROM dbo.DelivererIntentHistory WHERE delivererIntentId=4) <> @HistoryBefore
OR EXISTS (SELECT 1 FROM dbo.DeliveryRequesterShipment)
OR EXISTS (SELECT 1 FROM dbo.DeliveryRequesterIntent)
OR EXISTS (SELECT 1 FROM dbo.InteractionContext)
OR EXISTS (SELECT 1 FROM dbo.CollaborativeDeal)
    THROW 51933,N''Negative interaction/deal tests or rollback checks failed.'',1;';
IF @@TRANCOUNT <> 0 THROW 51934,N'Unexpected open test transaction.',1;

    SELECT N'All 52 original smoke checks completed (49 + 3 UserSettings).' AS result;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
