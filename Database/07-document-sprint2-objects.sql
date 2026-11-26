/*
    PassBy / Sprint 2
    07-document-sprint2-objects.sql

    Джерела:
      04-create-sprint2-tables.sql
      05-implement-integrity-constraints.sql
      06-configure-backend-permissions.sql

    Призначення:
      Додати / оновити MS_Description усіх об'єктів, визначених
      у скриптах Sprint 2, включно з temporal history-таблицями.

    Склад:
      16 основних таблиць,
       5 history-таблиць,
       4 DML-тригери,
       3 представлення,
       9 процедур.
      Разом: 37 об'єктів.

    Важливо:
      Документація відбиває ФАКТИЧНУ поведінку SQL з наданих файлів.
      MS_Description не створює нових бізнес-обмежень і не
      змінює таблиці, дані, процедури, представлення чи тригери.
      Наявні об'єкти першого спринту поза цими файлами не документуються.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF DB_NAME() = N'master'
    THROW 51600, N'Connect to the target application database, not master.', 1;

DECLARE @Documentation TABLE
(
    objectType NVARCHAR(16) NOT NULL,
    objectName SYSNAME NOT NULL,
    parentTable SYSNAME NULL,
    objectDescription NVARCHAR(3000) NOT NULL,
    PRIMARY KEY (objectType, objectName)
);

-- ============================================================
-- I. Основні таблиці
-- ============================================================
INSERT INTO @Documentation
    (objectType, objectName, parentTable, objectDescription)
VALUES
    (N'TABLE', N'OrderStatus', NULL,
     N'Довідник станів формування намірів: Draft, Private, Published та RawIntent. Статус описує публікацію/походження Order, а не виконання перевезення. Доступність Order визначають пов’язані CollaborativeDeal і представлення деталей.'),
    (N'TABLE', N'InteractionStatus', NULL,
     N'Довідник станів взаємодії: Unilateral (пропозиція однієї сторони), Mutual (підтверджена обома сторонами), Rejected (відхилена або закрита). Архівність не зберігається тут окремим статусом, а обчислюється з виконаних угод.'),
    (N'TABLE', N'RequestInitiator', NULL,
     N'Довідник сторони, що ініціювала InteractionContext: Deliverer або DeliveryRequester. Використовується для визначення цільового Order і права протилежного учасника підтвердити чи відхилити взаємодію.'),
    (N'TABLE', N'DealExecutionStatus', NULL,
     N'Довідник станів виконання CollaborativeDeal: AwaitingHandover, InTransit, AwaitingPayout, Fulfilled, Failed. Fulfilled і Failed є термінальними: їхню незмінність забезпечує тригер CollaborativeDeal. Цей довідник сам собою не контролює переходи між активними станами.'),
    (N'TABLE', N'AttemptStatus', NULL,
     N'Довідник результатів взаємодії з платіжним провайдером: Succeeded, ProviderRejected, CommunicationError та ProviderPending. CommunicationError не доводить відсутності операції в провайдера; ProviderPending не є остаточним результатом.'),
    (N'TABLE', N'PricingPolicy', NULL,
     N'Поточна політика комісії PassBy. commissionRate зберігає частку від 0 до 1; початкове значення 0.10. Таблиця є system-versioned temporal із PricingPolicyHistory; тригер забороняє INSERT/DELETE, дозволяючи змінювати ставку через UPDATE.'),
    (N'TABLE', N'UserSettings', NULL,
     N'Персональні налаштування UserAccount, один запис на користувача (PK userId). orderPublishingPolicy: 0 = Manual (створення звичайного Order у Private), 1 = Automatic (у Published). Явний Draft та автоматичний RawIntent не визначаються цією політикою.'),
    (N'TABLE', N'DelivererIntent', NULL,
     N'Намір кур’єра доставити посилку: маршрут GEOGRAPHY/SRID 4326, місткість, допустима винагорода, час відправлення, автор і статус. Підтримує звичайний Order та RawIntent. Temporal-історія в DelivererIntentHistory. Фактична доступність залежить від активних/Fulfilled угод; RawIntent і Order з Fulfilled-угодою захищені тригером від UPDATE/DELETE.'),
    (N'TABLE', N'DeliveryRequesterShipment', NULL,
     N'Самостійний опис посилки, власником якої є користувач DeliveryRequester: назва, необов’язковий опис, додатні вага та габарити. Посилка може існувати без Order і редагуватися. Попередні версії зберігаються в DeliveryRequesterShipmentHistory; складений FK у намірі гарантує відповідність власника.'),
    (N'TABLE', N'DeliveryRequesterIntent', NULL,
     N'Намір замовника організувати доставку власної посилки: координати GEOGRAPHY/SRID 4326, ціновий діапазон без комісії, автор, посилка та статус. Підтримує Order і RawIntent. Складений FK перевіряє належність посилки автору. Temporal-історія в DeliveryRequesterIntentHistory; RawIntent і Order після Fulfilled захищені від UPDATE/DELETE.'),
    (N'TABLE', N'ChatAccessPolicy', NULL,
     N'Temporal-політика повідомлень для кожного InteractionStatus: maxNumberMessages = NULL означає необмежену кількість, число задає загальний ліміт. У поточних даних Unilateral = 3, Mutual і Rejected = без числового ліміту. Версія політики вибирається за interactionStartAtUtc з ChatAccessPolicyHistory.'),
    (N'TABLE', N'InteractionContext', NULL,
     N'Контекст взаємодії між одним DelivererIntent та одним DeliveryRequesterIntent, з датою початку, роллю ініціатора і станом Unilateral/Mutual/Rejected. Один Order може брати участь у багатьох контекстах. Ексклюзивність стосується активних угод, а не Mutual; похідна архівність обчислюється в vInteractionContextDetails.'),
    (N'TABLE', N'UserMessage', NULL,
     N'Історія текстових повідомлень InteractionContext із автором UserAccount і часом UTC. Належність автора, історичний ліміт, архівність та атомарність запису перевіряє SendUserMessage; прямі INSERT/UPDATE/DELETE для passby_backend заборонені.'),
    (N'TABLE', N'CollaborativeDeal', NULL,
     N'Погоджена угода в InteractionContext: географічні умови, остаточна ціна без комісії, відправник, отримувач, хеші токенів передачі/доставки та стан виконання. У межах одного Order допускається максимум одна активна угода, Failed звільняє Order, Fulfilled остаточно його використовує. Термінальні угоди незмінні; інші поля обмежені правами backend.'),
    (N'TABLE', N'UserPaymentMethod', NULL,
     N'Платіжний метод, прив’язаний до UserAccount: маскований номер, тип картки, токени провайдера recToken/rec2Token і дата вимкнення disabledAtUtc. Вимкнення позначає стан методу, але історичні спроби платежу з ним зберігаються. Правила зберігання/захисту токенів визначаються окремо.'),
    (N'TABLE', N'PaymentOperationAttempt', NULL,
     N'Історичний запис окремої спроби платіжної операції угоди (AUTH, SETTLE, REFUND, P2P_CREDIT): сума, валюта, orderReference, відповідь провайдера, AttemptStatus та необов’язковий paymentMethodId. CreatePaymentOperationAttempt перевіряє належність зазначеного методу автору DeliveryRequesterIntent, але не перевіряє disabledAtUtc, попередні методи чи послідовність платежів. Прямі зміни backend заборонені.');

-- ============================================================
-- II. Temporal history-таблиці
-- ============================================================
INSERT INTO @Documentation
    (objectType, objectName, parentTable, objectDescription)
VALUES
    (N'HISTORY', N'PricingPolicyHistory', NULL,
     N'Автоматична system-versioned історія PricingPolicy. Зберігає попередні значення commissionRate та системні межі чинності validFrom/validTo; не є окремою бізнес-сутністю чи місцем прямого запису.'),
    (N'HISTORY', N'DelivererIntentHistory', NULL,
     N'Автоматична system-versioned історія DelivererIntent: попередні версії умов, статусу й інших полів наміру кур’єра. Для аналізу змін використовувати temporal-запити FOR SYSTEM_TIME.'),
    (N'HISTORY', N'DeliveryRequesterShipmentHistory', NULL,
     N'Автоматична system-versioned історія DeliveryRequesterShipment. Містить попередні версії атрибутів посилки; використовується для відтворення її історичного стану.'),
    (N'HISTORY', N'DeliveryRequesterIntentHistory', NULL,
     N'Автоматична system-versioned історія DeliveryRequesterIntent. Містить попередні версії умов і статусу наміру замовника; читати разом із основною temporal-таблицею.'),
    (N'HISTORY', N'ChatAccessPolicyHistory', NULL,
     N'Автоматична system-versioned історія ChatAccessPolicy. Дозволяє визначати версію політики чату, що діяла на момент створення InteractionContext.');

-- ============================================================
-- III. DML-тригери
-- ============================================================
INSERT INTO @Documentation
    (objectType, objectName, parentTable, objectDescription)
VALUES
    (N'TRIGGER', N'TR_PricingPolicy_BlockInsertDelete', N'PricingPolicy',
     N'AFTER INSERT, DELETE для PricingPolicy. Забороняє додавання і видалення записів тарифної політики (THROW 51001), дозволяє UPDATE існуючої комісії; для історії змін використовується temporal-механізм.'),
    (N'TRIGGER', N'TR_DelivererIntent_ImmutableFinalStates', N'DelivererIntent',
     N'AFTER UPDATE, DELETE для DelivererIntent. Забороняє зміну/видалення RawIntent і Order, пов’язаного хоча б з однією Fulfilled-угодою (THROW 51160). Працює з множинними змінами через inserted/deleted.'),
    (N'TRIGGER', N'TR_DeliveryRequesterIntent_ImmutableFinalStates', N'DeliveryRequesterIntent',
     N'AFTER UPDATE, DELETE для DeliveryRequesterIntent. Забороняє зміну/видалення RawIntent і Order замовника, пов’язаного хоча б з однією Fulfilled-угодою (THROW 51161). Працює з множинними змінами.'),
    (N'TRIGGER', N'TR_CollaborativeDeal_ImmutableFinalStates', N'CollaborativeDeal',
     N'AFTER UPDATE, DELETE для CollaborativeDeal. Забороняє будь-яку зміну або видалення угоди, яка ДО операції мала стан Failed або Fulfilled (THROW 51162). Дозволяє перший перехід з активного стану до фінального, але не перевіряє повну послідовність активних станів.');

-- ============================================================
-- IV. Представлення
-- ============================================================
INSERT INTO @Documentation
    (objectType, objectName, parentTable, objectDescription)
VALUES
    (N'VIEW', N'vDelivererIntentDetails', NULL,
     N'Розширене представлення DelivererIntent: умови Order, кількість взаємодій за станами, усі/активні/Fulfilled угоди, остання й активна угода. isAvailableAsTarget = Published без активних і Fulfilled угод; isAvailableAsInitiator = Private або Published за тих самих умов. RawIntent не є доступним для нових взаємодій.'),
    (N'VIEW', N'vDeliveryRequesterIntentDetails', NULL,
     N'Розширене представлення DeliveryRequesterIntent разом з атрибутами посилки: кількості взаємодій і угод, остання/активна угода, ознаки доступності. Ціль: Published без активних/Fulfilled; ініціатор: Private або Published без активних/Fulfilled. Відображає похідний стан, не зберігає його.'),
    (N'VIEW', N'vInteractionContextDetails', NULL,
     N'Розширене представлення InteractionContext: історична політика ChatAccessPolicy за interactionStartAtUtc, кількість повідомлень, isArchived і canSendMessage. Архівність = існує Fulfilled-угода іншої взаємодії, що використовує один із тих самих Order. Активна угода в іншому чаті не архівує; статус InteractionContext зберігається.');

-- ============================================================
-- V. Збережені процедури
-- ============================================================
INSERT INTO @Documentation
    (objectType, objectName, parentTable, objectDescription)
VALUES
    (N'PROCEDURE', N'CreateDelivererOrder', NULL,
     N'Створює звичайний DelivererIntent із маршрутом GEOGRAPHY/SRID 4326, часом, необов’язковими обмеженнями місткості/винагороди. Початковий статус: Draft при SaveAsDraft=1, інакше Published для Automatic або Private для Manual; за відсутності UserSettings застосовується Manual. Повертає ID та статус.'),
    (N'PROCEDURE', N'CreateDeliveryRequesterOrder', NULL,
     N'Створює звичайний DeliveryRequesterIntent для вказаної посилки із координатами та необов’язковими межами ціни. Належність посилки автору захищено складеним FK. Статус: Draft має пріоритет, інакше Published/Private за політикою UserSettings (відсутність налаштувань = Manual). Повертає ID та статус.'),
    (N'PROCEDURE', N'CreateInteractionContext', NULL,
     N'Атомарно створює Unilateral InteractionContext. Якщо InitiatorOrderId задано, використовує готовий Order автора; якщо NULL, генерує RawIntent із параметрів пошуку. Ціль має бути Published і доступна; готовий ініціатор Private/Published та доступний. Застосовує application locks до пов’язаних намірів, не забороняє множинні взаємодії без активної угоди.'),
    (N'PROCEDURE', N'AcceptInteractionContext', NULL,
     N'Переводить InteractionContext з Unilateral до Mutual лише за підтвердженням автора цільового Order. Повторне підтвердження, інший статус і сторонній responder відхиляються. ResponderUserId повинен надходити з довіреного контексту автентифікації.'),
    (N'PROCEDURE', N'RejectInteractionContext', NULL,
     N'Переводить InteractionContext з Unilateral до Rejected за рішенням автора цільового Order. Відхилення Mutual або повторне відхилення процедурою не підтримуються. Ліміти листування після зміни статусу визначаються ChatAccessPolicy, а не цією процедурою.'),
    (N'PROCEDURE', N'AcquireInteractionIntentLocks', NULL,
     N'Внутрішня процедура конкурентного захисту: вимагає активної транзакції, визначає DelivererIntent/DeliveryRequesterIntent для InteractionContext та бере transaction-owned exclusive sp_getapplock для ресурсів PassBy:Intent:D/R у стабільному порядку. Повертає ідентифікатори й поточні ознаки контексту через OUTPUT.'),
    (N'PROCEDURE', N'CreateCollaborativeDeal', NULL,
     N'Атомарно створює угоду в Mutual InteractionContext з учасником-автором одного з намірів, валідними координатами, ціною й різними хешами токенів. Цільовий Order має бути Published; готовий/RawIntent ініціатора допускається за правилами. Один Order не може мати понад одну активну угоду і не використовується після Fulfilled; Failed дозволяє повтор. Синхронізація через AcquireInteractionIntentLocks.'),
    (N'PROCEDURE', N'SendUserMessage', NULL,
     N'Атомарно додає UserMessage після перевірки учасника чату, історичного ліміту ChatAccessPolicy та відсутності архівності. Архівність визначається за Fulfilled у іншому InteractionContext, що використовує спільний Order; VIEW не викликається. Активні угоди в інших чатах самі по собі не блокують повідомлення. Читання InteractionContext серіалізовано UPDLOCK/HOLDLOCK.'),
    (N'PROCEDURE', N'CreatePaymentOperationAttempt', NULL,
     N'Атомарно записує платіжну спробу CollaborativeDeal для операцій AUTH/SETTLE/REFUND/P2P_CREDIT (допустимість типу забезпечує CHECK). За ненульового paymentMethodId перевіряє, що метод належить автору пов’язаного DeliveryRequesterIntent. Не перевіряє disabledAtUtc, попередній метод або результат інших спроб і порядок фінансових операцій. NULL paymentMethodId дозволено.');

-- ============================================================
-- VI. Попередня перевірка: усі 37 об'єктів уже мають існувати.
-- ============================================================

IF EXISTS
(
    SELECT 1
    FROM @Documentation AS d
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM sys.objects AS o
        INNER JOIN sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE s.name = N'dbo'
          AND o.name COLLATE DATABASE_DEFAULT = d.objectName
          AND o.type COLLATE DATABASE_DEFAULT =
              CASE d.objectType
                  WHEN N'TABLE' THEN N'U'
                  WHEN N'HISTORY' THEN N'U'
                  WHEN N'TRIGGER' THEN N'TR'
                  WHEN N'VIEW' THEN N'V'
                  WHEN N'PROCEDURE' THEN N'P'
              END
          AND
          (
              d.parentTable IS NULL
              OR o.parent_object_id =
                 OBJECT_ID(N'dbo.' + d.parentTable, N'U')
          )
    )
)
BEGIN
    SELECT
        d.objectType,
        N'dbo.' + d.objectName AS missingObject,
        d.parentTable
    FROM @Documentation AS d
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM sys.objects AS o
        INNER JOIN sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE s.name = N'dbo'
          AND o.name COLLATE DATABASE_DEFAULT = d.objectName
          AND o.type COLLATE DATABASE_DEFAULT =
              CASE d.objectType
                  WHEN N'TABLE' THEN N'U'
                  WHEN N'HISTORY' THEN N'U'
                  WHEN N'TRIGGER' THEN N'TR'
                  WHEN N'VIEW' THEN N'V'
                  WHEN N'PROCEDURE' THEN N'P'
              END
          AND
          (
              d.parentTable IS NULL
              OR o.parent_object_id =
                 OBJECT_ID(N'dbo.' + d.parentTable, N'U')
          )
    )
    ORDER BY d.objectType, d.objectName;

    THROW 51601, N'Cannot document: required objects are missing or not visible.', 1;
END;

-- ============================================================
-- VII. Idempotent MS_Description upsert.
--
-- DML-тригери є об'єктами другого рівня:
-- SCHEMA -> TABLE -> TRIGGER.
-- Усі інші об'єкти є об'єктами першого рівня:
-- SCHEMA -> TABLE / VIEW / PROCEDURE.
-- ============================================================

DECLARE
    @ObjectType NVARCHAR(16),
    @ObjectName SYSNAME,
    @ParentTable SYSNAME,
    @Description NVARCHAR(3000),
    @Level1Type NVARCHAR(16),
    @PropertyExists BIT;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE documentation_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT
            objectType,
            objectName,
            parentTable,
            objectDescription
        FROM @Documentation
        ORDER BY objectType, objectName;

    OPEN documentation_cursor;

    FETCH NEXT FROM documentation_cursor
        INTO @ObjectType, @ObjectName, @ParentTable, @Description;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @PropertyExists =
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM sys.extended_properties AS ep
                WHERE ep.class = 1
                  AND ep.major_id = OBJECT_ID(N'dbo.' + @ObjectName)
                  AND ep.minor_id = 0
                  AND ep.name = N'MS_Description'
            )
            THEN 1 ELSE 0 END;

        IF @ObjectType = N'TRIGGER'
        BEGIN
            IF @PropertyExists = 1
                EXEC sys.sp_updateextendedproperty
                    @name = N'MS_Description',
                    @value = @Description,
                    @level0type = N'SCHEMA',
                    @level0name = N'dbo',
                    @level1type = N'TABLE',
                    @level1name = @ParentTable,
                    @level2type = N'TRIGGER',
                    @level2name = @ObjectName;
            ELSE
                EXEC sys.sp_addextendedproperty
                    @name = N'MS_Description',
                    @value = @Description,
                    @level0type = N'SCHEMA',
                    @level0name = N'dbo',
                    @level1type = N'TABLE',
                    @level1name = @ParentTable,
                    @level2type = N'TRIGGER',
                    @level2name = @ObjectName;
        END
        ELSE
        BEGIN
            SET @Level1Type =
                CASE WHEN @ObjectType = N'HISTORY'
                    THEN N'TABLE'
                    ELSE @ObjectType
                END;

            IF @PropertyExists = 1
                EXEC sys.sp_updateextendedproperty
                    @name = N'MS_Description',
                    @value = @Description,
                    @level0type = N'SCHEMA',
                    @level0name = N'dbo',
                    @level1type = @Level1Type,
                    @level1name = @ObjectName;
            ELSE
                EXEC sys.sp_addextendedproperty
                    @name = N'MS_Description',
                    @value = @Description,
                    @level0type = N'SCHEMA',
                    @level0name = N'dbo',
                    @level1type = @Level1Type,
                    @level1name = @ObjectName;
        END;

        FETCH NEXT FROM documentation_cursor
            INTO @ObjectType, @ObjectName, @ParentTable, @Description;
    END;

    CLOSE documentation_cursor;
    DEALLOCATE documentation_cursor;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

-- ============================================================
-- VIII. Аудит результату.
-- ============================================================

SELECT
    d.objectType,
    N'dbo.' + d.objectName AS objectName,
    CASE
        WHEN ep.name = N'MS_Description'
            THEN N'OK'
        ELSE N'MISSING'
    END AS documentationStatus,
    CONVERT(NVARCHAR(3000), ep.value) AS description
FROM @Documentation AS d
LEFT JOIN sys.extended_properties AS ep
    ON ep.class = 1
   AND ep.major_id = OBJECT_ID(N'dbo.' + d.objectName)
   AND ep.minor_id = 0
   AND ep.name = N'MS_Description'
ORDER BY
    CASE d.objectType
        WHEN N'TABLE' THEN 1
        WHEN N'HISTORY' THEN 2
        WHEN N'TRIGGER' THEN 3
        WHEN N'VIEW' THEN 4
        WHEN N'PROCEDURE' THEN 5
    END,
    d.objectName;

SELECT
    COUNT(*) AS expectedDocumentedObjects,
    SUM
    (
        CASE WHEN ep.name = N'MS_Description' THEN 1 ELSE 0 END
    ) AS actualDocumentedObjects
FROM @Documentation AS d
LEFT JOIN sys.extended_properties AS ep
    ON ep.class = 1
   AND ep.major_id = OBJECT_ID(N'dbo.' + d.objectName)
   AND ep.minor_id = 0
   AND ep.name = N'MS_Description';
GO
