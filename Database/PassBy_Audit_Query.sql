/*
PassBy | Unified read-only database audit
Revision: 2026-11-25
Sources: PassBy_Audit_Query(3).sql (general audit) and (2).sql
         (effective permissions and migration verification).
Run in PassBy as dbo, or a principal with sufficient metadata visibility,
SELECT on audited objects and IMPERSONATE on passby_backend.
No persistent DDL or DML. Table variables hold audit results only.
No account records, password hashes, identity documents, or payment tokens exported.
Checks of module text are structural checks, not functional or concurrency tests.
*/
SET NOCOUNT ON;

IF DB_NAME() <> N'PassBy'
    THROW 52100, N'Incorrect target database.', 1;

IF @@TRANCOUNT <> 0
    THROW 52101, N'An active transaction already exists.', 1;


------------------------------------------------------
-- 01. DATABASE INFORMATION
------------------------------------------------------

PRINT '01. DATABASE INFORMATION';

SELECT
    SYSUTCDATETIME() AS auditCreatedAtUtc,
    @@VERSION AS serverVersion,
    DB_NAME() AS databaseName,
    USER_NAME() AS databaseUser;

SELECT
    name,
    collation_name,
    compatibility_level,
    recovery_model_desc,
    snapshot_isolation_state_desc,
    is_read_committed_snapshot_on,
    is_recursive_triggers_on,
    is_auto_create_stats_on,
    is_auto_update_stats_on
FROM sys.databases
WHERE database_id = DB_ID();


------------------------------------------------------
-- 02. DATABASE OBJECTS
------------------------------------------------------

PRINT '02. DATABASE OBJECTS';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,
    o.type_desc AS objectType,
    OBJECT_NAME(o.parent_object_id) AS parentObject,
    o.create_date,
    o.modify_date
FROM sys.objects AS o
WHERE o.is_ms_shipped = 0
ORDER BY
    o.type_desc,
    schemaName,
    objectName;


------------------------------------------------------
-- 03. OBJECT SUMMARY
------------------------------------------------------

PRINT '03. OBJECT SUMMARY';

SELECT
    type_desc AS objectType,
    COUNT(*) AS objectCount
FROM sys.objects
WHERE is_ms_shipped = 0
GROUP BY type_desc
ORDER BY type_desc;


------------------------------------------------------
-- 04. TABLES AND TEMPORAL CONFIGURATION
------------------------------------------------------

PRINT '04. TABLES AND TEMPORAL CONFIGURATION';

SELECT
    SCHEMA_NAME(t.schema_id) AS schemaName,
    t.name AS tableName,
    t.temporal_type_desc,

    OBJECT_SCHEMA_NAME(t.history_table_id)
        AS historySchema,

    OBJECT_NAME(t.history_table_id)
        AS historyTable,

    t.history_retention_period,
    t.history_retention_period_unit_desc,

    COL_NAME(t.object_id, p.start_column_id)
        AS periodStartColumn,

    COL_NAME(t.object_id, p.end_column_id)
        AS periodEndColumn

FROM sys.tables AS t

LEFT JOIN sys.periods AS p
    ON p.object_id = t.object_id

WHERE t.is_ms_shipped = 0

ORDER BY schemaName, tableName;


------------------------------------------------------
-- 05. TABLE ROW COUNTS
------------------------------------------------------

PRINT '05. TABLE ROW COUNTS';

SELECT
    SCHEMA_NAME(t.schema_id) AS schemaName,
    t.name AS tableName,
    SUM(p.rows) AS approximateRowCount
FROM sys.tables AS t
INNER JOIN sys.partitions AS p
    ON p.object_id = t.object_id
   AND p.index_id IN (0, 1)
WHERE t.is_ms_shipped = 0
GROUP BY
    t.schema_id,
    t.name
ORDER BY schemaName, tableName;


------------------------------------------------------
-- 06. TABLE AND VIEW COLUMNS
------------------------------------------------------

PRINT '06. TABLE AND VIEW COLUMNS';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,
    o.type_desc AS objectType,

    c.column_id,
    c.name AS columnName,

    TYPE_NAME(c.user_type_id) AS dataType,

    c.max_length,
    c.precision,
    c.scale,

    c.is_nullable,
    c.is_identity,

    ic.seed_value AS identitySeed,
    ic.increment_value AS identityIncrement,

    c.is_computed,
    cc.definition AS computedDefinition,
    cc.is_persisted,

    dc.name AS defaultConstraint,
    dc.definition AS defaultDefinition,

    c.generated_always_type_desc,
    c.is_hidden,
    c.collation_name

FROM sys.columns AS c

INNER JOIN sys.objects AS o
    ON o.object_id = c.object_id

LEFT JOIN sys.identity_columns AS ic
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id

LEFT JOIN sys.computed_columns AS cc
    ON cc.object_id = c.object_id
   AND cc.column_id = c.column_id

LEFT JOIN sys.default_constraints AS dc
    ON dc.object_id = c.default_object_id

WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V')

ORDER BY
    schemaName,
    objectName,
    c.column_id;


------------------------------------------------------
-- 07. PRIMARY AND UNIQUE KEYS
------------------------------------------------------

PRINT '07. PRIMARY AND UNIQUE KEYS';

SELECT
    SCHEMA_NAME(t.schema_id) AS schemaName,
    t.name AS tableName,

    kc.name AS constraintName,
    kc.type_desc AS constraintType,

    c.name AS columnName,
    ic.key_ordinal

FROM sys.key_constraints AS kc

INNER JOIN sys.tables AS t
    ON t.object_id = kc.parent_object_id

INNER JOIN sys.index_columns AS ic
    ON ic.object_id = t.object_id
   AND ic.index_id = kc.unique_index_id

INNER JOIN sys.columns AS c
    ON c.object_id = t.object_id
   AND c.column_id = ic.column_id

WHERE ic.key_ordinal > 0

ORDER BY
    schemaName,
    tableName,
    constraintName,
    ic.key_ordinal;


------------------------------------------------------
-- 08. FOREIGN KEYS
------------------------------------------------------

PRINT '08. FOREIGN KEYS';

SELECT
    fk.name AS foreignKeyName,

    OBJECT_SCHEMA_NAME(fk.parent_object_id)
        AS sourceSchema,

    OBJECT_NAME(fk.parent_object_id)
        AS sourceTable,

    COL_NAME(
        fkc.parent_object_id,
        fkc.parent_column_id
    ) AS sourceColumn,

    OBJECT_SCHEMA_NAME(fk.referenced_object_id)
        AS targetSchema,

    OBJECT_NAME(fk.referenced_object_id)
        AS targetTable,

    COL_NAME(
        fkc.referenced_object_id,
        fkc.referenced_column_id
    ) AS targetColumn,

    fkc.constraint_column_id,

    fk.delete_referential_action_desc,
    fk.update_referential_action_desc,

    fk.is_disabled,
    fk.is_not_trusted

FROM sys.foreign_keys AS fk

INNER JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id

ORDER BY
    sourceSchema,
    sourceTable,
    foreignKeyName,
    fkc.constraint_column_id;


------------------------------------------------------
-- 09. CHECK CONSTRAINTS
------------------------------------------------------

PRINT '09. CHECK CONSTRAINTS';

SELECT
    OBJECT_SCHEMA_NAME(parent_object_id)
        AS schemaName,

    OBJECT_NAME(parent_object_id)
        AS tableName,

    name AS constraintName,
    definition,
    is_disabled,
    is_not_trusted

FROM sys.check_constraints

ORDER BY schemaName, tableName, constraintName;


------------------------------------------------------
-- 10. DEFAULT CONSTRAINTS
------------------------------------------------------

PRINT '10. DEFAULT CONSTRAINTS';

SELECT
    OBJECT_SCHEMA_NAME(parent_object_id)
        AS schemaName,

    OBJECT_NAME(parent_object_id)
        AS tableName,

    COL_NAME(parent_object_id, parent_column_id)
        AS columnName,

    name AS constraintName,
    definition

FROM sys.default_constraints

ORDER BY schemaName, tableName, columnName;


------------------------------------------------------
-- 11. INDEXES
------------------------------------------------------

PRINT '11. INDEXES';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,

    i.name AS indexName,
    i.type_desc AS indexType,

    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled,

    i.has_filter,
    i.filter_definition,

    c.name AS columnName,
    ic.key_ordinal,
    ic.index_column_id,
    ic.is_descending_key,
    ic.is_included_column,

    i.fill_factor

FROM sys.indexes AS i

INNER JOIN sys.objects AS o
    ON o.object_id = i.object_id

LEFT JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id

LEFT JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id

WHERE o.is_ms_shipped = 0
  AND i.index_id > 0

ORDER BY
    schemaName,
    objectName,
    indexName,
    ic.index_column_id;


------------------------------------------------------
-- 12. PROCEDURES, VIEWS, TRIGGERS AND FUNCTIONS
------------------------------------------------------

PRINT '12. SQL MODULES';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,
    o.type_desc AS objectType,

    m.uses_ansi_nulls,
    m.uses_quoted_identifier,
    m.is_schema_bound,
    m.execute_as_principal_id,

    DATALENGTH(m.definition) AS definitionBytes

FROM sys.sql_modules AS m

INNER JOIN sys.objects AS o
    ON o.object_id = m.object_id

WHERE o.is_ms_shipped = 0

ORDER BY schemaName, objectType, objectName;


------------------------------------------------------
-- 13. FULL SQL MODULE DEFINITIONS
--
-- Definitions are split into chunks to reduce the
-- risk of truncation during export from SSMS.
-- Concatenate chunks in chunkNumber order.
------------------------------------------------------

PRINT '13. FULL SQL MODULE DEFINITIONS';

;WITH ModuleDefinitions AS
(
    SELECT
        o.object_id,

        SCHEMA_NAME(o.schema_id) AS schemaName,
        o.name AS objectName,
        o.type_desc AS objectType,

        m.definition

    FROM sys.sql_modules AS m

    INNER JOIN sys.objects AS o
        ON o.object_id = m.object_id

    WHERE o.is_ms_shipped = 0
),
DefinitionChunks AS
(
    SELECT
        object_id,
        schemaName,
        objectName,
        objectType,
        definition,

        CAST(1 AS INT) AS chunkNumber

    FROM ModuleDefinitions

    UNION ALL

    SELECT
        object_id,
        schemaName,
        objectName,
        objectType,
        definition,

        chunkNumber + 1

    FROM DefinitionChunks

    WHERE chunkNumber * 2000 < LEN(definition + N'#') - 1
)
SELECT
    schemaName,
    objectName,
    objectType,
    chunkNumber,

    SUBSTRING(
        definition,
        (chunkNumber - 1) * 2000 + 1,
        2000
    ) AS definitionChunk

FROM DefinitionChunks

ORDER BY
    schemaName,
    objectType,
    objectName,
    chunkNumber

OPTION (MAXRECURSION 0);


------------------------------------------------------
-- 14. PROCEDURE AND FUNCTION PARAMETERS
------------------------------------------------------

PRINT '14. MODULE PARAMETERS';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,

    p.parameter_id,
    p.name AS parameterName,

    TYPE_NAME(p.user_type_id) AS dataType,

    p.max_length,
    p.precision,
    p.scale,

    p.is_output,
    p.is_readonly,
    p.has_default_value,
    p.default_value

FROM sys.parameters AS p

INNER JOIN sys.objects AS o
    ON o.object_id = p.object_id

WHERE o.is_ms_shipped = 0

ORDER BY
    schemaName,
    objectName,
    p.parameter_id;


------------------------------------------------------
-- 15. TRIGGER CONFIGURATION
------------------------------------------------------

PRINT '15. TRIGGER CONFIGURATION';

SELECT
    t.name AS triggerName,
    OBJECT_SCHEMA_NAME(t.parent_id) AS parentSchema,
    OBJECT_NAME(t.parent_id) AS parentObject,

    t.is_disabled,
    t.is_instead_of_trigger,
    e.type_desc AS triggerEvent

FROM sys.triggers AS t

LEFT JOIN sys.trigger_events AS e
    ON e.object_id = t.object_id

WHERE t.is_ms_shipped = 0

ORDER BY
    triggerName,
    triggerEvent;


------------------------------------------------------
-- 16. SQL OBJECT DEPENDENCIES
------------------------------------------------------

PRINT '16. SQL OBJECT DEPENDENCIES';

SELECT
    OBJECT_SCHEMA_NAME(d.referencing_id)
        AS referencingSchema,

    OBJECT_NAME(d.referencing_id)
        AS referencingObject,

    o.type_desc AS referencingType,

    COL_NAME(d.referencing_id, d.referencing_minor_id)
        AS referencingColumn,

    d.referenced_server_name,
    d.referenced_database_name,

    COALESCE(
        d.referenced_schema_name,
        OBJECT_SCHEMA_NAME(d.referenced_id)
    ) AS referencedSchema,

    d.referenced_entity_name,

    COL_NAME(d.referenced_id, d.referenced_minor_id)
        AS referencedColumn,

    d.is_schema_bound_reference,
    d.is_caller_dependent,
    d.is_ambiguous

FROM sys.sql_expression_dependencies AS d

INNER JOIN sys.objects AS o
    ON o.object_id = d.referencing_id

WHERE o.is_ms_shipped = 0

ORDER BY
    referencingSchema,
    referencingObject,
    referencedSchema,
    d.referenced_entity_name;


------------------------------------------------------
-- 17. DATABASE PRINCIPALS
------------------------------------------------------

PRINT '17. DATABASE PRINCIPALS';

SELECT
    name AS principalName,
    type_desc,
    authentication_type_desc,
    default_schema_name
FROM sys.database_principals
WHERE type IN ('S', 'U', 'G', 'R', 'E', 'X')
  AND name NOT IN
  (
      'guest',
      'INFORMATION_SCHEMA',
      'sys'
  )
ORDER BY type_desc, principalName;


------------------------------------------------------
-- 18. DATABASE ROLE MEMBERSHIP
------------------------------------------------------

PRINT '18. DATABASE ROLE MEMBERSHIP';

SELECT
    r.name AS roleName,
    m.name AS memberName
FROM sys.database_role_members AS drm

INNER JOIN sys.database_principals AS r
    ON r.principal_id = drm.role_principal_id

INNER JOIN sys.database_principals AS m
    ON m.principal_id = drm.member_principal_id

ORDER BY roleName, memberName;


------------------------------------------------------
-- 19. EXPLICIT DATABASE PERMISSIONS
------------------------------------------------------

PRINT '19. EXPLICIT DATABASE PERMISSIONS';

SELECT
    p.name AS principalName,

    dp.state_desc,
    dp.permission_name,
    dp.class_desc,

    CASE
        WHEN dp.class = 0
            THEN DB_NAME()

        WHEN dp.class = 1
            THEN OBJECT_SCHEMA_NAME(dp.major_id)
                 + N'.'
                 + OBJECT_NAME(dp.major_id)

        WHEN dp.class = 3
            THEN SCHEMA_NAME(dp.major_id)

        ELSE CONVERT(NVARCHAR(30), dp.major_id)

    END AS targetObject,

    CASE
        WHEN dp.class = 1
            THEN COL_NAME(dp.major_id, dp.minor_id)
    END AS targetColumn

FROM sys.database_permissions AS dp

INNER JOIN sys.database_principals AS p
    ON p.principal_id = dp.grantee_principal_id

WHERE
    dp.class <> 1

    OR EXISTS
    (
        SELECT 1
        FROM sys.objects AS o
        WHERE o.object_id = dp.major_id
          AND o.is_ms_shipped = 0
    )

ORDER BY
    principalName,
    targetObject,
    dp.permission_name,
    targetColumn;


------------------------------------------------------
-- 20. OBJECT AND COLUMN DOCUMENTATION
------------------------------------------------------

PRINT '20. OBJECT AND COLUMN DOCUMENTATION';

SELECT
    SCHEMA_NAME(o.schema_id) AS schemaName,
    o.name AS objectName,
    o.type_desc AS objectType,

    COL_NAME(ep.major_id, ep.minor_id)
        AS columnName,

    ep.name AS propertyName,

    CONVERT(NVARCHAR(MAX), ep.value)
        AS description

FROM sys.extended_properties AS ep

INNER JOIN sys.objects AS o
    ON o.object_id = ep.major_id

WHERE ep.class = 1
  AND o.is_ms_shipped = 0

ORDER BY
    schemaName,
    objectName,
    ep.minor_id,
    ep.name;


------------------------------------------------------
-- 21. REFERENCE DATA
------------------------------------------------------

PRINT '21.1. ORDER STATUS';
SELECT * FROM dbo.OrderStatus;

PRINT '21.2. INTERACTION STATUS';
SELECT * FROM dbo.InteractionStatus;

PRINT '21.3. DEAL EXECUTION STATUS';
SELECT * FROM dbo.DealExecutionStatus;

PRINT '21.4. REQUEST INITIATOR';
SELECT * FROM dbo.RequestInitiator;

PRINT '21.5. PAYMENT ATTEMPT STATUS';
SELECT * FROM dbo.AttemptStatus;

PRINT '21.6. CHAT ACCESS POLICY';
SELECT * FROM dbo.ChatAccessPolicy;

PRINT '21.7. PRICING POLICY';
SELECT * FROM dbo.PricingPolicy;

PRINT '21.8. VERIFICATION OUTCOME';
SELECT * FROM dbo.VerificationOutcome;


------------------------------------------------------
-- 22. DATABASE INTEGRITY SUMMARY
------------------------------------------------------

PRINT '22. DATABASE INTEGRITY SUMMARY';

SELECT

    (
        SELECT COUNT(*)
        FROM sys.tables
        WHERE is_ms_shipped = 0
          AND temporal_type <> 1
    ) AS primaryTables,

    (
        SELECT COUNT(*)
        FROM sys.tables
        WHERE temporal_type = 1
    ) AS historyTables,

    (
        SELECT COUNT(*)
        FROM sys.procedures
        WHERE is_ms_shipped = 0
    ) AS storedProcedures,

    (
        SELECT COUNT(*)
        FROM sys.views
        WHERE is_ms_shipped = 0
    ) AS views,

    (
        SELECT COUNT(*)
        FROM sys.triggers
        WHERE is_ms_shipped = 0
    ) AS triggers,

    (
        SELECT COUNT(*)
        FROM sys.foreign_keys
    ) AS foreignKeys,

    (
        SELECT COUNT(*)
        FROM sys.foreign_keys
        WHERE is_disabled = 1
           OR is_not_trusted = 1
    ) AS problematicForeignKeys,

    (
        SELECT COUNT(*)
        FROM sys.check_constraints
        WHERE is_disabled = 1
           OR is_not_trusted = 1
    ) AS problematicCheckConstraints,

    (
        SELECT COUNT(*)
        FROM sys.triggers
        WHERE is_ms_shipped = 0
          AND is_disabled = 1
    ) AS disabledTriggers,

    (
        SELECT COUNT(*)
        FROM sys.sql_modules AS m
        INNER JOIN sys.objects AS o
            ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0
          AND m.definition IS NULL
    ) AS unavailableModuleDefinitions;


------------------------------------------------------
-- 23. EFFECTIVE KEY PERMISSIONS
------------------------------------------------------


PRINT '23. EFFECTIVE KEY PERMISSIONS';

DECLARE @Keys TABLE
(
    schemaName SYSNAME,
    tableName SYSNAME,
    columnName SYSNAME,
    keyType VARCHAR(2),
    constraintName SYSNAME,
    referencedTable NVARCHAR(257) NULL,
    referencedColumn SYSNAME NULL,
    isIdentity BIT
);

--------------------------------------------------
-- 1. Primary Keys
--------------------------------------------------

INSERT INTO @Keys

SELECT
    s.name,
    t.name,
    c.name,
    'PK',
    k.name,
    NULL,
    NULL,
    c.is_identity
FROM sys.key_constraints AS k
INNER JOIN sys.tables AS t
    ON t.object_id = k.parent_object_id
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
INNER JOIN sys.index_columns AS ic
    ON ic.object_id = t.object_id
   AND ic.index_id = k.unique_index_id
   AND ic.key_ordinal > 0
INNER JOIN sys.columns AS c
    ON c.object_id = t.object_id
   AND c.column_id = ic.column_id
WHERE k.type = 'PK'
  AND t.is_ms_shipped = 0;

--------------------------------------------------
-- 2. Foreign Keys
--------------------------------------------------

INSERT INTO @Keys

SELECT
    s.name,
    t.name,
    c.name,
    'FK',
    fk.name,
    rs.name + N'.' + rt.name,
    rc.name,
    c.is_identity
FROM sys.foreign_keys AS fk
INNER JOIN sys.foreign_key_columns AS fkc
    ON fkc.constraint_object_id = fk.object_id
INNER JOIN sys.tables AS t
    ON t.object_id = fkc.parent_object_id
INNER JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
INNER JOIN sys.columns AS c
    ON c.object_id = t.object_id
   AND c.column_id = fkc.parent_column_id
INNER JOIN sys.tables AS rt
    ON rt.object_id = fkc.referenced_object_id
INNER JOIN sys.schemas AS rs
    ON rs.schema_id = rt.schema_id
INNER JOIN sys.columns AS rc
    ON rc.object_id = rt.object_id
   AND rc.column_id = fkc.referenced_column_id
WHERE t.is_ms_shipped = 0;

--------------------------------------------------
-- 3. Effective backend permissions
--------------------------------------------------

DECLARE @KeyPermissions TABLE
(
    schemaName SYSNAME,
    tableName SYSNAME,
    columnName SYSNAME,
    keyType VARCHAR(2),
    constraintName SYSNAME,
    referencedTable NVARCHAR(257) NULL,
    referencedColumn SYSNAME NULL,
    isIdentity BIT,
    canBackendUpdate INT NULL
);

EXECUTE AS USER = 'passby_backend';

BEGIN TRY

    INSERT INTO @KeyPermissions
    SELECT
        schemaName,
        tableName,
        columnName,
        keyType,
        constraintName,
        referencedTable,
        referencedColumn,
        isIdentity,

        HAS_PERMS_BY_NAME
        (
            QUOTENAME(schemaName) + N'.' +
            QUOTENAME(tableName),
            'OBJECT',
            'UPDATE',
            columnName,
            'COLUMN'
        ) AS canBackendUpdate

    FROM @Keys;

    REVERT;

END TRY
BEGIN CATCH

    REVERT;
    THROW;

END CATCH;

SELECT *
FROM @KeyPermissions
ORDER BY schemaName, tableName, keyType DESC, columnName, constraintName;

-- Counts are distinct columns; a column may participate in multiple keys.
-- NULL means unresolved metadata/permissions, never a successful denial.
;WITH KeyColumns AS
(
    SELECT schemaName, tableName, columnName,
           MAX(CASE WHEN canBackendUpdate = 1 THEN 1 ELSE 0 END) AS isWritable,
           MAX(CASE WHEN canBackendUpdate IS NULL THEN 1 ELSE 0 END) AS isUnknown
    FROM @KeyPermissions
    GROUP BY schemaName, tableName, columnName
)
SELECT COUNT(*) AS distinctKeyColumns,
       COUNT(CASE WHEN isWritable = 1 THEN 1 END) AS writableKeyColumns,
       COUNT(CASE WHEN isUnknown = 1 THEN 1 END) AS unknownKeyColumns,
       CASE WHEN COUNT(*) > 0
                 AND MAX(isWritable) = 0 AND MAX(isUnknown) = 0
            THEN 'PASS' ELSE 'FAIL' END AS keyProtectionCheck
FROM KeyColumns;


------------------------------------------------------
-- 24. ORDER LIFECYCLE AND USER SETTINGS CHECKS
------------------------------------------------------


PRINT '24. ORDER LIFECYCLE AND USER SETTINGS CHECKS';

SELECT
    OBJECT_NAME(p.major_id) AS objectName,
    COL_NAME(p.major_id, p.minor_id) AS columnName,
    p.permission_name,
    p.state_desc
FROM sys.database_permissions AS p
WHERE p.grantee_principal_id =
      DATABASE_PRINCIPAL_ID('passby_backend')
  AND p.class = 1
  AND p.major_id IN
  (
      OBJECT_ID('dbo.DelivererIntent'),
      OBJECT_ID('dbo.DeliveryRequesterIntent'),
      OBJECT_ID('dbo.DelivererIntentHistory'),
      OBJECT_ID('dbo.DeliveryRequesterIntentHistory')
  )
ORDER BY objectName, columnName, permission_name;

SELECT
    name,
    modify_date,
    is_disabled,
    CASE
        WHEN is_disabled = 0
         AND OBJECT_DEFINITION(object_id)
             LIKE '%Cancelled%'
        THEN 'OK'
        ELSE 'MISSING'
    END AS cancelledProtection
FROM sys.triggers
WHERE object_id IN
(
    OBJECT_ID(N'dbo.TR_DelivererIntent_ImmutableFinalStates'),
    OBJECT_ID(N'dbo.TR_DeliveryRequesterIntent_ImmutableFinalStates')
);

DECLARE @Definition NVARCHAR(MAX) =
    OBJECT_DEFINITION(
        OBJECT_ID('dbo.CreateCollaborativeDeal')
    );

SELECT
    CASE
        WHEN @Definition IS NOT NULL
        THEN 'PASS' ELSE 'FAIL'
    END AS procedureExists,

    CASE
        WHEN CHARINDEX(
            N'@DStatus NOT IN (''Private'', ''Published'')',
            @Definition
        ) > 0
        THEN 'PASS' ELSE 'FAIL'
    END AS delivererStatusCheck,

    CASE
        WHEN CHARINDEX(
            N'@RStatus NOT IN (''Private'', ''Published'')',
            @Definition
        ) > 0
        THEN 'PASS' ELSE 'FAIL'
    END AS requesterStatusCheck,

    CASE
        WHEN CHARINDEX(
            N'@DStatus <> ''Published''',
            @Definition
        ) = 0
        AND CHARINDEX(
            N'@RStatus <> ''Published''',
            @Definition
        ) = 0
        THEN 'PASS' ELSE 'FAIL'
    END AS oldRestrictionsRemoved;

SELECT
    name,
    modify_date
FROM sys.procedures
WHERE object_id =
    OBJECT_ID('dbo.CreateCollaborativeDeal');

SELECT
    name,
    create_date,
    modify_date
FROM sys.procedures
WHERE object_id =
    OBJECT_ID('dbo.CloseInteractionContext');

SELECT
    name,
    modify_date,

    CASE
        WHEN OBJECT_DEFINITION(object_id)
             LIKE '%UPDLOCK%'
         AND OBJECT_DEFINITION(object_id)
             LIKE '%PK_DelivererIntent%'
         AND OBJECT_DEFINITION(object_id)
             LIKE '%PK_DeliveryRequesterIntent%'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS intentLockProtection

FROM sys.procedures
WHERE object_id =
    OBJECT_ID('dbo.CompleteCollaborativeDeal');


SELECT
    name,
    modify_date,
    is_disabled,

    CASE
        WHEN is_disabled = 0
         AND OBJECT_DEFINITION(object_id)
             LIKE '%READCOMMITTEDLOCK%'
         AND OBJECT_DEFINITION(object_id)
             LIKE '%Cancelled%'
         AND OBJECT_DEFINITION(object_id)
             LIKE '%Fulfilled%'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS immutabilityProtection

FROM sys.triggers
WHERE object_id IN
(
    OBJECT_ID(N'dbo.TR_DelivererIntent_ImmutableFinalStates'),
    OBJECT_ID(N'dbo.TR_DeliveryRequesterIntent_ImmutableFinalStates')
);

SELECT COUNT_BIG(*) AS accountsWithoutSettings
FROM dbo.UserAccount u WHERE NOT EXISTS (SELECT 1 FROM dbo.UserSettings s WHERE s.userId=u.userId);
SELECT name,is_disabled,CASE WHEN is_disabled = 0 AND OBJECT_DEFINITION(object_id) LIKE '%INSERT INTO dbo.UserSettings%' THEN 'PASS' ELSE 'FAIL' END AS settingsTrigger
FROM sys.triggers WHERE object_id=OBJECT_ID(N'dbo.TR_UserAccount_CreateUserSettings');


-- Missing objects must be visible, rather than silently yielding no rows.
SELECT v.objectName,
       CASE WHEN OBJECT_ID(v.objectName, v.objectType) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS objectExists
FROM (VALUES
    (N'dbo.SetDelivererOrderStatus', 'P'),
    (N'dbo.SetDeliveryRequesterOrderStatus', 'P'),
    (N'dbo.CloseInteractionContext', 'P'),
    (N'dbo.CreateCollaborativeDeal', 'P'),
    (N'dbo.CompleteCollaborativeDeal', 'P'),
    (N'dbo.TR_DelivererIntent_ImmutableFinalStates', 'TR'),
    (N'dbo.TR_DeliveryRequesterIntent_ImmutableFinalStates', 'TR'),
    (N'dbo.TR_UserAccount_CreateUserSettings', 'TR')
) AS v(objectName, objectType);


------------------------------------------------------
-- 25. EFFECTIVE SETTINGS AND PROCEDURE RIGHTS
------------------------------------------------------


PRINT '25. EFFECTIVE SETTINGS AND PROCEDURE RIGHTS';

EXECUTE AS USER = 'passby_backend';
BEGIN TRY
    SELECT HAS_PERMS_BY_NAME('dbo.UserSettings','OBJECT','SELECT') AS canSelect,
           HAS_PERMS_BY_NAME('dbo.UserSettings','OBJECT','INSERT') AS canInsert,
           HAS_PERMS_BY_NAME('dbo.UserSettings','OBJECT','DELETE') AS canDelete,
           HAS_PERMS_BY_NAME('dbo.UserSettings','OBJECT','UPDATE','userId','COLUMN') AS canUpdateUserId,
           HAS_PERMS_BY_NAME('dbo.UserSettings','OBJECT','UPDATE','orderPublishingPolicy','COLUMN') AS canUpdatePublishingPolicy,
           HAS_PERMS_BY_NAME('dbo.PasswordCredential','OBJECT','UPDATE','passwordHash','COLUMN') AS canUpdatePasswordHash;
    SELECT v.objectName,HAS_PERMS_BY_NAME(v.objectName,'OBJECT','EXECUTE') AS canExecute
    FROM (VALUES ('dbo.SetDelivererOrderStatus'),('dbo.SetDeliveryRequesterOrderStatus'),
                 ('dbo.CloseInteractionContext'),('dbo.CreateCollaborativeDeal'),
                 ('dbo.CompleteCollaborativeDeal'),('dbo.AcquireInteractionIntentLocks')) v(objectName);
    REVERT;
END TRY
BEGIN CATCH
    REVERT;
    THROW;
END CATCH;


------------------------------------------------------
-- 26. KNOWN IMPLEMENTATION LIMITATIONS
------------------------------------------------------

PRINT '26. KNOWN IMPLEMENTATION LIMITATIONS';

SELECT *
FROM
(
    VALUES

    (
        N'PAYOUT_METHOD',
        N'The courier selects an existing payment method
        during delivery confirmation. CollaborativeDeal
        does not persist this selection separately.'
    ),

    (
        N'P2P_CREDIT',
        N'CreatePaymentOperationAttempt currently validates
        payment method ownership against the requester,
        even for P2P_CREDIT. Courier payment methods
        require adaptation of this validation.'
    ),

    (
        N'PAYMENT_SEQUENCE',
        N'Payment operation sequencing and provider results
        are not enforced by database transition procedures.'
    ),

    (
        N'CONFIRMATION_TOKENS',
        N'Token generation, encryption, decryption and
        validation are backend responsibilities.'
    ),

    (
        N'EXECUTION_AUTHORIZATION',
        N'Execution transition procedures accept only
        CollaborativeDealId. Caller authorization and
        verification of business prerequisites are
        backend responsibilities.'
    ),

    (
        N'AGREED_DEAL_FAILURE',
        N'Failure of an already agreed deal is not
        implemented. FailCollaborativeDeal supports Draft.'
    ),

    (
        N'CHAT_READ_ACCESS',
        N'SendUserMessage enforces message creation access.
        Backend must separately enforce chat read access.'
    ),

    (
        N'DEAL_PARTICIPANTS',
        N'The requester being the sender or receiver is
        assumed by the chat participant calculation.
        This invariant is not fully enforced during
        draft creation and editing.'
    ),

    (
        N'TEMPORAL_PERMISSIONS',
        N'HAS_PERMS_BY_NAME returned INSERT = 1 for
        CollaborativeDealHistory despite explicit DENY.
        Direct INSERT was experimentally rejected
        by SQL Server error 13559.'
    ),

    (
        N'TEST_COVERAGE',
        N'Historical results: 17 lifecycle checks passed on 2026-11-24.
        On 2026-11-25, 45 main Order/interaction/deal checks,
        4 additional rollback checks and 3 UserSettings checks passed
        in the original separate scripts. All test data was rolled back.
        Consolidated migration and smoke tests have not been executed.
        Concurrent testing is deferred; backend integration is unverified.
        This audit does not execute smoke tests.'
    )

) AS limitations
(
    limitationCode,
    description
);


------------------------------------------------------
-- 27. AUDIT COMPLETION
------------------------------------------------------

PRINT '27. AUDIT COMPLETION';

SELECT
    N'DATABASE AUDIT COMPLETED' AS result,
    DB_NAME() AS databaseName,
    SYSUTCDATETIME() AS completedAtUtc;
