USE [PassBy];
GO

CREATE TABLE dbo.OrderStatus
/*
    Призначення:
        Довідник станів формування та публікації Order.

    Семантика:
        - Draft: незавершена чернетка.
        - Private: сформований приватний Order
            або автоматично створений сирий намір.
        - Published: опублікований Order.

    Стан виконання перевезення та доступність Order-у тут не зберігається.
    Він визначається через пов'язані угоди.
*/
(
    orderStatusCode VARCHAR(64) NOT NULL,
    statusDescription NVARCHAR(500) NOT NULL,

    CONSTRAINT PK_OrderStatus
        PRIMARY KEY (orderStatusCode)
);
GO
INSERT INTO dbo.OrderStatus
(
    orderStatusCode,
    statusDescription
)
VALUES
(
    'Draft',
    N'Незавершена чернетка Order.'
),
(
    'Private',
    N'Сформований неопублікований Order або приватний сирий намір, автоматично створений для взаємодії.'
),
(
    'Published',
    N'Опублікований Order. Фактична доступність визначається окремо.'
),
(
    'RawIntent',
    N'Автоматично сформований намір. Цей статус неможливо змінити і він однозначно ідентифікує автоматично сформовані наміри.'
);
GO

CREATE TABLE dbo.InteractionStatus
(
    interactionStatusCode VARCHAR(64) NOT NULL,
    statusDescription NVARCHAR(500) NOT NULL,

    CONSTRAINT PK_InteractionStatus
        PRIMARY KEY (interactionStatusCode)
);
GO
INSERT INTO dbo.InteractionStatus
    (interactionStatusCode, statusDescription)
VALUES
    ('Unilateral', N'Одностороння взаємодія, породжена ініціатором.'),
    ('Mutual', N'Двостороння взаємодія, погоджена другою стороною.'),
    ('Rejected', N'Взаємодію відхилено або закрито через недоступність Order');
GO

CREATE TABLE dbo.RequestInitiator
(
    requestInitiatorCode VARCHAR(64) NOT NULL,
    initiatorDescription NVARCHAR(500) NOT NULL,

    CONSTRAINT PK_RequestInitiator
        PRIMARY KEY (requestInitiatorCode)
);
GO
INSERT INTO dbo.RequestInitiator
(
    requestInitiatorCode,
    initiatorDescription
)
VALUES
    ('Deliverer', N'Кур’єр є ініціатором взаємодії.'),
    (N'DeliveryRequester', N'Замовник перевезення є ініціатором взаємодії.');
GO

CREATE TABLE dbo.DealExecutionStatus
(
    dealExecutionStatusCode VARCHAR(64) NOT NULL,
    statusDescription NVARCHAR(500) NOT NULL,

    CONSTRAINT PK_DealExecutionStatus
        PRIMARY KEY (dealExecutionStatusCode)
);
GO
INSERT INTO dbo.DealExecutionStatus
    (dealExecutionStatusCode, statusDescription)
VALUES
    (
        'AwaitingHandover',
        N'Угоду сформовано. Очікується передача посилки відправником кур’єру.'
    ),
    (
        'InTransit',
        N'Кур’єр прийняв посилку. Передачу підтверджено відповідним секретом, доставка виконується.'
    ),
    (
        'AwaitingPayout',
        N'Передачу посилки отримувачу підтверджено відповідним секретом. Очікується виплата винагороди кур’єру.'
    ),
    (
        'Fulfilled',
        N'Угоду успішно виконано: отримання посилки підтверджено, кур’єр отримав винагороду.'
    ),
    (
        'Failed',
        N'Виконання угоди завершилося невдачею.'
    );
GO

CREATE TABLE dbo.AttemptStatus
(
    attemptStatusCode VARCHAR(64) NOT NULL,
    statusDescription NVARCHAR(500) NOT NULL,

    CONSTRAINT PK_AttemptStatus
        PRIMARY KEY (attemptStatusCode)
);
GO
INSERT INTO dbo.AttemptStatus
    (attemptStatusCode, statusDescription)
VALUES
    (
        'Succeeded',
        N'Провайдер підтвердив успішне виконання фінансової операції.'
    ),
    (
        'ProviderRejected',
        N'Провайдер відхилив виконання фінансової операції.'
    ),
    (
        'CommunicationError',
        N'Спроба завершилася помилкою зв’язку. Фактичний результат операції невідомий.'
    ),
    (
        'ProviderPending',
        N'Спроба завершена. Провайдер повідомив, що фінансова операція ще обробляється.'
    );
GO

CREATE TABLE dbo.PricingPolicy
/*
    PricingPolicy

    Призначення:
        Зберігання актуальних правил до ціноутворення всередині системи.

    Семантика:
        - Існує один актуальний запис політики.
        - Початкова комісія становить 10%.
        - Комісія представлена часткою від 0 до 1.
        - Додавання та видалення записів заборонено.
        - Зміна комісії виконується через UPDATE.
        - Попередні версії автоматично зберігаються
          у PricingPolicyHistory.

    Temporal:
        validFrom і validTo описують системний період
        чинності версії запису, а не довільний
        бізнес-період дії тарифу.
*/
(
    pricingPolicyId BIGINT IDENTITY(1,1) NOT NULL,

    commissionRate DECIMAL(9,6) NOT NULL,

    validFrom DATETIME2(7)
        GENERATED ALWAYS AS ROW START NOT NULL,

    validTo DATETIME2(7)
        GENERATED ALWAYS AS ROW END NOT NULL,

    PERIOD FOR SYSTEM_TIME (validFrom, validTo),

    CONSTRAINT PK_PricingPolicy
        PRIMARY KEY (pricingPolicyId),

    CONSTRAINT CK_PricingPolicy_CommissionRate
        CHECK (commissionRate BETWEEN 0 AND 1)
)
WITH
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.PricingPolicyHistory
    )
);
GO
-- Ініціалізація єдиного запису.
INSERT INTO dbo.PricingPolicy (commissionRate)
VALUES (0.100000);
GO

CREATE TABLE dbo.UserSettings
/*
    Призначення:
        Зберігання системних налаштувань облікового
        запису користувача PassBy.

    Семантика:
        - Кожному користувачу може відповідати
          не більше одного набору налаштувань.
        - Налаштування належать конкретному UserAccount.
        - Початкова політика публікації: Manual.

        Політика не впливає на RawIntent та явно збережені Draft.
*/
(
    userId BIGINT NOT NULL,

    orderPublishingPolicy BIT NOT NULL
        CONSTRAINT DF_UserSettings_OrderPublishingPolicy
        DEFAULT (0),

    /*
        orderPublishingPolicy:
            - 0: "Manual", тобто сформований Order створюється
                у стані Private й потребує ручної публікації.
            - 1: "Automatic", тобто сформований Order автоматично
                отримує стан Published.
    */

    CONSTRAINT PK_UserSettings
        PRIMARY KEY (userId),

    CONSTRAINT FK_UserSettings_UserAccount
        FOREIGN KEY (userId)
        REFERENCES dbo.UserAccount (userId)
);
GO

CREATE TABLE dbo.DelivererIntent
/*
    Призначення:
        Представлення наміру користувача виконати
        перевезення посилки.

    Семантика:
        Намір може виникнути двома способами:

        1. Order:
           Користувач створює замовлення на перевезення.
           Початковий статус визначається сценарієм
           створення та його налаштуваннями.

        2. RawIntent:
           Намір автоматично формується під час пошуку
           протилежного Order для початку взаємодії.
           Його єдиний статус — RawIntent.

    Інваріанти:
        - Один Order = не більше однієї активної угоди одночасно.
        - Автор повинен мати роль Deliverer.
        - Винагорода та характеристики посилки
          не можуть бути від'ємними.
        - Мінімальна винагорода не перевищує максимальну.
        - Початковий статус задає відповідна процедура.
        - Прямий INSERT для backend забороняється
          окремою конфігурацією прав.

    Temporal:
        SQL Server автоматично зберігає попередні
        версії в DelivererIntentHistory.

    Фізичні домовленості:
        - Координати: GEOGRAPHY, SRID 4326.
        - NULL у характеристиках: критерій не заданий.
        - Одиниці вимірювання габаритів і ваги
          потрібно закріпити в контракті API.
*/
(
    delivererIntentId BIGINT IDENTITY(1,1) NOT NULL,

    startingCoordinates GEOGRAPHY NOT NULL,
    endCoordinates GEOGRAPHY NOT NULL,

    availableMaxWeight DECIMAL(12,3) NULL,
    availableMaxLength DECIMAL(12,3) NULL,
    availableMaxDepth DECIMAL(12,3) NULL,
    availableMaxHeight DECIMAL(12,3) NULL,

    minRewardReceived DECIMAL(18,2) NULL,
    maxRewardReceived DECIMAL(18,2) NULL,

    departureTimeAtUtc DATETIME2(7) NOT NULL,

    createdAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_DelivererIntent_CreatedAtUtc
        DEFAULT (SYSUTCDATETIME()),

    validFrom DATETIME2(7)
        GENERATED ALWAYS AS ROW START NOT NULL,

    validTo DATETIME2(7)
        GENERATED ALWAYS AS ROW END NOT NULL,

    PERIOD FOR SYSTEM_TIME (validFrom, validTo),

    orderStatusCode VARCHAR(64) NOT NULL,

    authorDelivererUserId BIGINT NOT NULL,

    CONSTRAINT PK_DelivererIntent
        PRIMARY KEY (delivererIntentId),

    CONSTRAINT FK_DelivererIntent_OrderStatus
        FOREIGN KEY (orderStatusCode)
        REFERENCES dbo.OrderStatus (orderStatusCode),

    CONSTRAINT FK_DelivererIntent_Deliverer
        FOREIGN KEY (authorDelivererUserId)
        REFERENCES dbo.Deliverer (userId),

    CONSTRAINT CK_DelivererIntent_Capacity
        CHECK (
            (availableMaxWeight IS NULL OR availableMaxWeight > 0)
            AND (availableMaxLength IS NULL OR availableMaxLength > 0)
            AND (availableMaxDepth IS NULL OR availableMaxDepth > 0)
            AND (availableMaxHeight IS NULL OR availableMaxHeight > 0)
        ),

    CONSTRAINT CK_DelivererIntent_Reward
        CHECK (
            (minRewardReceived IS NULL OR minRewardReceived >= 0)
            AND (maxRewardReceived IS NULL OR maxRewardReceived >= 0)
            AND (
                minRewardReceived IS NULL
                OR maxRewardReceived IS NULL
                OR minRewardReceived <= maxRewardReceived
            )
        )
)
WITH
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.DelivererIntentHistory
    )
);
GO

CREATE TABLE dbo.DeliveryRequesterShipment
/*
    Призначення:
        Зберігання характеристик посилки, яку
        користувач бажає передати для перевезення.

    Семантика:
        - Посилка є самостійною сутністю.
        - Для існування посилки не потрібен Order.
        - Посилка створюється користувачем вручну.
        - Посилка не має власного життєвого статусу.
        - Характеристики посилки дозволено змінювати.
        - Всі бізнес-поля обов'язкові, окрім опису.
        - Посилка може використовуватися наміром
          DeliveryRequesterIntent.

    Обмеження:
        - Назва посилки не може бути порожньою.
        - Вага та всі габарити повинні бути додатними.
        - Опис може мати значення NULL.

    Temporal:
        Попередні версії записів автоматично
        зберігаються у DeliveryRequesterShipmentHistory.

    Фізичні домовленості:
        - Вага та габарити використовують DECIMAL(12,3).
        - Одиниці вимірювання мають бути визначені
          в контракті системи.
*/
(
    deliveryRequesterShipmentId BIGINT IDENTITY(1,1) NOT NULL,
    ownerDeliveryRequesterUserId BIGINT NOT NULL,
    
    shipmentName NVARCHAR(200) NOT NULL,
    shipmentDescription NVARCHAR(2000) NULL,

    shipmentWeight DECIMAL(12,3) NOT NULL,
    shipmentLength DECIMAL(12,3) NOT NULL,
    shipmentDepth DECIMAL(12,3) NOT NULL,
    shipmentHeight DECIMAL(12,3) NOT NULL,

    validFrom DATETIME2(7)
        GENERATED ALWAYS AS ROW START NOT NULL,

    validTo DATETIME2(7)
        GENERATED ALWAYS AS ROW END NOT NULL,

    PERIOD FOR SYSTEM_TIME (validFrom, validTo),

    CONSTRAINT PK_DeliveryRequesterShipment
        PRIMARY KEY (deliveryRequesterShipmentId),

    CONSTRAINT CK_DeliveryRequesterShipment_Name
        CHECK (
            LEN(TRIM(shipmentName)) > 0
        ),

    CONSTRAINT CK_DeliveryRequesterShipment_Dimensions
        CHECK (
            shipmentWeight > 0
            AND shipmentLength > 0
            AND shipmentDepth > 0
            AND shipmentHeight > 0
        ),

    CONSTRAINT FK_DeliveryRequesterShipment_Owner
        FOREIGN KEY (ownerDeliveryRequesterUserId)
        REFERENCES dbo.DeliveryRequester (userId),

    CONSTRAINT UQ_DeliveryRequesterShipment_IdOwner
        UNIQUE
        (
            deliveryRequesterShipmentId,
            ownerDeliveryRequesterUserId
        )
)
WITH
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.DeliveryRequesterShipmentHistory
    )
);
GO

CREATE TABLE dbo.DeliveryRequesterIntent
/*
    Призначення:
        Представлення наміру замовника організувати
        перевезення належної йому посилки.

    Семантика:
        Намір може виникнути двома способами:

        1. Order:
           Користувач створює замовлення на перевезення.
           Початковий статус визначається сценарієм
           створення та політикою публікації.

        2. RawIntent:
           Намір автоматично формується під час
           пошуку протилежного Order для початку
           взаємодії.

    Інваріанти:
        - Один Order = не більше однієї активної угоди одночасно.
        - Автором є DeliveryRequester.
        - Кожен намір обов'язково містить посилання
          на існуючу посилку.
        - Посилка повинна належати автору наміру.
        - Межі ціни не можуть бути від'ємними.
        - Мінімальна ціна не перевищує максимальну.
        - RawIntent та фінальні Order незмінні
          після досягнення відповідного статусу.
        - Створення виконується через спеціалізовані
          процедури, а не прямий INSERT бекенду.

    Temporal:
        SQL Server автоматично зберігає попередні
        версії записів у DeliveryRequesterIntentHistory.

    Фізичні домовленості:
        - Координати: GEOGRAPHY, SRID 4326.
        - Ціна: DECIMAL(18,2), без комісії PassBy.
        - NULL у межах ціни означає відсутність
          відповідного обмеження.
*/
(
    deliveryRequesterIntentId BIGINT IDENTITY(1,1) NOT NULL,

    receivingCoordinates GEOGRAPHY NOT NULL,
    destinationCoordinates GEOGRAPHY NOT NULL,

    minPriceWithoutCommission DECIMAL(18,2) NULL,
    maxPriceWithoutCommission DECIMAL(18,2) NULL,

    createdAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_DeliveryRequesterIntent_CreatedAtUtc
        DEFAULT (SYSUTCDATETIME()),

    validFrom DATETIME2(7)
        GENERATED ALWAYS AS ROW START NOT NULL,

    validTo DATETIME2(7)
        GENERATED ALWAYS AS ROW END NOT NULL,

    PERIOD FOR SYSTEM_TIME (validFrom, validTo),

    orderStatusCode VARCHAR(64) NOT NULL,

    deliveryRequesterShipmentId BIGINT NOT NULL,
    authorDeliveryRequesterUserId BIGINT NOT NULL,

    CONSTRAINT PK_DeliveryRequesterIntent
        PRIMARY KEY (deliveryRequesterIntentId),

    CONSTRAINT FK_DeliveryRequesterIntent_OrderStatus
        FOREIGN KEY (orderStatusCode)
        REFERENCES dbo.OrderStatus (orderStatusCode),

    CONSTRAINT FK_DeliveryRequesterIntent_Author
        FOREIGN KEY (authorDeliveryRequesterUserId)
        REFERENCES dbo.DeliveryRequester (userId),

    CONSTRAINT FK_DeliveryRequesterIntent_OwnedShipment
        FOREIGN KEY
        (
            deliveryRequesterShipmentId,
            authorDeliveryRequesterUserId
        )
        REFERENCES dbo.DeliveryRequesterShipment
        (
            deliveryRequesterShipmentId,
            ownerDeliveryRequesterUserId
        ),

    CONSTRAINT CK_DeliveryRequesterIntent_Price
        CHECK
        (
            (
                minPriceWithoutCommission IS NULL
                OR minPriceWithoutCommission >= 0
            )
            AND
            (
                maxPriceWithoutCommission IS NULL
                OR maxPriceWithoutCommission >= 0
            )
            AND
            (
                minPriceWithoutCommission IS NULL
                OR maxPriceWithoutCommission IS NULL
                OR minPriceWithoutCommission <= maxPriceWithoutCommission
            )
        )
)
WITH
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.DeliveryRequesterIntentHistory
    )
);
GO

CREATE TABLE dbo.ChatAccessPolicy
/*
    Призначення:
        Зберігання правил доступу до чату
        залежно від стану взаємодії.

    Семантика:
        - Кожному InteractionStatus може відповідати
          одна поточна політика.
        - maxNumberMessages визначає обмеження
          кількості повідомлень.
        - NULL означає відсутність числового ліміту.
        - Історія змін політик зберігається автоматично.

    Temporal:
        Попередні версії зберігаються
        в ChatAccessPolicyHistory.

    Примітка:
        Використання історичної версії політики
        для конкретного контексту взаємодії
        буде реалізовано окремо.
*/
(
    interactionStatusCode VARCHAR(64) NOT NULL,

    maxNumberMessages INT NULL,
    policyStatusDescription NVARCHAR(500) NOT NULL,

    validFrom DATETIME2(7)
        GENERATED ALWAYS AS ROW START NOT NULL,

    validTo DATETIME2(7)
        GENERATED ALWAYS AS ROW END NOT NULL,

    PERIOD FOR SYSTEM_TIME (validFrom, validTo),

    CONSTRAINT PK_ChatAccessPolicy
        PRIMARY KEY (interactionStatusCode),

    CONSTRAINT FK_ChatAccessPolicy_InteractionStatus
        FOREIGN KEY (interactionStatusCode)
        REFERENCES dbo.InteractionStatus (interactionStatusCode),

    CONSTRAINT CK_ChatAccessPolicy_MaxMessages
        CHECK (
            maxNumberMessages IS NULL
            OR maxNumberMessages >= 0
        )
)
WITH
(
    SYSTEM_VERSIONING = ON
    (
        HISTORY_TABLE = dbo.ChatAccessPolicyHistory
    )
);
GO
INSERT INTO dbo.ChatAccessPolicy
(
    interactionStatusCode,
    maxNumberMessages,
    policyStatusDescription
)
VALUES
    ('Unilateral', 3, N'Обмежений чат: у обносторонній взаємодії чат обмежений.'),
    ('Mutual', NULL, N'Розблокований чат: при двосторонній взаємодії чат не має обмежень.'),
    ('Rejected', NULL, N'Розблокований чат: при завершеній взаємодії чат не має обмежень.');
GO

CREATE TABLE dbo.InteractionContext
(
    interactionContextId BIGINT IDENTITY(1,1) NOT NULL,

    interactionStartAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_InteractionContext_StartAtUtc
        DEFAULT (SYSUTCDATETIME()),

    delivererIntentId BIGINT NOT NULL,
    deliveryRequesterIntentId BIGINT NOT NULL,

    requestInitiatorCode VARCHAR(64) NOT NULL,

    interactionStatusCode VARCHAR(64) NOT NULL
        CONSTRAINT DF_InteractionContext_Status
        DEFAULT ('Unilateral'),

    CONSTRAINT PK_InteractionContext
        PRIMARY KEY (interactionContextId),

    CONSTRAINT FK_InteractionContext_DelivererIntent
        FOREIGN KEY (delivererIntentId)
        REFERENCES dbo.DelivererIntent (delivererIntentId),

    CONSTRAINT FK_InteractionContext_DeliveryRequesterIntent
        FOREIGN KEY (deliveryRequesterIntentId)
        REFERENCES dbo.DeliveryRequesterIntent (deliveryRequesterIntentId),

    CONSTRAINT FK_InteractionContext_RequestInitiator
        FOREIGN KEY (requestInitiatorCode)
        REFERENCES dbo.RequestInitiator (requestInitiatorCode),

    CONSTRAINT FK_InteractionContext_InteractionStatus
        FOREIGN KEY (interactionStatusCode)
        REFERENCES dbo.InteractionStatus (interactionStatusCode)
);
GO

CREATE TABLE dbo.UserMessage
/*
    Призначення:
        Зберігання текстових повідомлень
        користувачів у межах взаємодії.

    Семантика:
        - Кожне повідомлення належить
          одному InteractionContext.
        - Повідомлення має одного автора.
        - Час відправлення зберігається в UTC.

    Обмеження:
        - Перевірка участі автора у взаємодії
          буде реалізована окремо.
        - Ліміти повідомлень визначаються
          через ChatAccessPolicy.
*/
(
    userMessageId BIGINT IDENTITY(1,1) NOT NULL,

    userMessageText NVARCHAR(MAX) NOT NULL,

    sentAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_UserMessage_SentAtUtc
        DEFAULT (SYSUTCDATETIME()),

    interactionContextId BIGINT NOT NULL,
    authorUserId BIGINT NOT NULL,

    CONSTRAINT PK_UserMessage
        PRIMARY KEY (userMessageId),

    CONSTRAINT FK_UserMessage_InteractionContext
        FOREIGN KEY (interactionContextId)
        REFERENCES dbo.InteractionContext (interactionContextId),

    CONSTRAINT FK_UserMessage_Author
        FOREIGN KEY (authorUserId)
        REFERENCES dbo.UserAccount (userId)
);
GO

CREATE TABLE dbo.CollaborativeDeal
/*
    Призначення:
        Зберігання погодженої угоди про перевезення
        та поточного стану її виконання.

    Семантика:
        - Угода формується на основі InteractionContext.
        - Умови угоди фіксуються при її створенні.
        - Стан виконання визначає DealExecutionStatus.
        - Одна взаємодія може бути пов'язана
          з історією укладення угод.
        - Один Order може брати участь
          у декількох послідовних угодах.

    Обмеження:
        - Погоджена ціна не може бути від'ємною.
        - Незмінність погоджених умов та правила
          переходів виконання реалізуються окремо.
        - Одночасна участь Order у кількох активних
          угодах повинна бути заборонена окремо.

    Підтвердження:
        Два хеші секретів використовуватимуться
        для підтвердження передачі та отримання
        посилки через QR.
*/
(
    collaborativeDealId BIGINT IDENTITY(1,1) NOT NULL,

    receivingCoordinates GEOGRAPHY NOT NULL,
    destinationCoordinates GEOGRAPHY NOT NULL,

    finalPriceWithoutCommission DECIMAL(18,2) NOT NULL,

    pickupConfirmationTokenHash VARBINARY(32) NOT NULL,
    deliveryConfirmationTokenHash VARBINARY(32) NOT NULL,

    createdAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_CollaborativeDeal_CreatedAtUtc
        DEFAULT (SYSUTCDATETIME()),

    dealExecutionStatusCode VARCHAR(64) NOT NULL,

    senderUserId BIGINT NOT NULL,
    receiverUserId BIGINT NOT NULL,

    interactionContextId BIGINT NOT NULL,

    CONSTRAINT PK_CollaborativeDeal
        PRIMARY KEY (collaborativeDealId),

    CONSTRAINT FK_CollaborativeDeal_Status
        FOREIGN KEY (dealExecutionStatusCode)
        REFERENCES dbo.DealExecutionStatus (dealExecutionStatusCode),

    CONSTRAINT FK_CollaborativeDeal_Sender
        FOREIGN KEY (senderUserId)
        REFERENCES dbo.UserAccount (userId),

    CONSTRAINT FK_CollaborativeDeal_Receiver
        FOREIGN KEY (receiverUserId)
        REFERENCES dbo.UserAccount (userId),

    CONSTRAINT FK_CollaborativeDeal_InteractionContext
        FOREIGN KEY (interactionContextId)
        REFERENCES dbo.InteractionContext (interactionContextId),

    CONSTRAINT CK_CollaborativeDeal_Price
        CHECK (
            finalPriceWithoutCommission >= 0
        )
);

GO

CREATE TABLE dbo.UserPaymentMethod
/*
    Призначення:
        Зберігання платіжних методів користувачів
        для взаємодії з платіжним провайдером.

    Семантика:
        - Метод належить одному UserAccount.
        - maskedCardNumber містить лише маскований номер.
        - recToken і rec2Token представляють токени
          платіжного провайдера.
        - NULL у disabledAtUtc означає, що
          метод не позначений як вимкнений.
        - Токени можуть бути відсутніми залежно
          від можливостей платіжного провайдера.

    Безпека:
        Захист токенів та права доступу до них
        визначаються окремо.
*/
(
    paymentMethodId BIGINT IDENTITY(1,1) NOT NULL,

    maskedCardNumber VARCHAR(32) NOT NULL,
    cardType VARCHAR(40) NOT NULL,

    recToken NVARCHAR(512) NULL,
    rec2Token NVARCHAR(512) NULL,

    createdAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_UserPaymentMethod_CreatedAtUtc
        DEFAULT (SYSUTCDATETIME()),

    disabledAtUtc DATETIME2(7) NULL,

    userId BIGINT NOT NULL,

    CONSTRAINT PK_UserPaymentMethod
        PRIMARY KEY (paymentMethodId),

    CONSTRAINT FK_UserPaymentMethod_UserAccount
        FOREIGN KEY (userId)
        REFERENCES dbo.UserAccount (userId),

    CONSTRAINT CK_UserPaymentMethod_DisabledAtUtc
        CHECK (
            disabledAtUtc IS NULL
            OR disabledAtUtc >= createdAtUtc
        )
);
GO

CREATE TABLE dbo.PaymentOperationAttempt
/*
    Призначення:
        Зберігання спроб виконання платіжних операцій
        у межах CollaborativeDeal.

    Семантика:
        - Кожен запис описує одну завершену
          спробу взаємодії з провайдером.
        - Операції: AUTH, SETTLE, REFUND, P2P_CREDIT.
        - Результат спроби визначається AttemptStatus.
        - paymentMethodId може бути NULL.
        - orderReference може повторюватися
          для пов'язаних операцій провайдера.
        - CommunicationError не гарантує,
          що операція не була виконана провайдером.
        - ProviderPending означає, що провайдер
          ще не надав остаточного результату.

    Обмеження:
        - Сума операції не може бути від'ємною.
        - Спроба обов'язково пов'язана з угодою.
        - Порядок та допустимість фінансових
          операцій контролюються окремо.
*/
(
    attemptId BIGINT IDENTITY(1,1) NOT NULL,

    operationType VARCHAR(24) NOT NULL,
    amount DECIMAL(18,2) NOT NULL,
    currency CHAR(3) NOT NULL,

    orderReference NVARCHAR(100) NOT NULL,

    providerStatus VARCHAR(50) NULL,
    reasonCode INT NULL,

    createdAtUtc DATETIME2(7) NOT NULL
        CONSTRAINT DF_PaymentOperationAttempt_CreatedAtUtc
        DEFAULT (SYSUTCDATETIME()),

    attemptStatusCode VARCHAR(64) NOT NULL,

    paymentMethodId BIGINT NULL,
    collaborativeDealId BIGINT NOT NULL,

    CONSTRAINT PK_PaymentOperationAttempt
        PRIMARY KEY (attemptId),

    CONSTRAINT FK_PaymentOperationAttempt_Status
        FOREIGN KEY (attemptStatusCode)
        REFERENCES dbo.AttemptStatus (attemptStatusCode),

    CONSTRAINT FK_PaymentOperationAttempt_PaymentMethod
        FOREIGN KEY (paymentMethodId)
        REFERENCES dbo.UserPaymentMethod (paymentMethodId),

    CONSTRAINT FK_PaymentOperationAttempt_CollaborativeDeal
        FOREIGN KEY (collaborativeDealId)
        REFERENCES dbo.CollaborativeDeal (collaborativeDealId),

    CONSTRAINT CK_PaymentOperationAttempt_OperationType
        CHECK (
            operationType IN
            (
                'AUTH',
                'SETTLE',
                'REFUND',
                'P2P_CREDIT'
            )
        ),

    CONSTRAINT CK_PaymentOperationAttempt_Amount
        CHECK (
            amount >= 0
        )
);
GO

ALTER TABLE dbo.Deliverer
ADD CONSTRAINT DF_Deliverer_RegisteredAtUtc
DEFAULT (SYSUTCDATETIME())
FOR registeredAtUtc;
GO

ALTER TABLE dbo.DeliveryRequester
ADD CONSTRAINT DF_DeliveryRequester_RegisteredAtUtc
DEFAULT (SYSUTCDATETIME())
FOR registeredAtUtc;
GO

SELECT
    name AS TableName,
    create_date AS CreatedAt
FROM sys.tables
ORDER BY name;

SELECT
    OBJECT_NAME(parent_object_id) AS TableName,
    name AS ForeignKeyName,
    is_disabled,
    is_not_trusted
FROM sys.foreign_keys
WHERE is_disabled = 1
   OR is_not_trusted = 1;
GO