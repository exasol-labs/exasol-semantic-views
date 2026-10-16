local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local scalar_rows = query(sql_text, params or {})
    if scalar_rows == nil or #scalar_rows == 0 then return nil end
    return scalar_rows[1][1]
end
local function direct_column(expression, source_alias)
    if expression == nil or expression == null then return nil end
    local text = tostring(expression):match("^%s*(.-)%s*$")
    local alias, column = string.match(text,
        "^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)$")
    if alias ~= nil and string.upper(alias) == string.upper(tostring(source_alias)) then
        return string.upper(column)
    end
    alias, column = string.match(text,
        '^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*"([^"]+)"$')
    if alias ~= nil and string.upper(alias) == string.upper(tostring(source_alias)) then
        return column
    end
    return nil
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID,
           er.REPRESENTATION_ID, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
           er.SOURCE_ALIAS, e.SOURCE_ALIAS AS ENTITY_SOURCE_ALIAS,
           er.REPRESENTATION_ROLE, er.VALID_FROM, er.VALID_TO,
           er.COVERAGE_PREDICATE
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
    representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_045: active representation not found: " .. representation_name)
end
local row = rows[1]
local model_id = row_value(row, "MODEL_ID", 1)
local version_id = row_value(row, "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(row, "ENTITY_ID", 3)
local representation_id = row_value(row, "REPRESENTATION_ID", 4)
local source_schema = row_value(row, "SOURCE_SCHEMA", 5)
local source_object = row_value(row, "SOURCE_OBJECT", 6)
local source_alias = row_value(row, "SOURCE_ALIAS", 7)
local entity_source_alias = row_value(row, "ENTITY_SOURCE_ALIAS", 8)
if string.upper(tostring(source_alias)) ~= string.upper(tostring(entity_source_alias)) then
    error("SEMANTIC_ADMIN_048: representation alias does not match the entity alias: "
        .. tostring(entity_source_alias))
end
local previous_rows = query([[
    SELECT REPRESENTATION_ID, REPRESENTATION_NAME, SOURCE_SCHEMA,
           SOURCE_OBJECT, SOURCE_ALIAS
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND REPRESENTATION_ROLE = 'PRIMARY'
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id})
local previous_representation_id = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "REPRESENTATION_ID", 1) or nil
local previous_name = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "REPRESENTATION_NAME", 2) or null
local previous_source_schema = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "SOURCE_SCHEMA", 3) or nil
local previous_source_object = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "SOURCE_OBJECT", 4) or nil
local previous_source_alias = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "SOURCE_ALIAS", 5) or nil
local changed = tostring(row_value(row, "REPRESENTATION_ROLE", 9)) ~= "PRIMARY"

if changed then
    -- Promotion changes which representation anchors canonical keys. Reject a
    -- target that can only be valid as an alternate before mutating roles.
    local key_columns = query([[
        SELECT DISTINCT ukc.COLUMN_NAME
        FROM SYS_SEMANTIC.UNIQUE_KEYS uk
        JOIN SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
          ON ukc.UNIQUE_KEY_ID = uk.UNIQUE_KEY_ID
        WHERE uk.ENTITY_ID = :entity_id
          AND uk.STATUS = 'ACTIVE'
          AND ukc.COLUMN_NAME IS NOT NULL
          AND ukc.EXPRESSION IS NULL
        ORDER BY ukc.COLUMN_NAME
    ]], {entity_id = entity_id})
    for _, key_row in ipairs(key_columns or {}) do
        local key_column = row_value(key_row, "COLUMN_NAME", 1)
        local column_count = scalar([[
            SELECT COUNT(*)
            FROM SYS.EXA_ALL_COLUMNS
            WHERE (COLUMN_SCHEMA = :source_schema OR COLUMN_SCHEMA = UPPER(:source_schema))
              AND (COLUMN_TABLE = :source_object OR COLUMN_TABLE = UPPER(:source_object))
              AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
        ]], {source_schema = source_schema, source_object = source_object,
            column_name = key_column})
        if tonumber(column_count or 0) == 0 then
            error("SEMANTIC_ADMIN_058: promotion rejected; target representation '"
                .. representation_name .. "' cannot anchor declared unique-key column "
                .. tostring(key_column) .. ". Normalize the source to expose the canonical "
                .. "column or keep it as an alternate representation.")
        end
    end

    local anchored_identity_rows = query([[
        SELECT DISTINCT ukc.COLUMN_NAME, ib.BINDING_KIND, ib.SOURCE_EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEYS uk
        JOIN SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
          ON ukc.UNIQUE_KEY_ID = uk.UNIQUE_KEY_ID
        JOIN SYS_SEMANTIC.RELATIONSHIPS r
          ON r.MODEL_ID = uk.MODEL_ID AND r.VERSION_ID = uk.VERSION_ID
         AND (r.FROM_ENTITY_ID = uk.ENTITY_ID OR r.TO_ENTITY_ID = uk.ENTITY_ID)
         AND r.STATUS = 'ACTIVE'
        JOIN SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
          ON rkm.RELATIONSHIP_ID = r.RELATIONSHIP_ID
         AND ((r.FROM_ENTITY_ID = uk.ENTITY_ID
               AND rkm.FROM_COLUMN_NAME = ukc.COLUMN_NAME)
           OR (r.TO_ENTITY_ID = uk.ENTITY_ID
               AND rkm.TO_COLUMN_NAME = ukc.COLUMN_NAME))
        JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
          ON si.ENTITY_ID = uk.ENTITY_ID AND si.STATUS = 'ACTIVE'
        LEFT JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
          ON ib.IDENTITY_ID = si.IDENTITY_ID
         AND ib.REPRESENTATION_ID = :representation_id
         AND ib.STATUS = 'ACTIVE'
        WHERE uk.ENTITY_ID = :entity_id
          AND uk.STATUS = 'ACTIVE'
          AND ukc.COLUMN_NAME IS NOT NULL
          AND ukc.EXPRESSION IS NULL
          AND 1 = (SELECT COUNT(*)
                   FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS scalar_key
                   WHERE scalar_key.UNIQUE_KEY_ID = uk.UNIQUE_KEY_ID)
    ]], {entity_id = entity_id, representation_id = representation_id})
    for _, identity_row in ipairs(anchored_identity_rows or {}) do
        local key_column = row_value(identity_row, "COLUMN_NAME", 1)
        local binding_kind = row_value(identity_row, "BINDING_KIND", 2)
        local binding_expression = row_value(identity_row, "SOURCE_EXPRESSION", 3)
        local bound_column = direct_column(binding_expression, source_alias)
        if tostring(binding_kind) ~= "DIRECT"
            or bound_column == nil
            or tostring(bound_column) ~= tostring(key_column) then
            error("SEMANTIC_ADMIN_058: promotion rejected; target representation '"
                .. representation_name .. "' does not anchor relationship key "
                .. tostring(key_column) .. " with a bare DIRECT identity binding. "
                .. "Keep it as an alternate or bind the canonical key directly.")
        end
    end

    -- A stale clean run is recovery evidence only when the current primary is
    -- itself trapped by one of the prospective checks above. Unrelated stale
    -- validation history must not authorize a new promotion.
    local recovery_from_invalid_primary = false
    for _, key_row in ipairs(key_columns or {}) do
        local key_column = row_value(key_row, "COLUMN_NAME", 1)
        local column_count = scalar([[
            SELECT COUNT(*)
            FROM SYS.EXA_ALL_COLUMNS
            WHERE (COLUMN_SCHEMA = :source_schema OR COLUMN_SCHEMA = UPPER(:source_schema))
              AND (COLUMN_TABLE = :source_object OR COLUMN_TABLE = UPPER(:source_object))
              AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
        ]], {source_schema = previous_source_schema,
            source_object = previous_source_object, column_name = key_column})
        if tonumber(column_count or 0) == 0 then
            recovery_from_invalid_primary = true
        end
    end
    local previous_identity_rows = query([[
        SELECT DISTINCT ukc.COLUMN_NAME, ib.BINDING_KIND, ib.SOURCE_EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEYS uk
        JOIN SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
          ON ukc.UNIQUE_KEY_ID = uk.UNIQUE_KEY_ID
        JOIN SYS_SEMANTIC.RELATIONSHIPS r
          ON r.MODEL_ID = uk.MODEL_ID AND r.VERSION_ID = uk.VERSION_ID
         AND (r.FROM_ENTITY_ID = uk.ENTITY_ID OR r.TO_ENTITY_ID = uk.ENTITY_ID)
         AND r.STATUS = 'ACTIVE'
        JOIN SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
          ON rkm.RELATIONSHIP_ID = r.RELATIONSHIP_ID
         AND ((r.FROM_ENTITY_ID = uk.ENTITY_ID
               AND rkm.FROM_COLUMN_NAME = ukc.COLUMN_NAME)
           OR (r.TO_ENTITY_ID = uk.ENTITY_ID
               AND rkm.TO_COLUMN_NAME = ukc.COLUMN_NAME))
        JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
          ON si.ENTITY_ID = uk.ENTITY_ID AND si.STATUS = 'ACTIVE'
        LEFT JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
          ON ib.IDENTITY_ID = si.IDENTITY_ID
         AND ib.REPRESENTATION_ID = :representation_id
         AND ib.STATUS = 'ACTIVE'
        WHERE uk.ENTITY_ID = :entity_id
          AND uk.STATUS = 'ACTIVE'
          AND ukc.COLUMN_NAME IS NOT NULL
          AND ukc.EXPRESSION IS NULL
          AND 1 = (SELECT COUNT(*)
                   FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS scalar_key
                   WHERE scalar_key.UNIQUE_KEY_ID = uk.UNIQUE_KEY_ID)
    ]], {entity_id = entity_id,
        representation_id = previous_representation_id})
    for _, identity_row in ipairs(previous_identity_rows or {}) do
        local key_column = row_value(identity_row, "COLUMN_NAME", 1)
        local binding_kind = row_value(identity_row, "BINDING_KIND", 2)
        local binding_expression = row_value(identity_row, "SOURCE_EXPRESSION", 3)
        local bound_column = direct_column(binding_expression,
            previous_source_alias)
        if tostring(binding_kind) ~= "DIRECT"
            or bound_column == nil
            or tostring(bound_column) ~= tostring(key_column) then
            recovery_from_invalid_primary = true
        end
    end

    local stale_default_count = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
        WHERE defaults.ENTITY_ID = :entity_id
          AND defaults.REPRESENTATION_ID = :previous_representation_id
          AND defaults.IS_DEFAULT = TRUE
          AND defaults.STATUS = 'ACTIVE'
          AND EXISTS (
            SELECT 1
            FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
            WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
              AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
              AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
              AND explicit.IS_DEFAULT = FALSE
              AND explicit.STATUS = 'ACTIVE'
          )
    ]], {entity_id = entity_id,
        previous_representation_id = previous_representation_id})

    if tonumber(stale_default_count or 0) > 0 then
        -- Repair catalog states produced by the pre-fix promotion path. Move a
        -- collided compatibility default back to the requested representation
        -- when that representation has no binding for the attribute. If it
        -- already has an explicit binding, the stale default is redundant.
        query([[
            UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            SET REPRESENTATION_ID = :representation_id,
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE ATTRIBUTE_BINDING_ID IN (
              SELECT defaults.ATTRIBUTE_BINDING_ID
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
              WHERE defaults.ENTITY_ID = :entity_id
                AND defaults.REPRESENTATION_ID = :previous_representation_id
                AND defaults.IS_DEFAULT = TRUE
                AND defaults.STATUS = 'ACTIVE'
                AND EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
                  WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
                    AND explicit.IS_DEFAULT = FALSE
                    AND explicit.STATUS = 'ACTIVE'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS target
                  WHERE target.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND target.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND target.REPRESENTATION_ID = :representation_id
                    AND target.STATUS = 'ACTIVE'
                )
            )
        ]], {entity_id = entity_id, representation_id = representation_id,
            previous_representation_id = previous_representation_id})
        query([[
            DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            WHERE ATTRIBUTE_BINDING_ID IN (
              SELECT defaults.ATTRIBUTE_BINDING_ID
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
              WHERE defaults.ENTITY_ID = :entity_id
                AND defaults.REPRESENTATION_ID = :previous_representation_id
                AND defaults.IS_DEFAULT = TRUE
                AND defaults.STATUS = 'ACTIVE'
                AND EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
                  WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
                    AND explicit.IS_DEFAULT = FALSE
                    AND explicit.STATUS = 'ACTIVE'
                )
            )
        ]], {entity_id = entity_id,
            previous_representation_id = previous_representation_id})
        local repair_validation = query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
            {model_name = model_name})
        for _, validation_row in ipairs(repair_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
                error("SEMANTIC_ADMIN_048: stale default bindings were repaired, but model validation still fails: "
                    .. tostring(row_value(validation_row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR")
                    .. " " .. tostring(row_value(validation_row, "MESSAGE", 5) or "validation failed"))
            end
        end
    else
        local validation_rows = query([[
            SELECT VALIDATION_RUN_ID
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND (STATUS IN ('OK', 'WARNING')
                   OR STATUS = 'STALE' AND :allow_stale_recovery = TRUE)
              AND ERROR_COUNT = 0
            ORDER BY VALIDATION_RUN_ID DESC LIMIT 1
        ]], {model_id = model_id, version_id = version_id,
            allow_stale_recovery = recovery_from_invalid_primary})
        if validation_rows == nil or #validation_rows == 0 then
            error("SEMANTIC_ADMIN_048: representations must have a clean VALIDATE_MODEL run before promotion")
        end
    end
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET REPRESENTATION_ROLE = 'ALTERNATE',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE ENTITY_ID = :entity_id
          AND REPRESENTATION_ROLE = 'PRIMARY'
          AND STATUS = 'ACTIVE'
    ]], {entity_id = entity_id})
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET REPRESENTATION_ROLE = 'PRIMARY',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = representation_id})
    query([[
        UPDATE SYS_SEMANTIC.ENTITIES
        SET SOURCE_SCHEMA = :source_schema, SOURCE_OBJECT = :source_object,
            SOURCE_ALIAS = :source_alias
        WHERE ENTITY_ID = :entity_id
    ]], {entity_id = entity_id, source_schema = source_schema,
        source_object = source_object, source_alias = source_alias})
    query([[
        UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        SET REPRESENTATION_ID = :representation_id,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE ATTRIBUTE_BINDING_ID IN (
          SELECT defaults.ATTRIBUTE_BINDING_ID
          FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
          WHERE defaults.ENTITY_ID = :entity_id
            AND defaults.REPRESENTATION_ID = :previous_representation_id
            AND defaults.IS_DEFAULT = TRUE
            AND defaults.STATUS = 'ACTIVE'
            AND NOT EXISTS (
              SELECT 1
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
              WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                AND explicit.REPRESENTATION_ID = :representation_id
                AND explicit.IS_DEFAULT = FALSE
                AND explicit.STATUS = 'ACTIVE'
            )
          )
    ]], {entity_id = entity_id, representation_id = representation_id,
        previous_representation_id = previous_representation_id})
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
    ]], {model_id = model_id, version_id = version_id})
end

-- Promotion is accepted on a valid model and the numbers stay correct, so
-- neither of these is an error. Both leave a catalog state whose next reader
-- draws the wrong conclusion, and nothing else reports them: the role flip is
-- silent, and VALIDATE_MODEL sees a legal model afterwards.
--
--   * A representation whose coverage is a closed window or a predicate is now
--     the entity's PRIMARY, so the representation that answers for uncovered
--     rows is an ALTERNATE. Under F3 that is a deliberate shape for a rebuild
--     and a mistake the rest of the time, and only the caller knows which.
--   * REPRESENTATION_NAME is free text and 'primary' is the conventional name
--     for the F0 compatibility row. Promoting anything else leaves a
--     representation *named* primary holding role ALTERNATE, which reads as a
--     catalog inconsistency to everyone who meets it later. The advisory names
--     RENAME_ENTITY_REPRESENTATION, which exists because this warning needed it:
--     for three evaluations it told the reader to rename and the product had no
--     rename, so the one state it reports was the one state nobody could leave.
--
-- Both are advisory, and they say so by arriving in the WARNINGS column of the
-- result row rather than as a raised error. That is the only thing that marks
-- them advisory: the codes are ordinary SEMANTIC_ADMIN_NNN, because severity is
-- carried by the channel here exactly as VALIDATE_MODEL carries it in its
-- SEVERITY column. They were briefly SEMANTIC_ADMIN_W060/W061 -- a 'W' prefix
-- invented for advisory codes -- which put two numbering conventions in one
-- namespace to express what the column already said. 060 and 061 were taken by
-- refusals, hence 220.
local warnings = {}
if changed then
    local valid_from = row_value(row, "VALID_FROM", 10)
    local valid_to = row_value(row, "VALID_TO", 11)
    local coverage_predicate = row_value(row, "COVERAGE_PREDICATE", 12)
    -- VALID_TO is the whole test. A representation with only a VALID_FROM is
    -- still the open-ended one -- it is the partition new rows land in -- and
    -- warning on it would fire on the ordinary act of promoting the hot
    -- partition back, training the reader to ignore the column.
    if not missing(valid_to) then
        local window = {"VALID_TO " .. tostring(valid_to)}
        if not missing(valid_from) then
            window[#window + 1] = "VALID_FROM " .. tostring(valid_from)
        end
        if not missing(coverage_predicate) then
            window[#window + 1] = "COVERAGE_PREDICATE "
                .. tostring(coverage_predicate)
        end
        warnings[#warnings + 1] = "SEMANTIC_ADMIN_220: representation '"
            .. representation_name .. "' is now PRIMARY for entity '"
            .. entity_name .. "' but its coverage is bounded ("
            .. table.concat(window, ", ")
            .. "), so rows outside that window are answered by an ALTERNATE."
            .. " Promote the open-ended representation instead, or widen this"
            .. " one's coverage, unless a bounded primary is intended."
    end
    if previous_name ~= null
        and string.upper(tostring(previous_name)) == "PRIMARY"
        and string.upper(representation_name) ~= "PRIMARY" then
        warnings[#warnings + 1] = "SEMANTIC_ADMIN_221: representation named '"
            .. tostring(previous_name) .. "' now holds role ALTERNATE, because '"
            .. representation_name .. "' took role PRIMARY. The name and the role"
            .. " disagree from here on. Rename it after its source instead --"
            .. " EXECUTE SCRIPT SEMANTIC_ADMIN.RENAME_ENTITY_REPRESENTATION('"
            .. model_name .. "', '" .. entity_name .. "', '"
            .. tostring(previous_name) .. "', '<new_name>') -- which is a pure"
            .. " relabel: every reference to a representation is by"
            .. " REPRESENTATION_ID, so nothing else moves."
    end
end
local warning_text = null
if #warnings > 0 then
    warning_text = table.concat(warnings, " ")
end

exit({{representation_id, model_name, entity_name, previous_name,
    representation_name, source_schema, source_object, changed, warning_text}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  PREVIOUS_PRIMARY VARCHAR(256),
  PRIMARY_REPRESENTATION VARCHAR(256),
  SOURCE_SCHEMA VARCHAR(256),
  SOURCE_OBJECT VARCHAR(256),
  CHANGED BOOLEAN,
  WARNINGS VARCHAR(2000000)
]])
