-- Separate smoke test from the supplied successful script.
-- Runs test data inside transactions and rolls them back; IDENTITY gaps may remain.
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N'PassBy'
    THROW 51900, N'Incorrect target database.', 1;

IF @@TRANCOUNT <> 0
    THROW 51901, N'An existing transaction is active.', 1;

DECLARE
    @Step NVARCHAR(200) = N'Initialization',
    @Impersonated BIT = 0,

    @Deliverer BIGINT,
    @Requester BIGINT,
    @ThirdUser BIGINT,

    @ShipmentId BIGINT,
    @DId BIGINT,
    @RId BIGINT,
    @ContextId BIGINT,
    @DealId BIGINT,
    @CancelledDealId BIGINT,

    @PaymentReference NVARCHAR(100) =
        CONCAT(N'SMOKE-', NEWID());

BEGIN TRY

    BEGIN TRANSACTION;


    --------------------------------------------------
    -- 1. Підготовка тестових даних
    --------------------------------------------------

    SET @Step = N'Prepare test data';

    SELECT TOP (1)
        @Deliverer = d.userId,
        @Requester = r.userId
    FROM dbo.Deliverer AS d
    CROSS JOIN dbo.DeliveryRequester AS r
    INNER JOIN dbo.UserAccount AS du
        ON du.userId = d.userId
    INNER JOIN dbo.UserAccount AS ru
        ON ru.userId = r.userId
    WHERE d.userId <> r.userId
      AND d.isBlocked = 0
      AND r.isBlocked = 0
      AND du.isBlocked = 0
      AND ru.isBlocked = 0
    ORDER BY d.userId, r.userId;

    SELECT TOP (1)
        @ThirdUser = userId
    FROM dbo.UserAccount
    WHERE userId NOT IN (@Deliverer, @Requester)
      AND isBlocked = 0
    ORDER BY userId;

    IF @Deliverer IS NULL
       OR @Requester IS NULL
       OR @ThirdUser IS NULL
        THROW 51902,
            N'Not enough eligible users for smoke testing.',
            1;


    -- Тестова посилка.

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
        @Requester,
        N'SMOKE TEST',
        N'Temporary test shipment',
        1, 10, 10, 10
    );

    SET @ShipmentId = CAST(SCOPE_IDENTITY() AS BIGINT);


    -- Тестовий Order кур'єра.

    INSERT INTO dbo.DelivererIntent
    (
        startingCoordinates,
        endCoordinates,
        departureTimeAtUtc,
        orderStatusCode,
        authorDelivererUserId
    )
    VALUES
    (
        geography::Point(50.0, 36.2, 4326),
        geography::Point(50.1, 36.3, 4326),
        DATEADD(DAY, 1, SYSUTCDATETIME()),
        'Published',
        @Deliverer
    );

    SET @DId = CAST(SCOPE_IDENTITY() AS BIGINT);


    -- Тестовий Order замовника.

    INSERT INTO dbo.DeliveryRequesterIntent
    (
        receivingCoordinates,
        destinationCoordinates,
        minPriceWithoutCommission,
        maxPriceWithoutCommission,
        orderStatusCode,
        deliveryRequesterShipmentId,
        authorDeliveryRequesterUserId
    )
    VALUES
    (
        geography::Point(50.0, 36.2, 4326),
        geography::Point(50.1, 36.3, 4326),
        100,
        500,
        'Published',
        @ShipmentId,
        @Requester
    );

    SET @RId = CAST(SCOPE_IDENTITY() AS BIGINT);


    -- Тестова погоджена взаємодія.

    INSERT INTO dbo.InteractionContext
    (
        delivererIntentId,
        deliveryRequesterIntentId,
        requestInitiatorCode,
        interactionStatusCode
    )
    VALUES
    (
        @DId,
        @RId,
        'Deliverer',
        'Mutual'
    );

    SET @ContextId = CAST(SCOPE_IDENTITY() AS BIGINT);

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- Подальші операції виконує backend
    --------------------------------------------------

    EXECUTE AS USER = 'passby_backend';

    SET @Impersonated = 1;


    --------------------------------------------------
    -- 2. Створення чернетки
    --------------------------------------------------

    SET @Step = N'Create draft';

    EXEC dbo.CreateCollaborativeDeal
        @InteractionContextId = @ContextId,
        @ActorUserId = @Deliverer,
        @ReceivingLatitude = 50.0,
        @ReceivingLongitude = 36.2,
        @DestinationLatitude = 50.1,
        @DestinationLongitude = 36.3,
        @FinalPriceWithoutCommission = 300,
        @SenderUserId = @Requester,
        @ReceiverUserId = @ThirdUser;

    SELECT @DealId = collaborativeDealId
    FROM dbo.CollaborativeDeal
    WHERE interactionContextId = @ContextId
      AND dealExecutionStatusCode = 'Draft';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'Draft'
          AND termsRevision = 1
          AND delivererAccepted = 1
          AND deliveryRequesterAccepted = 0
          AND isAgreed = 0
          AND isActive = 1
    )
        THROW 51903, N'Invalid initial draft state.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 3. Резервування Order
    --------------------------------------------------

    SET @Step = N'Order reservation';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = @DId
          AND activeDealId = @DealId
          AND activeDealCount = 1
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
    OR NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDeliveryRequesterIntentDetails
        WHERE deliveryRequesterIntentId = @RId
          AND activeDealId = @DealId
          AND activeDealCount = 1
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
        THROW 51904, N'Order reservation failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 4. Редагування чернетки замовником
    --------------------------------------------------

    SET @Step = N'Update draft and temporal revision';

    EXEC dbo.UpdateCollaborativeDealDraft
        @CollaborativeDealId = @DealId,
        @ActorUserId = @Requester,
        @ExpectedTermsRevision = 1,
        @ReceivingLatitude = 50.0,
        @ReceivingLongitude = 36.2,
        @DestinationLatitude = 50.1,
        @DestinationLongitude = 36.3,
        @FinalPriceWithoutCommission = 350,
        @SenderUserId = @Requester,
        @ReceiverUserId = @ThirdUser;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND termsRevision = 2
          AND finalPriceWithoutCommission = 350
          AND lastProposedByUserId = @Requester
          AND delivererAccepted = 0
          AND deliveryRequesterAccepted = 1
    )
        THROW 51905, N'Draft revision is incorrect.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.CollaborativeDealHistory
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'Draft'
          AND finalPriceWithoutCommission = 300
          AND lastProposedByUserId = @Deliverer
    )
        THROW 51906, N'Previous revision was not preserved.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 5. Надсилання повідомлення
    --------------------------------------------------

    SET @Step = N'Chat before agreement';

    EXEC dbo.SendUserMessage
        @InteractionContextId = @ContextId,
        @AuthorUserId = @Deliverer,
        @MessageText = N'SMOKE TEST: before agreement';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.UserMessage
        WHERE interactionContextId = @ContextId
          AND authorUserId = @Deliverer
          AND userMessageText =
              N'SMOKE TEST: before agreement'
    )
        THROW 51907, N'Message was not created.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 6. Скасування чернетки
    --------------------------------------------------

    SET @Step = N'Cancel draft';

    EXEC dbo.FailCollaborativeDeal
        @CollaborativeDealId = @DealId,
        @ActorUserId = @Deliverer;

    SET @CancelledDealId = @DealId;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'Failed'
          AND termsRevision = 2
          AND isAgreed = 0
          AND isActive = 0
          AND isFinalized = 1
    )
        THROW 51908, N'Draft cancellation failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 7. Звільнення Order
    --------------------------------------------------

    SET @Step = N'Order release';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = @DId
          AND activeDealCount = 0
          AND isAvailableAsTarget = 1
          AND isAvailableAsInitiator = 1
    )
    OR NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDeliveryRequesterIntentDetails
        WHERE deliveryRequesterIntentId = @RId
          AND activeDealCount = 0
          AND isAvailableAsTarget = 1
          AND isAvailableAsInitiator = 1
    )
        THROW 51909, N'Order release failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 8. Повторне створення угоди
    --------------------------------------------------

    SET @Step = N'Recreate draft after cancellation';

    EXEC dbo.CreateCollaborativeDeal
        @InteractionContextId = @ContextId,
        @ActorUserId = @Deliverer,
        @ReceivingLatitude = 50.0,
        @ReceivingLongitude = 36.2,
        @DestinationLatitude = 50.1,
        @DestinationLongitude = 36.3,
        @FinalPriceWithoutCommission = 400,
        @SenderUserId = @Requester,
        @ReceiverUserId = @ThirdUser;

    SET @DealId = NULL;

    SELECT @DealId = collaborativeDealId
    FROM dbo.CollaborativeDeal
    WHERE interactionContextId = @ContextId
      AND dealExecutionStatusCode = 'Draft';

    IF @DealId IS NULL
       OR @DealId = @CancelledDealId
        THROW 51910, N'Draft recreation failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 9. Остаточне погодження
    --
    -- Використовуються тестові байтові значення,
    -- а не справжні зашифровані секрети.
    --------------------------------------------------

    SET @Step = N'Accept deal';

    EXEC dbo.AcceptCollaborativeDeal
        @CollaborativeDealId = @DealId,
        @ActorUserId = @Requester,
        @ExpectedTermsRevision = 1,
        @PickupConfirmationTokenEncrypted = 0x12345678,
        @DeliveryConfirmationTokenEncrypted = 0x87654321;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'AwaitingHandover'
          AND termsRevision = 1
          AND delivererAccepted = 1
          AND deliveryRequesterAccepted = 1
          AND agreedAtUtc IS NOT NULL
          AND isAgreed = 1
    )
        THROW 51911, N'Deal acceptance failed.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.CollaborativeDeal
        WHERE collaborativeDealId = @DealId
          AND pickupConfirmationTokenEncrypted = 0x12345678
          AND deliveryConfirmationTokenEncrypted = 0x87654321
    )
        THROW 51912, N'Confirmation tokens were not saved.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 10. Приєднання третього учасника
    --------------------------------------------------

    SET @Step = N'Chat after agreement';

    EXEC dbo.SendUserMessage
        @InteractionContextId = @ContextId,
        @AuthorUserId = @ThirdUser,
        @MessageText = N'SMOKE TEST: third participant';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.UserMessage
        WHERE interactionContextId = @ContextId
          AND authorUserId = @ThirdUser
          AND userMessageText =
              N'SMOKE TEST: third participant'
    )
        THROW 51913, N'Third participant message failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 11. Реєстрація платіжної спроби
    --------------------------------------------------

    SET @Step = N'Create payment attempt';

    EXEC dbo.CreatePaymentOperationAttempt
        @CollaborativeDealId = @DealId,
        @OperationType = 'AUTH',
        @Amount = 400,
        @Currency = 'UAH',
        @OrderReference = @PaymentReference,
        @AttemptStatusCode = 'Succeeded',
        @PaymentMethodId = NULL;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.PaymentOperationAttempt
        WHERE collaborativeDealId = @DealId
          AND orderReference = @PaymentReference
          AND operationType = 'AUTH'
          AND amount = 400
    )
        THROW 51914, N'Payment attempt was not created.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 12. Передача посилки кур'єру
    --------------------------------------------------

    SET @Step = N'Confirm handover';

    EXEC dbo.ConfirmDealHandover
        @CollaborativeDealId = @DealId;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'InTransit'
          AND termsRevision = 1
    )
        THROW 51915, N'Handover transition failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 13. Передача посилки отримувачу
    --------------------------------------------------

    SET @Step = N'Confirm delivery';

    EXEC dbo.ConfirmDealDelivery
        @CollaborativeDealId = @DealId;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'AwaitingPayout'
          AND termsRevision = 1
    )
        THROW 51916, N'Delivery transition failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 14. Завершення угоди
    --------------------------------------------------

    SET @Step = N'Complete deal';

    EXEC dbo.CompleteCollaborativeDeal
        @CollaborativeDealId = @DealId;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vCollaborativeDealDetails
        WHERE collaborativeDealId = @DealId
          AND dealExecutionStatusCode = 'Fulfilled'
          AND termsRevision = 1
          AND isAgreed = 1
          AND isActive = 0
          AND isFinalized = 1
    )
        THROW 51917, N'Deal completion failed.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 15. Остаточне блокування Order
    --------------------------------------------------

    SET @Step = N'Fulfilled order availability';

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDelivererIntentDetails
        WHERE delivererIntentId = @DId
          AND fulfilledDealCount = 1
          AND activeDealCount = 0
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
    OR NOT EXISTS
    (
        SELECT 1
        FROM dbo.vDeliveryRequesterIntentDetails
        WHERE deliveryRequesterIntentId = @RId
          AND fulfilledDealCount = 1
          AND activeDealCount = 0
          AND isAvailableAsTarget = 0
          AND isAvailableAsInitiator = 0
    )
        THROW 51918, N'Fulfilled orders remain available.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 16. Повна історія виконання
    --------------------------------------------------

    SET @Step = N'Complete temporal history';

    IF
    (
        SELECT COUNT_BIG(*)
        FROM dbo.CollaborativeDealHistory
        WHERE collaborativeDealId = @DealId
    ) <> 4
        THROW 51919, N'Unexpected history size.', 1;

    SELECT @Step AS testName, 'PASS' AS result;


    --------------------------------------------------
    -- 17. Відображення фінальних результатів
    --------------------------------------------------

    SELECT
        collaborativeDealId,
        dealExecutionStatusCode,
        termsRevision,
        finalPriceWithoutCommission,
        delivererAccepted,
        deliveryRequesterAccepted,
        isAgreed,
        isActive,
        isFinalized
    FROM dbo.vCollaborativeDealDetails
    WHERE interactionContextId = @ContextId
    ORDER BY collaborativeDealId;


    SELECT
        collaborativeDealId,
        dealExecutionStatusCode,
        finalPriceWithoutCommission,
        lastProposedByUserId,
        validFrom,
        validTo
    FROM dbo.CollaborativeDealHistory
    WHERE collaborativeDealId IN
        (@DealId, @CancelledDealId)
    ORDER BY
        collaborativeDealId,
        validFrom,
        validTo;


    --------------------------------------------------
    -- 18. Відкочення ВСІХ тестових записів
    --------------------------------------------------

    REVERT;

    SET @Impersonated = 0;

    ROLLBACK TRANSACTION;

    SELECT
        N'ALL LIFECYCLE SMOKE TESTS PASSED' AS result,
        N'Test data rolled back' AS cleanup;

END TRY
BEGIN CATCH

    IF @Impersonated = 1
    BEGIN
        REVERT;
        SET @Impersonated = 0;
    END;

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        @Step AS failedTest,
        'FAIL' AS result,
        ERROR_NUMBER() AS errorNumber,
        ERROR_MESSAGE() AS errorMessage,
        ERROR_PROCEDURE() AS errorProcedure,
        ERROR_LINE() AS errorLine,
        N'Test transaction rolled back' AS cleanup;

END CATCH;


------------------------------------------------------
-- 19. Незалежна перевірка захисту Temporal History
------------------------------------------------------

SET XACT_ABORT OFF;

BEGIN TRY

    BEGIN TRANSACTION;

    EXECUTE AS USER = 'passby_backend';

    SET @Impersonated = 1;

    EXEC sys.sp_executesql N'
        INSERT INTO dbo.CollaborativeDealHistory
        SELECT *
        FROM dbo.CollaborativeDealHistory
        WHERE 1 = 0;
    ';

    REVERT;

    SET @Impersonated = 0;

    ROLLBACK TRANSACTION;

    SELECT
        N'Direct history insert protection' AS testName,
        'FAIL' AS result,
        N'Unexpected INSERT permission' AS details;

END TRY
BEGIN CATCH

    IF @Impersonated = 1
    BEGIN
        REVERT;
        SET @Impersonated = 0;
    END;

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        N'Direct history insert protection' AS testName,
        CASE
            WHEN ERROR_NUMBER() IN (229, 13559)
                THEN 'PASS'
            ELSE 'UNEXPECTED ERROR'
        END AS result,
        ERROR_NUMBER() AS errorNumber,
        ERROR_MESSAGE() AS details;

END CATCH;


------------------------------------------------------
-- 20. Перевірка очищення тестових даних
------------------------------------------------------

SELECT
    @@TRANCOUNT AS remainingTransactions,

    (
        SELECT COUNT_BIG(*)
        FROM dbo.InteractionContext
        WHERE interactionContextId = @ContextId
    ) AS remainingTestInteractions,

    (
        SELECT COUNT_BIG(*)
        FROM dbo.CollaborativeDeal
        WHERE interactionContextId = @ContextId
    ) AS remainingTestDeals,

    (
        SELECT COUNT_BIG(*)
        FROM dbo.CollaborativeDealHistory
        WHERE interactionContextId = @ContextId
    ) AS remainingTestHistory,

    (
        SELECT COUNT_BIG(*)
        FROM dbo.PaymentOperationAttempt
        WHERE orderReference = @PaymentReference
    ) AS remainingTestPayments;

SET XACT_ABORT ON;
