USE [PassBy]
GO

-- Глобальна структурна заборона на додавання налаштувань системи з ціноутворення
CREATE OR ALTER TRIGGER dbo.TR_PricingPolicy_BlockInsertDelete
ON dbo.PricingPolicy
AFTER INSERT, DELETE
AS
/*
    Заборона створення та видалення записів.

    AFTER-тригер відхиляє INSERT і DELETE.
    UPDATE залишається дозволеним.
*/
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM inserted)
       OR EXISTS (SELECT 1 FROM deleted)
    BEGIN;
        THROW 51001,
            N'PricingPolicy: INSERT and DELETE are prohibited.',
            1;
    END;
END;
GO

-- Процедура для додавання Order-у в DelivererIntent
CREATE OR ALTER PROCEDURE dbo.CreateDelivererOrder
    @AuthorDelivererUserId BIGINT,

    @StartLatitude FLOAT,
    @StartLongitude FLOAT,
    @EndLatitude FLOAT,
    @EndLongitude FLOAT,

    @DepartureTimeAtUtc DATETIME2(7),

    @AvailableMaxWeight DECIMAL(12,3) = NULL,
    @AvailableMaxLength DECIMAL(12,3) = NULL,
    @AvailableMaxDepth DECIMAL(12,3) = NULL,
    @AvailableMaxHeight DECIMAL(12,3) = NULL,

    @MinRewardReceived DECIMAL(18,2) = NULL,
    @MaxRewardReceived DECIMAL(18,2) = NULL,

    @SaveAsDraft BIT = 0
AS
BEGIN
    /*
        Створення звичайного Order кур'єра.

        Draft має пріоритет над політикою публікації.
        0 = Manual, 1 = Automatic.

        За відсутності UserSettings:
            використовується Manual.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Policy BIT = 0;
    DECLARE @InitialStatus VARCHAR(64);

    IF @SaveAsDraft IS NULL
        THROW 51010, N'SaveAsDraft cannot be NULL.', 1;

    IF @StartLatitude IS NULL
       OR @StartLongitude IS NULL
       OR @EndLatitude IS NULL
       OR @EndLongitude IS NULL
       OR @StartLatitude NOT BETWEEN -90 AND 90
       OR @EndLatitude NOT BETWEEN -90 AND 90
       OR @StartLongitude NOT BETWEEN -180 AND 180
       OR @EndLongitude NOT BETWEEN -180 AND 180
        THROW 51011, N'Invalid coordinates.', 1;

    IF @DepartureTimeAtUtc IS NULL
        THROW 51012, N'Departure time is required.', 1;

    SELECT @Policy = orderPublishingPolicy
    FROM dbo.UserSettings
    WHERE userId = @AuthorDelivererUserId;

    SET @InitialStatus =
        CASE
            WHEN @SaveAsDraft = 1 THEN 'Draft'
            WHEN @Policy = 1 THEN 'Published'
            ELSE 'Private'
        END;

    INSERT INTO dbo.DelivererIntent
    (
        startingCoordinates,
        endCoordinates,
        availableMaxWeight,
        availableMaxLength,
        availableMaxDepth,
        availableMaxHeight,
        minRewardReceived,
        maxRewardReceived,
        departureTimeAtUtc,
        orderStatusCode,
        authorDelivererUserId
    )
    VALUES
    (
        geography::Point(
            @StartLatitude, @StartLongitude, 4326
        ),
        geography::Point(
            @EndLatitude, @EndLongitude, 4326
        ),
        @AvailableMaxWeight,
        @AvailableMaxLength,
        @AvailableMaxDepth,
        @AvailableMaxHeight,
        @MinRewardReceived,
        @MaxRewardReceived,
        @DepartureTimeAtUtc,
        @InitialStatus,
        @AuthorDelivererUserId
    );

    SELECT
        CAST(SCOPE_IDENTITY() AS BIGINT)
            AS delivererIntentId,
        @InitialStatus AS orderStatusCode;
END;
GO
-- Заборона зміни сутностей DelivererIntent у фінальних станах
CREATE OR ALTER TRIGGER dbo.TR_DelivererIntent_ImmutableFinalStates
ON dbo.DelivererIntent
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Незмінність DelivererIntent:

        1. RawIntent не можна редагувати або видаляти.
        2. Звичайний Order не можна перетворювати
           на RawIntent через UPDATE.
        3. Order із хоча б однією Fulfilled-угодою
           не можна редагувати або видаляти.

        Підтримуються масові UPDATE і DELETE.
    */

    -- Незмінність RawIntent.
    IF EXISTS
    (
        SELECT 1
        FROM deleted
        WHERE orderStatusCode = 'RawIntent'
    )
    OR EXISTS
    (
        SELECT 1
        FROM inserted
        WHERE orderStatusCode = 'RawIntent'
    )
    BEGIN
        THROW 51002,
            N'DelivererIntent: RawIntent records are immutable.',
            1;
    END;

    -- Незмінність остаточно виконаного Order.
    IF EXISTS
    (
        SELECT 1
        FROM deleted AS d

        INNER JOIN dbo.InteractionContext AS ic
            ON ic.delivererIntentId = d.delivererIntentId

        INNER JOIN dbo.CollaborativeDeal AS cd
            ON cd.interactionContextId =
               ic.interactionContextId

        WHERE cd.dealExecutionStatusCode = 'Fulfilled'
    )
    BEGIN
        THROW 51160,
            N'DelivererIntent: fulfilled Order is immutable.',
            1;
    END;
END;
GO

-- Процедура для додавання Order-у в DeliveryRequesterIntent
CREATE OR ALTER PROCEDURE dbo.CreateDeliveryRequesterOrder
    @AuthorDeliveryRequesterUserId BIGINT,
    @DeliveryRequesterShipmentId BIGINT,

    @ReceivingLatitude FLOAT,
    @ReceivingLongitude FLOAT,
    @DestinationLatitude FLOAT,
    @DestinationLongitude FLOAT,

    @MinPriceWithoutCommission DECIMAL(18,2) = NULL,
    @MaxPriceWithoutCommission DECIMAL(18,2) = NULL,

    @SaveAsDraft BIT = 0
AS
BEGIN
    /*
        Створення звичайного Order замовника.

        Посилка повинна належати автору.
        Відповідність гарантує складений FK.

        Draft має пріоритет над політикою публікації.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Policy BIT = 0;
    DECLARE @InitialStatus VARCHAR(64);

    IF @SaveAsDraft IS NULL
        THROW 51013, N'SaveAsDraft cannot be NULL.', 1;

    IF @ReceivingLatitude IS NULL
       OR @ReceivingLongitude IS NULL
       OR @DestinationLatitude IS NULL
       OR @DestinationLongitude IS NULL
       OR @ReceivingLatitude NOT BETWEEN -90 AND 90
       OR @DestinationLatitude NOT BETWEEN -90 AND 90
       OR @ReceivingLongitude NOT BETWEEN -180 AND 180
       OR @DestinationLongitude NOT BETWEEN -180 AND 180
        THROW 51014, N'Invalid coordinates.', 1;

    SELECT @Policy = orderPublishingPolicy
    FROM dbo.UserSettings
    WHERE userId = @AuthorDeliveryRequesterUserId;

    SET @InitialStatus =
        CASE
            WHEN @SaveAsDraft = 1 THEN 'Draft'
            WHEN @Policy = 1 THEN 'Published'
            ELSE 'Private'
        END;

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
        geography::Point(
            @ReceivingLatitude, @ReceivingLongitude, 4326
        ),
        geography::Point(
            @DestinationLatitude, @DestinationLongitude, 4326
        ),
        @MinPriceWithoutCommission,
        @MaxPriceWithoutCommission,
        @InitialStatus,
        @DeliveryRequesterShipmentId,
        @AuthorDeliveryRequesterUserId
    );

    SELECT
        CAST(SCOPE_IDENTITY() AS BIGINT)
            AS participantOrderId,
        @InitialStatus AS orderStatusCode;
END;
GO
-- Заборона зміни сутностей DeliveryRequesterIntent у фінальних станах
CREATE OR ALTER TRIGGER dbo.TR_DeliveryRequesterIntent_ImmutableFinalStates
ON dbo.DeliveryRequesterIntent
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Незмінність DeliveryRequesterIntent:

        1. RawIntent не можна редагувати або видаляти.
        2. Звичайний Order не можна перетворювати
           на RawIntent через UPDATE.
        3. Order із хоча б однією Fulfilled-угодою
           не можна редагувати або видаляти.

        Підтримуються масові UPDATE і DELETE.
    */

    -- Незмінність RawIntent.
    IF EXISTS
    (
        SELECT 1
        FROM deleted
        WHERE orderStatusCode = 'RawIntent'
    )
    OR EXISTS
    (
        SELECT 1
        FROM inserted
        WHERE orderStatusCode = 'RawIntent'
    )
    BEGIN
        THROW 51013,
            N'DeliveryRequesterIntent: RawIntent records are immutable.',
            1;
    END;

    -- Незмінність остаточно виконаного Order.
    IF EXISTS
    (
        SELECT 1
        FROM deleted AS r

        INNER JOIN dbo.InteractionContext AS ic
            ON ic.deliveryRequesterIntentId =
               r.deliveryRequesterIntentId

        INNER JOIN dbo.CollaborativeDeal AS cd
            ON cd.interactionContextId =
               ic.interactionContextId

        WHERE cd.dealExecutionStatusCode = 'Fulfilled'
    )
    BEGIN
        THROW 51161,
            N'DeliveryRequesterIntent: fulfilled Order is immutable.',
            1;
    END;
END;
GO

-- Процедура для додавання нових взаємодій та автоматичне формування RawIntent
CREATE OR ALTER PROCEDURE dbo.CreateInteractionContext
    @RequestInitiatorCode VARCHAR(64),
    @InitiatorUserId BIGINT,
    @TargetOrderId BIGINT,

    @InitiatorOrderId BIGINT = NULL,

    -- Координати нового наміру з параметрів пошуку.
    @FromLatitude FLOAT = NULL,
    @FromLongitude FLOAT = NULL,
    @ToLatitude FLOAT = NULL,
    @ToLongitude FLOAT = NULL,

    -- Новий DelivererIntent.
    @DepartureTimeAtUtc DATETIME2(7) = NULL,
    @AvailableMaxWeight DECIMAL(12,3) = NULL,
    @AvailableMaxLength DECIMAL(12,3) = NULL,
    @AvailableMaxDepth DECIMAL(12,3) = NULL,
    @AvailableMaxHeight DECIMAL(12,3) = NULL,
    @MinRewardReceived DECIMAL(18,2) = NULL,
    @MaxRewardReceived DECIMAL(18,2) = NULL,

    -- Новий DeliveryRequesterIntent.
    @DeliveryRequesterShipmentId BIGINT = NULL,
    @MinPriceWithoutCommission DECIMAL(18,2) = NULL,
    @MaxPriceWithoutCommission DECIMAL(18,2) = NULL
AS
BEGIN
    /*
        Призначення:
            Створення односторонньої взаємодії.

        Сценарії:
            1. InitiatorOrderId заданий:
               використати два готових Order.

            2. InitiatorOrderId = NULL:
               створити RawIntent із параметрів пошуку.

        Доступність:
            Перевіряється за агрегованими VIEW
            усередині транзакції.

        Конкурентність:
            Для обох готових намірів отримуються
            application locks у визначеному порядку.

            Процедури створення угод та зміни
            доступності повинні використовувати
            той самий протокол блокування.
    */

    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @RequestInitiatorCode IS NULL
       OR @RequestInitiatorCode NOT IN
          ('Deliverer', 'DeliveryRequester')
        THROW 51020, N'Invalid initiator role.', 1;

    IF @InitiatorUserId IS NULL
       OR @TargetOrderId IS NULL
        THROW 51021, N'Initiator and target are required.', 1;

    IF @InitiatorOrderId IS NULL
    BEGIN
        IF @FromLatitude IS NULL
           OR @FromLongitude IS NULL
           OR @ToLatitude IS NULL
           OR @ToLongitude IS NULL
           OR @FromLatitude NOT BETWEEN -90 AND 90
           OR @ToLatitude NOT BETWEEN -90 AND 90
           OR @FromLongitude NOT BETWEEN -180 AND 180
           OR @ToLongitude NOT BETWEEN -180 AND 180
            THROW 51022, N'Invalid search coordinates.', 1;
    END;

    DECLARE @DelivererIntentId BIGINT;
    DECLARE @DeliveryRequesterIntentId BIGINT;
    DECLARE @InteractionContextId BIGINT;

    DECLARE @TargetResource NVARCHAR(255);
    DECLARE @InitiatorResource NVARCHAR(255);
    DECLARE @FirstResource NVARCHAR(255);
    DECLARE @SecondResource NVARCHAR(255);
    DECLARE @LockResult INT;

    /*
        Ресурси блокування:

        D = DelivererIntent
        R = DeliveryRequesterIntent

        Однакове ім'я ресурсу для будь-якої операції
        над конкретним наміром.
    */

    SET @TargetResource = CONCAT(
        N'PassBy:Intent:',
        CASE
            WHEN @RequestInitiatorCode = 'Deliverer'
            THEN N'R:'
            ELSE N'D:'
        END,
        CONVERT(NVARCHAR(20), @TargetOrderId)
    );

    IF @InitiatorOrderId IS NOT NULL
    BEGIN
        SET @InitiatorResource = CONCAT(
            N'PassBy:Intent:',
            CASE
                WHEN @RequestInitiatorCode = 'Deliverer'
                THEN N'D:'
                ELSE N'R:'
            END,
            CONVERT(NVARCHAR(20), @InitiatorOrderId)
        );
    END;

    /*
        Сортуємо ресурси, щоб транзакції
        брали блокування в однаковому порядку.
    */

    IF @InitiatorResource IS NULL
    BEGIN
        SET @FirstResource = @TargetResource;
    END
    ELSE IF
        @TargetResource COLLATE Latin1_General_100_BIN2
        < @InitiatorResource COLLATE Latin1_General_100_BIN2
    BEGIN
        SET @FirstResource = @TargetResource;
        SET @SecondResource = @InitiatorResource;
    END
    ELSE
    BEGIN
        SET @FirstResource = @InitiatorResource;
        SET @SecondResource = @TargetResource;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @FirstResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 51030, N'Failed to lock Order.', 1;

        IF @SecondResource IS NOT NULL
        BEGIN
            EXEC @LockResult = sys.sp_getapplock
                @Resource = @SecondResource,
                @LockMode = 'Exclusive',
                @LockOwner = 'Transaction',
                @LockTimeout = 10000;

            IF @LockResult < 0
                THROW 51031, N'Failed to lock second Order.', 1;
        END;

        IF @RequestInitiatorCode = 'Deliverer'
        BEGIN
            /*
                Ініціатор: Deliverer.
                Ціль: DeliveryRequesterIntent.
            */

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.DeliveryRequesterIntent
                    WITH (UPDLOCK, HOLDLOCK)
                WHERE deliveryRequesterIntentId = @TargetOrderId
                  AND orderStatusCode = 'Published'
            )
                THROW 51023, N'Target Order is not published.', 1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.vDeliveryRequesterIntentDetails
                WHERE deliveryRequesterIntentId = @TargetOrderId
                  AND isAvailableAsTarget = 1
            )
                THROW 51024, N'Target Order is unavailable.', 1;

            SET @DeliveryRequesterIntentId = @TargetOrderId;

            IF @InitiatorOrderId IS NOT NULL
            BEGIN
                IF NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.DelivererIntent
                        WITH (UPDLOCK, HOLDLOCK)
                    WHERE delivererIntentId = @InitiatorOrderId
                      AND authorDelivererUserId = @InitiatorUserId
                      AND orderStatusCode IN ('Private', 'Published')
                )
                    THROW 51025, N'Invalid initiator Order.', 1;

                IF NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.vDelivererIntentDetails
                    WHERE delivererIntentId = @InitiatorOrderId
                      AND isAvailableAsInitiator = 1
                )
                    THROW 51026, N'Initiator Order is unavailable.', 1;

                SET @DelivererIntentId = @InitiatorOrderId;
            END
            ELSE
            BEGIN
                IF @DepartureTimeAtUtc IS NULL
                    THROW 51027, N'Departure time is required.', 1;

                INSERT INTO dbo.DelivererIntent
                (
                    startingCoordinates,
                    endCoordinates,
                    availableMaxWeight,
                    availableMaxLength,
                    availableMaxDepth,
                    availableMaxHeight,
                    minRewardReceived,
                    maxRewardReceived,
                    departureTimeAtUtc,
                    orderStatusCode,
                    authorDelivererUserId
                )
                VALUES
                (
                    geography::Point(
                        @FromLatitude, @FromLongitude, 4326
                    ),
                    geography::Point(
                        @ToLatitude, @ToLongitude, 4326
                    ),
                    @AvailableMaxWeight,
                    @AvailableMaxLength,
                    @AvailableMaxDepth,
                    @AvailableMaxHeight,
                    @MinRewardReceived,
                    @MaxRewardReceived,
                    @DepartureTimeAtUtc,
                    'RawIntent',
                    @InitiatorUserId
                );

                SET @DelivererIntentId =
                    CAST(SCOPE_IDENTITY() AS BIGINT);
            END;
        END
        ELSE
        BEGIN
            /*
                Ініціатор: DeliveryRequester.
                Ціль: DelivererIntent.
            */

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.DelivererIntent
                    WITH (UPDLOCK, HOLDLOCK)
                WHERE delivererIntentId = @TargetOrderId
                  AND orderStatusCode = 'Published'
            )
                THROW 51028, N'Target Order is not published.', 1;

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.vDelivererIntentDetails
                WHERE delivererIntentId = @TargetOrderId
                  AND isAvailableAsTarget = 1
            )
                THROW 51029, N'Target Order is unavailable.', 1;

            SET @DelivererIntentId = @TargetOrderId;

            IF @InitiatorOrderId IS NOT NULL
            BEGIN
                IF NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.DeliveryRequesterIntent
                        WITH (UPDLOCK, HOLDLOCK)
                    WHERE deliveryRequesterIntentId = @InitiatorOrderId
                      AND authorDeliveryRequesterUserId = @InitiatorUserId
                      AND orderStatusCode IN ('Private', 'Published')
                )
                    THROW 51032, N'Invalid initiator Order.', 1;

                IF NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.vDeliveryRequesterIntentDetails
                    WHERE deliveryRequesterIntentId = @InitiatorOrderId
                      AND isAvailableAsInitiator = 1
                )
                    THROW 51033, N'Initiator Order is unavailable.', 1;

                SET @DeliveryRequesterIntentId = @InitiatorOrderId;
            END
            ELSE
            BEGIN
                IF @DeliveryRequesterShipmentId IS NULL
                    THROW 51034, N'Shipment is required.', 1;

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
                    geography::Point(
                        @FromLatitude, @FromLongitude, 4326
                    ),
                    geography::Point(
                        @ToLatitude, @ToLongitude, 4326
                    ),
                    @MinPriceWithoutCommission,
                    @MaxPriceWithoutCommission,
                    'RawIntent',
                    @DeliveryRequesterShipmentId,
                    @InitiatorUserId
                );

                SET @DeliveryRequesterIntentId =
                    CAST(SCOPE_IDENTITY() AS BIGINT);
            END;
        END;

        -- Заборона взаємодії користувача із самим собою.
        IF EXISTS
        (
            SELECT 1
            FROM dbo.DelivererIntent AS d
            INNER JOIN dbo.DeliveryRequesterIntent AS r
                ON d.delivererIntentId = @DelivererIntentId
               AND r.deliveryRequesterIntentId = @DeliveryRequesterIntentId
            WHERE d.authorDelivererUserId =
                  r.authorDeliveryRequesterUserId
        )
            THROW 51035,
                N'Self-interaction is not allowed.',
                1;

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
            'Unilateral'
        );

        SET @InteractionContextId =
            CAST(SCOPE_IDENTITY() AS BIGINT);

        COMMIT TRANSACTION;

        SELECT
            @InteractionContextId AS interactionContextId,
            @DelivererIntentId AS delivererIntentId,
            @DeliveryRequesterIntentId
                AS deliveryRequesterIntentId,
            'Unilateral' AS interactionStatusCode;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

-- Процедура прийняття взаємодії
CREATE OR ALTER PROCEDURE dbo.AcceptInteractionContext
    @InteractionContextId BIGINT,
    @ResponderUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        Призначення:
            Підтвердження односторонньої взаємодії
            другою стороною.

        Перехід:
            Unilateral -> Mutual

        Обмеження:
            - Взаємодія повинна існувати.
            - Поточний стан: Unilateral.
            - ResponderUserId повинен бути автором
              цільового Order.
            - Повторне підтвердження заборонено.

        Примітка:
            ResponderUserId повинен надходити
            із перевіреного контексту автентифікації.
    */

    IF @InteractionContextId IS NULL
       OR @ResponderUserId IS NULL
    BEGIN
        THROW 51040,
            N'InteractionContextId and ResponderUserId are required.',
            1;
    END;

    UPDATE ic
    SET interactionStatusCode = 'Mutual'
    FROM dbo.InteractionContext AS ic
    WHERE ic.interactionContextId = @InteractionContextId
      AND ic.interactionStatusCode = 'Unilateral'
      AND
      (
          (
              ic.requestInitiatorCode = 'Deliverer'
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.DeliveryRequesterIntent AS r
                  WHERE r.deliveryRequesterIntentId =
                        ic.deliveryRequesterIntentId
                    AND r.authorDeliveryRequesterUserId =
                        @ResponderUserId
              )
          )
          OR
          (
              ic.requestInitiatorCode = 'DeliveryRequester'
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.DelivererIntent AS d
                  WHERE d.delivererIntentId =
                        ic.delivererIntentId
                    AND d.authorDelivererUserId =
                        @ResponderUserId
              )
          )
      );

    IF @@ROWCOUNT <> 1
    BEGIN
        THROW 51041,
            N'Interaction cannot be accepted: invalid state or responder.',
            1;
    END;

    SELECT
        interactionContextId,
        interactionStatusCode
    FROM dbo.InteractionContext
    WHERE interactionContextId = @InteractionContextId;
END;
GO
-- Процедура відхилення взаємодії
CREATE OR ALTER PROCEDURE dbo.RejectInteractionContext
    @InteractionContextId BIGINT,
    @ResponderUserId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        Призначення:
            Відхилення односторонньої взаємодії
            власником цільового Order.

        Перехід:
            Unilateral -> Rejected

        Обмеження:
            - Поточний стан: Unilateral.
            - Дію виконує власник цільового Order.
            - Повторне відхилення заборонено.
            - Відхилення Mutual не підтримується
              цією процедурою.
    */

    IF @InteractionContextId IS NULL
       OR @ResponderUserId IS NULL
    BEGIN
        THROW 51042,
            N'InteractionContextId and ResponderUserId are required.',
            1;
    END;

    UPDATE ic
    SET interactionStatusCode = 'Rejected'
    FROM dbo.InteractionContext AS ic
    WHERE ic.interactionContextId = @InteractionContextId
      AND ic.interactionStatusCode = 'Unilateral'
      AND
      (
          (
              ic.requestInitiatorCode = 'Deliverer'
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.DeliveryRequesterIntent AS r
                  WHERE r.deliveryRequesterIntentId =
                        ic.deliveryRequesterIntentId
                    AND r.authorDeliveryRequesterUserId =
                        @ResponderUserId
              )
          )
          OR
          (
              ic.requestInitiatorCode = 'DeliveryRequester'
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.DelivererIntent AS d
                  WHERE d.delivererIntentId =
                        ic.delivererIntentId
                    AND d.authorDelivererUserId =
                        @ResponderUserId
              )
          )
      );

    IF @@ROWCOUNT <> 1
    BEGIN
        THROW 51043,
            N'Interaction cannot be rejected: invalid state or responder.',
            1;
    END;

    SELECT
        interactionContextId,
        interactionStatusCode
    FROM dbo.InteractionContext
    WHERE interactionContextId = @InteractionContextId;
END;
GO

-- Допоміжна для конкурентних змін
CREATE OR ALTER PROCEDURE dbo.AcquireInteractionIntentLocks
    @InteractionContextId BIGINT,
    @DelivererIntentId BIGINT OUTPUT,
    @DeliveryRequesterIntentId BIGINT OUTPUT,
    @RequestInitiatorCode VARCHAR(64) OUTPUT,
    @InteractionStatusCode VARCHAR(64) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT = 0
        THROW 51100, N'Active transaction required.', 1;

    /*
        Спочатку отримуємо ідентифікатори.
        Поки не утримуємо блокування контексту.
    */

    SELECT
        @DelivererIntentId = delivererIntentId,
        @DeliveryRequesterIntentId = deliveryRequesterIntentId
    FROM dbo.InteractionContext
    WHERE interactionContextId = @InteractionContextId;

    IF @DelivererIntentId IS NULL
       OR @DeliveryRequesterIntentId IS NULL
        THROW 51101, N'InteractionContext not found.', 1;

    DECLARE @DResource NVARCHAR(255) = CONCAT(
        N'PassBy:Intent:D:',
        CONVERT(NVARCHAR(20), @DelivererIntentId)
    );

    DECLARE @RResource NVARCHAR(255) = CONCAT(
        N'PassBy:Intent:R:',
        CONVERT(NVARCHAR(20), @DeliveryRequesterIntentId)
    );

    DECLARE @FirstResource NVARCHAR(255);
    DECLARE @SecondResource NVARCHAR(255);
    DECLARE @LockResult INT;

    IF @DResource COLLATE Latin1_General_100_BIN2
       < @RResource COLLATE Latin1_General_100_BIN2
    BEGIN
        SET @FirstResource = @DResource;
        SET @SecondResource = @RResource;
    END
    ELSE
    BEGIN
        SET @FirstResource = @RResource;
        SET @SecondResource = @DResource;
    END;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @FirstResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @DbPrincipal = 'public',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 51102, N'First intent lock failed.', 1;

    EXEC @LockResult = sys.sp_getapplock
        @Resource = @SecondResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Transaction',
        @DbPrincipal = 'public',
        @LockTimeout = 10000;

    IF @LockResult < 0
        THROW 51103, N'Second intent lock failed.', 1;

    /*
        Тепер фіксуємо контекст і перевіряємо,
        що його зв'язки не змінилися.
    */

    SELECT
        @RequestInitiatorCode = requestInitiatorCode,
        @InteractionStatusCode = interactionStatusCode
    FROM dbo.InteractionContext WITH (UPDLOCK, HOLDLOCK)
    WHERE interactionContextId = @InteractionContextId
      AND delivererIntentId = @DelivererIntentId
      AND deliveryRequesterIntentId =
          @DeliveryRequesterIntentId;

    IF @@ROWCOUNT <> 1
        THROW 51104, N'InteractionContext changed.', 1;
END;
GO
-- Процедура конкурентного створення угоди
CREATE OR ALTER PROCEDURE dbo.CreateCollaborativeDeal
    @InteractionContextId BIGINT,
    @ActorUserId BIGINT,

    @ReceivingLatitude FLOAT,
    @ReceivingLongitude FLOAT,
    @DestinationLatitude FLOAT,
    @DestinationLongitude FLOAT,

    @FinalPriceWithoutCommission DECIMAL(18,2),

    @SenderUserId BIGINT,
    @ReceiverUserId BIGINT,

    @PickupConfirmationTokenHash VARBINARY(32),
    @DeliveryConfirmationTokenHash VARBINARY(32)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        Створення погодженої угоди.

        Правила:

        1. InteractionContext повинен бути Mutual.

        2. ActorUserId повинен бути одним з авторів
           пов'язаних намірів.

        3. Target Order повинен бути Published.

        4. Initiator Intent може бути:
           Private, Published або RawIntent.

        5. Один Order може брати участь
           не більш ніж в одній активній угоді
           одночасно.

        6. Order, який має хоча б одну
           Fulfilled-угоду, не може бути
           використаний повторно.

        7. Failed не блокує повторне
           створення угоди.

        8. Створення атомарне і захищене
           від конкурентних викликів
           через AcquireInteractionIntentLocks.
    */

    -- Валідація обов'язкових параметрів.
    IF @InteractionContextId IS NULL
       OR @ActorUserId IS NULL
       OR @SenderUserId IS NULL
       OR @ReceiverUserId IS NULL
       OR @PickupConfirmationTokenHash IS NULL
       OR @DeliveryConfirmationTokenHash IS NULL
       OR @FinalPriceWithoutCommission IS NULL
       OR @FinalPriceWithoutCommission < 0
        THROW 51110,
            N'Invalid deal parameters.',
            1;

    -- Підтвердження передачі та доставки
    -- повинні використовувати різні токени.
    IF @PickupConfirmationTokenHash =
       @DeliveryConfirmationTokenHash
        THROW 51111,
            N'Confirmation tokens must be different.',
            1;

    -- Валідація координат.
    IF @ReceivingLatitude IS NULL
       OR @ReceivingLongitude IS NULL
       OR @DestinationLatitude IS NULL
       OR @DestinationLongitude IS NULL
       OR @ReceivingLatitude NOT BETWEEN -90 AND 90
       OR @DestinationLatitude NOT BETWEEN -90 AND 90
       OR @ReceivingLongitude NOT BETWEEN -180 AND 180
       OR @DestinationLongitude NOT BETWEEN -180 AND 180
        THROW 51112,
            N'Invalid deal coordinates.',
            1;

    -- Пов'язані наміри та взаємодія.
    DECLARE @DId BIGINT;
    DECLARE @RId BIGINT;

    DECLARE @InitiatorCode VARCHAR(64);
    DECLARE @InteractionStatus VARCHAR(64);

    -- Статуси намірів.
    DECLARE @DStatus VARCHAR(64);
    DECLARE @RStatus VARCHAR(64);

    -- Автори намірів.
    DECLARE @DelivererUserId BIGINT;
    DECLARE @RequesterUserId BIGINT;

    -- Результат створення.
    DECLARE @CreatedDealId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
            Отримуємо блокування обох намірів.

            Процедура також повертає актуальні
            ідентифікатори намірів та параметри
            взаємодії.
        */

        EXEC dbo.AcquireInteractionIntentLocks
            @InteractionContextId = @InteractionContextId,
            @DelivererIntentId = @DId OUTPUT,
            @DeliveryRequesterIntentId = @RId OUTPUT,
            @RequestInitiatorCode = @InitiatorCode OUTPUT,
            @InteractionStatusCode = @InteractionStatus OUTPUT;

        -- Угоду можна створити лише
        -- в погодженій взаємодії.
        IF @InteractionStatus <> 'Mutual'
            THROW 51113,
                N'Interaction must be Mutual.',
                1;

        /*
            Отримуємо актуальні характеристики
            пов'язаних намірів.
        */

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
                N'Linked intents not found.',
                1;

        /*
            Виконавець операції повинен бути
            одним з авторів намірів.
        */

        IF @ActorUserId NOT IN
           (@DelivererUserId, @RequesterUserId)
            THROW 51115,
                N'Actor does not participate in the interaction.',
                1;

        /*
            Перевірка статусів залежно від
            ініціатора взаємодії.

            Target повинен бути Published.

            Initiator:
                Private,
                Published,
                RawIntent.
        */

        IF @InitiatorCode = 'Deliverer'
        BEGIN
            IF @RStatus <> 'Published'
               OR @DStatus NOT IN
                  ('Private', 'Published', 'RawIntent')
                THROW 51116,
                    N'Intents are not eligible for a deal.',
                    1;
        END
        ELSE IF @InitiatorCode = 'DeliveryRequester'
        BEGIN
            IF @DStatus <> 'Published'
               OR @RStatus NOT IN
                  ('Private', 'Published', 'RawIntent')
                THROW 51117,
                    N'Intents are not eligible for a deal.',
                    1;
        END
        ELSE
            THROW 51118,
                N'Invalid interaction initiator.',
                1;

        /*
            Перевірка остаточно виконаних Order.

            Наявність хоча б однієї Fulfilled
            забороняє створення нової угоди.

            Перевіряємо всі взаємодії,
            пов'язані з обома намірами.

            Не використовуємо VIEW.
        */

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
                    OR ic.deliveryRequesterIntentId = @RId
                )
                AND cd.dealExecutionStatusCode = 'Fulfilled'
        )
            THROW 51120,
                N'At least one intent has a fulfilled deal.',
                1;

        /*
            Перевірка активних угод.

            Один Order не може брати участь
            у двох активних угодах одночасно.

            Fulfilled і Failed є завершеними
            станами.

            Failed не перешкоджає повторному
            створенню угоди.
        */

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
                    OR ic.deliveryRequesterIntentId = @RId
                )
                AND cd.dealExecutionStatusCode
                    NOT IN ('Fulfilled', 'Failed')
        )
            THROW 51119,
                N'At least one intent has an active deal.',
                1;

        /*
            Усі перевірки пройдено.

            Створюємо нову активну угоду.
        */

        INSERT INTO dbo.CollaborativeDeal
        (
            receivingCoordinates,
            destinationCoordinates,
            finalPriceWithoutCommission,
            pickupConfirmationTokenHash,
            deliveryConfirmationTokenHash,
            dealExecutionStatusCode,
            senderUserId,
            receiverUserId,
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
            @PickupConfirmationTokenHash,
            @DeliveryConfirmationTokenHash,
            'AwaitingHandover',
            @SenderUserId,
            @ReceiverUserId,
            @InteractionContextId
        );

        SET @CreatedDealId =
            CAST(SCOPE_IDENTITY() AS BIGINT);

        COMMIT TRANSACTION;

        SELECT
            @CreatedDealId AS collaborativeDealId,
            'AwaitingHandover' AS dealExecutionStatusCode;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO
-- Тригер для заборони змінювати та видаляти угоди у фінальних станах
CREATE OR ALTER TRIGGER dbo.TR_CollaborativeDeal_ImmutableFinalStates
ON dbo.CollaborativeDeal
AFTER UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    /*
        Незмінність завершених CollaborativeDeal.

        Правила:

        1. Fulfilled і Failed є фінальними станами.

        2. Після переходу в фінальний стан
           угоду не можна змінювати або видаляти.

        3. Перехід з активного стану в Fulfilled
           або Failed дозволений.

        4. Перевірка підтримує масові операції.
    */

    IF EXISTS
    (
        SELECT 1
        FROM deleted
        WHERE dealExecutionStatusCode
            IN ('Fulfilled', 'Failed')
    )
    BEGIN
        THROW 51162,
            N'CollaborativeDeal: finalized deals are immutable.',
            1;
    END;
END;
GO

-- Процедура для створення(надсилання) повідомлення у чат взаємодії
CREATE OR ALTER PROCEDURE dbo.SendUserMessage
    @InteractionContextId BIGINT,
    @AuthorUserId BIGINT,
    @MessageText NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
        Надсилання повідомлення у взаємодію.

        Правила:

        1. Автор повинен бути учасником чату.

        2. Використовується історична політика
           на момент створення InteractionContext.

        3. Ліміт повідомлень контролюється
           в межах транзакції.

        4. Архівна взаємодія не дозволяє
           надсилати нові повідомлення.

        5. Архівність визначається через
           Fulfilled в ІНШІЙ взаємодії
           будь-якого пов'язаного Order.

        6. Активна угода в іншій взаємодії
           не блокує надсилання повідомлень.

        7. Створення повідомлення атомарне.
    */

    IF @InteractionContextId IS NULL
       OR @AuthorUserId IS NULL
       OR @MessageText IS NULL
        THROW 51040,
            N'Invalid message parameters.',
            1;

    DECLARE
        @InteractionStatusCode VARCHAR(64),
        @InteractionStartAtUtc DATETIME2(7),

        @DelivererIntentId BIGINT,
        @DeliveryRequesterIntentId BIGINT,

        @DelivererUserId BIGINT,
        @DeliveryRequesterUserId BIGINT,

        @CollaborativeDealId BIGINT,
        @SenderUserId BIGINT,
        @ReceiverUserId BIGINT,

        @MaxNumberMessages INT,
        @PolicyFound BIT = 0,

        @MessageCount BIGINT,
        @NewMessageId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
            1. Отримуємо контекст взаємодії.

            UPDLOCK + HOLDLOCK серіалізують
            виклики для одного InteractionContext.

            Додатково отримуємо ID обох Order
            для подальшої перевірки архівності.
        */

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
                N'Interaction context not found.',
                1;

        /*
            2. Шукаємо останню угоду
               поточної взаємодії.

            За відсутності угоди її ID
            залишається NULL.
        */

        SELECT TOP (1)
            @CollaborativeDealId =
                cd.collaborativeDealId,

            @SenderUserId =
                cd.senderUserId,

            @ReceiverUserId =
                cd.receiverUserId

        FROM dbo.CollaborativeDeal AS cd

        WHERE cd.interactionContextId =
              @InteractionContextId

        ORDER BY
            cd.createdAtUtc DESC,
            cd.collaborativeDealId DESC;

        /*
            3. Перевіряємо учасників.

            Кур'єр завжди є учасником чату.

            Якщо угоди немає:
                Кур'єр + замовник.

            Якщо угода є:
                Кур'єр + відправник + отримувач.
        */

        IF
        (
            @AuthorUserId <> @DelivererUserId

            AND
            (
                (
                    @CollaborativeDealId IS NULL

                    AND @AuthorUserId <>
                        @DeliveryRequesterUserId
                )

                OR

                (
                    @CollaborativeDealId IS NOT NULL

                    AND @AuthorUserId <> @SenderUserId

                    AND @AuthorUserId <> @ReceiverUserId
                )
            )
        )
            THROW 51042,
                N'User is not a participant of this chat.',
                1;

        /*
            4. Перевіряємо архівність.

            Взаємодія архівна, якщо хоча б один
            із пов'язаних Order має Fulfilled
            в ІНШОМУ InteractionContext.

            Активні угоди та Failed не блокують
            надсилання повідомлень.

            VIEW не використовується.
        */

        IF EXISTS
        (
            SELECT 1

            FROM dbo.InteractionContext AS related

            INNER JOIN dbo.CollaborativeDeal AS cd
                WITH (HOLDLOCK)
                ON cd.interactionContextId =
                   related.interactionContextId

            WHERE
                related.interactionContextId <>
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
                    'Fulfilled'
        )
            THROW 51045,
                N'Cannot send messages to an archived interaction.',
                1;

        /*
            5. Знаходимо історичну політику.

            Використовуємо поточний статус
            взаємодії та історичну версію
            політики на момент її створення.
        */

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
                N'Chat access policy not found.',
                1;

        /*
            6. Перевіряємо ліміт повідомлень.

            NULL означає необмежений чат.

            Якщо ліміту немає, COUNT
            не виконується.

            Блокування InteractionContext
            захищає від конкурентних викликів
            SendUserMessage для одного чату.
        */

        IF @MaxNumberMessages IS NOT NULL
        BEGIN
            SELECT
                @MessageCount = COUNT_BIG(*)

            FROM dbo.UserMessage

            WHERE interactionContextId =
                  @InteractionContextId;

            IF @MessageCount >= @MaxNumberMessages
                THROW 51044,
                    N'Chat message limit exceeded.',
                    1;
        END;

        /*
            7. Створюємо повідомлення.

            Авторизація, архівність і ліміт
            уже перевірені.
        */

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

        COMMIT TRANSACTION;

        SELECT
            @NewMessageId AS userMessageId,
            @InteractionContextId AS interactionContextId,
            @AuthorUserId AS authorUserId;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO

-- Процедура для PaymentOperationAttempt: перевіряє належність методу оплати замовнику перевезення (лише він може оплачувати виконану угоду)
CREATE OR ALTER PROCEDURE dbo.CreatePaymentOperationAttempt
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

    /*
        Створення історичного запису
        про спробу платіжної операції.

        Перевіряємо:
            - існування угоди;
            - належність зазначеного
              платіжного методу замовнику.

        Не перевіряємо:
            - disabledAtUtc;
            - попередньо використаний метод;
            - результат інших спроб;
            - послідовність платіжних операцій.

        NULL у paymentMethodId дозволений.
    */

    IF @CollaborativeDealId IS NULL
       OR @OperationType IS NULL
       OR @Amount IS NULL
       OR @Currency IS NULL
       OR @OrderReference IS NULL
       OR @AttemptStatusCode IS NULL
        THROW 51220,
            N'Invalid payment attempt parameters.',
            1;

    DECLARE
        @ExpectedPayerUserId BIGINT,
        @NewAttemptId BIGINT;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
            1. Визначаємо замовника угоди
               через DeliveryRequesterIntent.
        */

        SELECT
            @ExpectedPayerUserId =
                r.authorDeliveryRequesterUserId

        FROM dbo.CollaborativeDeal AS cd

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
                N'Collaborative deal not found.',
                1;

        /*
            2. Якщо метод зазначений,
               перевіряємо його власника.

            Стан disabledAtUtc навмисно
            не враховується.
        */

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
                    N'Payment method does not belong to the delivery requester.',
                    1;
        END;

        /*
            3. Створюємо історичну спробу.
        */

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

        COMMIT TRANSACTION;

        SELECT
            @NewAttemptId AS attemptId,
            @CollaborativeDealId AS collaborativeDealId,
            @PaymentMethodId AS paymentMethodId;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;

    END CATCH;
END;
GO

-- Представлення для Order-ів, які описують їх стан більш детально, враховуючи історію участі у взаємодіях та угодах
CREATE OR ALTER VIEW dbo.vDelivererIntentDetails
AS
SELECT
    d.delivererIntentId,
    d.authorDelivererUserId,
    d.startingCoordinates,
    d.endCoordinates,
    d.availableMaxWeight,
    d.availableMaxLength,
    d.availableMaxDepth,
    d.availableMaxHeight,
    d.minRewardReceived,
    d.maxRewardReceived,
    d.departureTimeAtUtc,
    d.createdAtUtc,
    d.orderStatusCode,
    d.validFrom,
    d.validTo,

    interactions.totalInteractionCount,
    interactions.unilateralInteractionCount,
    interactions.mutualInteractionCount,
    interactions.rejectedInteractionCount,

    deals.totalDealCount,
    deals.activeDealCount,
    deals.fulfilledDealCount,

    latestDeal.collaborativeDealId AS lastDealId,
    latestDeal.dealExecutionStatusCode
        AS lastDealExecutionStatusCode,
    latestDeal.createdAtUtc AS lastDealCreatedAtUtc,

    activeDeal.collaborativeDealId AS activeDealId,
    activeDeal.dealExecutionStatusCode
        AS activeDealExecutionStatusCode,

    CAST(
        CASE
            WHEN d.orderStatusCode = 'Published'
             AND deals.activeDealCount = 0
             AND deals.fulfilledDealCount = 0
            THEN 1 ELSE 0
        END AS BIT
    ) AS isAvailableAsTarget,

    CAST(
        CASE
            WHEN d.orderStatusCode IN ('Private', 'Published')
             AND deals.activeDealCount = 0
             AND deals.fulfilledDealCount = 0
            THEN 1 ELSE 0
        END AS BIT
    ) AS isAvailableAsInitiator

FROM dbo.DelivererIntent AS d

OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS totalInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Unilateral'
                THEN 1
            END
        ) AS unilateralInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Mutual'
                THEN 1
            END
        ) AS mutualInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Rejected'
                THEN 1
            END
        ) AS rejectedInteractionCount

    FROM dbo.InteractionContext AS ic
    WHERE ic.delivererIntentId = d.delivererIntentId
) AS interactions

OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS totalDealCount,

        COUNT_BIG(
            CASE
                WHEN cd.dealExecutionStatusCode
                    NOT IN ('Fulfilled', 'Failed')
                THEN 1
            END
        ) AS activeDealCount,

        COUNT_BIG(
            CASE
                WHEN cd.dealExecutionStatusCode = 'Fulfilled'
                THEN 1
            END
        ) AS fulfilledDealCount

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.delivererIntentId = d.delivererIntentId
) AS deals

OUTER APPLY
(
    SELECT TOP (1)
        cd.collaborativeDealId,
        cd.dealExecutionStatusCode,
        cd.createdAtUtc

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.delivererIntentId = d.delivererIntentId

    ORDER BY
        cd.createdAtUtc DESC,
        cd.collaborativeDealId DESC
) AS latestDeal

OUTER APPLY
(
    SELECT TOP (1)
        cd.collaborativeDealId,
        cd.dealExecutionStatusCode

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.delivererIntentId = d.delivererIntentId
      AND cd.dealExecutionStatusCode
          NOT IN ('Fulfilled', 'Failed')

    ORDER BY
        cd.createdAtUtc DESC,
        cd.collaborativeDealId DESC
) AS activeDeal;
GO
CREATE OR ALTER VIEW dbo.vDeliveryRequesterIntentDetails
AS
SELECT
    r.deliveryRequesterIntentId,
    r.authorDeliveryRequesterUserId,
    r.deliveryRequesterShipmentId,
    r.receivingCoordinates,
    r.destinationCoordinates,
    r.minPriceWithoutCommission,
    r.maxPriceWithoutCommission,
    r.createdAtUtc,
    r.orderStatusCode,
    r.validFrom,
    r.validTo,

    s.shipmentName,
    s.shipmentDescription,
    s.shipmentWeight,
    s.shipmentLength,
    s.shipmentDepth,
    s.shipmentHeight,

    interactions.totalInteractionCount,
    interactions.unilateralInteractionCount,
    interactions.mutualInteractionCount,
    interactions.rejectedInteractionCount,

    deals.totalDealCount,
    deals.activeDealCount,
    deals.fulfilledDealCount,

    latestDeal.collaborativeDealId AS lastDealId,
    latestDeal.dealExecutionStatusCode
        AS lastDealExecutionStatusCode,
    latestDeal.createdAtUtc AS lastDealCreatedAtUtc,

    activeDeal.collaborativeDealId AS activeDealId,
    activeDeal.dealExecutionStatusCode
        AS activeDealExecutionStatusCode,

    CAST(
        CASE
            WHEN r.orderStatusCode = 'Published'
             AND deals.activeDealCount = 0
             AND deals.fulfilledDealCount = 0
            THEN 1 ELSE 0
        END AS BIT
    ) AS isAvailableAsTarget,

    CAST(
        CASE
            WHEN r.orderStatusCode IN ('Private', 'Published')
             AND deals.activeDealCount = 0
             AND deals.fulfilledDealCount = 0
            THEN 1 ELSE 0
        END AS BIT
    ) AS isAvailableAsInitiator

FROM dbo.DeliveryRequesterIntent AS r

INNER JOIN dbo.DeliveryRequesterShipment AS s
    ON s.deliveryRequesterShipmentId =
       r.deliveryRequesterShipmentId

OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS totalInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Unilateral'
                THEN 1
            END
        ) AS unilateralInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Mutual'
                THEN 1
            END
        ) AS mutualInteractionCount,

        COUNT_BIG(
            CASE
                WHEN ic.interactionStatusCode = 'Rejected'
                THEN 1
            END
        ) AS rejectedInteractionCount

    FROM dbo.InteractionContext AS ic
    WHERE ic.deliveryRequesterIntentId =
          r.deliveryRequesterIntentId
) AS interactions

OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS totalDealCount,

        COUNT_BIG(
            CASE
                WHEN cd.dealExecutionStatusCode
                    NOT IN ('Fulfilled', 'Failed')
                THEN 1
            END
        ) AS activeDealCount,

        COUNT_BIG(
            CASE
                WHEN cd.dealExecutionStatusCode = 'Fulfilled'
                THEN 1
            END
        ) AS fulfilledDealCount

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.deliveryRequesterIntentId =
          r.deliveryRequesterIntentId
) AS deals

OUTER APPLY
(
    SELECT TOP (1)
        cd.collaborativeDealId,
        cd.dealExecutionStatusCode,
        cd.createdAtUtc

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.deliveryRequesterIntentId =
          r.deliveryRequesterIntentId

    ORDER BY
        cd.createdAtUtc DESC,
        cd.collaborativeDealId DESC
) AS latestDeal

OUTER APPLY
(
    SELECT TOP (1)
        cd.collaborativeDealId,
        cd.dealExecutionStatusCode

    FROM dbo.InteractionContext AS ic
    INNER JOIN dbo.CollaborativeDeal AS cd
        ON cd.interactionContextId = ic.interactionContextId

    WHERE ic.deliveryRequesterIntentId =
          r.deliveryRequesterIntentId
      AND cd.dealExecutionStatusCode
          NOT IN ('Fulfilled', 'Failed')

    ORDER BY
        cd.createdAtUtc DESC,
        cd.collaborativeDealId DESC
) AS activeDeal;
GO

-- Представлення для вдаємодії, яке описує її детальний стан, що агрегується з угод та Order-ів.
CREATE OR ALTER VIEW dbo.vInteractionContextDetails
AS
SELECT
    ic.interactionContextId,
    ic.interactionStartAtUtc,
    ic.delivererIntentId,
    ic.deliveryRequesterIntentId,
    ic.requestInitiatorCode,
    ic.interactionStatusCode,

    [policy].maxNumberMessages,
    [policy].policyStatusDescription,

    [policy].validFrom AS policyValidFrom,
    [policy].validTo AS policyValidTo,

    [messages].messageCount,

    [archive].isArchived,

    CAST(
        CASE
            -- Архівна взаємодія:
            -- надсилання повідомлень заборонене.
            WHEN [archive].isArchived = 1
                THEN 0

            -- Немає відповідної політики.
            WHEN [policy].interactionStatusCode IS NULL
                THEN 0

            -- Політика без обмеження кількості.
            WHEN [policy].maxNumberMessages IS NULL
                THEN 1

            -- Ліміт повідомлень ще не вичерпаний.
            WHEN [messages].messageCount <
                 [policy].maxNumberMessages
                THEN 1

            ELSE 0
        END AS BIT
    ) AS canSendMessage

FROM dbo.InteractionContext AS ic

/*
    Історична політика чату.

    Використовується версія політики,
    яка діяла на момент створення взаємодії.
*/

LEFT JOIN dbo.ChatAccessPolicy
    FOR SYSTEM_TIME ALL AS [policy]
    ON [policy].interactionStatusCode =
       ic.interactionStatusCode
    AND ic.interactionStartAtUtc >= [policy].validFrom
    AND ic.interactionStartAtUtc < [policy].validTo

/*
    Загальна кількість повідомлень взаємодії.
*/

OUTER APPLY
(
    SELECT
        COUNT_BIG(*) AS messageCount

    FROM dbo.UserMessage AS um

    WHERE um.interactionContextId =
          ic.interactionContextId
) AS [messages]

/*
    Обчислювана архівність взаємодії.

    Взаємодія стає архівною, якщо:

    - хоча б один пов'язаний Order
      має угоду зі статусом Fulfilled;

    - ця угода належить ІНШІЙ взаємодії.

    Важливо:

    1. Статус InteractionContext не змінюється.

    2. Виконання угоди всередині поточної
       взаємодії не архівує її автоматично.

    3. Failed не спричиняє архівацію.

    4. Наявність активної угоди в іншій
       взаємодії не спричиняє архівацію.
*/

CROSS APPLY
(
    SELECT
        CAST(
            CASE
                WHEN EXISTS
                (
                    SELECT 1

                    FROM dbo.InteractionContext AS related

                    INNER JOIN dbo.CollaborativeDeal AS cd
                        ON cd.interactionContextId =
                           related.interactionContextId

                    WHERE
                        related.interactionContextId <>
                            ic.interactionContextId

                        AND
                        (
                            related.delivererIntentId =
                                ic.delivererIntentId

                            OR

                            related.deliveryRequesterIntentId =
                                ic.deliveryRequesterIntentId
                        )

                        AND cd.dealExecutionStatusCode =
                            'Fulfilled'
                )
                THEN 1
                ELSE 0
            END AS BIT
        ) AS isArchived
) AS [archive];
GO

-- Швидкий пошук взаємодій за намірами.

CREATE NONCLUSTERED INDEX IX_InteractionContext_DelivererIntent
ON dbo.InteractionContext
(
    delivererIntentId,
    interactionStatusCode
);
GO
CREATE NONCLUSTERED INDEX IX_InteractionContext_DeliveryRequesterIntent
ON dbo.InteractionContext
(
    deliveryRequesterIntentId,
    interactionStatusCode
);
GO

-- Пошук угод конкретного контексту та останніх за часом створення.

CREATE NONCLUSTERED INDEX IX_CollaborativeDeal_Context_CreatedAt
ON dbo.CollaborativeDeal
(
    interactionContextId,
    createdAtUtc DESC,
    collaborativeDealId DESC
)
INCLUDE (dealExecutionStatusCode);
GO

-- Підрахунок повідомлень і отримання історії повідомлень у контексті.

CREATE NONCLUSTERED INDEX IX_UserMessage_Context_SentAt
ON dbo.UserMessage
(
    interactionContextId,
    sentAtUtc,
    userMessageId
);
GO

-- Пошук по конкретному чату (взаємодії)
CREATE NONCLUSTERED INDEX IX_UserMessage_InteractionContextId
ON dbo.UserMessage (interactionContextId);
GO

-- Пошук актуальних Order за публічністю та найважливішими скалярними параметрами.

CREATE NONCLUSTERED INDEX IX_DelivererIntent_Search
ON dbo.DelivererIntent
(
    orderStatusCode,
    departureTimeAtUtc
)
INCLUDE
(
    availableMaxWeight,
    availableMaxLength,
    availableMaxDepth,
    availableMaxHeight,
    minRewardReceived,
    maxRewardReceived
);
GO
CREATE NONCLUSTERED INDEX IX_DeliveryRequesterIntent_Search
ON dbo.DeliveryRequesterIntent
(
    orderStatusCode,
    minPriceWithoutCommission,
    maxPriceWithoutCommission
);
GO

CREATE SPATIAL INDEX SIX_DelivererIntent_Starting
ON dbo.DelivererIntent (startingCoordinates)
USING GEOGRAPHY_AUTO_GRID;
GO
CREATE SPATIAL INDEX SIX_DelivererIntent_End
ON dbo.DelivererIntent (endCoordinates)
USING GEOGRAPHY_AUTO_GRID;
GO
CREATE SPATIAL INDEX SIX_DeliveryRequesterIntent_Receiving
ON dbo.DeliveryRequesterIntent (receivingCoordinates)
USING GEOGRAPHY_AUTO_GRID;
GO
CREATE SPATIAL INDEX SIX_DeliveryRequesterIntent_Destination
ON dbo.DeliveryRequesterIntent (destinationCoordinates)
USING GEOGRAPHY_AUTO_GRID;
GO

-- Індекси
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    i.is_unique AS IsUnique,
    i.is_primary_key AS IsPrimaryKey,
    c.name AS ColumnName,
    ic.key_ordinal AS KeyPosition,
    ic.is_included_column AS IsIncludedColumn,
    ic.is_descending_key AS IsDescending,
    i.filter_definition AS FilterDefinition
FROM sys.indexes AS i
INNER JOIN sys.tables AS t
    ON t.object_id = i.object_id
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
LEFT JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
LEFT JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
ORDER BY
    s.name,
    t.name,
    i.name,
    ic.key_ordinal,
    ic.index_column_id;
GO

-- Тригери
SELECT
    OBJECT_SCHEMA_NAME(tr.object_id) AS SchemaName,
    tr.name AS TriggerName,
    OBJECT_SCHEMA_NAME(tr.parent_id) AS TableSchema,
    OBJECT_NAME(tr.parent_id) AS TableName,
    tr.is_instead_of_trigger AS IsInsteadOf,
    tr.is_disabled AS IsDisabled,
    tr.create_date AS CreatedAt,
    tr.modify_date AS ModifiedAt
FROM sys.triggers AS tr
WHERE tr.is_ms_shipped = 0
  AND tr.parent_class = 1
ORDER BY
    TableName,
    TriggerName;
GO

-- Процедури
SELECT
    s.name AS SchemaName,
    p.name AS ProcedureName,
    p.create_date AS CreatedAt,
    p.modify_date AS ModifiedAt
FROM sys.procedures AS p
INNER JOIN sys.schemas AS s
    ON s.schema_id = p.schema_id
WHERE p.is_ms_shipped = 0
ORDER BY
    s.name,
    p.name;
GO

-- Представлення
SELECT
    s.name AS SchemaName,
    v.name AS ViewName,
    v.create_date AS CreatedAt,
    v.modify_date AS ModifiedAt
FROM sys.views AS v
INNER JOIN sys.schemas AS s
    ON s.schema_id = v.schema_id
WHERE v.is_ms_shipped = 0
ORDER BY
    s.name,
    v.name;
GO