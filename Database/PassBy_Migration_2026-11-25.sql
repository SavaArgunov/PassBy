/*
PassBy | Migration 2026-11-25
Requires the 2026-11-24 migration and existing dbo schema / passby_backend.
Run as dbo or authorized deployment principal; connect to PassBy.
No demo orders, no smoke test data. Existing settings are preserved.
All stages share one outer transaction; original inner COMMITs do not commit it.
Replay guards for two patches; do not use against an unrelated/newer schema.
Concurrency implementation retained; multi-session testing deferred.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
IF DB_NAME() <> N'PassBy'
    THROW 51600, N'Invalid target database.', 1;
IF @@TRANCOUNT <> 0
    THROW 51601, N'An active transaction already exists.', 1;
IF DATABASE_PRINCIPAL_ID(N'passby_backend') IS NULL
    THROW 51600, N'Expected backend principal missing.', 1;
IF OBJECT_ID(N'dbo.AcquireInteractionIntentLocks',N'P') IS NULL
   OR OBJECT_ID(N'dbo.vInteractionContextDetails',N'V') IS NULL
   OR COL_LENGTH(N'dbo.CollaborativeDeal',N'agreedAtUtc') IS NULL
    THROW 51600, N'Expected previous migration missing.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    -- 01 UserSettings automation and backfill
    EXEC sys.sp_executesql N'-- Reconstructed from final audit (original migration absent from query collection).
IF NOT EXISTS (
    SELECT 1 FROM sys.default_constraints AS d
    JOIN sys.columns AS c ON c.object_id=d.parent_object_id AND c.column_id=d.parent_column_id
    WHERE d.parent_object_id=OBJECT_ID(N''dbo.UserSettings'')
      AND c.name=N''orderPublishingPolicy'' AND d.definition=N''((0))''
)
    THROW 51610, N''Expected UserSettings default 0 missing.'', 1;

INSERT INTO dbo.UserSettings (userId)
SELECT u.userId
FROM dbo.UserAccount AS u
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.UserSettings AS s WITH (UPDLOCK,HOLDLOCK)
    WHERE s.userId=u.userId
);

EXEC sys.sp_executesql N''CREATE OR ALTER TRIGGER dbo.TR_UserAccount_CreateUserSettings
ON dbo.UserAccount
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.UserSettings (userId)
    SELECT i.userId FROM inserted AS i;
END;'';

DENY INSERT, DELETE ON OBJECT::dbo.UserSettings TO [passby_backend];
DENY UPDATE ON OBJECT::dbo.UserSettings (userId) TO [passby_backend];

IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class=1 AND major_id=OBJECT_ID(N''dbo.UserSettings'') AND minor_id=0 AND name=N''MS_Description'')
    EXEC sys.sp_updateextendedproperty @name=N''MS_Description'', @value=N''Персональні налаштування користувача.         Автоматично створюються при INSERT у UserAccount         через TR_UserAccount_CreateUserSettings.         orderPublishingPolicy: 0 = Manual, 1 = Automatic.         Визначає початковий статус сформованого Order:         Private або Published.         Явне створення Draft має пріоритет над політикою.         Зміна налаштувань не впливає на наявні Order.         Прямі INSERT, DELETE та UPDATE userId         для backend заборонені.         UPDATE orderPublishingPolicy дозволено.'', @level0type=N''SCHEMA'', @level0name=N''dbo'', @level1type=N''TABLE'', @level1name=N''UserSettings'';
ELSE
    EXEC sys.sp_addextendedproperty @name=N''MS_Description'', @value=N''Персональні налаштування користувача.         Автоматично створюються при INSERT у UserAccount         через TR_UserAccount_CreateUserSettings.         orderPublishingPolicy: 0 = Manual, 1 = Automatic.         Визначає початковий статус сформованого Order:         Private або Published.         Явне створення Draft має пріоритет над політикою.         Зміна налаштувань не впливає на наявні Order.         Прямі INSERT, DELETE та UPDATE userId         для backend заборонені.         UPDATE orderPublishingPolicy дозволено.'', @level0type=N''SCHEMA'', @level0name=N''dbo'', @level1type=N''TABLE'', @level1name=N''UserSettings'';

IF EXISTS (SELECT 1 FROM sys.extended_properties WHERE class=1 AND major_id=OBJECT_ID(N''dbo.TR_UserAccount_CreateUserSettings'') AND minor_id=0 AND name=N''MS_Description'')
    EXEC sys.sp_updateextendedproperty @name=N''MS_Description'', @value=N''AFTER INSERT для UserAccount.         Автоматично створює UserSettings для кожного         нового користувача з налаштуваннями за замовчуванням.         Підтримує вставлення декількох користувачів         одним SQL-запитом.         Створення налаштувань відбувається         в межах транзакції створення UserAccount.         Backend не повинен створювати UserSettings окремо.'', @level0type=N''SCHEMA'', @level0name=N''dbo'', @level1type=N''TABLE'', @level1name=N''UserAccount'', @level2type=N''TRIGGER'', @level2name=N''TR_UserAccount_CreateUserSettings'';
ELSE
    EXEC sys.sp_addextendedproperty @name=N''MS_Description'', @value=N''AFTER INSERT для UserAccount.         Автоматично створює UserSettings для кожного         нового користувача з налаштуваннями за замовчуванням.         Підтримує вставлення декількох користувачів         одним SQL-запитом.         Створення налаштувань відбувається         в межах транзакції створення UserAccount.         Backend не повинен створювати UserSettings окремо.'', @level0type=N''SCHEMA'', @level0name=N''dbo'', @level1type=N''TABLE'', @level1name=N''UserAccount'', @level2type=N''TRIGGER'', @level2name=N''TR_UserAccount_CreateUserSettings'';

IF EXISTS (SELECT 1 FROM dbo.UserAccount AS u WHERE NOT EXISTS
    (SELECT 1 FROM dbo.UserSettings AS s WHERE s.userId=u.userId))
    THROW 51611, N''UserSettings backfill incomplete.'', 1;';


    -- 02 Order status and permissions
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    --------------------------------------------------
    -- 1. Додавання фінального статусу
    --------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.OrderStatus
        WHERE orderStatusCode = ''Cancelled''
    )
    BEGIN
        INSERT INTO dbo.OrderStatus
        (
            orderStatusCode,
            statusDescription
        )
        VALUES
        (
            ''Cancelled'',
            N''Скасований Order. Фінальний незмінний стан.''
        );
    END;

    --------------------------------------------------
    -- 2. Права DelivererIntent
    --------------------------------------------------

    DENY UPDATE ON OBJECT::dbo.DelivererIntent
    (
        delivererIntentId,
        authorDelivererUserId,
        orderStatusCode,
        createdAtUtc,
        validFrom,
        validTo
    )
    TO [passby_backend];

    DENY INSERT, DELETE
    ON OBJECT::dbo.DelivererIntent
    TO [passby_backend];

    --------------------------------------------------
    -- 3. Права DeliveryRequesterIntent
    --------------------------------------------------

    DENY UPDATE ON OBJECT::dbo.DeliveryRequesterIntent
    (
        deliveryRequesterIntentId,
        authorDeliveryRequesterUserId,
        deliveryRequesterShipmentId,
        orderStatusCode,
        createdAtUtc,
        validFrom,
        validTo
    )
    TO [passby_backend];

    DENY INSERT, DELETE
    ON OBJECT::dbo.DeliveryRequesterIntent
    TO [passby_backend];

    --------------------------------------------------
    -- 4. Захист Temporal History
    --------------------------------------------------

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.DelivererIntentHistory
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.DeliveryRequesterIntentHistory
    TO [passby_backend];
COMMIT TRANSACTION;

    SELECT
        N''Order lifecycle foundation successfully updated.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 03 Finalization locks and final Intent triggers
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    --------------------------------------------------
    -- 1. CompleteCollaborativeDeal
    --------------------------------------------------

    IF NOT (
        CHARINDEX(N''@LockedDId'', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N''dbo.CompleteCollaborativeDeal'')), N'''')) > 0
        AND CHARINDEX(N''@LockedRId'', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CompleteCollaborativeDeal''))) > 0
        AND CHARINDEX(N''INDEX(PK_DelivererIntent)'', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CompleteCollaborativeDeal''))) > 0
        AND CHARINDEX(N''INDEX(PK_DeliveryRequesterIntent)'', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CompleteCollaborativeDeal''))) > 0
    )
    BEGIN
        IF CHARINDEX(N''@LockedDId'', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N''dbo.CompleteCollaborativeDeal'')), N'''')) > 0
            THROW 51641, N''Partially patched completion procedure.'', 1;
    DECLARE @Definition NVARCHAR(MAX) =
        OBJECT_DEFINITION(
            OBJECT_ID(''dbo.CompleteCollaborativeDeal'')
        );

    IF @Definition IS NULL
        THROW 51640,
            N''CompleteCollaborativeDeal not found.'',
            1;

    IF CHARINDEX(
        N''CREATE PROCEDURE dbo.CompleteCollaborativeDeal'',
        @Definition
    ) = 0
    OR CHARINDEX(
        N''UPDATE dbo.CollaborativeDeal'',
        @Definition
    ) = 0
        THROW 51641,
            N''Unexpected procedure definition.'',
            1;

    DECLARE @LockBlock NVARCHAR(MAX) = N''

        -- Блокування обох Order перед фіналізацією.
        -- Узгоджує завершення угоди з прямим UPDATE.

        DECLARE @LockedDId BIGINT;
        DECLARE @LockedRId BIGINT;

        SELECT
            @LockedDId = delivererIntentId
        FROM dbo.DelivererIntent
            WITH (
                UPDLOCK,
                HOLDLOCK,
                INDEX(PK_DelivererIntent)
            )
        WHERE delivererIntentId = @DId;

        SELECT
            @LockedRId = deliveryRequesterIntentId
        FROM dbo.DeliveryRequesterIntent
            WITH (
                UPDLOCK,
                HOLDLOCK,
                INDEX(PK_DeliveryRequesterIntent)
            )
        WHERE deliveryRequesterIntentId = @RId;

        IF @LockedDId IS NULL
           OR @LockedRId IS NULL
            THROW 51642,
                N''''Linked Orders not found.'''',
                1;

    '';

    SET @Definition = REPLACE(
        @Definition,
        N''UPDATE dbo.CollaborativeDeal'',
        @LockBlock + N''UPDATE dbo.CollaborativeDeal''
    );

    SET @Definition = REPLACE(
        @Definition,
        N''CREATE PROCEDURE dbo.CompleteCollaborativeDeal'',
        N''ALTER PROCEDURE dbo.CompleteCollaborativeDeal''
    );

    EXEC sys.sp_executesql @Definition;

    END;

    --------------------------------------------------
    -- 2. Спільний шаблон тригерів Intent
    --------------------------------------------------

    DECLARE @TriggerTemplate NVARCHAR(MAX) = N''

    ALTER TRIGGER dbo.__TRIGGER__
    ON dbo.__TABLE__
    AFTER UPDATE, DELETE
    AS
    BEGIN
        SET NOCOUNT ON;

        -- Заборона фізичного видалення.

        IF EXISTS
        (
            SELECT 1
            FROM deleted AS d
            LEFT JOIN inserted AS i
                ON i.__ID__ = d.__ID__
            WHERE i.__ID__ IS NULL
        )
            THROW __DELETE_ERROR__,
                N''''__TABLE__ cannot be deleted.'''',
                1;

        -- Незмінність Cancelled.

        IF EXISTS
        (
            SELECT 1
            FROM deleted
            WHERE orderStatusCode = ''''Cancelled''''
        )
            THROW __CANCEL_ERROR__,
                N''''Cancelled __TABLE__ is immutable.'''',
                1;

        -- Незмінність Fulfilled.
        -- Читання з блокуванням замість RCSI.

        IF EXISTS
        (
            SELECT 1
            FROM deleted AS d
            INNER JOIN dbo.InteractionContext AS ic
                WITH (READCOMMITTEDLOCK)
                ON ic.__ID__ = d.__ID__
            INNER JOIN dbo.CollaborativeDeal AS cd
                WITH (READCOMMITTEDLOCK)
                ON cd.interactionContextId =
                   ic.interactionContextId
            WHERE cd.dealExecutionStatusCode =
                  ''''Fulfilled''''
        )
            THROW __FULFILLED_ERROR__,
                N''''__TABLE__: fulfilled Order is immutable.'''',
                1;
    END;
    '';

    --------------------------------------------------
    -- 3. DelivererIntent
    --------------------------------------------------

    DECLARE @DSql NVARCHAR(MAX) = @TriggerTemplate;

    SET @DSql = REPLACE(@DSql, ''__TRIGGER__'',
        ''TR_DelivererIntent_ImmutableFinalStates'');

    SET @DSql = REPLACE(@DSql, ''__TABLE__'',
        ''DelivererIntent'');

    SET @DSql = REPLACE(@DSql, ''__ID__'',
        ''delivererIntentId'');

    SET @DSql = REPLACE(@DSql, ''__DELETE_ERROR__'',
        ''51602'');

    SET @DSql = REPLACE(@DSql, ''__CANCEL_ERROR__'',
        ''51603'');

    SET @DSql = REPLACE(@DSql, ''__FULFILLED_ERROR__'',
        ''51160'');

    EXEC sys.sp_executesql @DSql;

    --------------------------------------------------
    -- 4. DeliveryRequesterIntent
    --------------------------------------------------

    DECLARE @RSql NVARCHAR(MAX) = @TriggerTemplate;

    SET @RSql = REPLACE(@RSql, ''__TRIGGER__'',
        ''TR_DeliveryRequesterIntent_ImmutableFinalStates'');

    SET @RSql = REPLACE(@RSql, ''__TABLE__'',
        ''DeliveryRequesterIntent'');

    SET @RSql = REPLACE(@RSql, ''__ID__'',
        ''deliveryRequesterIntentId'');

    SET @RSql = REPLACE(@RSql, ''__DELETE_ERROR__'',
        ''51604'');

    SET @RSql = REPLACE(@RSql, ''__CANCEL_ERROR__'',
        ''51605'');

    SET @RSql = REPLACE(@RSql, ''__FULFILLED_ERROR__'',
        ''51161'');

    EXEC sys.sp_executesql @RSql;

    COMMIT TRANSACTION;

    SELECT
        N''Order finalization concurrency protection updated.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 04 Order lifecycle procedures
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

--------------------------------------------------
-- 0. Перевірка попередньої міграції
--------------------------------------------------

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.OrderStatus
    WHERE orderStatusCode = ''Cancelled''
)
    THROW 51615,
        N''Order lifecycle foundation is missing.'',
        1;

IF
(
    SELECT COUNT(*)
    FROM sys.triggers AS t
    WHERE t.name IN
    (
        ''TR_DelivererIntent_ImmutableFinalStates'',
        ''TR_DeliveryRequesterIntent_ImmutableFinalStates''
    )
      AND t.is_disabled = 0
      AND OBJECT_DEFINITION(t.object_id)
          LIKE ''%Cancelled%''
) <> 2
    THROW 51616,
        N''Order immutability triggers are not configured.'',
        1;

IF
(
    SELECT COUNT(*)
    FROM sys.database_permissions AS p
    WHERE p.grantee_principal_id =
          DATABASE_PRINCIPAL_ID(''passby_backend'')
      AND p.class = 1
      AND p.major_id IN
      (
          OBJECT_ID(''dbo.DelivererIntent''),
          OBJECT_ID(''dbo.DeliveryRequesterIntent'')
      )
      AND p.minor_id > 0
      AND p.permission_name = ''UPDATE''
      AND p.state = ''D''
) < 13
    THROW 51617,
        N''Order column permissions are not configured.'',
        1;

BEGIN TRY
    BEGIN TRANSACTION;

    --------------------------------------------------
    -- 1. Спільний шаблон процедури
    --------------------------------------------------

    DECLARE @Template NVARCHAR(MAX) = N''

    CREATE OR ALTER PROCEDURE dbo.__PROCEDURE__
        @OrderId BIGINT,
        @ActorUserId BIGINT,
        @NewStatusCode VARCHAR(64)
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        --------------------------------------------------
        -- Валідація параметрів
        --------------------------------------------------

        IF @OrderId IS NULL
           OR @ActorUserId IS NULL
           OR @NewStatusCode IS NULL
            THROW 51620,
                N''''Invalid Order status parameters.'''',
                1;

        IF @NewStatusCode NOT IN
        (
            ''''Draft'''',
            ''''Private'''',
            ''''Published'''',
            ''''Cancelled''''
        )
            THROW 51621,
                N''''Invalid target Order status.'''',
                1;

        DECLARE @CurrentStatus VARCHAR(64);
        DECLARE @CanonicalStatus VARCHAR(64);
        DECLARE @OwnerUserId BIGINT;
        DECLARE @WasChanged BIT = 0;
        DECLARE @LockResult INT;

        DECLARE @LockResource NVARCHAR(255) =
            CONCAT(
                N''''PassBy:Intent:__LOCK__:'''',
                CONVERT(NVARCHAR(20), @OrderId)
            );

        BEGIN TRY
            BEGIN TRANSACTION;

            --------------------------------------------------
            -- Конкурентне блокування Order
            --------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock
                @Resource = @LockResource,
                @LockMode = ''''Exclusive'''',
                @LockOwner = ''''Transaction'''',
                @DbPrincipal = ''''public'''',
                @LockTimeout = 10000;

            IF @LockResult < 0
                THROW 51622,
                    N''''Failed to lock Order.'''',
                    1;

            --------------------------------------------------
            -- Отримання актуального стану
            --------------------------------------------------

            SELECT
                @CurrentStatus = orderStatusCode,
                @OwnerUserId = __AUTHOR__
            FROM dbo.__TABLE__
                WITH (UPDLOCK, HOLDLOCK)
            WHERE __ID__ = @OrderId;

            IF @OwnerUserId IS NULL
                THROW 51623,
                    N''''Order not found.'''',
                    1;

            IF @OwnerUserId <> @ActorUserId
                THROW 51624,
                    N''''Actor does not own this Order.'''',
                    1;

            SELECT
                @CanonicalStatus = orderStatusCode
            FROM dbo.OrderStatus
            WHERE orderStatusCode = @NewStatusCode;

            IF @CanonicalStatus IS NULL
                THROW 51621,
                    N''''Invalid target Order status.'''',
                    1;

            SET @NewStatusCode = @CanonicalStatus;

            --------------------------------------------------
            -- Ідемпотентність
            --
            -- Повторний запит не виконує UPDATE.
            --------------------------------------------------

            IF @CurrentStatus = @NewStatusCode
            BEGIN
                COMMIT TRANSACTION;

                SELECT
                    @OrderId AS __ID__,
                    @CurrentStatus AS previousOrderStatusCode,
                    @CurrentStatus AS orderStatusCode,
                    @WasChanged AS wasChanged;

                RETURN;
            END;

            --------------------------------------------------
            -- Захист фінальних станів
            --------------------------------------------------

            IF @CurrentStatus = ''''Cancelled''''
                THROW 51625,
                    N''''Cancelled Order is immutable.'''',
                    1;

            IF EXISTS
            (
                SELECT 1
                FROM dbo.InteractionContext AS ic
                INNER JOIN dbo.CollaborativeDeal AS cd
                    ON cd.interactionContextId =
                       ic.interactionContextId
                WHERE ic.__ID__ = @OrderId
                  AND cd.dealExecutionStatusCode =
                      ''''Fulfilled''''
            )
                THROW 51626,
                    N''''Fulfilled Order is immutable.'''',
                    1;

            --------------------------------------------------
            -- Перевірка допустимості переходу
            --------------------------------------------------

            IF NOT
            (
                (
                    @CurrentStatus = ''''Draft''''
                    AND @NewStatusCode IN
                    (
                        ''''Private'''',
                        ''''Published'''',
                        ''''Cancelled''''
                    )
                )
                OR
                (
                    @CurrentStatus = ''''Private''''
                    AND @NewStatusCode IN
                    (
                        ''''Published'''',
                        ''''Cancelled''''
                    )
                )
                OR
                (
                    @CurrentStatus = ''''Published''''
                    AND @NewStatusCode IN
                    (
                        ''''Private'''',
                        ''''Cancelled''''
                    )
                )
            )
                THROW 51627,
                    N''''Invalid Order status transition.'''',
                    1;

            --------------------------------------------------
            -- Додаткові перевірки при скасуванні
            --------------------------------------------------

            IF @NewStatusCode = ''''Cancelled''''
            BEGIN

                -- Активна угода резервує Order.

                IF EXISTS
                (
                    SELECT 1
                    FROM dbo.InteractionContext AS ic
                    INNER JOIN dbo.CollaborativeDeal AS cd
                        ON cd.interactionContextId =
                           ic.interactionContextId
                    WHERE ic.__ID__ = @OrderId
                      AND cd.dealExecutionStatusCode
                          NOT IN (''''Fulfilled'''', ''''Failed'''')
                )
                    THROW 51628,
                        N''''Order has an active deal.'''',
                        1;

                -- Активні неархівні взаємодії.

                IF EXISTS
                (
                    SELECT 1
                    FROM dbo.vInteractionContextDetails AS ic
                    WHERE ic.__ID__ = @OrderId
                      AND ic.interactionStatusCode IN
                          (''''Unilateral'''', ''''Mutual'''')
                      AND ic.isArchived = 0
                )
                    THROW 51629,
                        N''''Order has an active interaction.'''',
                        1;

            END;

            --------------------------------------------------
            -- Атомарна зміна статусу
            --------------------------------------------------

            UPDATE dbo.__TABLE__
            SET orderStatusCode = @NewStatusCode
            WHERE __ID__ = @OrderId
              AND orderStatusCode = @CurrentStatus;

            IF @@ROWCOUNT <> 1
                THROW 51630,
                    N''''Order status update failed.'''',
                    1;

            SET @WasChanged = 1;

            COMMIT TRANSACTION;

            SELECT
                @OrderId AS __ID__,
                @CurrentStatus AS previousOrderStatusCode,
                @NewStatusCode AS orderStatusCode,
                @WasChanged AS wasChanged;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
    '';

    --------------------------------------------------
    -- 2. Процедура для Order кур''єра
    --------------------------------------------------

    DECLARE @DelivererSql NVARCHAR(MAX) = @Template;

    SET @DelivererSql = REPLACE(
        @DelivererSql,
        N''__PROCEDURE__'',
        N''SetDelivererOrderStatus''
    );

    SET @DelivererSql = REPLACE(
        @DelivererSql,
        N''__TABLE__'',
        N''DelivererIntent''
    );

    SET @DelivererSql = REPLACE(
        @DelivererSql,
        N''__ID__'',
        N''delivererIntentId''
    );

    SET @DelivererSql = REPLACE(
        @DelivererSql,
        N''__AUTHOR__'',
        N''authorDelivererUserId''
    );

    SET @DelivererSql = REPLACE(
        @DelivererSql,
        N''__LOCK__'',
        N''D''
    );

    EXEC sys.sp_executesql @DelivererSql;

    --------------------------------------------------
    -- 3. Процедура для Order замовника
    --------------------------------------------------

    DECLARE @RequesterSql NVARCHAR(MAX) = @Template;

    SET @RequesterSql = REPLACE(
        @RequesterSql,
        N''__PROCEDURE__'',
        N''SetDeliveryRequesterOrderStatus''
    );

    SET @RequesterSql = REPLACE(
        @RequesterSql,
        N''__TABLE__'',
        N''DeliveryRequesterIntent''
    );

    SET @RequesterSql = REPLACE(
        @RequesterSql,
        N''__ID__'',
        N''deliveryRequesterIntentId''
    );

    SET @RequesterSql = REPLACE(
        @RequesterSql,
        N''__AUTHOR__'',
        N''authorDeliveryRequesterUserId''
    );

    SET @RequesterSql = REPLACE(
        @RequesterSql,
        N''__LOCK__'',
        N''R''
    );

    EXEC sys.sp_executesql @RequesterSql;

    --------------------------------------------------
    -- 4. Права виконання
    --------------------------------------------------

    GRANT EXECUTE
    ON OBJECT::dbo.SetDelivererOrderStatus
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.SetDeliveryRequesterOrderStatus
    TO [passby_backend];

    COMMIT TRANSACTION;

    SELECT
        N''Order lifecycle procedures successfully created.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 05 Deal publication checks
    EXEC sys.sp_executesql N'IF (
    CHARINDEX(N''@DStatus NOT IN (''''Private'''', ''''Published'''')'', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal'')), N'''')) > 0
    AND CHARINDEX(N''@RStatus NOT IN (''''Private'''', ''''Published'''')'', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal''))) > 0
    AND CHARINDEX(N''@DStatus <> ''''Published'''''', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal''))) = 0
    AND CHARINDEX(N''@RStatus <> ''''Published'''''', OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal''))) = 0
)
BEGIN
    SELECT N''CreateCollaborativeDeal already updated.'' AS result;
END
ELSE
BEGIN
    IF CHARINDEX(N''@DStatus NOT IN (''''Private'''', ''''Published'''')'', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal'')), N'''')) > 0
       OR CHARINDEX(N''@RStatus NOT IN (''''Private'''', ''''Published'''')'', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N''dbo.CreateCollaborativeDeal'')), N'''')) > 0
        THROW 51632, N''Partially patched deal procedure.'', 1;
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @Definition NVARCHAR(MAX) =
        OBJECT_DEFINITION(
            OBJECT_ID(''dbo.CreateCollaborativeDeal'')
        );

    --------------------------------------------------
    -- 1. Перевірка очікуваного визначення
    --------------------------------------------------

    IF @Definition IS NULL
        THROW 51631,
            N''CreateCollaborativeDeal definition not found.'',
            1;

    IF CHARINDEX(
        N''@RStatus <> ''''Published'''''',
        @Definition
    ) = 0
    OR CHARINDEX(
        N''@DStatus <> ''''Published'''''',
        @Definition
    ) = 0
        THROW 51632,
            N''Expected status checks not found.'',
            1;

    IF CHARINDEX(
        N''CREATE PROCEDURE dbo.CreateCollaborativeDeal'',
        @Definition
    ) = 0
        THROW 51633,
            N''Unexpected procedure definition format.'',
            1;

    --------------------------------------------------
    -- 2. Адаптація перевірок публічності
    --------------------------------------------------

    SET @Definition = REPLACE(
        @Definition,
        N''@RStatus <> ''''Published'''''',
        N''@RStatus NOT IN (''''Private'''', ''''Published'''')''
    );

    SET @Definition = REPLACE(
        @Definition,
        N''@DStatus <> ''''Published'''''',
        N''@DStatus NOT IN (''''Private'''', ''''Published'''')''
    );

    --------------------------------------------------
    -- 3. Актуалізація коментаря
    --------------------------------------------------

    SET @Definition = REPLACE(
        @Definition,
        N''Target Order повинен бути Published.'',
        N''Target Order: Private або Published.''
    );

    --------------------------------------------------
    -- 4. Оновлення процедури
    --------------------------------------------------

    SET @Definition = REPLACE(
        @Definition,
        N''CREATE PROCEDURE dbo.CreateCollaborativeDeal'',
        N''ALTER PROCEDURE dbo.CreateCollaborativeDeal''
    );

    EXEC sys.sp_executesql @Definition;

    COMMIT TRANSACTION;

    SELECT
        N''CreateCollaborativeDeal successfully updated.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;
END;';


    -- 06 CloseInteractionContext
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

IF DB_NAME() <> N''PassBy''
    THROW 51600, N''Invalid target database.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    EXEC sys.sp_executesql N''

    CREATE OR ALTER PROCEDURE dbo.CloseInteractionContext
        @InteractionContextId BIGINT,
        @ActorUserId BIGINT
    AS
    BEGIN
        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        --------------------------------------------------
        -- 1. Валідація параметрів
        --------------------------------------------------

        IF @InteractionContextId IS NULL
           OR @ActorUserId IS NULL
            THROW 51634,
                N''''Invalid interaction closure parameters.'''',
                1;

        DECLARE @DId BIGINT;
        DECLARE @RId BIGINT;

        DECLARE @InitiatorCode VARCHAR(64);
        DECLARE @CurrentStatus VARCHAR(64);

        DECLARE @DelivererUserId BIGINT;
        DECLARE @RequesterUserId BIGINT;

        DECLARE @WasChanged BIT = 0;

        BEGIN TRY
            BEGIN TRANSACTION;

            --------------------------------------------------
            -- 2. Блокування Order та InteractionContext
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
                    @CurrentStatus OUTPUT;

            --------------------------------------------------
            -- 3. Визначення учасників
            --------------------------------------------------

            SELECT
                @DelivererUserId =
                    authorDelivererUserId
            FROM dbo.DelivererIntent
            WHERE delivererIntentId = @DId;

            SELECT
                @RequesterUserId =
                    authorDeliveryRequesterUserId
            FROM dbo.DeliveryRequesterIntent
            WHERE deliveryRequesterIntentId = @RId;

            IF @DelivererUserId IS NULL
               OR @RequesterUserId IS NULL
                THROW 51635,
                    N''''Linked Orders not found.'''',
                    1;

            IF @ActorUserId NOT IN
            (
                @DelivererUserId,
                @RequesterUserId
            )
                THROW 51636,
                    N''''Actor does not participate in this interaction.'''',
                    1;

            --------------------------------------------------
            -- 4. Повторне завершення
            --------------------------------------------------

            IF @CurrentStatus = ''''Rejected''''
            BEGIN
                COMMIT TRANSACTION;

                SELECT
                    @InteractionContextId
                        AS interactionContextId,
                    @CurrentStatus
                        AS previousInteractionStatusCode,
                    @CurrentStatus
                        AS interactionStatusCode,
                    @WasChanged
                        AS wasChanged;

                RETURN;
            END;

            --------------------------------------------------
            -- 5. Перевірка поточного стану
            --------------------------------------------------

            IF @CurrentStatus NOT IN
            (
                ''''Unilateral'''',
                ''''Mutual''''
            )
                THROW 51637,
                    N''''Invalid interaction state.'''',
                    1;

            --------------------------------------------------
            -- 6. Перевірка пов''''язаних угод
            --
            -- Failed не перешкоджає завершенню.
            -- Будь-яка інша угода перешкоджає.
            --------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.CollaborativeDeal AS cd
                    WITH (UPDLOCK, HOLDLOCK)
                WHERE cd.interactionContextId =
                      @InteractionContextId
                  AND cd.dealExecutionStatusCode <>
                      ''''Failed''''
            )
                THROW 51638,
                    N''''Interaction has an active or fulfilled deal.'''',
                    1;

            --------------------------------------------------
            -- 7. Завершення взаємодії
            --------------------------------------------------

            UPDATE dbo.InteractionContext
            SET interactionStatusCode = ''''Rejected''''
            WHERE interactionContextId =
                  @InteractionContextId
              AND interactionStatusCode =
                  @CurrentStatus;

            IF @@ROWCOUNT <> 1
                THROW 51639,
                    N''''Interaction closure failed.'''',
                    1;

            SET @WasChanged = 1;

            COMMIT TRANSACTION;

            SELECT
                @InteractionContextId
                    AS interactionContextId,
                @CurrentStatus
                    AS previousInteractionStatusCode,
                ''''Rejected''''
                    AS interactionStatusCode,
                @WasChanged
                    AS wasChanged;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;
    END;
    '';

    GRANT EXECUTE
    ON OBJECT::dbo.CloseInteractionContext
    TO [passby_backend];

    COMMIT TRANSACTION;

    SELECT
        N''CloseInteractionContext successfully created.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 07 PK and structural FK permissions
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51710, N''Invalid target database.'', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DENY UPDATE ON OBJECT::dbo.Deliverer
    (
        userId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.DeliveryRequester
    (
        userId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.DeliveryRequesterShipment
    (
        deliveryRequesterShipmentId,
        ownerDeliveryRequesterUserId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.IDCardData
    (
        documentId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.PasswordCredential
    (
        credentialId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.UserAccount
    (
        userId,
        credentialId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.UserPaymentMethod
    (
        paymentMethodId,
        userId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.ValidatedDocument
    (
        documentId,
        userId,
        verificationProviderId
    )
    TO [passby_backend];

    DENY UPDATE ON OBJECT::dbo.VerificationProvider
    (
        providerId
    )
    TO [passby_backend];

    COMMIT TRANSACTION;

    SELECT
        N''Primary and structural foreign keys protected.''
            AS result;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 08 Object documentation
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51700, N''Invalid target database.'', 1;

--------------------------------------------------
-- 1. Актуальна документація об''єктів
--------------------------------------------------

DECLARE @Descriptions TABLE
(
    objectName SYSNAME PRIMARY KEY,
    objectType VARCHAR(20),
    parentTable SYSNAME NULL,
    description NVARCHAR(2000)
);

--------------------------------------------------
-- 1.1. Таблиці
--------------------------------------------------

INSERT INTO @Descriptions VALUES

(
    ''OrderStatus'', ''TABLE'', NULL,
    N''Довідник статусів Order: Draft, Private, Published,
    Cancelled. Draft означає незавершену чернетку.
    Private та Published визначають публічність сформованого
    Order. Cancelled є фінальним незмінним статусом.
    Fulfilled не є статусом Order: виконаність визначається
    через пов’язану CollaborativeDeal.
    Фактична доступність Order залежить від його статусу
    та наявності активних або виконаних угод.''
),

(
    ''DelivererIntent'', ''TABLE'', NULL,
    N''Order кур’єра: маршрут GEOGRAPHY/SRID 4326,
    обмеження місткості, винагорода, час відправлення,
    автор і статус.
    Створення та зміна статусу виконуються через процедури.
    Backend може безпосередньо редагувати звичайні атрибути,
    зокрема під час активної взаємодії або угоди.
    Ідентифікатор, автор, статус, дата створення та системні
    часові межі захищені від прямого UPDATE backend.
    Фізичне видалення заборонено.
    Cancelled та Order з Fulfilled-угодою є незмінними.
    Історія зберігається у DelivererIntentHistory.''
),

(
    ''DeliveryRequesterIntent'', ''TABLE'', NULL,
    N''Order замовника: координати передачі й доставки,
    ціновий діапазон без комісії, посилка, автор і статус.
    Складений FK гарантує належність посилки автору.
    Створення та зміна статусу виконуються через процедури.
    Backend може редагувати звичайні атрибути безпосередньо,
    зокрема під час активної взаємодії або угоди.
    Ідентифікатор, автор, прив’язана посилка, статус,
    дата створення та системні часові межі захищені
    від прямого UPDATE backend.
    Фізичне видалення заборонено.
    Cancelled та Order з Fulfilled-угодою є незмінними.
    Історія зберігається у DeliveryRequesterIntentHistory.''
),

(
    ''DelivererIntentHistory'', ''TABLE'', NULL,
    N''Автоматична system-versioned історія DelivererIntent.
    Зберігає попередні версії атрибутів і статусу Order.
    Прямі INSERT, UPDATE та DELETE backend заборонені.
    Для відтворення стану використовувати FOR SYSTEM_TIME
    AS OF з моментом часу в UTC.
    Для аналізу всіх фізичних історичних версій, включно
    з версіями нульової тривалості, читати історичну
    таблицю безпосередньо.
    Ідемпотентне встановлення поточного статусу через
    SetDelivererOrderStatus не створює нової версії.''
),

(
    ''DeliveryRequesterIntentHistory'', ''TABLE'', NULL,
    N''Автоматична system-versioned історія
    DeliveryRequesterIntent. Зберігає попередні версії
    атрибутів і статусу Order замовника.
    Прямі INSERT, UPDATE та DELETE backend заборонені.
    Історичний стан посилки необхідно читати окремо
    з DeliveryRequesterShipment на той самий момент часу.
    FOR SYSTEM_TIME ALL не повертає версії нульової
    тривалості; для їх аналізу читати історичну таблицю.
    Ідемпотентне встановлення поточного статусу через
    SetDeliveryRequesterOrderStatus не створює нової версії.''
),

(
    ''InteractionContext'', ''TABLE'', NULL,
    N''Контекст взаємодії одного DelivererIntent та одного
    DeliveryRequesterIntent. Зберігає момент початку,
    сторону-ініціатора та стан Unilateral, Mutual або Rejected.
    Один Order може брати участь у багатьох взаємодіях.
    Ексклюзивність забезпечується активними угодами.
    Зміна публічності Order не завершує наявні взаємодії.
    Будь-який автор пов’язаного Order може завершити
    Unilateral або Mutual через CloseInteractionContext,
    якщо контекст не містить активної чи Fulfilled-угоди.
    Активні неархівні взаємодії перешкоджають скасуванню Order.
    Архівність є похідною ознакою.''
),

(
    ''InteractionStatus'', ''TABLE'', NULL,
    N''Довідник станів взаємодії:
    Unilateral — одностороння пропозиція;
    Mutual — підтверджена взаємодія;
    Rejected — відхилена або завершена взаємодія.
    Rejected може виникнути як після Unilateral,
    так і після Mutual.
    Архівність є похідною ознакою, а не окремим статусом.
    Завершення взаємодії не означає автоматичної
    заборони листування: діє ChatAccessPolicy.''
),

(
    ''CollaborativeDeal'', ''TABLE'', NULL,
    N''Temporal-сутність угоди в межах InteractionContext.
    Зберігає координати, остаточну ціну без комісії,
    відправника, отримувача, останнього автора пропозиції,
    дату погодження, зашифровані секрети та стан.
    Для створення угоди обидва Order повинні бути Private
    або Published, а InteractionContext — Mutual.
    Draft резервує обидва пов’язані Order.
    Активна угода не забороняє змінювати звичайні атрибути
    та публічність Order, але перешкоджає їх скасуванню.
    Failed звільняє Order, не завершуючи InteractionContext.
    Fulfilled остаточно використовує Order та робить
    їх незмінними.
    Умови угоди редагуються лише до погодження.
    Прямі зміни CollaborativeDeal backend заборонені.''
);

--------------------------------------------------
-- 1.2. Процедури
--------------------------------------------------

INSERT INTO @Descriptions VALUES

(
    ''SetDelivererOrderStatus'', ''PROCEDURE'', NULL,
    N''Керує життєвим циклом Order кур’єра.
    Параметри: OrderId, ActorUserId, NewStatusCode.
    Виконавець повинен бути автором Order.
    Дозволені переходи:
    Draft -> Private, Published або Cancelled;
    Private -> Published або Cancelled;
    Published -> Private або Cancelled.
    Скасування заборонено за наявності активної угоди,
    Fulfilled-угоди або активної неархівної взаємодії.
    Cancelled та виконані Order не допускають зміни статусу.
    Повторне встановлення поточного статусу є успішною
    операцією без UPDATE та нової історичної версії.
    Використовує transaction-owned application lock
    та блокування запису Order.
    Повертає ID, попередній статус, поточний статус
    та wasChanged.''
),

(
    ''SetDeliveryRequesterOrderStatus'', ''PROCEDURE'', NULL,
    N''Керує життєвим циклом Order замовника.
    Параметри: OrderId, ActorUserId, NewStatusCode.
    Виконавець повинен бути автором Order.
    Дозволені переходи:
    Draft -> Private, Published або Cancelled;
    Private -> Published або Cancelled;
    Published -> Private або Cancelled.
    Скасування заборонено за наявності активної угоди,
    Fulfilled-угоди або активної неархівної взаємодії.
    Cancelled та виконані Order не допускають зміни статусу.
    Повторне встановлення поточного статусу не виконує
    UPDATE та не створює історичної версії.
    Використовує transaction-owned application lock
    та блокування запису Order.
    Повертає ID, попередній статус, поточний статус
    та wasChanged.''
),

(
    ''CloseInteractionContext'', ''PROCEDURE'', NULL,
    N''Атомарно завершує InteractionContext.
    Параметри: InteractionContextId, ActorUserId.
    Виконавець повинен бути автором одного з пов’язаних Order.
    Дозволені переходи Unilateral -> Rejected
    та Mutual -> Rejected.
    Повторне завершення Rejected є ідемпотентним.
    Наявність активної або Fulfilled-угоди блокує завершення.
    Failed-угоди не перешкоджають завершенню.
    Не змінює статуси Order та угод.
    Не змінює правила листування.
    Використовує AcquireInteractionIntentLocks.
    Повертає ID контексту, попередній та поточний статус,
    а також wasChanged.''
),

(
    ''RejectInteractionContext'', ''PROCEDURE'', NULL,
    N''Переводить Unilateral у Rejected за рішенням
    автора цільового Order.
    Повторне відхилення та завершення Mutual через цю
    процедуру не підтримуються.
    Для загального завершення Unilateral або Mutual
    будь-яким автором Order використовувати
    CloseInteractionContext.
    Правила листування визначаються ChatAccessPolicy.''
),

(
    ''CreateCollaborativeDeal'', ''PROCEDURE'', NULL,
    N''Атомарно створює Draft у Mutual InteractionContext.
    Виконавець повинен бути автором одного з Order.
    Обидва Order повинні мати статус Private або Published,
    незалежно від сторони-ініціатора взаємодії.
    Draft та Cancelled не допускаються.
    Перевіряє відсутність активних або Fulfilled-угод,
    координати, ціну та належність виконавця до взаємодії.
    Створена Draft-угода резервує обидва Order.
    Автор пропозиції стає lastProposedByUserId.
    Дата погодження та секрети залишаються NULL.
    Початкова редакція умов дорівнює 1.''
),

(
    ''FailCollaborativeDeal'', ''PROCEDURE'', NULL,
    N''Переводить Draft-угоду у Failed за рішенням
    одного з авторів пов’язаних Order.
    Умови, останній автор пропозиції та історія зберігаються.
    Order звільняються від резервування цією угодою.
    InteractionContext автоматично не завершується.
    Для подальшого скасування Order необхідно завершити
    його активні неархівні взаємодії.
    Скасування вже погодженої угоди не реалізовано.''
),

(
    ''CompleteCollaborativeDeal'', ''PROCEDURE'', NULL,
    N''Атомарно переводить CollaborativeDeal
    з AwaitingPayout до Fulfilled.
    Використовує AcquireInteractionIntentLocks та
    UPDLOCK/HOLDLOCK на обох пов’язаних Intent через PK
    для синхронізації з прямим редагуванням Order.
    Після виконання угоди Order стають незмінними
    та остаточно недоступними для нових угод.
    Інші взаємодії зі спільними Order стають архівними.
    Статус Order окремо не змінюється.
    Підтвердження успішної виплати належить backend.
    Процедура самостійно не перевіряє результат платежу.''
);

--------------------------------------------------
-- 1.3. Тригери
--------------------------------------------------

INSERT INTO @Descriptions VALUES

(
    ''TR_DelivererIntent_ImmutableFinalStates'',
    ''TRIGGER'', ''DelivererIntent'',
    N''AFTER UPDATE, DELETE для DelivererIntent.
    Забороняє фізичне видалення будь-якого Order (51602).
    Забороняє UPDATE Order, попередній статус якого
    Cancelled (51603).
    Забороняє UPDATE Order, пов’язаного хоча б з однією
    Fulfilled-угодою (51160).
    Перевірка Fulfilled використовує READCOMMITTEDLOCK
    для читання зафіксованого стану з блокуванням.
    Працює з множинними змінами.
    Контроль переходів статусу активного Order належить
    SetDelivererOrderStatus та правам доступу.''
),

(
    ''TR_DeliveryRequesterIntent_ImmutableFinalStates'',
    ''TRIGGER'', ''DeliveryRequesterIntent'',
    N''AFTER UPDATE, DELETE для DeliveryRequesterIntent.
    Забороняє фізичне видалення будь-якого Order (51604).
    Забороняє UPDATE Order, попередній статус якого
    Cancelled (51605).
    Забороняє UPDATE Order, пов’язаного хоча б з однією
    Fulfilled-угодою (51161).
    Перевірка Fulfilled використовує READCOMMITTEDLOCK
    для читання зафіксованого стану з блокуванням.
    Працює з множинними змінами.
    Контроль переходів статусу активного Order належить
    SetDeliveryRequesterOrderStatus та правам доступу.''
);

--------------------------------------------------
-- 1.4. Представлення
--------------------------------------------------

INSERT INTO @Descriptions VALUES

(
    ''vDelivererIntentDetails'', ''VIEW'', NULL,
    N''Розширене представлення поточного Order кур’єра.
    Містить кількість взаємодій та угод, останню й активну
    угоду, похідні ознаки доступності.
    isAvailableAsTarget = 1 лише для Published Order
    без активних або Fulfilled-угод.
    isAvailableAsInitiator = 1 лише для Private або Published
    Order без активних або Fulfilled-угод.
    Draft-угода резервує Order.
    Draft та Cancelled Order недоступні в обох ролях.
    Публічність і фактична доступність є різними ознаками.
    Представлення описує поточний стан, а не історичний
    стан Order на момент початку взаємодії.''
),

(
    ''vDeliveryRequesterIntentDetails'', ''VIEW'', NULL,
    N''Розширене представлення поточного Order замовника
    разом із поточними атрибутами посилки.
    Містить кількість взаємодій та угод, останню й активну
    угоду, похідні ознаки доступності.
    isAvailableAsTarget = 1 лише для Published Order
    без активних або Fulfilled-угод.
    isAvailableAsInitiator = 1 лише для Private або Published
    Order без активних або Fulfilled-угод.
    Draft-угода резервує Order.
    Draft та Cancelled Order недоступні в обох ролях.
    Представлення не відтворює історичного стану
    Order або посилки на момент початку взаємодії.''
);

--------------------------------------------------
-- 2. Запис MS_Description
--------------------------------------------------

DECLARE @ObjectName SYSNAME;
DECLARE @ObjectType VARCHAR(20);
DECLARE @ParentTable SYSNAME;
DECLARE @Description NVARCHAR(2000);

DECLARE @Level1Type VARCHAR(20);
DECLARE @Level1Name SYSNAME;
DECLARE @Level2Type VARCHAR(20);
DECLARE @Level2Name SYSNAME;

DECLARE @ObjectId INT;

DECLARE @Updated INT = 0;
DECLARE @Created INT = 0;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE description_cursor CURSOR LOCAL FAST_FORWARD
    FOR
        SELECT objectName, objectType, parentTable, description
        FROM @Descriptions;

    OPEN description_cursor;

    FETCH NEXT FROM description_cursor INTO
        @ObjectName, @ObjectType,
        @ParentTable, @Description;

    WHILE @@FETCH_STATUS = 0
    BEGIN

        SET @ObjectId =
            OBJECT_ID(N''dbo.'' + QUOTENAME(@ObjectName));

        IF @ObjectId IS NULL
            THROW 51702, N''Documented object not found.'', 1;

        IF @ObjectType = ''TRIGGER''
        BEGIN
            SET @Level1Type = ''TABLE'';
            SET @Level1Name = @ParentTable;
            SET @Level2Type = ''TRIGGER'';
            SET @Level2Name = @ObjectName;
        END
        ELSE
        BEGIN
            SET @Level1Type = @ObjectType;
            SET @Level1Name = @ObjectName;
            SET @Level2Type = NULL;
            SET @Level2Name = NULL;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM sys.extended_properties
            WHERE class = 1
              AND major_id = @ObjectId
              AND minor_id = 0
              AND name = ''MS_Description''
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

            SET @Updated += 1;

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

            SET @Created += 1;

        END;

        FETCH NEXT FROM description_cursor INTO
            @ObjectName, @ObjectType,
            @ParentTable, @Description;

    END;

    CLOSE description_cursor;
    DEALLOCATE description_cursor;

    --------------------------------------------------
    -- 3. Перевірка записаної документації
    --------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM @Descriptions AS d
        LEFT JOIN sys.extended_properties AS p
            ON p.major_id =
               OBJECT_ID(N''dbo.'' + QUOTENAME(d.objectName))
           AND p.class = 1
           AND p.minor_id = 0
           AND p.name = ''MS_Description''
        WHERE p.major_id IS NULL
           OR CONVERT(NVARCHAR(2000), p.value)
              <> d.description
    )
        THROW 51703, N''Documentation verification failed.'', 1;

    COMMIT TRANSACTION;

    SELECT
        N''Database documentation successfully updated.''
            AS result,
        @Updated AS updatedDescriptions,
        @Created AS createdDescriptions,
        @Updated + @Created AS totalDescriptions;

    SELECT
        objectName,
        objectType,
        ''PASS'' AS documentationCheck
    FROM @Descriptions
    ORDER BY objectType, objectName;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    -- 09 Column documentation
    EXEC sys.sp_executesql N'SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() <> N''PassBy''
    THROW 51710, N''Invalid target database.'', 1;

DECLARE @Descriptions TABLE
(
    tableName SYSNAME,
    columnName SYSNAME,
    description NVARCHAR(2000),
    PRIMARY KEY (tableName, columnName)
);

--------------------------------------------------
-- 1. Документація структурних атрибутів
--------------------------------------------------

INSERT INTO @Descriptions VALUES

(
    ''Deliverer'', ''userId'',
    N''Первинний та зовнішній ключ ролі кур’єра.
    Визначає користувача, якому належить роль.
    Незмінний структурний атрибут.
    Прямий UPDATE backend заборонено.''
),

(
    ''DeliveryRequester'', ''userId'',
    N''Первинний та зовнішній ключ ролі замовника.
    Визначає користувача, якому належить роль.
    Незмінний структурний атрибут.
    Прямий UPDATE backend заборонено.''
),

(
    ''DeliveryRequesterShipment'',
    ''deliveryRequesterShipmentId'',
    N''Незмінний первинний ключ посилки.
    Прямий UPDATE backend заборонено.''
),

(
    ''DeliveryRequesterShipment'',
    ''ownerDeliveryRequesterUserId'',
    N''Незмінний структурний FK власника посилки.
    Передавання посилки іншому власнику через UPDATE
    не підтримується.
    Прямий UPDATE backend заборонено.''
),

(
    ''IDCardData'', ''documentId'',
    N''Первинний та зовнішній ключ ValidatedDocument.
    Визначає документ, якому належать дані ID-картки.
    Переприв’язування даних до іншого документа
    не підтримується.
    Прямий UPDATE backend заборонено.''
),

(
    ''PasswordCredential'', ''credentialId'',
    N''Незмінний первинний ключ облікових даних.
    Зміна пароля виконується оновленням відповідних
    атрибутів наявного запису без зміни ідентифікатора.
    Прямий UPDATE ключа backend заборонено.''
),

(
    ''UserAccount'', ''userId'',
    N''Незмінний первинний ключ облікового запису.
    Прямий UPDATE backend заборонено.''
),

(
    ''UserAccount'', ''credentialId'',
    N''Незмінний структурний FK облікових даних акаунта.
    Зміна пароля не потребує створення нового
    PasswordCredential або переприв’язування акаунта.
    Оновлюються атрибути наявного PasswordCredential.
    Прямий UPDATE backend заборонено.''
),

(
    ''UserPaymentMethod'', ''paymentMethodId'',
    N''Незмінний первинний ключ платіжного методу.
    Прямий UPDATE backend заборонено.''
),

(
    ''UserPaymentMethod'', ''userId'',
    N''Незмінний структурний FK власника платіжного методу.
    Передавання методу іншому користувачу не підтримується.
    Прямий UPDATE backend заборонено.''
),

(
    ''ValidatedDocument'', ''documentId'',
    N''Незмінний первинний ключ валідованого документа.
    Прямий UPDATE backend заборонено.''
),

(
    ''ValidatedDocument'', ''userId'',
    N''Незмінний структурний FK користувача,
    з яким пов’язаний валідований документ.
    Переприв’язування документа не підтримується.
    Прямий UPDATE backend заборонено.''
),

(
    ''ValidatedDocument'', ''verificationProviderId'',
    N''Незмінний структурний FK провайдера верифікації,
    з яким пов’язана валідація документа.
    Зміна провайдера наявного запису не підтримується.
    Прямий UPDATE backend заборонено.''
),

(
    ''VerificationProvider'', ''providerId'',
    N''Незмінний первинний ключ провайдера верифікації.
    Прямий UPDATE backend заборонено.''
);

--------------------------------------------------
-- 2. Запис документації
--------------------------------------------------

DECLARE @TableName SYSNAME;
DECLARE @ColumnName SYSNAME;
DECLARE @Description NVARCHAR(2000);

DECLARE @ObjectId INT;
DECLARE @ColumnId INT;

DECLARE @Created INT = 0;
DECLARE @Updated INT = 0;

BEGIN TRY

    BEGIN TRANSACTION;

    DECLARE description_cursor CURSOR LOCAL FAST_FORWARD
    FOR
        SELECT tableName, columnName, description
        FROM @Descriptions;

    OPEN description_cursor;

    FETCH NEXT FROM description_cursor INTO
        @TableName, @ColumnName, @Description;

    WHILE @@FETCH_STATUS = 0
    BEGIN

        SET @ObjectId =
            OBJECT_ID(N''dbo.'' + QUOTENAME(@TableName));

        SET @ColumnId =
            COLUMNPROPERTY(
                @ObjectId,
                @ColumnName,
                ''ColumnId''
            );

        IF @ObjectId IS NULL OR @ColumnId IS NULL
            THROW 51712,
                N''Documented column not found.'',
                1;

        IF EXISTS
        (
            SELECT 1
            FROM sys.extended_properties
            WHERE class = 1
              AND major_id = @ObjectId
              AND minor_id = @ColumnId
              AND name = ''MS_Description''
        )
        BEGIN

            EXEC sys.sp_updateextendedproperty
                @name = N''MS_Description'',
                @value = @Description,
                @level0type = N''SCHEMA'',
                @level0name = N''dbo'',
                @level1type = N''TABLE'',
                @level1name = @TableName,
                @level2type = N''COLUMN'',
                @level2name = @ColumnName;

            SET @Updated += 1;

        END
        ELSE
        BEGIN

            EXEC sys.sp_addextendedproperty
                @name = N''MS_Description'',
                @value = @Description,
                @level0type = N''SCHEMA'',
                @level0name = N''dbo'',
                @level1type = N''TABLE'',
                @level1name = @TableName,
                @level2type = N''COLUMN'',
                @level2name = @ColumnName;

            SET @Created += 1;

        END;

        FETCH NEXT FROM description_cursor INTO
            @TableName, @ColumnName, @Description;

    END;

    CLOSE description_cursor;
    DEALLOCATE description_cursor;

    --------------------------------------------------
    -- 3. Перевірка документації
    --------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM @Descriptions AS d
        LEFT JOIN sys.extended_properties AS p
            ON p.class = 1
           AND p.major_id =
               OBJECT_ID(N''dbo.'' + QUOTENAME(d.tableName))
           AND p.minor_id =
               COLUMNPROPERTY(
                   OBJECT_ID(
                       N''dbo.'' + QUOTENAME(d.tableName)
                   ),
                   d.columnName,
                   ''ColumnId''
               )
           AND p.name = ''MS_Description''
        WHERE p.major_id IS NULL
           OR CONVERT(NVARCHAR(2000), p.value)
              <> d.description
    )
        THROW 51713,
            N''Column documentation verification failed.'',
            1;

    COMMIT TRANSACTION;

    SELECT
        N''Structural key documentation updated.'' AS result,
        @Created AS createdDescriptions,
        @Updated AS updatedDescriptions,
        @Created + @Updated AS totalDescriptions;

    SELECT
        tableName,
        columnName,
        ''PASS'' AS documentationCheck
    FROM @Descriptions
    ORDER BY tableName, columnName;

END TRY
BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;

END CATCH;';


    IF @@TRANCOUNT <> 1 OR XACT_STATE() <> 1
        THROW 51719, N'Unexpected migration transaction state.', 1;

    COMMIT TRANSACTION;
    SELECT N'PassBy migration 2026-11-25 completed.' AS result;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
