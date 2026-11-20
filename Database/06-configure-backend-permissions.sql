USE [PassBy]
GO

IF EXISTS (
    SELECT 1
    FROM sys.database_principals
    WHERE name = N'passby_backend'
)
BEGIN
    /*
        Забороняємо пряме створення намірів
        і контекстів взаємодії.
    */

    DENY INSERT
    ON OBJECT::dbo.DelivererIntent
    TO [passby_backend];
    
    DENY INSERT
    ON OBJECT::dbo.DeliveryRequesterIntent
    TO [passby_backend];
    
    DENY INSERT
    ON OBJECT::dbo.InteractionContext
    TO [passby_backend];
    
    /*
        Надаємо доступ лише до контрольованих
        сценаріїв створення.
    */
    
    GRANT EXECUTE
    ON OBJECT::dbo.CreateDelivererOrder
    TO [passby_backend];
    
    GRANT EXECUTE
    ON OBJECT::dbo.CreateDeliveryRequesterOrder
    TO [passby_backend];
    
    GRANT EXECUTE
    ON OBJECT::dbo.CreateInteractionContext
    TO [passby_backend];

    /*
        Довідкові таблиці.

        Backend не може:
            - додавати нові значення;
            - змінювати існуючі значення;
            - видаляти значення.

        SELECT не обмежується.
    */

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.OrderStatus
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.InteractionStatus
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.RequestInitiator
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.DealExecutionStatus
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.AttemptStatus
    TO [passby_backend];

    /*
        Системні політики.

        Зміна дозволяється через адміністративний
        доступ або спеціалізовані процедури.
    */

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.ChatAccessPolicy
    TO [passby_backend];

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.PricingPolicy
    TO [passby_backend];

    /*
        CollaborativeDeal.

        Угоди є незмінними, окрім статусу – його може змінювати логіка Backend-у.
        Угоду можна створити виключно за визначеною процедурою.
    */

    DENY INSERT, DELETE
    ON OBJECT::dbo.CollaborativeDeal
    TO [passby_backend];

    DENY UPDATE
    (
        receivingCoordinates,
        destinationCoordinates,
        finalPriceWithoutCommission,
        pickupConfirmationTokenHash,
        deliveryConfirmationTokenHash,
        createdAtUtc,
        senderUserId,
        receiverUserId,
        interactionContextId
    )
    ON OBJECT::dbo.CollaborativeDeal
    TO [passby_backend];

    /*
        Backend самостійно керує
        життєвим циклом виконання.
    */

    GRANT UPDATE (dealExecutionStatusCode)
    ON OBJECT::dbo.CollaborativeDeal
    TO [passby_backend];

    /*
        Створення лише через процедуру.
    */

    GRANT EXECUTE
    ON OBJECT::dbo.CreateCollaborativeDeal
    TO [passby_backend];

    -- Права для спроби оплати

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.PaymentOperationAttempt
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.CreatePaymentOperationAttempt
    TO [passby_backend];

    /*
        Заборона прямого оновлення
        InteractionContext.
    */

    DENY UPDATE
    ON OBJECT::dbo.InteractionContext
    TO [passby_backend];

    /*
        Дозволені контрольовані сценарії.
    */

    GRANT EXECUTE
    ON OBJECT::dbo.AcceptInteractionContext
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.RejectInteractionContext
    TO [passby_backend];

    -- Дозволи UserMessage

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.UserMessage
    TO [passby_backend];

    GRANT EXECUTE
    ON OBJECT::dbo.SendUserMessage
    TO [passby_backend];

    -- Тільки читання довідника.

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.VerificationOutcome
    TO [passby_backend];

    GRANT SELECT
    ON OBJECT::dbo.VerificationOutcome
    TO [passby_backend];

    -- Тільки читання результатів верифікації.

    DENY INSERT, UPDATE, DELETE
    ON OBJECT::dbo.IdentityVerification
    TO [passby_backend];

    GRANT SELECT
    ON OBJECT::dbo.IdentityVerification
    TO [passby_backend];
END
ELSE
BEGIN
    PRINT N'Користувач passby_backend не знайдений.';
END;
GO

WITH RelevantPrincipals AS
(
    SELECT principal_id, name
    FROM sys.database_principals
    WHERE name IN (N'passby_backend', N'public')

    UNION ALL

    SELECT
        rolePrincipal.principal_id,
        rolePrincipal.name
    FROM sys.database_role_members AS rm
    INNER JOIN RelevantPrincipals AS memberPrincipal
        ON rm.member_principal_id = memberPrincipal.principal_id
    INNER JOIN sys.database_principals AS rolePrincipal
        ON rolePrincipal.principal_id = rm.role_principal_id
)
SELECT DISTINCT
    rp.name AS principalName,

    CASE o.type
        WHEN 'U' THEN 'TABLE'
        WHEN 'V' THEN 'VIEW'
        WHEN 'P' THEN 'PROCEDURE'
        WHEN 'TR' THEN 'TRIGGER'
        ELSE o.type_desc
    END AS objectType,

    OBJECT_SCHEMA_NAME(o.object_id)
        + '.' + o.name AS objectName,

    CASE
        WHEN p.minor_id > 0
        THEN COL_NAME(p.major_id, p.minor_id)
        ELSE NULL
    END AS columnName,

    p.permission_name AS permissionName,
    p.state_desc AS permissionState

FROM sys.database_permissions AS p

INNER JOIN RelevantPrincipals AS rp
    ON rp.principal_id = p.grantee_principal_id

INNER JOIN sys.objects AS o
    ON o.object_id = p.major_id

WHERE
    p.class = 1
    AND o.is_ms_shipped = 0
    AND o.type IN ('U', 'V', 'P', 'TR')

ORDER BY
    objectType,
    objectName,
    columnName,
    principalName,
    permissionName

OPTION (MAXRECURSION 100);
GO

SELECT
    SCHEMA_NAME(schema_id) AS schemaName,
    name AS objectName,
    type AS objectType
INTO #AuditObjects
FROM sys.objects
WHERE type IN ('U', 'V', 'P')
  AND is_ms_shipped = 0;

BEGIN TRY
    EXECUTE AS USER = 'passby_backend';

    SELECT
        CASE a.objectType
            WHEN 'U' THEN 'TABLE'
            WHEN 'V' THEN 'VIEW'
            WHEN 'P' THEN 'PROCEDURE'
        END AS objectType,

        a.schemaName + '.' + a.objectName AS objectName,

        perm.permissionName,

        HAS_PERMS_BY_NAME(
            QUOTENAME(a.schemaName) + '.' +
            QUOTENAME(a.objectName),
            'OBJECT',
            perm.permissionName
        ) AS hasPermission

    FROM #AuditObjects AS a

    CROSS APPLY
    (
        VALUES
            ('SELECT'),
            ('INSERT'),
            ('UPDATE'),
            ('DELETE'),
            ('EXECUTE'),
            ('ALTER'),
            ('CONTROL')
    ) AS perm(permissionName)

    WHERE
        (
            a.objectType IN ('U', 'V')
            AND perm.permissionName IN
            (
                'SELECT',
                'INSERT',
                'UPDATE',
                'DELETE',
                'ALTER',
                'CONTROL'
            )
        )
        OR
        (
            a.objectType = 'P'
            AND perm.permissionName IN
            (
                'EXECUTE',
                'ALTER',
                'CONTROL'
            )
        )

    ORDER BY
        objectType,
        objectName,
        perm.permissionName;

    REVERT;
END TRY
BEGIN CATCH
    IF USER_NAME() = 'passby_backend'
        REVERT;

    THROW;
END CATCH;

DROP TABLE #AuditObjects;
GO
