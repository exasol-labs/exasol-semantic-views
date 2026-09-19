local M = {}
local json = assert(ESV_JSON, "shared JSON runtime is required")
-- Bound to their own names rather than through a module alias: 763 call sites
-- read better as `row_value(row, ...)`, a `rows` alias would be shadowed by the
-- many local `rows` variables these files declare, and four names cost the chunk
-- exactly what the four function definitions they replace used to.
assert(ESV_ROWS, "shared row runtime is required")
local missing, row_value, null_if_missing, scalar =
    ESV_ROWS.missing, ESV_ROWS.row_value, ESV_ROWS.null_if_missing, ESV_ROWS.scalar
local sql_text = assert(ESV_SQL_TEXT, "shared SQL text runtime is required")
local grain_graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")
local identity_join = assert(ESV_IDENTITY_JOIN,
    "shared identity join runtime is required")
local source_columns = assert(ESV_SOURCE_COLUMNS,
    "shared source-column runtime is required")
local metric_plan = assert(ESV_METRIC_PLAN, "metric plan runtime is required")

local VALID_CARDINALITIES = {
    ONE_TO_ONE = true,
    ONE_TO_MANY = true,
    MANY_TO_ONE = true,
    MANY_TO_MANY = true,
}

local VALID_JOIN_TYPES = {
    INNER = true,
    LEFT = true,
}

-- Reasons emitted by the shared grain graph for an edge that would attribute
-- one fact row to several dimension rows. Named here so rule SEMANTIC_MODEL_030
-- can offer the remedy that exists (object membership) rather than one that
-- does not (a relationship-level declaration).
local FANOUT_REASONS = {
    ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED = true,
    MANY_TO_MANY_UNSUPPORTED = true,
}

-- Closed set of FANOUT_POLICY values. None authorizes traversal of a fanning
-- edge; each records what the modeler intends a planner to do if the technique
-- is ever proven. ADD_RELATIONSHIP rejects anything else on write, so a value
-- outside this set means the row predates that check.
local VALID_FANOUT_POLICIES = {
    ALLOCATE = true,
    DEDUPLICATE = true,
    REFERENCE_ONLY = true,
}

local VALID_AGENT_SCOPE_TYPES = {
    MODEL = true,
    SEMANTIC_OBJECT = true,
    ENTITY = true,
    DIMENSION = true,
    FACT = true,
    METRIC = true,
}

local VALID_AGENT_INSTRUCTION_KINDS = {
    AMBIGUITY = true,
    DEFINITION = true,
    GENERAL = true,
    POLICY = true,
    PRECONDITION = true,
    PREFERENCE = true,
    SAFETY = true,
    STYLE = true,
}

local VALID_EXTENSION_SCOPE_TYPES = {
    MODEL = true,
    SEMANTIC_OBJECT = true,
    ENTITY = true,
    RELATIONSHIP = true,
    DIMENSION = true,
    FACT = true,
    METRIC = true,
}

local VALID_UNIQUE_KEY_KINDS = {
    PRIMARY = true,
    UNIQUE = true,
    ALTERNATE = true,
}

local SQL_WORDS = {
    ABS = true,
    AND = true,
    AS = true,
    ASC = true,
    AVG = true,
    BETWEEN = true,
    BY = true,
    CASE = true,
    CAST = true,
    COALESCE = true,
    COUNT = true,
    DATE = true,
    DATE_TRUNC = true,
    DAY = true,
    DECIMAL = true,
    DESC = true,
    DISTINCT = true,
    DOUBLE = true,
    ELSE = true,
    END = true,
    EXTRACT = true,
    FALSE = true,
    FILTER = true,
    FLOAT = true,
    FROM = true,
    GROUP = true,
    HAVING = true,
    HOUR = true,
    IF = true,
    IN = true,
    INT = true,
    INTEGER = true,
    IS = true,
    LPAD = true,
    MAX = true,
    MIN = true,
    MINUTE = true,
    MONTH = true,
    NOT = true,
    NULL = true,
    NULLIF = true,
    NUMBER = true,
    ON = true,
    OR = true,
    ORDER = true,
    OVER = true,
    PARTITION = true,
    ROUND = true,
    SECOND = true,
    SELECT = true,
    SUM = true,
    THEN = true,
    TIMESTAMP = true,
    TRUE = true,
    TRUNC = true,
    VARCHAR = true,
    WHEN = true,
    WHERE = true,
    YEAR = true,
}

-- Exasol built-in functions only. QUARTER() does not exist in Exasol -- use CEIL(MONTH(date)/3.0)
local ALLOWED_FUNCTIONS = {
    ABS = true,
    AVG = true,
    CAST = true,
    CEIL = true,
    COALESCE = true,
    CONCAT = true,
    COUNT = true,
    DATE_TRUNC = true,
    DAY = true,
    EXTRACT = true,
    FLOOR = true,
    LPAD = true,
    LOWER = true,
    LTRIM = true,
    MAX = true,
    MIN = true,
    MONTH = true,
    NULLIF = true,
    REPLACE = true,
    ROUND = true,
    RTRIM = true,
    SUBSTR = true,
    SUM = true,
    TO_CHAR = true,
    TO_DATE = true,
    TRIM = true,
    TRUNC = true,
    UPPER = true,
    YEAR = true,
}

local allowed_function_names = {}
for function_name, _ in pairs(ALLOWED_FUNCTIONS) do
    SQL_WORDS[function_name] = true
    table.insert(allowed_function_names, function_name)
end
table.sort(allowed_function_names)
local ALLOWED_FUNCTION_NAMES = table.concat(allowed_function_names, ", ")

local CAST_TARGET_TYPES = {
    BIGINT = true,
    BOOLEAN = true,
    CHAR = true,
    DATE = true,
    DEC = true,
    DECIMAL = true,
    DOUBLE = true,
    FLOAT = true,
    GEOMETRY = true,
    HASHTYPE = true,
    INT = true,
    INTEGER = true,
    INTERVAL = true,
    NUMBER = true,
    NUMERIC = true,
    REAL = true,
    SMALLINT = true,
    TIMESTAMP = true,
    TINYINT = true,
    VARCHAR = true,
    VARCHAR2 = true,
}

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function count_query(sql_text, params)
    return tonumber(scalar(sql_text, params) or 0) or 0
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function nil_if_missing(value)
    if missing(value) then
        return nil
    end
    return value
end

-- Well-formedness of a user-supplied JSON payload -- extension `data_json`,
-- agent metadata -- under the strict scalar grammar. This was a fourth
-- hand-written JSON parser; it is now the strict mode of the one in
-- shared/json.lua. The strictness is the point: the compiler's decoder is
-- lenient about what it accepts because it re-reads payloads this runtime
-- itself wrote, but a model author's JSON is refused at definition time rather
-- than surprising someone at query time.
local function valid_json_text(text)
    return json.is_valid(text)
end

local function start_validation_run(ctx)
    query([[
        INSERT INTO SYS_SEMANTIC.VALIDATION_RUNS (
          MODEL_ID, VERSION_ID, MODEL_NAME, STATUS
        ) VALUES (
          :model_id, :version_id, :model_name, 'RUNNING'
        )
    ]], {
        model_id = null_if_missing(ctx.model_id),
        version_id = null_if_missing(ctx.version_id),
        model_name = null_if_missing(ctx.model_name),
    })

    ctx.validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE COALESCE(MODEL_NAME, '') = COALESCE(:model_name, '')
    ]], {model_name = null_if_missing(ctx.model_name)})
end

local function add_issue(ctx, severity, object_type, object_name, rule_code, message)
    local dedupe_key = table.concat({
        tostring(severity),
        tostring(object_type),
        tostring(object_name),
        tostring(rule_code),
        tostring(message),
    }, "|")
    if ctx.issue_seen[dedupe_key] then
        return
    end
    ctx.issue_seen[dedupe_key] = true

    local issue = {
        severity = severity,
        object_type = object_type,
        object_name = object_name,
        rule_code = rule_code,
        message = message,
    }
    table.insert(ctx.issues, issue)

    if severity == "ERROR" then
        ctx.error_count = ctx.error_count + 1
    elseif severity == "PRECONDITION" then
        ctx.precondition_count = ctx.precondition_count + 1
    elseif severity == "WARNING" then
        ctx.warning_count = ctx.warning_count + 1
    end

    if not missing(ctx.validation_run_id) then
        query([[
            INSERT INTO SYS_SEMANTIC.VALIDATION_RESULTS (
              VALIDATION_RUN_ID, MODEL_ID, VERSION_ID, SEVERITY, OBJECT_TYPE,
              OBJECT_NAME, RULE_CODE, MESSAGE
            ) VALUES (
              :validation_run_id, :model_id, :version_id, :severity, :object_type,
              :object_name, :rule_code, :message
            )
        ]], {
            validation_run_id = ctx.validation_run_id,
            model_id = null_if_missing(ctx.model_id),
            version_id = null_if_missing(ctx.version_id),
            severity = severity,
            object_type = object_type,
            object_name = null_if_missing(object_name),
            rule_code = rule_code,
            message = message,
        })
    end
end

local function finish_validation_run(ctx)
    if missing(ctx.validation_run_id) then
        return
    end
    local status = "OK"
    if ctx.error_count > 0 then
        status = "ERROR"
    elseif ctx.precondition_count > 0 then
        status = "PRECONDITION"
    elseif ctx.warning_count > 0 then
        status = "WARNING"
    end
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS
        SET STATUS = :status,
            FINISHED_AT = CURRENT_TIMESTAMP,
            ISSUE_COUNT = :issue_count,
            ERROR_COUNT = :error_count,
            WARNING_COUNT = :warning_count
        WHERE VALIDATION_RUN_ID = :validation_run_id
    ]], {
        status = status,
        issue_count = #ctx.issues,
        error_count = ctx.error_count,
        warning_count = ctx.warning_count,
        validation_run_id = ctx.validation_run_id,
    })
end

local function source_object_exists(schema_name, object_name)
    return count_query([[
        SELECT COUNT(*)
        FROM (
          SELECT TABLE_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_TABLES
          WHERE (TABLE_SCHEMA = :schema_name OR TABLE_SCHEMA = UPPER(:schema_name))
            AND (TABLE_NAME = :object_name OR TABLE_NAME = UPPER(:object_name))
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE (VIEW_SCHEMA = :schema_name OR VIEW_SCHEMA = UPPER(:schema_name))
            AND (VIEW_NAME = :object_name OR VIEW_NAME = UPPER(:object_name))
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name}) > 0
end

local function source_column_exists(schema_name, object_name, column_name)
    return count_query([[
        SELECT COUNT(*)
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
    ]], {schema_name = schema_name, object_name = object_name, column_name = column_name}) > 0
end

local function source_column_type(schema_name, object_name, column_name)
    local ok, rows = pcall(query, [[
        SELECT COLUMN_TYPE
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
        ORDER BY CASE WHEN COLUMN_NAME = :column_name THEN 0 ELSE 1 END
        LIMIT 1
    ]], {schema_name = schema_name, object_name = object_name,
          column_name = column_name})
    if not ok or rows == nil or #rows == 0 then return nil end
    local data_type = row_value(rows[1], "COLUMN_TYPE", 1)
    if type(data_type) ~= "string" then return nil end
    return data_type
end

local function relationship_type_family(data_type)
    local value = upper(data_type)
    if value:match("^DECIMAL") or value:match("^DOUBLE")
        or value:match("^FLOAT") or value:match("^INTEGER")
        or value:match("^BIGINT") or value:match("^SMALLINT") then
        return "NUMERIC"
    elseif value:match("^CHAR") or value:match("^VARCHAR") then
        return "STRING"
    elseif value:match("^DATE") or value:match("^TIMESTAMP") then
        return "TEMPORAL"
    elseif value:match("^INTERVAL") then
        return "INTERVAL"
    elseif value:match("^BOOLEAN") then
        return "BOOLEAN"
    elseif value:match("^GEOMETRY") then
        return "GEOMETRY"
    elseif value:match("^HASHTYPE") then
        return "HASHTYPE"
    end
    return value:match("^([A-Z_]+)") or value
end

local function simple_relationship_equality(expression)
    local shape = tostring(expression or "")
    shape = shape:gsub('[A-Za-z_][A-Za-z0-9_]*%s*%.%s*"[^"]+"', "REF")
    shape = shape:gsub("[A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*", "REF")
    shape = shape:gsub("%s+", "")
    while shape:match("^%b()$") do shape = shape:sub(2, -2) end
    return shape == "REF=REF"
end

local function qualified_column_refs(expression)
    local refs = {}
    if missing(expression) then
        return refs
    end
    local text = sql_text.strip_string_literals(tostring(expression))
    local pos = 1
    while pos <= #text do
        local start_pos, alias_end, alias = string.find(
            text, "([A-Za-z_][A-Za-z0-9_]*)", pos)
        if start_pos == nil then break end
        local cursor = alias_end + 1
        while string.match(string.sub(text, cursor, cursor), "%s") do
            cursor = cursor + 1
        end
        if string.sub(text, cursor, cursor) ~= "." then
            pos = alias_end + 1
        else
            cursor = cursor + 1
            while string.match(string.sub(text, cursor, cursor), "%s") do
                cursor = cursor + 1
            end
            local column_name = nil
            local quoted = false
            if string.sub(text, cursor, cursor) == '"' then
                quoted = true
                cursor = cursor + 1
                local parts = {}
                while cursor <= #text do
                    local char = string.sub(text, cursor, cursor)
                    local next_char = string.sub(text, cursor + 1, cursor + 1)
                    if char == '"' and next_char == '"' then
                        parts[#parts + 1] = '"'
                        cursor = cursor + 2
                    elseif char == '"' then
                        cursor = cursor + 1
                        column_name = table.concat(parts)
                        break
                    else
                        parts[#parts + 1] = char
                        cursor = cursor + 1
                    end
                end
            else
                local column_start, column_end
                column_start, column_end, column_name = string.find(
                    text, "([A-Za-z_][A-Za-z0-9_]*)", cursor)
                if column_start ~= cursor then
                    column_name = nil
                elseif column_end ~= nil then
                    cursor = column_end + 1
                end
            end
            local after = cursor
            while string.match(string.sub(text, after, after), "%s") do
                after = after + 1
            end
            if column_name ~= nil and string.sub(text, after, after) ~= "(" then
                refs[#refs + 1] = {
                    alias = upper(alias),
                    column_name = quoted and column_name or upper(column_name),
                }
            end
            pos = math.max(cursor, alias_end + 1)
        end
    end
    return refs
end

local function aliases_in_expression(expression)
    local aliases = {}
    for _, ref in ipairs(qualified_column_refs(expression)) do
        aliases[ref.alias] = true
    end
    return aliases
end

local function column_refs_in_expression(expression)
    return qualified_column_refs(expression)
end

local function schema_qualified_functions(expression)
    local functions = {}
    if missing(expression) then
        return functions
    end
    local text = sql_text.strip_string_literals(tostring(expression))
    for schema_name, function_name in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
        functions[upper(schema_name) .. "." .. upper(function_name)] = true
    end
    return functions
end

local function unsupported_functions(expression)
    local found = {}
    if missing(expression) then
        return found
    end
    local text = sql_text.strip_string_literals(tostring(expression))
    local pos = 1
    while true do
        local start_pos, end_pos, fn = string.find(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%(", pos)
        if start_pos == nil then
            break
        end
        local normalized = upper(fn)
        local prefix = string.sub(text, 1, start_pos - 1)
        local schema_qualified = string.match(prefix, "[A-Za-z_][A-Za-z0-9_]*%s*%.%s*$") ~= nil
        local previous_word = string.match(prefix, "([A-Za-z_][A-Za-z0-9_]*)%s*$")
        local cast_target = CAST_TARGET_TYPES[normalized] and upper(previous_word or "") == "AS"
        if not schema_qualified and not cast_target and not ALLOWED_FUNCTIONS[normalized] then
            found[normalized] = true
        end
        pos = end_pos + 1
    end
    return found
end

local function dependency_tokens(expression)
    local tokens = {}
    if missing(expression) then
        return tokens
    end
    local text = sql_text.strip_string_literals(tostring(expression))
    text = string.gsub(text, "[A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*", " ")
    for token in string.gmatch(text, "[A-Za-z_][A-Za-z0-9_]*") do
        local normalized = upper(token)
        if not SQL_WORDS[normalized] then
            tokens[normalized] = token
        end
    end
    return tokens
end

local function extract_json_array_values(json_text, key_name)
    local values = {}
    if missing(json_text) then
        return values
    end
    local text = tostring(json_text)
    local lower_text = string.lower(text)
    local pattern = '"' .. string.lower(key_name) .. '"%s*:%s*%[(.-)%]'
    local start_pos, end_pos = string.find(lower_text, pattern)
    if start_pos == nil then
        return values
    end
    local raw = string.sub(text, start_pos, end_pos)
    for value in string.gmatch(raw, '"([^"]+)"') do
        if string.lower(value) ~= string.lower(key_name) then
            table.insert(values, value)
        end
    end
    return values
end

local function load_model(ctx, model_name_arg)
    if missing(model_name_arg) then
        ctx.model_name = nil
        start_validation_run(ctx)
        add_issue(ctx, "ERROR", "MODEL", nil, "SEMANTIC_MODEL_000", "MODEL_NAME is required.")
        return false
    end
    ctx.model_name = trim(model_name_arg)
    local rows = query([[
        SELECT
          m.MODEL_ID,
          m.ACTIVE_VERSION_ID AS VERSION_ID,
          mv.VERSION_NUMBER,
          m.GOVERNANCE_MODE
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = ctx.model_name})
    if rows == nil or #rows == 0 then
        start_validation_run(ctx)
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_000", "Model not found: " .. ctx.model_name .. ".")
        return false
    end

    ctx.model_id = row_value(rows[1], "MODEL_ID", 1)
    ctx.version_id = row_value(rows[1], "VERSION_ID", 2)
    ctx.governance_mode = row_value(rows[1], "GOVERNANCE_MODE", 4)
    start_validation_run(ctx)

    if missing(ctx.version_id) then
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_002", "Model has no active version.")
        return false
    end
    return true
end

local function load_catalog(ctx)
    ctx.entities = {}
    ctx.representations = {}
    ctx.representations_by_entity = {}
    ctx.entity_by_id = {}
    ctx.entity_alias_by_id = {}
    ctx.entity_name_by_id = {}
    ctx.entity_id_by_name = {}
    local entity_rows = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME,
               er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
               e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION,
               er.REPRESENTATION_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.REPRESENTATION_ROLE, er.PRIORITY
        FROM SYS_SEMANTIC.ENTITIES e
        LEFT JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local id = row_value(row, "ENTITY_ID", 1)
        local entity = {
            id = id,
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
            primary_key_expr = row_value(row, "PRIMARY_KEY_EXPR", 6),
            grain_description = row_value(row, "GRAIN_DESCRIPTION", 7),
            primary_representation = {
                id = row_value(row, "REPRESENTATION_ID", 8),
                entity_id = row_value(row, "ENTITY_ID", 1),
                name = row_value(row, "REPRESENTATION_NAME", 9),
                source_kind = row_value(row, "SOURCE_KIND", 10),
                role = row_value(row, "REPRESENTATION_ROLE", 11),
                priority = row_value(row, "PRIORITY", 12),
                source_schema = row_value(row, "SOURCE_SCHEMA", 3),
                source_object = row_value(row, "SOURCE_OBJECT", 4),
                alias = row_value(row, "SOURCE_ALIAS", 5),
            },
        }
        table.insert(ctx.entities, entity)
        ctx.entity_by_id[key(id)] = entity
        ctx.entity_alias_by_id[key(id)] = upper(entity.alias)
        ctx.entity_name_by_id[key(id)] = tostring(entity.name)
        ctx.entity_id_by_name[upper(entity.name)] = id
    end

    local representation_rows = query([[
        SELECT er.REPRESENTATION_ID, er.ENTITY_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
               er.SOURCE_ALIAS, er.REPRESENTATION_ROLE, er.PRIORITY,
               er.FRESHNESS_POLICY, er.COVERAGE_PREDICATE, er.VALID_FROM,
               er.VALID_TO, COALESCE(ra.AUTHORITY_ROLE, 'PREFER') AS AUTHORITY_ROLE
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
        LEFT JOIN SYS_SEMANTIC.REPRESENTATION_AUTHORITIES ra
          ON ra.MODEL_ID = er.MODEL_ID AND ra.VERSION_ID = er.VERSION_ID
         AND ra.REPRESENTATION_ID = er.REPRESENTATION_ID AND ra.STATUS = 'ACTIVE'
        WHERE er.MODEL_ID = :model_id
          AND er.VERSION_ID = :version_id
          AND er.STATUS = 'ACTIVE'
        ORDER BY er.ENTITY_ID,
          CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN 0 ELSE 1 END,
          er.PRIORITY, er.REPRESENTATION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(representation_rows or {}) do
        local representation = {
            id = row_value(row, "REPRESENTATION_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "REPRESENTATION_NAME", 3),
            source_kind = row_value(row, "SOURCE_KIND", 4),
            source_schema = row_value(row, "SOURCE_SCHEMA", 5),
            source_object = row_value(row, "SOURCE_OBJECT", 6),
            alias = row_value(row, "SOURCE_ALIAS", 7),
            role = row_value(row, "REPRESENTATION_ROLE", 8),
            priority = row_value(row, "PRIORITY", 9),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 10),
            coverage_predicate = row_value(row, "COVERAGE_PREDICATE", 11),
            valid_from = row_value(row, "VALID_FROM", 12),
            valid_to = row_value(row, "VALID_TO", 13),
            authority_role = row_value(row, "AUTHORITY_ROLE", 14) or "PREFER",
        }
        table.insert(ctx.representations, representation)
        local entity_key = key(representation.entity_id)
        ctx.representations_by_entity[entity_key] =
            ctx.representations_by_entity[entity_key] or {}
        table.insert(ctx.representations_by_entity[entity_key], representation)
        if upper(representation.role) == "PRIMARY" and ctx.entity_by_id[entity_key] ~= nil then
            ctx.entity_by_id[entity_key].primary_representation = representation
        end
    end

    ctx.dimensions = {}
    ctx.dimension_by_id = {}
    ctx.dimension_by_name = {}
    local dimension_rows = query([[
        SELECT DIMENSION_ID, DIMENSION_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE,
               DESCRIPTION, UNIT_HINT, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED
        FROM SYS_SEMANTIC.DIMENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY DIMENSION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(dimension_rows or {}) do
        local id = row_value(row, "DIMENSION_ID", 1)
        local dimension = {
            id = id,
            name = row_value(row, "DIMENSION_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            description = row_value(row, "DESCRIPTION", 6),
            unit_hint = row_value(row, "UNIT_HINT", 7),
            format_hint = row_value(row, "FORMAT_HINT", 8),
            is_hidden = row_value(row, "IS_HIDDEN", 9),
            is_certified = row_value(row, "IS_CERTIFIED", 10),
        }
        table.insert(ctx.dimensions, dimension)
        ctx.dimension_by_id[key(id)] = dimension
        ctx.dimension_by_name[upper(dimension.name)] = dimension
    end

    ctx.facts = {}
    ctx.fact_by_id = {}
    ctx.fact_by_name = {}
    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE, DESCRIPTION,
               UNIT_HINT, FORMAT_HINT, IS_PRIVATE, IS_CERTIFIED
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY FACT_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(fact_rows or {}) do
        local id = row_value(row, "FACT_ID", 1)
        local fact = {
            id = id,
            name = row_value(row, "FACT_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            description = row_value(row, "DESCRIPTION", 6),
            unit_hint = row_value(row, "UNIT_HINT", 7),
            format_hint = row_value(row, "FORMAT_HINT", 8),
            is_private = row_value(row, "IS_PRIVATE", 9),
            is_certified = row_value(row, "IS_CERTIFIED", 10),
        }
        table.insert(ctx.facts, fact)
        ctx.fact_by_id[key(id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

    ctx.attribute_bindings = {}
    ctx.bindings_by_attribute = {}
    local binding_rows = query([[
        SELECT ATTRIBUTE_BINDING_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
               REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
               BINDING_PRIORITY, IS_DEFAULT
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          CASE WHEN BINDING_ROLE = 'PREFER' THEN 0 ELSE 1 END,
          BINDING_PRIORITY, ATTRIBUTE_BINDING_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(binding_rows or {}) do
        local binding = {
            id = row_value(row, "ATTRIBUTE_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 3),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 4),
            representation_id = row_value(row, "REPRESENTATION_ID", 5),
            expression = row_value(row, "SOURCE_EXPRESSION", 6),
            role = row_value(row, "BINDING_ROLE", 7),
            priority = row_value(row, "BINDING_PRIORITY", 8),
            is_default = row_value(row, "IS_DEFAULT", 9),
        }
        table.insert(ctx.attribute_bindings, binding)
        local attribute_key = upper(binding.attribute_type) .. ":" .. key(binding.attribute_id)
        ctx.bindings_by_attribute[attribute_key] =
            ctx.bindings_by_attribute[attribute_key] or {}
        table.insert(ctx.bindings_by_attribute[attribute_key], binding)
    end

    ctx.attribute_fusion_policies = {}
    ctx.fusion_policy_by_attribute = {}
    local fusion_policy_rows = query([[
        SELECT ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID, FUSION_STRATEGY
        FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(fusion_policy_rows or {}) do
        local policy = {
            entity_id = row_value(row, "ENTITY_ID", 1),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 2),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 3),
            strategy = row_value(row, "FUSION_STRATEGY", 4),
        }
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        ctx.attribute_fusion_policies[#ctx.attribute_fusion_policies + 1] = policy
        ctx.fusion_policy_by_attribute[attribute_key] = policy
    end

    ctx.semantic_identities = {}
    ctx.identity_by_id = {}
    ctx.identities_by_entity = {}
    local identity_rows = query([[
        SELECT IDENTITY_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND, DATA_TYPE
        FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, IDENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(identity_rows or {}) do
        local identity = {id = row_value(row, "IDENTITY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "IDENTITY_NAME", 3),
            kind = row_value(row, "IDENTITY_KIND", 4),
            data_type = row_value(row, "DATA_TYPE", 5), bindings = {}}
        ctx.semantic_identities[#ctx.semantic_identities + 1] = identity
        ctx.identity_by_id[key(identity.id)] = identity
        ctx.identities_by_entity[key(identity.entity_id)] =
            ctx.identities_by_entity[key(identity.entity_id)] or {}
        table.insert(ctx.identities_by_entity[key(identity.entity_id)], identity)
    end
    ctx.identity_bindings = {}
    local identity_binding_rows = query([[
        SELECT ib.IDENTITY_BINDING_ID, ib.ENTITY_ID, ib.IDENTITY_ID,
               ib.REPRESENTATION_ID, ib.SOURCE_EXPRESSION, ib.BINDING_KIND,
               im.IDENTITY_MAPPING_ID, im.SOURCE_SCHEMA, im.SOURCE_OBJECT,
               im.SOURCE_LOCAL_COLUMN, im.SEMANTIC_KEY_COLUMN,
               im.CERTIFICATION_STATUS
        FROM SYS_SEMANTIC.IDENTITY_BINDINGS ib
        LEFT JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS im
          ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID
         AND im.STATUS = 'ACTIVE'
        WHERE ib.MODEL_ID = :model_id AND ib.VERSION_ID = :version_id
          AND ib.STATUS = 'ACTIVE'
        ORDER BY ib.IDENTITY_ID, ib.IDENTITY_BINDING_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(identity_binding_rows or {}) do
        local binding = {id = row_value(row, "IDENTITY_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            identity_id = row_value(row, "IDENTITY_ID", 3),
            representation_id = row_value(row, "REPRESENTATION_ID", 4),
            expression = row_value(row, "SOURCE_EXPRESSION", 5),
            kind = row_value(row, "BINDING_KIND", 6),
            mapping = not missing(row_value(row, "IDENTITY_MAPPING_ID", 7)) and {
                id = row_value(row, "IDENTITY_MAPPING_ID", 7),
                source_schema = row_value(row, "SOURCE_SCHEMA", 8),
                source_object = row_value(row, "SOURCE_OBJECT", 9),
                local_column = row_value(row, "SOURCE_LOCAL_COLUMN", 10),
                semantic_column = row_value(row, "SEMANTIC_KEY_COLUMN", 11),
                certification = row_value(row, "CERTIFICATION_STATUS", 12),
            } or nil}
        ctx.identity_bindings[#ctx.identity_bindings + 1] = binding
        local identity = ctx.identity_by_id[key(binding.identity_id)]
        if identity ~= nil then
            identity.bindings[#identity.bindings + 1] = binding
            identity.binding_by_representation = identity.binding_by_representation or {}
            identity.binding_by_representation[key(binding.representation_id)] = binding
        end
    end

    ctx.metrics = {}
    ctx.metric_by_id = {}
    ctx.metric_by_name = {}
    local metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION, FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DESCRIPTION, UNIT_HINT, FORMAT_HINT,
               IS_PRIVATE, IS_CERTIFIED,
               COALESCE(METRIC_KIND, METRIC_TYPE) AS METRIC_KIND,
               AGGREGATION_FUNCTION, DISTINCT_KEY_EXPR,
               NON_ADDITIVE_DIMENSION_ID, WINDOW_SPEC_JSON
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY METRIC_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(metric_rows or {}) do
        local id = row_value(row, "METRIC_ID", 1)
        local metric = {
            id = id,
            name = row_value(row, "METRIC_NAME", 2),
            base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            filter_expr = row_value(row, "FILTER_EXPR", 5),
            metric_type = row_value(row, "METRIC_TYPE", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            description = row_value(row, "DESCRIPTION", 8),
            unit_hint = row_value(row, "UNIT_HINT", 9),
            format_hint = row_value(row, "FORMAT_HINT", 10),
            is_private = row_value(row, "IS_PRIVATE", 11),
            is_certified = row_value(row, "IS_CERTIFIED", 12),
            -- Carried for the planner's classification, which decides whether
            -- this metric has a mergeable aggregate state and a known input
            -- grain. See validate_metric_plannability.
            metric_kind = row_value(row, "METRIC_KIND", 13),
            aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 14),
            distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 15),
            non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 16),
            window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 17),
            inputs = {},
            filters = {},
        }
        table.insert(ctx.metrics, metric)
        ctx.metric_by_id[key(id)] = metric
        ctx.metric_by_name[upper(metric.name)] = metric
    end

    local metric_input_rows = query([[
        SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE,
               mi.INPUT_OBJECT_ID, mi.EXPRESSION_ALIAS, mi.FILTER_EXPR,
               mi.ORDINAL_POSITION
        FROM SYS_SEMANTIC.METRIC_INPUTS mi
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mi.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mi.METRIC_ID, mi.ORDINAL_POSITION
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(metric_input_rows or {}) do
        local metric = ctx.metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.inputs[#metric.inputs + 1] = {
                role = row_value(row, "INPUT_ROLE", 2),
                object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
                object_id = row_value(row, "INPUT_OBJECT_ID", 4),
                expression_alias = row_value(row, "EXPRESSION_ALIAS", 5),
                filter_expr = row_value(row, "FILTER_EXPR", 6),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
            }
        end
    end

    ctx.relationships = {}
    ctx.relationship_by_id = {}
    local relationship_rows = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY,
               PATH_PRIORITY
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY RELATIONSHIP_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(relationship_rows or {}) do
        local id = row_value(row, "RELATIONSHIP_ID", 1)
        local relationship = {
            id = id,
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
            key_mappings = {},
        }
        table.insert(ctx.relationships, relationship)
        ctx.relationship_by_id[key(id)] = relationship
    end

    local mapping_rows = query([[
        SELECT rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION,
               rkm.FROM_COLUMN_NAME, rkm.FROM_EXPRESSION,
               rkm.TO_COLUMN_NAME, rkm.TO_EXPRESSION
        FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
        JOIN SYS_SEMANTIC.RELATIONSHIPS r
          ON r.RELATIONSHIP_ID = rkm.RELATIONSHIP_ID
        WHERE r.MODEL_ID = :model_id
          AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE'
        ORDER BY rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(mapping_rows or {}) do
        local relationship = ctx.relationship_by_id[key(row_value(row, "RELATIONSHIP_ID", 1))]
        if relationship ~= nil then
            relationship.key_mappings[#relationship.key_mappings + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                from_column_name = row_value(row, "FROM_COLUMN_NAME", 3),
                from_expression = row_value(row, "FROM_EXPRESSION", 4),
                to_column_name = row_value(row, "TO_COLUMN_NAME", 5),
                to_expression = row_value(row, "TO_EXPRESSION", 6),
            }
        end
    end

    -- Semantic objects with root entity IDs - needed to validate that a metric
    -- base entity is reachable from the join-root when computing the valid-combinations matrix.
    ctx.semantic_objects = {}
    ctx.semantic_object_by_id = {}
    local object_rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(object_rows or {}) do
        local id = row_value(row, "OBJECT_ID", 1)
        local object = {
            object_id = id,
            name = row_value(row, "OBJECT_NAME", 2),
            root_entity_id = row_value(row, "ROOT_ENTITY_ID", 3),
        }
        table.insert(ctx.semantic_objects, object)
        ctx.semantic_object_by_id[key(id)] = object
    end

    ctx.unique_keys = {}
    ctx.unique_key_by_id = {}
    local unique_key_rows = query([[
        SELECT UNIQUE_KEY_ID, ENTITY_ID, KEY_NAME, KEY_KIND, SOURCE_FORMAT
        FROM SYS_SEMANTIC.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY UNIQUE_KEY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(unique_key_rows or {}) do
        local id = row_value(row, "UNIQUE_KEY_ID", 1)
        local unique_key = {
            id = id,
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "KEY_NAME", 3),
            kind = row_value(row, "KEY_KIND", 4),
            source_format = row_value(row, "SOURCE_FORMAT", 5),
            columns = {},
        }
        table.insert(ctx.unique_keys, unique_key)
        ctx.unique_key_by_id[key(id)] = unique_key
    end

    local unique_key_column_rows = query([[
        SELECT ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION, ukc.COLUMN_NAME, ukc.EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
        JOIN SYS_SEMANTIC.UNIQUE_KEYS uk
          ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID
        WHERE uk.MODEL_ID = :model_id
          AND uk.VERSION_ID = :version_id
          AND uk.STATUS = 'ACTIVE'
        ORDER BY ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(unique_key_column_rows or {}) do
        local unique_key = ctx.unique_key_by_id[key(row_value(row, "UNIQUE_KEY_ID", 1))]
        if unique_key ~= nil then
            table.insert(unique_key.columns, {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                column_name = row_value(row, "COLUMN_NAME", 3),
                expression = row_value(row, "EXPRESSION", 4),
            })
        end
    end
    ctx.unique_keys_by_entity = {}
    for _, unique_key in ipairs(ctx.unique_keys) do
        local canonical = grain_graph.canonical_key(unique_key)
        unique_key.columns = canonical.columns
        unique_key.kind = canonical.kind
        local entity_key = key(unique_key.entity_id)
        ctx.unique_keys_by_entity[entity_key] = ctx.unique_keys_by_entity[entity_key] or {}
        ctx.unique_keys_by_entity[entity_key][#ctx.unique_keys_by_entity[entity_key] + 1] = unique_key
    end

    ctx.custom_extensions = {}
    local extension_rows = query([[
        SELECT CUSTOM_EXTENSION_ID, SCOPE_TYPE, SCOPE_ID, VENDOR_NAME,
               EXTENSION_NAME, SOURCE_FORMAT, DATA_JSON
        FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
        ORDER BY CUSTOM_EXTENSION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(extension_rows or {}) do
        table.insert(ctx.custom_extensions, {
            id = row_value(row, "CUSTOM_EXTENSION_ID", 1),
            scope_type = row_value(row, "SCOPE_TYPE", 2),
            scope_id = row_value(row, "SCOPE_ID", 3),
            vendor_name = row_value(row, "VENDOR_NAME", 4),
            extension_name = row_value(row, "EXTENSION_NAME", 5),
            source_format = row_value(row, "SOURCE_FORMAT", 6),
            data_json = row_value(row, "DATA_JSON", 7),
        })
    end
end

local function representations_for_entity(ctx, entity)
    if entity == nil then return {} end
    local representations = (ctx.representations_by_entity or {})[key(entity.id)] or {}
    if #representations == 0 and not missing(entity.source_schema)
        and not missing(entity.source_object) then
        return {{
            id = entity.primary_representation and entity.primary_representation.id or nil,
            entity_id = entity.id,
            name = entity.primary_representation and entity.primary_representation.name or "primary",
            source_kind = "RELATION",
            source_schema = entity.source_schema,
            source_object = entity.source_object,
            alias = entity.alias,
            role = "PRIMARY",
            priority = 1,
        }}
    end
    return representations
end

local function entity_column_types(ctx, entity, column_name)
    local result = {}
    local seen = {}
    for _, representation in ipairs(representations_for_entity(ctx, entity)) do
        local data_type = source_column_type(representation.source_schema,
            representation.source_object, column_name)
        if not missing(data_type) then
            local descriptor = tostring(representation.name) .. "=" .. tostring(data_type)
            if not seen[descriptor] then
                seen[descriptor] = true
                result[#result + 1] = {
                    family = relationship_type_family(data_type),
                    descriptor = descriptor,
                }
            end
        end
    end
    table.sort(result, function(left, right)
        return left.descriptor < right.descriptor
    end)
    return result
end

local function entity_uses_partition_fusion(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    if #representations < 2 then return false end
    for _, representation in ipairs(representations) do
        if missing(representation.coverage_predicate) then return false end
    end
    return true
end

local function trim_text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalized_timestamp(value)
    if missing(value) then return nil end
    local text = trim_text(value):gsub("T", " ")
    local date, time, fraction = text:match(
        "^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)(%.%d+)$")
    if date == nil then
        date, time = text:match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)$")
    end
    if date == nil then return nil end
    fraction = (fraction or ""):gsub("0+$", ""):gsub("%.$", "")
    return date .. " " .. time .. fraction
end

local function comparable_timestamp(value)
    return normalized_timestamp(value) or tostring(value or "")
end

local function partition_key_expression(value)
    local compact = trim_text(value):gsub("%s+", "")
    while compact:match("^%b()$") do compact = compact:sub(2, -2) end
    local alias, column = compact:match("^([%a_][%w_]*)%.([%a_][%w_]*)$")
    if alias == nil then
        alias, column = compact:match('^([%a_][%w_]*)%."([^"]+)"$')
    end
    if alias == nil then return nil end
    return upper(alias) .. "." .. tostring(column)
end

local function parse_partition_bound(clause)
    local expression, literal = trim_text(clause):match(
        "^(.-)%s*>=%s*[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]%s*'([^']+)'%s*$")
    local operator = ">="
    if expression == nil then
        expression, literal = trim_text(clause):match(
            "^(.-)%s*<%s*[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]%s*'([^']+)'%s*$")
        operator = "<"
    end
    local key_expression = partition_key_expression(expression)
    local timestamp = normalized_timestamp(literal)
    if key_expression == nil or timestamp == nil then return nil end
    return {key_expression = key_expression, operator = operator, timestamp = timestamp}
end

local function parse_partition_predicate(predicate)
    local text = trim_text(predicate)
    while text:match("^%b()$") do text = trim_text(text:sub(2, -2)) end
    local upper_text = upper(text)
    local and_start, and_end = upper_text:find("%s+AND%s+")
    if and_start == nil then
        local bound = parse_partition_bound(text)
        return bound and {bound} or nil
    end
    if upper_text:find("%s+AND%s+", and_end + 1) ~= nil then return nil end
    local first = parse_partition_bound(text:sub(1, and_start - 1))
    local second = parse_partition_bound(text:sub(and_end + 1))
    if first == nil or second == nil
        or first.key_expression ~= second.key_expression then return nil end
    return {first, second}
end

-- Name the near-miss a modeller actually makes. Hot/cold boundaries are usually
-- written on a DATE column, so `DATE '2026-07-01'` is the natural thing to type,
-- and the canonical-form message never said the literal itself must be a
-- TIMESTAMP -- it read as if the interval did not match, when it did.
local function partition_literal_hint(predicate)
    local text = tostring(predicate or "")
    for type_word, literal in string.gmatch(text, "([%a_]+)%s*'([^']*)'") do
        if upper(type_word) ~= "TIMESTAMP" then
            local suggestion = literal
            if not string.find(literal, ":", 1, true) then
                suggestion = literal .. " 00:00:00"
            end
            return " Found " .. type_word .. " '" .. literal
                .. "': a coverage bound must be a TIMESTAMP literal, so write"
                .. " TIMESTAMP '" .. suggestion .. "' (a TIMESTAMP literal compares"
                .. " correctly against a DATE column)."
        end
    end
    return ""
end

local function predicate_matches_partition_interval(representation)
    local bounds = parse_partition_predicate(representation.coverage_predicate)
    if bounds == nil then return false, nil end
    local expected_from = normalized_timestamp(representation.valid_from)
    local expected_to = normalized_timestamp(representation.valid_to)
    local actual_from, actual_to, key_expression
    for _, bound in ipairs(bounds) do
        key_expression = key_expression or bound.key_expression
        if bound.key_expression ~= key_expression then return false, nil end
        if bound.operator == ">=" then
            if actual_from ~= nil then return false, nil end
            actual_from = bound.timestamp
        elseif bound.operator == "<" then
            if actual_to ~= nil then return false, nil end
            actual_to = bound.timestamp
        end
    end
    return actual_from == expected_from and actual_to == expected_to, key_expression
end

local function entity_has_base_metric(ctx, entity)
    for _, metric in ipairs(ctx.metrics or {}) do
        if key(metric.base_entity_id) == key(entity.id) then return true end
    end
    return false
end

local function validate_partition_coverage(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    local metadata_count = 0
    for _, representation in ipairs(representations) do
        if not missing(representation.coverage_predicate)
            or not missing(representation.valid_from)
            or not missing(representation.valid_to) then
            metadata_count = metadata_count + 1
        end
    end
    if metadata_count == 0 then return end

    local entity_name = tostring(entity.name)
    if #representations < 2 or metadata_count ~= #representations then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
            "UNION fusion requires coverage metadata on every active representation.")
        return
    end
    -- Admin authoring scripts validate after each mutation. An empty model must
    -- be able to add its first metric and satisfy this rule in that operation.
    if #(ctx.metrics or {}) > 0 and not entity_has_base_metric(ctx, entity) then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_043",
            "Partitioned entity '" .. entity_name
                .. "' is the base entity of no active metric. Temporal partition fusion "
                .. "applies only "
                .. "to metric-leaf entities; partitioned joined dimensions are unsupported. "
                .. "Remove the coverage declarations or define a metric based on this entity.")
    end

    local ordered = {}
    for _, representation in ipairs(representations) do
        local object_name = entity_name .. "." .. tostring(representation.name)
        if missing(representation.coverage_predicate) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "UNION partition requires a coverage predicate.")
        end
        if missing(representation.valid_from) and missing(representation.valid_to) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "UNION partition requires VALID_FROM or VALID_TO.")
        end
        if not missing(representation.valid_from)
            and not missing(representation.valid_to)
            and comparable_timestamp(representation.valid_from)
                >= comparable_timestamp(representation.valid_to) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "VALID_FROM must be earlier than VALID_TO.")
        end
        local predicate = tostring(representation.coverage_predicate or "")
        local predicate_matches, partition_key =
            predicate_matches_partition_interval(representation)
        if not predicate_matches then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042",
                "Coverage predicate must be canonical half-open SQL over one qualified column: "
                    .. ">= VALID_FROM and < VALID_TO, omitting comparisons for NULL bounds. "
                    .. "Predicate timestamp literals must exactly match the declared interval."
                    .. partition_literal_hint(predicate))
        elseif partition_key == nil then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "Coverage predicate has no certifiable partition key.")
        end
        for alias, _ in pairs(aliases_in_expression(predicate)) do
            if alias ~= upper(representation.alias) then
                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                    "SEMANTIC_MODEL_042", "Coverage predicate references alias outside its representation: "
                        .. tostring(alias) .. ".")
            end
        end
        for function_name, _ in pairs(unsupported_functions(predicate)) do
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "Coverage predicate uses unsupported function: "
                    .. tostring(function_name) .. ".")
        end
        for _, ref in ipairs(column_refs_in_expression(predicate)) do
            if ref.alias == upper(representation.alias)
                and not source_column_exists(representation.source_schema,
                    representation.source_object, ref.column_name) then
                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                    "SEMANTIC_MODEL_042", "Coverage predicate references unknown source column: "
                        .. tostring(ref.column_name) .. ".")
            end
        end
        ordered[#ordered + 1] = representation
    end
    table.sort(ordered, function(left, right)
        if missing(left.valid_from) ~= missing(right.valid_from) then
            return missing(left.valid_from)
        end
        return comparable_timestamp(left.valid_from)
            < comparable_timestamp(right.valid_from)
    end)
    if not missing(ordered[1].valid_from)
        or not missing(ordered[#ordered].valid_to) then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
            "UNION coverage must be open-ended before the first and after the last partition.")
    end
    for index = 2, #ordered do
        local previous = ordered[index - 1]
        local current = ordered[index]
        if missing(previous.valid_to) or missing(current.valid_from)
            or comparable_timestamp(previous.valid_to)
                ~= comparable_timestamp(current.valid_from) then
            add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
                "UNION partition intervals must be contiguous and non-overlapping; boundary mismatch between "
                    .. tostring(previous.name) .. " and " .. tostring(current.name) .. ".")
        end
    end
end

local function missing_representation_columns(ctx, entity, column_name)
    local names = {}
    for _, representation in ipairs(representations_for_entity(ctx, entity)) do
        if not source_column_exists(representation.source_schema,
            representation.source_object, column_name) then
            names[#names + 1] = tostring(representation.name)
        end
    end
    table.sort(names)
    return names
end

local function validate_partition_attribute_bindings(ctx)
    local function validate_attribute(attribute_type, attribute)
        local entity = ctx.entity_by_id[key(attribute.entity_id)]
        if entity == nil or not entity_uses_partition_fusion(ctx, entity) then return end
        local bindings = (ctx.bindings_by_attribute or {})[
            attribute_type .. ":" .. key(attribute.id)] or {}
        local bound_representations = {}
        for _, binding in ipairs(bindings) do
            bound_representations[key(binding.representation_id)] = true
        end
        for _, representation in ipairs(representations_for_entity(ctx, entity)) do
            if not bound_representations[key(representation.id)] then
                local object_name = tostring(attribute.name) .. "@" .. tostring(representation.name)
                add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                    "SEMANTIC_MODEL_052", "Attribute '" .. tostring(attribute.name)
                        .. "' has no binding on partition '" .. tostring(representation.name)
                        .. "' of entity '" .. tostring(entity.name)
                        .. "'. Add it with ADD_ATTRIBUTE_BINDING.")
            end
        end
    end

    for _, dimension in ipairs(ctx.dimensions or {}) do
        validate_attribute("DIMENSION", dimension)
    end
    for _, fact in ipairs(ctx.facts or {}) do
        validate_attribute("FACT", fact)
    end
end

local function complete_semantic_identity(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    for _, identity in ipairs((ctx.identities_by_entity or {})[key(entity.id)] or {}) do
        local complete = #representations > 0
        for _, representation in ipairs(representations) do
            local binding = identity.binding_by_representation
                and identity.binding_by_representation[key(representation.id)] or nil
            if binding == nil or (upper(binding.kind) == "MAPPED"
                and (binding.mapping == nil
                    or upper(binding.mapping.certification) ~= "CERTIFIED")) then
                complete = false
                break
            end
        end
        if complete then return identity end
    end
    return nil
end

local function missing_unique_key_columns(ctx, entity, column_name)
    local identity = complete_semantic_identity(ctx, entity)
    if identity == nil then
        return missing_representation_columns(ctx, entity, column_name)
    end
    local primary = entity.primary_representation
    if primary ~= nil and not source_column_exists(primary.source_schema,
        primary.source_object, column_name) then
        return {tostring(primary.name)}
    end
    return {}
end

-- The semantic identity a named representation has no binding for, when that is
-- why the representation is unusable.
--
-- alternate_representation_remedy below lists all three ways to complete a
-- declaration because it usually cannot tell which one is missing. When the
-- entity carries an F5 identity and this representation has no binding for it,
-- it can tell: that is the only completion that will help. BUG-G04 hit exactly
-- this -- ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY registers an F4
-- representation and there is no compound form that also binds the identity, so
-- the generic three-option remedy was what a modeller following the documented
-- F4-over-F5 use case got.
local function missing_identity_binding_for(ctx, representation_name)
    -- Representation-scoped names arrive as "entity.representation".
    local bare = tostring(representation_name):match("([^%.]+)$")
        or tostring(representation_name)
    for _, representation in ipairs(ctx.representations or {}) do
        if upper(representation.name) == upper(bare) then
            for _, identity in ipairs((ctx.identities_by_entity or {})[
                    key(representation.entity_id)] or {}) do
                local binding = identity.binding_by_representation
                    and identity.binding_by_representation[key(representation.id)]
                    or nil
                if binding == nil then return identity end
            end
            return nil
        end
    end
    return nil
end

-- Name the remedy for a defect that lives in an alternate representation.
--
-- Registering an alternate is accepted on a draft and leaves the model invalid
-- until the declaration is completed (F3 coverage, attribute bindings, or a
-- certified F5 identity). Every later authoring call then fails on the
-- representation rather than on what was attempted, and the recovery --
-- REMOVE_ENTITY_REPRESENTATION -- appeared in no message. The suffix is added
-- only when every named representation is an ALTERNATE: a PRIMARY cannot be
-- removed, so suggesting it would be wrong.
local function alternate_representation_remedy(ctx, names)
    if names == nil or #names == 0 then return "" end
    local role_by_name = {}
    for _, representation in ipairs(ctx.representations or {}) do
        role_by_name[upper(representation.name)] = upper(representation.role)
    end
    for _, name in ipairs(names) do
        -- "entity.representation" for representation-scoped issues.
        local bare = tostring(name):match("([^%.]+)$") or tostring(name)
        if role_by_name[upper(bare)] ~= "ALTERNATE" then return "" end
    end
    local subject = #names == 1 and ("Representation " .. tostring(names[1]))
        or ("Representations " .. table.concat(names, ", "))
    -- When every named representation is unusable for the same, knowable
    -- reason, say which call fixes it instead of offering three.
    local identity_name = nil
    for _, name in ipairs(names) do
        local identity = missing_identity_binding_for(ctx, name)
        if identity == nil then
            identity_name = nil
            break
        end
        identity_name = identity.name
    end
    if identity_name ~= nil then
        return " " .. subject .. " has no binding for semantic identity '"
            .. tostring(identity_name) .. "', which is why it is not yet usable"
            .. " (SEMANTIC_MODEL_060). Add it with ADD_IDENTITY_BINDING -- plus"
            .. " ADD_IDENTITY_MAPPING_RELATION for a MAPPED binding -- or remove"
            .. " the representation with REMOVE_ENTITY_REPRESENTATION."
    end
    return " " .. subject .. " is registered but not yet usable, and blocks"
        .. " unrelated authoring until it is. Complete the declaration (temporal"
        .. " coverage with SET_REPRESENTATION_COVERAGE_BATCH, attribute bindings"
        .. " with ADD_ATTRIBUTE_BINDING, or a certified semantic identity), or"
        .. " remove"
        .. " it with REMOVE_ENTITY_REPRESENTATION."
end

local function representation_suffix(names)
    if names == nil or #names == 0 then return "" end
    return " in representation(s): " .. table.concat(names, ", ")
end

local function identity_binding_remedy()
    return " Attribute bindings do not remap identity or joins. Use a certified semantic identity for representation-local entity keys; relationship join columns still require canonical source views."
end

-- MODEL_ID is functionally determined by VERSION_ID -- MODEL_VERSIONS maps a
-- version to exactly one model -- and stored anyway on 29 tables, because
-- almost every read filters by model and the join would be on every one of
-- them. That trade is worth making. What it costs is that the invariant "this
-- row's MODEL_ID is its version's MODEL_ID" is held up entirely by 29 tables'
-- worth of INSERT statements each remembering to pass both, plus
-- shared/catalog_rollback.lua restoring both from a snapshot. Exasol's foreign
-- keys are declared DISABLE by design, so the engine will not catch a
-- disagreement, and a row filed under the wrong model is invisible: it simply
-- stops being read, or starts being read by the wrong model.
--
-- The table list is derived, not restated. A new catalog table carrying both
-- columns is checked the day it is added, without anyone remembering to append
-- it here -- which is the only way a 29-name list stays correct.
local function validate_catalog_integrity(ctx)
    local tables = query([[
        SELECT COLUMN_TABLE
        FROM SYS.EXA_ALL_COLUMNS
        WHERE COLUMN_SCHEMA = 'SYS_SEMANTIC'
          AND COLUMN_NAME IN ('MODEL_ID', 'VERSION_ID')
          AND COLUMN_OBJECT_TYPE = 'TABLE'
        GROUP BY COLUMN_TABLE
        HAVING COUNT(DISTINCT COLUMN_NAME) = 2
        ORDER BY COLUMN_TABLE
    ]])
    if tables == nil or #tables == 0 then
        return
    end
    local branches = {}
    for _, row in ipairs(tables) do
        local table_name = tostring(row_value(row, "COLUMN_TABLE", 1))
        branches[#branches + 1] = "SELECT '" .. table_name .. "' AS CATALOG_TABLE,"
            .. " COUNT(*) AS MISMATCH_COUNT FROM SYS_SEMANTIC." .. table_name
            .. " WHERE (VERSION_ID = :version_id AND MODEL_ID <> :model_id)"
            .. " OR (MODEL_ID = :model_id AND VERSION_ID NOT IN ("
            .. "SELECT VERSION_ID FROM SYS_SEMANTIC.MODEL_VERSIONS"
            .. " WHERE MODEL_ID = :model_id))"
    end
    local mismatches = query(
        "SELECT CATALOG_TABLE, MISMATCH_COUNT FROM ("
        .. table.concat(branches, " UNION ALL ")
        .. ") WHERE MISMATCH_COUNT > 0 ORDER BY CATALOG_TABLE",
        {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(mismatches or {}) do
        local table_name = tostring(row_value(row, "CATALOG_TABLE", 1))
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_062",
            "Catalog corruption in SYS_SEMANTIC." .. table_name .. ": "
            .. tostring(row_value(row, "MISMATCH_COUNT", 2))
            .. " row(s) name a MODEL_ID that disagrees with the model their "
            .. "VERSION_ID belongs to. A row filed under the wrong model is not "
            .. "read by either. Repair the rows before publishing.")
    end
end

local function validate_structural_rules(ctx)
    local invalid_representation_rows = query([[
        SELECT e.ENTITY_NAME, COUNT(er.REPRESENTATION_ID) AS PRIMARY_COUNT
        FROM SYS_SEMANTIC.ENTITIES e
        LEFT JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        GROUP BY e.ENTITY_ID, e.ENTITY_NAME
        HAVING COUNT(er.REPRESENTATION_ID) <> 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(invalid_representation_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "ENTITY_NAME", 1),
            "SEMANTIC_MODEL_035",
            "Entity must have exactly one active PRIMARY representation; found "
                .. tostring(row_value(row, "PRIMARY_COUNT", 2)) .. ".")
    end
    local representation_names = {}
    for _, representation in ipairs(ctx.representations or {}) do
        local entity = ctx.entity_by_id[key(representation.entity_id)]
        local entity_name = entity and entity.name or tostring(representation.entity_id)
        local object_name = entity_name .. "." .. tostring(representation.name)
        local entity_key = key(representation.entity_id)
        representation_names[entity_key] = representation_names[entity_key] or {}
        local name_key = upper(representation.name)
        if representation_names[entity_key][name_key] then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation name is not unique within the entity.")
        end
        representation_names[entity_key][name_key] = true
        if entity == nil then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation references a missing entity.")
        elseif upper(representation.alias) ~= upper(entity.alias) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representations must use the entity's stable source alias: "
                    .. tostring(entity.alias) .. ".")
        end
        local source_kind = upper(representation.source_kind)
        if source_kind ~= "RELATION" and source_kind ~= "VIRTUAL_SCHEMA" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Unsupported representation source kind: "
                    .. tostring(representation.source_kind) .. ".")
        end
        local role = upper(representation.role)
        if role ~= "PRIMARY" and role ~= "ALTERNATE" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Unsupported representation role: "
                    .. tostring(representation.role) .. ".")
        end
        local priority = tonumber(representation.priority)
        if priority == nil or priority < 1 or priority % 1 ~= 0 then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation priority must be a positive integer.")
        end
        if not source_object_exists(representation.source_schema,
            representation.source_object) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_001", "Source object is not visible: "
                    .. tostring(representation.source_schema) .. "."
                    .. tostring(representation.source_object) .. ".")
        end
    end
    for _, entity in ipairs(ctx.entities) do validate_partition_coverage(ctx, entity) end
    for _, entity in ipairs(ctx.entities) do
        if not missing(entity.primary_key_expr) then
            local owning_alias = upper(entity.alias)
            for alias, _ in pairs(aliases_in_expression(entity.primary_key_expr)) do
                if alias ~= owning_alias then
                    add_issue(ctx, "ERROR", "ENTITY", entity.name,
                        "SEMANTIC_MODEL_036", "Legacy primary-key expression references alias outside the entity: "
                            .. tostring(alias) .. ".")
                end
            end
            local referenced = {}
            for _, ref in ipairs(column_refs_in_expression(entity.primary_key_expr)) do
                local missing_representations =
                    missing_unique_key_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "ENTITY", entity.name,
                        "SEMANTIC_MODEL_036", "Legacy primary-key expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations)
                            .. identity_binding_remedy())
                end
                if ref.alias == owning_alias then
                    referenced[upper(ref.column_name)] = true
                end
            end
            -- The legacy expression is a bootstrap hint, not a proof source, so
            -- nothing else checks it against the declared key. Left unchecked, an
            -- entity can advertise a key expression that is not unique at its own
            -- grain -- exactly what a reader inspecting ENTITIES takes for the key.
            for _, unique_key in ipairs(ctx.unique_keys_by_entity[key(entity.id)] or {}) do
                if upper(unique_key.kind) == "PRIMARY" and #unique_key.columns > 0 then
                    local uncovered = {}
                    for _, column in ipairs(unique_key.columns) do
                        local column_name = column.column_name
                        if not missing(column_name)
                            and not referenced[upper(column_name)] then
                            uncovered[#uncovered + 1] = tostring(column_name)
                        end
                    end
                    if #uncovered > 0 then
                        add_issue(ctx, "WARNING", "ENTITY", entity.name,
                            "SEMANTIC_MODEL_054",
                            "Legacy primary-key expression does not reference every column of "
                                .. "primary key " .. tostring(unique_key.name) .. " ("
                                .. table.concat(uncovered, ", ") .. "), so it is not unique at "
                                .. "the entity's grain. It is a bootstrap hint only: grain proofs "
                                .. "use the declared unique key. Correct the expression or drop it.")
                    end
                end
            end
        end
    end

    local duplicate_alias_rows = query([[
        SELECT UPPER(er.SOURCE_ALIAS) AS SOURCE_ALIAS, COUNT(*) AS ALIAS_COUNT
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        GROUP BY UPPER(er.SOURCE_ALIAS)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(duplicate_alias_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "SOURCE_ALIAS", 1), "SEMANTIC_MODEL_003",
            "Entity alias is not unique within the model version.")
    end

    local reserved_alias_rows = query([[
        SELECT e.ENTITY_NAME, er.SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        JOIN SYS.EXA_SQL_KEYWORDS k
          ON UPPER(k.KEYWORD) = UPPER(er.SOURCE_ALIAS)
         AND k.RESERVED = TRUE
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(reserved_alias_rows or {}) do
        local alias = row_value(row, "SOURCE_ALIAS", 2)
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "ENTITY_NAME", 1), "SEMANTIC_MODEL_034",
            "Entity alias '" .. tostring(alias) .. "' is an Exasol reserved word; choose another alias.")
    end

    local missing_roots = query([[
        SELECT so.OBJECT_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        LEFT JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = so.ROOT_ENTITY_ID
         AND e.MODEL_ID = so.MODEL_ID
         AND e.VERSION_ID = so.VERSION_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND so.STATUS = 'ACTIVE'
          AND e.ENTITY_ID IS NULL
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(missing_roots or {}) do
        add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", row_value(row, "OBJECT_NAME", 1), "SEMANTIC_MODEL_004",
            "Semantic object root entity does not exist in this model version.")
    end

    local invalid_columns = query([[
        SELECT so.OBJECT_NAME, oc.COLUMN_KIND, oc.COLUMN_NAME
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON oc.COLUMN_KIND = 'DIMENSION'
         AND d.DIMENSION_ID = oc.OBJECT_REF_ID
         AND d.MODEL_ID = so.MODEL_ID
         AND d.VERSION_ID = so.VERSION_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON oc.COLUMN_KIND = 'FACT'
         AND f.FACT_ID = oc.OBJECT_REF_ID
         AND f.MODEL_ID = so.MODEL_ID
         AND f.VERSION_ID = so.VERSION_ID
        LEFT JOIN SYS_SEMANTIC.METRICS mt
          ON oc.COLUMN_KIND = 'METRIC'
         AND mt.METRIC_ID = oc.OBJECT_REF_ID
         AND mt.MODEL_ID = so.MODEL_ID
         AND mt.VERSION_ID = so.VERSION_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND (
            oc.COLUMN_KIND NOT IN ('DIMENSION', 'FACT', 'METRIC')
            OR (oc.COLUMN_KIND = 'DIMENSION' AND d.DIMENSION_ID IS NULL)
            OR (oc.COLUMN_KIND = 'FACT' AND f.FACT_ID IS NULL)
            OR (oc.COLUMN_KIND = 'METRIC' AND mt.METRIC_ID IS NULL)
          )
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(invalid_columns or {}) do
        add_issue(ctx, "ERROR", "OBJECT_COLUMN", row_value(row, "OBJECT_NAME", 1) .. "." .. row_value(row, "COLUMN_NAME", 3),
            "SEMANTIC_MODEL_005", "Semantic object column references a missing or unsupported catalog object.")
    end
end

local function custom_extension_scope_exists(ctx, scope_type, scope_id)
    if missing(scope_type) or missing(scope_id) then
        return false
    end
    if scope_type == "MODEL" then
        return key(scope_id) == key(ctx.model_id)
    elseif scope_type == "SEMANTIC_OBJECT" then
        return ctx.semantic_object_by_id[key(scope_id)] ~= nil
    elseif scope_type == "ENTITY" then
        return ctx.entity_by_id[key(scope_id)] ~= nil
    elseif scope_type == "RELATIONSHIP" then
        return ctx.relationship_by_id[key(scope_id)] ~= nil
    elseif scope_type == "DIMENSION" then
        return ctx.dimension_by_id[key(scope_id)] ~= nil
    elseif scope_type == "FACT" then
        return ctx.fact_by_id[key(scope_id)] ~= nil
    elseif scope_type == "METRIC" then
        return ctx.metric_by_id[key(scope_id)] ~= nil
    end
    return false
end

local function extension_object_name(extension)
    return tostring(extension.vendor_name)
        .. "."
        .. tostring(extension.extension_name)
        .. "#"
        .. tostring(extension.id)
end

local function validate_custom_extensions(ctx)
    for _, extension in ipairs(ctx.custom_extensions) do
        local scope_type = upper(extension.scope_type)
        local object_name = extension_object_name(extension)
        if not VALID_EXTENSION_SCOPE_TYPES[scope_type] then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_026",
                "Custom extension has unsupported scope type: " .. tostring(extension.scope_type) .. ".")
        elseif not custom_extension_scope_exists(ctx, scope_type, extension.scope_id) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_026",
                "Custom extension scope does not exist in this model version: "
                .. scope_type .. "#" .. tostring(extension.scope_id) .. ".")
        end

        if missing(extension.vendor_name) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension vendor_name is required.")
        end
        if missing(extension.extension_name) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension extension_name is required.")
        end
        if missing(extension.source_format) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension source_format is required.")
        end
        if not valid_json_text(extension.data_json) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension DATA_JSON must be valid JSON.")
        end
    end
end

local function unique_key_object_name(ctx, unique_key)
    local entity_name = ctx.entity_name_by_id[key(unique_key.entity_id)] or tostring(unique_key.entity_id)
    return entity_name .. "." .. tostring(unique_key.name)
end

local function validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, object_name)
    for alias, _ in pairs(aliases_in_expression(column.expression)) do
        if alias ~= owning_alias then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
                "Unique key expression references alias outside the owning entity: " .. alias .. ".")
        end
    end
    for fn, _ in pairs(unsupported_functions(column.expression)) do
        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
            "Unique key expression uses unsupported function: " .. fn .. ".")
    end
    for _, ref in ipairs(column_refs_in_expression(column.expression)) do
        local missing_representations = missing_unique_key_columns(ctx, entity, ref.column_name)
        if ref.alias == owning_alias and #missing_representations > 0 then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
            "Unique key expression references unknown source column: " .. ref.alias .. "."
                    .. ref.column_name .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations)
                    .. identity_binding_remedy())
        end
    end
end

local function validate_unique_keys(ctx)
    for _, unique_key in ipairs(ctx.unique_keys) do
        local object_name = unique_key_object_name(ctx, unique_key)
        local entity = ctx.entity_by_id[key(unique_key.entity_id)]
        if entity == nil then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key owning entity does not exist in this model version.")
        end

        local key_kind = upper(unique_key.kind)
        if not VALID_UNIQUE_KEY_KINDS[key_kind] then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unsupported unique key kind: " .. tostring(unique_key.kind) .. ".")
        end

        if missing(unique_key.name) then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key name is required.")
        end
        if #unique_key.columns == 0 then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key must contain at least one column or expression.")
        end

        if entity ~= nil then
            local owning_alias = upper(entity.alias)
            for _, column in ipairs(unique_key.columns) do
                local column_name = column.column_name
                local expression = column.expression
                local column_object_name = object_name .. "[" .. tostring(column.ordinal_position) .. "]"
                if missing(column.ordinal_position) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column ordinal position is required.")
                end
                if missing(column_name) and missing(expression) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column must define either COLUMN_NAME or EXPRESSION.")
                elseif not missing(column_name) and not missing(expression) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column must not define both COLUMN_NAME and EXPRESSION.")
                elseif not missing(column_name) then
                    local missing_representations =
                        missing_unique_key_columns(ctx, entity, column_name)
                    if #missing_representations > 0 then
                        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                            "Unique key column references unknown source column: "
                                .. tostring(column_name)
                                .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations)
                                .. identity_binding_remedy())
                    end
                else
                    validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, column_object_name)
                end
            end
        end
    end
end

-- Delegates to the shared resolver so validator probes and compiler rendering
-- agree on the physical spelling of a declared key column. See
-- lua/semantic_layer/shared/source_columns.lua.
local function resolved_source_column_name(representation, column_name)
    return source_columns.resolve(query, representation.source_schema,
        representation.source_object, column_name)
end

local function representation_key_query(representation, unique_key)
    local expressions = {}
    for _, column in ipairs(unique_key.columns or {}) do
        if not missing(column.column_name) then
            local physical_name, resolution_error = resolved_source_column_name(
                representation, column.column_name)
            if physical_name == nil then return nil, resolution_error end
            expressions[#expressions + 1] = tostring(representation.alias)
                .. "." .. sql_text.quote_ident(physical_name)
        elseif not missing(column.expression) then
            expressions[#expressions + 1] = tostring(column.expression)
        end
    end
    if #expressions == 0 then return nil, "declared key has no executable columns" end
    local source = sql_text.quote_qualified(representation.source_schema,
        representation.source_object) .. " " .. tostring(representation.alias)
    return "SELECT " .. table.concat(expressions, ", ")
        .. " FROM " .. source
        .. " GROUP BY " .. table.concat(expressions, ", "), nil
end

local function probe_count(sql_text)
    local ok, rows = pcall(query, sql_text)
    if not ok then return nil, tostring(rows) end
    if rows == nil or #rows == 0 then return nil, "probe returned no rows" end
    return tonumber(row_value(rows[1], "PROBE_COUNT", 1) or 0), nil
end

local function validate_semantic_identities(ctx)
    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    local names = {}
    local identity_counts = {}
    for _, identity in ipairs(ctx.semantic_identities or {}) do
        local entity = ctx.entity_by_id[key(identity.entity_id)]
        local object_name = (entity and entity.name or tostring(identity.entity_id))
            .. "." .. tostring(identity.name)
        local name_key = upper(identity.name)
        if names[name_key] then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity names must be unique within a model.")
        end
        names[name_key] = true
        identity_counts[key(identity.entity_id)] = (identity_counts[key(identity.entity_id)] or 0) + 1
        if identity_counts[key(identity.entity_id)] > 1 then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "An entity may have only one active semantic identity.")
        end
        if entity == nil then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity references an unknown entity.")
        end
        local kind = upper(identity.kind)
        if kind ~= "BUSINESS" and kind ~= "GLOBAL" then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Identity kind must be BUSINESS or GLOBAL.")
        end
        if missing(identity.data_type) then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity data type is required.")
        end
        if entity ~= nil then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if not missing(representation.coverage_predicate)
                    or not missing(representation.valid_from)
                    or not missing(representation.valid_to) then
                    add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                        "SEMANTIC_MODEL_047", "A semantic identity cannot be combined with temporal representation coverage on the same entity.")
                    break
                end
            end
        end
        local seen_representations = {}
        for _, binding in ipairs(identity.bindings or {}) do
            local representation = representation_by_id[key(binding.representation_id)]
            local binding_name = object_name .. "@"
                .. tostring(representation and representation.name or binding.representation_id)
            if missing(binding.expression) then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Source-local identity expression is required.")
            end
            if seen_representations[key(binding.representation_id)] then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Duplicate identity binding for representation.")
            end
            seen_representations[key(binding.representation_id)] = true
            if representation == nil or key(representation.entity_id) ~= key(identity.entity_id)
                or key(binding.entity_id) ~= key(identity.entity_id) then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Identity binding representation or entity is inconsistent.")
            else
                for fn, _ in pairs(unsupported_functions(binding.expression)) do
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                        "SEMANTIC_MODEL_047", "Unsupported function in source-local identity expression: "
                            .. fn .. ".")
                end
                for alias, _ in pairs(aliases_in_expression(binding.expression)) do
                    if alias ~= upper(representation.alias) then
                        add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                            "SEMANTIC_MODEL_047", "Source-local identity expression references alias outside its representation: " .. alias .. ".")
                    end
                end
                for _, ref in ipairs(column_refs_in_expression(binding.expression)) do
                    if ref.alias == upper(representation.alias)
                        and not source_column_exists(representation.source_schema,
                            representation.source_object, ref.column_name) then
                        add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                            "SEMANTIC_MODEL_047", "Source-local identity expression references unknown column: " .. ref.column_name .. ".")
                    end
                end
            end
            local binding_kind = upper(binding.kind)
            if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Identity binding kind must be DIRECT or MAPPED.")
            elseif binding_kind == "DIRECT" and binding.mapping ~= nil then
                add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                    "SEMANTIC_MODEL_048", "DIRECT identity binding must not have a mapping relation.")
            elseif binding_kind == "MAPPED" then
                local mapping = binding.mapping
                if mapping == nil or upper(mapping.certification) ~= "CERTIFIED" then
                    add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                        "SEMANTIC_MODEL_048", "MAPPED identity binding requires one CERTIFIED mapping relation.")
                elseif not source_object_exists(mapping.source_schema, mapping.source_object)
                    or not source_column_exists(mapping.source_schema,
                        mapping.source_object, mapping.local_column)
                    or not source_column_exists(mapping.source_schema,
                        mapping.source_object, mapping.semantic_column) then
                    add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                        "SEMANTIC_MODEL_048", "Certified mapping relation or key columns are not visible.")
                end
            end
        end
        if entity ~= nil and #representations_for_entity(ctx, entity) > 1 then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if not seen_representations[key(representation.id)] then
                    add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                        "SEMANTIC_MODEL_060", "Semantic identity has no binding for active representation: "
                            .. tostring(representation.name) .. ".")
                end
            end
        end
    end
end

local function identity_grouped_key_query(representation, binding)
    local semantic_expression
    local from_sql = sql_text.quote_qualified(representation.source_schema,
        representation.source_object) .. " " .. tostring(representation.alias)
    if upper(binding.kind) == "DIRECT" then
        semantic_expression = tostring(binding.expression)
    else
        local mapping = binding.mapping
        local local_column, semantic_column = identity_join.columns(query, mapping)
        local map_alias = "f5_map_" .. tostring(binding.id)
        semantic_expression = identity_join.key(map_alias, semantic_column)
        from_sql = from_sql .. " JOIN " .. identity_join.mapping_source(mapping)
            .. " " .. map_alias .. " ON "
            .. identity_join.predicate(binding.expression, map_alias, local_column)
    end
    return "SELECT " .. semantic_expression .. " FROM " .. from_sql
        .. " WHERE " .. semantic_expression .. " IS NOT NULL GROUP BY "
        .. semantic_expression
end

local function validate_semantic_identity_data(ctx)
    if (ctx.error_count or 0) > 0 then return end
    for _, identity in ipairs(ctx.semantic_identities or {}) do
        local entity = ctx.entity_by_id[key(identity.entity_id)]
        if entity ~= nil and complete_semantic_identity(ctx, entity) == identity then
            local grouped = {}
            local primary_query = nil
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                local binding = identity.binding_by_representation[key(representation.id)]
                local object_name = tostring(entity.name) .. "." .. tostring(identity.name)
                    .. "@" .. tostring(representation.name)
                local total, total_error = probe_count("SELECT COUNT(*) AS PROBE_COUNT FROM "
                    .. sql_text.quote_qualified(representation.source_schema,
                        representation.source_object))
                local local_distinct, local_error = probe_count(
                    "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                    .. tostring(binding.expression) .. " FROM "
                    .. sql_text.quote_qualified(representation.source_schema,
                        representation.source_object) .. " " .. tostring(representation.alias)
                    .. " WHERE " .. tostring(binding.expression) .. " IS NOT NULL GROUP BY "
                    .. tostring(binding.expression) .. ") f5_local_keys")
                if total_error ~= nil or local_error ~= nil then
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", object_name,
                        "SEMANTIC_MODEL_049", "Could not prove source-local identity uniqueness: "
                            .. tostring(total_error or local_error) .. ".")
                elseif total ~= local_distinct then
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", object_name,
                        "SEMANTIC_MODEL_049", "Source-local identity is null or non-unique: row_count="
                            .. tostring(total) .. ", distinct_key_count=" .. tostring(local_distinct) .. ".")
                end
                if upper(binding.kind) == "MAPPED" then
                    local mapping = binding.mapping
                    local map_local_column, map_semantic_column =
                        identity_join.columns(query, mapping)
                    local map_source = identity_join.mapping_source(mapping)
                    local map_total, map_total_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM " .. map_source)
                    local map_local, map_local_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. sql_text.quote_ident(map_local_column) .. " FROM " .. map_source
                        .. " WHERE " .. sql_text.quote_ident(map_local_column) .. " IS NOT NULL"
                        .. " AND " .. sql_text.quote_ident(map_semantic_column) .. " IS NOT NULL"
                        .. " GROUP BY " .. sql_text.quote_ident(map_local_column) .. ") f5_map_local")
                    local map_semantic, map_semantic_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. sql_text.quote_ident(map_semantic_column) .. " FROM " .. map_source
                        .. " WHERE " .. sql_text.quote_ident(map_local_column) .. " IS NOT NULL"
                        .. " AND " .. sql_text.quote_ident(map_semantic_column) .. " IS NOT NULL"
                        .. " GROUP BY " .. sql_text.quote_ident(map_semantic_column) .. ") f5_map_semantic")
                    local mapped_local, mapped_local_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. tostring(binding.expression) .. " FROM "
                        .. sql_text.quote_qualified(representation.source_schema,
                            representation.source_object) .. " " .. tostring(representation.alias)
                        .. " JOIN " .. map_source .. " f5_total_map ON "
                        .. tostring(binding.expression) .. " = f5_total_map."
                        .. sql_text.quote_ident(map_local_column) .. " GROUP BY "
                        .. tostring(binding.expression) .. ") f5_mapped_local_keys")
                    if map_total_error ~= nil or map_local_error ~= nil
                        or map_semantic_error ~= nil or mapped_local_error ~= nil then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Could not probe certified identity mapping: "
                                .. tostring(map_total_error or map_local_error
                                    or map_semantic_error or mapped_local_error) .. ".")
                    elseif map_total ~= map_local or map_total ~= map_semantic then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Certified identity mapping must be one-to-one: rows="
                                .. tostring(map_total) .. ", local_keys=" .. tostring(map_local)
                                .. ", semantic_keys=" .. tostring(map_semantic) .. ".")
                    elseif mapped_local ~= total then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Certified identity mapping is not total for the representation: source_keys="
                                .. tostring(total) .. ", mapped_source_keys="
                                .. tostring(mapped_local) .. ".")
                    end
                end
                local grouped_query = identity_grouped_key_query(representation, binding)
                grouped[key(representation.id)] = grouped_query
                if upper(representation.role) == "PRIMARY" then
                    primary_query = grouped_query
                end
            end
            if primary_query ~= nil then
                for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                    if upper(representation.role) ~= "PRIMARY" then
                        local alternate_query = grouped[key(representation.id)]
                        local forward, forward_error = probe_count(
                            "SELECT COUNT(*) AS PROBE_COUNT FROM (" .. primary_query
                                .. " MINUS " .. alternate_query .. ") f5_key_difference")
                        local reverse, reverse_error = probe_count(
                            "SELECT COUNT(*) AS PROBE_COUNT FROM (" .. alternate_query
                                .. " MINUS " .. primary_query .. ") f5_key_difference")
                        if forward_error ~= nil or reverse_error ~= nil then
                            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY",
                                tostring(entity.name) .. "." .. tostring(identity.name),
                                "SEMANTIC_MODEL_049", "Could not compare canonical semantic key sets: "
                                    .. tostring(forward_error or reverse_error) .. ".")
                        elseif forward ~= 0 or reverse ~= 0 then
                            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY",
                                tostring(entity.name) .. "." .. tostring(identity.name),
                                "SEMANTIC_MODEL_049", "Canonical semantic key set differs for representation "
                                    .. tostring(representation.name) .. ": missing_in_alternate="
                                    .. tostring(forward) .. ", missing_in_primary=" .. tostring(reverse) .. ".")
                        end
                    end
                end
            end
        end
    end
end

local function relationship_side_identity_remap(ctx, relationship, side,
        entity, representation)
    if entity == nil or representation == nil then
        return nil, "RELATIONSHIP_ENDPOINT_MISSING"
    end
    local unique_key, key_error = grain_graph.scalar_mapping_key(
        ctx.unique_keys_by_entity[key(entity.id)] or {},
        relationship.key_mappings or {}, side)
    if unique_key == nil then return nil, key_error end
    local identity = complete_semantic_identity(ctx, entity)
    if identity == nil then return nil, "COMPLETE_SEMANTIC_IDENTITY_MISSING" end
    return grain_graph.direct_identity_remap(identity,
        entity.primary_representation, representation, unique_key)
end

local function relationship_mapping_side(relationship, entity, ref)
    if entity == nil or upper(entity.alias) ~= ref.alias then return nil end
    local side = key(entity.id) == key(relationship.from_entity_id) and "from"
        or key(entity.id) == key(relationship.to_entity_id) and "to" or nil
    if side == nil then return nil end
    for _, mapping in ipairs(relationship.key_mappings or {}) do
        local column_name = mapping[side .. "_column_name"]
        if not missing(column_name) and upper(column_name) == upper(ref.column_name) then
            return side
        end
    end
    return nil
end

local MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS = 60

local function validate_representation_probe_timeout(ctx)
    local has_multi_representation_probe = false
    for _, entity in ipairs(ctx.entities or {}) do
        if #representations_for_entity(ctx, entity) > 1 then
            has_multi_representation_probe = true
            break
        end
    end
    if not has_multi_representation_probe then return true end

    local ok, rows = pcall(query, [[
        SELECT SESSION_VALUE
        FROM EXA_PARAMETERS
        WHERE PARAMETER_NAME = 'QUERY_TIMEOUT'
    ]])
    local timeout = ok and rows ~= nil and #rows > 0
        and tonumber(row_value(rows[1], "SESSION_VALUE", 1)) or nil
    if timeout == nil or timeout < 1
        or timeout > MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS then
        add_issue(ctx, "PRECONDITION", "MODEL", ctx.model_name,
            "SEMANTIC_MODEL_041",
            "Multi-representation key probes require session QUERY_TIMEOUT between 1 and "
                .. tostring(MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS)
                .. " seconds; current value is " .. tostring(timeout or "unavailable")
                .. ". Run ALTER SESSION SET QUERY_TIMEOUT="
                .. tostring(MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS)
                .. " before EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL."
                .. " Exasol applies the timeout to the complete script.")
        return false
    end
    return true
end

local function validate_representation_data_equivalence(ctx)
    if (ctx.error_count or 0) > 0 then return end
    for _, entity in ipairs(ctx.entities or {}) do
        local representations = representations_for_entity(ctx, entity)
        if #representations > 1 and complete_semantic_identity(ctx, entity) == nil then
            local unique_keys = ctx.unique_keys_by_entity[key(entity.id)] or {}
            if #unique_keys == 0 then
                add_issue(ctx, "ERROR", "ENTITY", entity.name,
                    "SEMANTIC_MODEL_037",
                    "Multiple representations require at least one declared unique key to prove grain and identity equivalence.")
            end
            local primary = entity.primary_representation
            local partitioned = entity_uses_partition_fusion(ctx, entity)
            for _, unique_key in ipairs(unique_keys) do
                local object_name = unique_key_object_name(ctx, unique_key)
                local probes = {}
                for _, representation in ipairs(representations) do
                    local grouped_keys, build_error =
                        representation_key_query(representation, unique_key)
                    local representation_name = tostring(entity.name) .. "."
                        .. tostring(representation.name)
                    local probe = {
                        grouped_keys = grouped_keys,
                        build_error = build_error,
                        representation_name = representation_name,
                    }
                    probes[key(representation.id)] = probe
                    if build_error ~= nil then
                        add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                            representation_name,
                            "SEMANTIC_MODEL_037", "Could not construct declared key probe "
                                .. object_name .. ": " .. tostring(build_error) .. ".")
                    end
                    if grouped_keys ~= nil then
                        local total_sql = "SELECT COUNT(*) AS PROBE_COUNT FROM "
                            .. sql_text.quote_qualified(representation.source_schema,
                                representation.source_object)
                            .. " " .. tostring(representation.alias)
                        local distinct_sql = "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                            .. grouped_keys .. ") representation_keys"
                        probe.total_count, probe.total_error = probe_count(total_sql)
                        probe.distinct_count, probe.distinct_error = probe_count(distinct_sql)
                        local total_count = probe.total_count
                        local total_error = probe.total_error
                        local distinct_count = probe.distinct_count
                        local distinct_error = probe.distinct_error
                        if total_error ~= nil or distinct_error ~= nil then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_037",
                                "Could not prove declared key " .. object_name .. ": "
                                    .. tostring(total_error or distinct_error) .. ".")
                        elseif total_count ~= distinct_count then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_037",
                                "Declared key " .. object_name
                                    .. " does not preserve grain: row_count="
                                    .. tostring(total_count) .. ", distinct_key_count="
                                    .. tostring(distinct_count) .. ".")
                        end

                    end
                end

                local primary_probe = primary ~= nil and probes[key(primary.id)] or nil
                for _, representation in ipairs(partitioned and {} or representations) do
                    if primary ~= nil and key(representation.id) ~= key(primary.id) then
                        local probe = probes[key(representation.id)] or {}
                        local representation_name = probe.representation_name
                            or tostring(entity.name) .. "." .. tostring(representation.name)
                        if primary_probe == nil or primary_probe.build_error ~= nil then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_038",
                                "Could not construct PRIMARY key probe " .. object_name
                                    .. ": " .. tostring(primary_probe and primary_probe.build_error
                                        or "primary representation is unavailable") .. ".")
                        elseif primary_probe.distinct_error ~= nil
                            or probe.distinct_error ~= nil then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Could not compare declared key " .. object_name
                                        .. " with PRIMARY representation: "
                                        .. tostring(primary_probe.distinct_error
                                            or probe.distinct_error) .. ".")
                        elseif primary_probe.distinct_count ~= probe.distinct_count then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_038",
                                "Declared key cardinality differs from PRIMARY for "
                                    .. object_name .. ": primary="
                                    .. tostring(primary_probe.distinct_count)
                                    .. ", alternate=" .. tostring(probe.distinct_count) .. "."
                                    .. alternate_representation_remedy(ctx,
                                        {representation_name}))
                        elseif primary_probe.grouped_keys ~= nil
                            and probe.grouped_keys ~= nil then
                            local missing_from_alternate, forward_error = probe_count(
                                "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                                    .. primary_probe.grouped_keys .. " MINUS "
                                    .. probe.grouped_keys
                                    .. ") representation_key_difference")
                            local missing_from_primary, reverse_error = probe_count(
                                "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                                    .. probe.grouped_keys .. " MINUS "
                                    .. primary_probe.grouped_keys
                                    .. ") representation_key_difference")
                            if forward_error ~= nil or reverse_error ~= nil then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Could not compare declared key set " .. object_name
                                        .. " with PRIMARY representation: "
                                        .. tostring(forward_error or reverse_error) .. ".")
                            elseif missing_from_alternate ~= 0
                                or missing_from_primary ~= 0 then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Declared key set differs from PRIMARY for "
                                        .. object_name .. ": missing_in_alternate="
                                        .. tostring(missing_from_alternate)
                                        .. ", missing_in_primary="
                                        .. tostring(missing_from_primary) .. "."
                                        .. alternate_representation_remedy(ctx,
                                            {representation_name}))
                            end
                        end
                    end
                end
            end
        end
    end
end

local function validate_relationship_key_mappings(ctx)
    local function validate_side(relationship, mapping, side, entity)
        local column_name = mapping[side .. "_column_name"]
        local expression = mapping[side .. "_expression"]
        local has_column = not missing(column_name)
        local has_expression = not missing(expression)
        if has_column == has_expression then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032",
                "Relationship key mapping " .. tostring(mapping.ordinal_position)
                    .. " must define exactly one " .. side .. " column or expression.")
            return
        end
        if has_expression then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032",
                "Expression relationship key mappings are not supported by typed grain proofs; "
                    .. "normalize the expression into a source view and map a column.")
            return
        end
        local unavailable = {}
        local available_count = 0
        if has_column and entity ~= nil then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if source_column_exists(representation.source_schema,
                    representation.source_object, column_name) then
                    available_count = available_count + 1
                else
                    local remap = relationship_side_identity_remap(ctx,
                        relationship, side, entity, representation)
                    if remap ~= nil then
                        available_count = available_count + 1
                    else
                        unavailable[#unavailable + 1] = tostring(representation.name)
                    end
                end
            end
        end
        table.sort(unavailable)
        if has_column and entity ~= nil and available_count == 0 then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032", "No active representation can provide or safely remap the "
                    .. side .. " relationship key column: " .. tostring(column_name)
                    .. "." .. identity_binding_remedy())
        elseif #unavailable > 0 then
            add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_050", "Relationship candidate excludes " .. side
                    .. " representation(s): " .. table.concat(unavailable, ", ")
                    .. "; the endpoint key is absent and no anchored DIRECT identity remap is available.")
        end
    end

    local function side_matches_unique_key(relationship, side, entity_id)
        for _, unique_key in ipairs(ctx.unique_keys_by_entity[key(entity_id)] or {}) do
            if grain_graph.mapping_matches_key(
                relationship.key_mappings, side, unique_key
            ) then
                return true
            end
        end
        return false
    end

    for _, relationship in ipairs(ctx.relationships) do
        local mappings = relationship.key_mappings or {}
        if #mappings == 0 then
            add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_031",
                "Relationship has no structured endpoint key mappings; legacy "
                    .. "single-branch compilation remains available. For grain "
                    .. "proofs, declare a unique key and its ordered columns first, "
                    .. "then add ordered relationship key mappings.")
        else
            local from_entity = ctx.entity_by_id[key(relationship.from_entity_id)]
            local to_entity = ctx.entity_by_id[key(relationship.to_entity_id)]
            for index, mapping in ipairs(mappings) do
                if tonumber(mapping.ordinal_position) ~= index then
                    add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                        "SEMANTIC_MODEL_032",
                        "Relationship key mapping ordinals must be contiguous from 1.")
                end
                validate_side(relationship, mapping, "from", from_entity)
                validate_side(relationship, mapping, "to", to_entity)
            end

            local cardinality = upper(relationship.cardinality)
            local from_unique = side_matches_unique_key(
                relationship, "from", relationship.from_entity_id
            )
            local to_unique = side_matches_unique_key(
                relationship, "to", relationship.to_entity_id
            )
            local uniqueness_ok = true
            if cardinality == "MANY_TO_ONE" then
                uniqueness_ok = to_unique
            elseif cardinality == "ONE_TO_MANY" then
                uniqueness_ok = from_unique
            elseif cardinality == "ONE_TO_ONE" then
                uniqueness_ok = from_unique and to_unique
            end
            if not uniqueness_ok then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_033",
                    "Relationship endpoint mappings do not match the declared "
                        .. "unique key required by cardinality "
                        .. tostring(relationship.cardinality) .. ".")
            end
        end
    end
end

local function relationship_edges(ctx)
    for _, relationship in ipairs(ctx.relationships) do
        local from_exists = ctx.entity_name_by_id[key(relationship.from_entity_id)] ~= nil
        local to_exists = ctx.entity_name_by_id[key(relationship.to_entity_id)] ~= nil
        if not from_exists or not to_exists then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_006",
                "Relationship endpoint does not exist in this model version.")
        end

        local cardinality = upper(relationship.cardinality)
        if not VALID_CARDINALITIES[cardinality] then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_008",
                "Unsupported relationship cardinality: " .. tostring(relationship.cardinality) .. ".")
        end

        local join_type = upper(relationship.join_type)
        if not VALID_JOIN_TYPES[join_type] then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_009",
                "Unsupported relationship join type: " .. tostring(relationship.join_type) .. ".")
        end

        -- The policy records modeler intent for a fanning relationship. It does
        -- not authorize traversal: many-to-many edges stay unsafe for metric
        -- attribution, so any visible metric/dimension pair that needs one is
        -- rejected by the compatibility matrix (SEMANTIC_MODEL_030).
        if cardinality == "MANY_TO_MANY" and missing(relationship.fanout_policy) then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_010",
                "Many-to-many relationship requires an explicit fanout policy. "
                    .. "A policy declares intent and does not make the relationship "
                    .. "traversable for metric attribution.")
        elseif not missing(relationship.fanout_policy) then
            local policy = upper(relationship.fanout_policy)
            if not VALID_FANOUT_POLICIES[policy] then
                add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_053",
                    "Unrecognized fanout policy: " .. tostring(relationship.fanout_policy)
                        .. ". Expected ALLOCATE, DEDUPLICATE, or REFERENCE_ONLY. The value"
                        .. " is recorded but carries no meaning, and no policy authorizes"
                        .. " traversal of a fanning relationship.")
            elseif cardinality ~= "MANY_TO_MANY" then
                add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_053",
                    "Fanout policy " .. policy .. " is declared on a "
                        .. tostring(cardinality) .. " relationship, where it has no"
                        .. " meaning. Traversal against the declared direction is"
                        .. " refused as ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED whether a"
                        .. " policy is present or not.")
            end
        end

        local allowed_aliases = {}
        if from_exists then
            allowed_aliases[ctx.entity_alias_by_id[key(relationship.from_entity_id)]] = true
        end
        if to_exists then
            allowed_aliases[ctx.entity_alias_by_id[key(relationship.to_entity_id)]] = true
        end
        local aliases = aliases_in_expression(relationship.join_condition)
        local alias_count = 0
        for alias, _ in pairs(aliases) do
            alias_count = alias_count + 1
            if not allowed_aliases[alias] then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_007",
                    "Join condition references unknown or out-of-scope alias: " .. alias .. ".")
            end
        end
        if alias_count == 0 then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_007",
                "Join condition must reference the relationship endpoint aliases.")
        end

        local join_refs = column_refs_in_expression(relationship.join_condition)
        for _, ref in ipairs(join_refs) do
            local source_entity = nil
            for _, entity in ipairs(ctx.entities or {}) do
                if upper(entity.alias) == ref.alias then
                    source_entity = entity
                    break
                end
            end
            local missing_representations = source_entity ~= nil
                and missing_representation_columns(ctx, source_entity, ref.column_name) or {}
            local mapped_side = relationship_mapping_side(relationship,
                source_entity, ref)
            if source_entity ~= nil and #missing_representations > 0
                and mapped_side == nil then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_017", "Relationship join condition references unknown source column: "
                        .. ref.alias .. "." .. ref.column_name
                        .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations)
                        .. identity_binding_remedy())
            end
        end

        if simple_relationship_equality(relationship.join_condition)
            and #join_refs == 2 and from_exists and to_exists then
            local from_entity = ctx.entity_by_id[key(relationship.from_entity_id)]
            local to_entity = ctx.entity_by_id[key(relationship.to_entity_id)]
            local from_alias = ctx.entity_alias_by_id[key(relationship.from_entity_id)]
            local to_alias = ctx.entity_alias_by_id[key(relationship.to_entity_id)]
            local from_ref, to_ref
            for _, ref in ipairs(join_refs) do
                if ref.alias == from_alias then from_ref = ref end
                if ref.alias == to_alias then to_ref = ref end
            end
            if from_ref ~= nil and to_ref ~= nil then
                local from_types = entity_column_types(
                    ctx, from_entity, from_ref.column_name)
                local to_types = entity_column_types(
                    ctx, to_entity, to_ref.column_name)
                local incompatible = false
                for _, from_type in ipairs(from_types) do
                    for _, to_type in ipairs(to_types) do
                        if from_type.family ~= to_type.family then
                            incompatible = true
                            break
                        end
                    end
                    if incompatible then break end
                end
                if incompatible then
                    local from_descriptions = {}
                    local to_descriptions = {}
                    for _, item in ipairs(from_types) do
                        from_descriptions[#from_descriptions + 1] = item.descriptor
                    end
                    for _, item in ipairs(to_types) do
                        to_descriptions[#to_descriptions + 1] = item.descriptor
                    end
                    add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                        "SEMANTIC_MODEL_051",
                        "Relationship join endpoints are type-incompatible: "
                            .. tostring(from_alias) .. "."
                            .. tostring(from_ref.column_name) .. " ["
                            .. table.concat(from_descriptions, ", ") .. "] vs "
                            .. tostring(to_alias) .. "."
                            .. tostring(to_ref.column_name) .. " ["
                            .. table.concat(to_descriptions, ", ") .. "].")
                end
            end
        end

    end

    return grain_graph.build_edges(ctx.relationships)
end

local function find_path(edge_map, from_id, to_id, require_safe)
    local proof = grain_graph.prove_path(edge_map, from_id, to_id, {
        require_safe = require_safe,
        reject_ambiguous = true,
    })
    return proof.ok, proof.reason, proof.path, proof
end

local function reachable_aliases(ctx, base_entity_id, safe_edges)
    local aliases = {}
    if missing(base_entity_id) then
        return aliases
    end
    local queue = {base_entity_id}
    local seen = {[key(base_entity_id)] = true}
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        local alias = ctx.entity_alias_by_id[key(current)]
        if alias ~= nil then
            aliases[alias] = true
        end
        for _, edge in ipairs(safe_edges[key(current)] or {}) do
            local next_key = key(edge.to_id)
            if not seen[next_key] then
                seen[next_key] = true
                table.insert(queue, edge.to_id)
            end
        end
    end
    return aliases
end

local function validate_expressions(ctx, safe_edges)
    validate_partition_attribute_bindings(ctx)
    for _, dimension in ipairs(ctx.dimensions) do
        if ctx.entity_name_by_id[key(dimension.entity_id)] == nil then
            add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_004",
                "Dimension owning entity does not exist in this model version.")
        end
        local owning_alias = ctx.entity_alias_by_id[key(dimension.entity_id)]
        for alias, _ in pairs(aliases_in_expression(dimension.expression)) do
            if alias ~= owning_alias then
                add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_013",
                    "Dimension expression references alias outside the owning entity: " .. alias .. ".")
            end
        end
        for fn, _ in pairs(unsupported_functions(dimension.expression)) do
            add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_016",
                "Unsupported function in dimension expression: " .. fn .. ".")
        end
        local entity = ctx.entity_by_id[key(dimension.entity_id)]
        local bindings = (ctx.bindings_by_attribute or {})["DIMENSION:" .. key(dimension.id)] or {}
        local explicit_binding = false
        for _, binding in ipairs(bindings) do
            if binding.is_default ~= true then explicit_binding = true end
        end
        if entity ~= nil and not explicit_binding then
            for _, ref in ipairs(column_refs_in_expression(dimension.expression)) do
                local missing_representations =
                    missing_representation_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_017",
                        "Dimension expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations))
                end
            end
        end
    end

    for _, fact in ipairs(ctx.facts) do
        if ctx.entity_name_by_id[key(fact.entity_id)] == nil then
            add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_004",
                "Fact owning entity does not exist in this model version.")
        end
        local owning_alias = ctx.entity_alias_by_id[key(fact.entity_id)]
        for alias, _ in pairs(aliases_in_expression(fact.expression)) do
            if alias ~= owning_alias then
                add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_013",
                    "Fact expression references alias outside the owning entity: " .. alias .. ".")
            end
        end
        for fn, _ in pairs(unsupported_functions(fact.expression)) do
            add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_016",
                "Unsupported function in fact expression: " .. fn .. ".")
        end
        local entity = ctx.entity_by_id[key(fact.entity_id)]
        local bindings = (ctx.bindings_by_attribute or {})["FACT:" .. key(fact.id)] or {}
        local explicit_binding = false
        for _, binding in ipairs(bindings) do
            if binding.is_default ~= true then explicit_binding = true end
        end
        if entity ~= nil and not explicit_binding then
            for _, ref in ipairs(column_refs_in_expression(fact.expression)) do
                local missing_representations =
                    missing_representation_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_017",
                        "Fact expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations))
                end
            end
        end
    end

    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    local seen = {}
    for _, binding in ipairs(ctx.attribute_bindings or {}) do
        local attribute_type = upper(binding.attribute_type)
        local attribute = attribute_type == "DIMENSION"
            and ctx.dimension_by_id[key(binding.attribute_id)]
            or attribute_type == "FACT" and ctx.fact_by_id[key(binding.attribute_id)] or nil
        local representation = representation_by_id[key(binding.representation_id)]
        local object_name = (attribute and attribute.name or tostring(binding.attribute_id))
            .. "@" .. (representation and representation.name or tostring(binding.representation_id))
        local binding_key = attribute_type .. ":" .. key(binding.attribute_id)
            .. ":" .. key(binding.representation_id)
        if seen[binding_key] then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Duplicate active binding for attribute and representation.")
        end
        seen[binding_key] = true
        if attribute == nil or (attribute_type ~= "DIMENSION" and attribute_type ~= "FACT") then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding references an unknown dimension or fact.")
        elseif key(attribute.entity_id) ~= key(binding.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding entity does not match the attribute owner.")
        end
        if representation == nil or key(representation.entity_id) ~= key(binding.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding representation does not belong to the attribute entity.")
        end
        local role = upper(binding.role)
        if role ~= "PREFER" and role ~= "FALLBACK" then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding role must be PREFER or FALLBACK.")
        end
        local priority = tonumber(binding.priority)
        if priority == nil or priority < 1 or priority % 1 ~= 0 then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding priority must be a positive integer.")
        end
        if attribute ~= nil and representation ~= nil then
            local owning_alias = upper(representation.alias)
            for alias, _ in pairs(aliases_in_expression(binding.expression)) do
                if alias ~= owning_alias then
                    add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                        "SEMANTIC_MODEL_040", "Binding expression references alias outside its representation: "
                            .. tostring(alias) .. ".")
                end
            end
            for fn, _ in pairs(unsupported_functions(binding.expression)) do
                add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                    "SEMANTIC_MODEL_040", "Unsupported function in binding expression: "
                        .. tostring(fn) .. ". Permitted functions: "
                        .. ALLOWED_FUNCTION_NAMES .. ".")
            end
            for _, ref in ipairs(column_refs_in_expression(binding.expression)) do
                if ref.alias == owning_alias and not source_column_exists(
                    representation.source_schema, representation.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                        "SEMANTIC_MODEL_040", "Binding expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name .. ".")
                end
            end
        end
    end

    for _, metric in ipairs(ctx.metrics) do
        if ctx.entity_name_by_id[key(metric.base_entity_id)] == nil then
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_014",
                "Metric base entity does not exist in this model version.")
        end
        for fn, _ in pairs(unsupported_functions(metric.expression)) do
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_016",
                "Unsupported function in metric expression: " .. fn .. ".")
        end
        for fn, _ in pairs(unsupported_functions(metric.filter_expr)) do
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_016",
                "Unsupported function in metric filter expression: " .. fn .. ".")
        end
        local valid_aliases = reachable_aliases(ctx, metric.base_entity_id, safe_edges)
        for alias, _ in pairs(aliases_in_expression(metric.filter_expr)) do
            if not valid_aliases[alias] then
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_013",
                    "Metric filter references an alias not reachable from the metric base entity: " .. alias .. ".")
            end
        end
        for _, ref in ipairs(column_refs_in_expression(metric.filter_expr)) do
            if valid_aliases[ref.alias] then
                local source_entity = nil
                for _, entity in ipairs(ctx.entities) do
                    if upper(entity.alias) == ref.alias then
                        source_entity = entity
                        break
                    end
                end
                local missing_representations = source_entity ~= nil
                    and missing_representation_columns(ctx, source_entity, ref.column_name) or {}
                if source_entity ~= nil and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_017",
                        "Metric filter references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. "."
                            .. alternate_representation_remedy(ctx, missing_representations))
                end
            end
        end
    end
end

local function fusion_attribute(ctx, policy)
    local attribute_type = upper(policy.attribute_type)
    if attribute_type == "DIMENSION" then
        return ctx.dimension_by_id[key(policy.attribute_id)]
    elseif attribute_type == "FACT" then
        return ctx.fact_by_id[key(policy.attribute_id)]
    end
    return nil
end

-- A NULL placeholder that outranks real data.
--
-- Surfacing an attribute only a supplemental source carries is the case fusion
-- exists for, and the authoring API makes you declare the primary's side of it
-- as a literal: ADD_DIMENSION_WITH_BINDINGS takes EXPRESSION for the primary
-- and BINDINGS_JSON for the alternates, so "the primary has no such column"
-- is written CAST(NULL AS VARCHAR(10)). That declaration is correct and
-- necessary. What is not correct is leaving it PREFER.
--
-- The compiler picks a whole representation per entity and then reads that
-- representation's binding for each attribute, and the first key in that
-- choice is how many FALLBACK bindings the candidate needs. So a PREFER
-- placeholder on the primary beats a PREFER binding on the alternate that
-- actually has the data, and every row comes back NULL -- on a model that
-- validates clean, publishes, and answers with STATUS = OK. Nothing else
-- reports it: each binding is individually well-formed, the expression is
-- valid SQL, and the grain proof holds. The pair is the defect.
--
-- Scoped to the pair deliberately. An attribute whose bindings are *all*
-- placeholders is a column that is not available anywhere yet -- a stub, not a
-- wrong answer -- and is left alone.
local function validate_null_placeholder_bindings(ctx)
    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    local attribute_keys = {}
    for attribute_key, _ in pairs(ctx.bindings_by_attribute or {}) do
        attribute_keys[#attribute_keys + 1] = attribute_key
    end
    table.sort(attribute_keys)
    for _, attribute_key in ipairs(attribute_keys) do
        local bindings = ctx.bindings_by_attribute[attribute_key] or {}
        local placeholders = {}
        local real_count = 0
        for _, binding in ipairs(bindings) do
            if sql_text.is_null_literal(binding.expression) then
                if upper(binding.role or "PREFER") ~= "FALLBACK" then
                    placeholders[#placeholders + 1] = binding
                end
            else
                real_count = real_count + 1
            end
        end
        if real_count > 0 then
            for _, binding in ipairs(placeholders) do
                local attribute_type = upper(binding.attribute_type)
                local attribute = attribute_type == "DIMENSION"
                    and ctx.dimension_by_id[key(binding.attribute_id)]
                    or ctx.fact_by_id[key(binding.attribute_id)]
                local representation = representation_by_id[key(binding.representation_id)]
                local attribute_name = attribute and attribute.name
                    or tostring(binding.attribute_id)
                local representation_name = representation and representation.name
                    or tostring(binding.representation_id)
                add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING",
                    attribute_name .. "@" .. representation_name,
                    "SEMANTIC_MODEL_063",
                    "Binding for '" .. attribute_name .. "' on representation '"
                    .. representation_name .. "' is the literal NULL "
                    .. tostring(binding.expression) .. " but carries role "
                    .. tostring(binding.role or "PREFER")
                    .. ", while another representation binds real data. A "
                    .. "placeholder that says 'this source does not have the "
                    .. "column' must not be preferred over one that does, or "
                    .. "every row returns NULL. Give it role FALLBACK: "
                    .. "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING('"
                    .. tostring(ctx.model_name) .. "', '" .. attribute_type
                    .. "', '" .. attribute_name .. "', '" .. representation_name
                    .. "', '" .. tostring(binding.expression) .. "', 'FALLBACK', "
                    .. tostring(binding.priority or 1) .. ").")
            end
        end
    end
end

local function validate_fusion_policies(ctx)
    local representation_by_id = {}
    local authoritative_by_entity = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
        local role = upper(representation.authority_role or "PREFER")
        if role ~= "AUTHORITATIVE" and role ~= "PREFER" and role ~= "SUPPLEMENTAL" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", representation.name,
                "SEMANTIC_MODEL_044", "Authority role must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL.")
        elseif role == "AUTHORITATIVE" then
            local entity_key = key(representation.entity_id)
            authoritative_by_entity[entity_key] =
                (authoritative_by_entity[entity_key] or 0) + 1
        end
    end
    for entity_id, count in pairs(authoritative_by_entity) do
        if count > 1 then
            local entity = ctx.entity_by_id[key(entity_id)]
            add_issue(ctx, "ERROR", "ENTITY", entity and entity.name or entity_id,
                "SEMANTIC_MODEL_044",
                "At most one active representation may be AUTHORITATIVE for an entity.")
        end
    end

    for _, policy in ipairs(ctx.attribute_fusion_policies or {}) do
        local strategy = upper(policy.strategy)
        local attribute = fusion_attribute(ctx, policy)
        local object_name = attribute and attribute.name or tostring(policy.attribute_id)
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        if strategy ~= "PREFER" and strategy ~= "COALESCE" and strategy ~= "RECONCILE" then
            add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                "SEMANTIC_MODEL_044", "Fusion strategy must be PREFER, COALESCE, or RECONCILE.")
        elseif attribute == nil or key(attribute.entity_id) ~= key(policy.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                "SEMANTIC_MODEL_044", "Fusion policy references an unknown or mismatched attribute.")
        elseif strategy ~= "PREFER" then
            local entity = ctx.entity_by_id[key(attribute.entity_id)]
            local bindings = ctx.bindings_by_attribute[attribute_key] or {}
            local contributor_representations = {}
            local authority_count = 0
            for _, binding in ipairs(bindings) do
                local representation = representation_by_id[key(binding.representation_id)]
                if representation ~= nil then
                    contributor_representations[key(representation.id)] = true
                    if upper(representation.authority_role or "PREFER") == "AUTHORITATIVE" then
                        authority_count = authority_count + 1
                    end
                end
            end
            local contributor_count = 0
            for _, _ in pairs(contributor_representations) do
                contributor_count = contributor_count + 1
            end
            if contributor_count < 2 then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044", strategy
                        .. " requires active bindings on at least two representations.")
            end
            if grain_graph.physical_unique_key(ctx.unique_keys_by_entity[key(attribute.entity_id)]) == nil
                and (entity == nil or complete_semantic_identity(ctx, entity) == nil) then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044", strategy
                        .. " requires a complete certified semantic identity or a declared unique key containing physical columns only.")
            end
            if entity ~= nil and entity_uses_partition_fusion(ctx, entity) then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044",
                    "Attribute reconciliation cannot be combined with partition UNION on the same entity.")
            end
            if strategy == "RECONCILE" and authority_count ~= 1 then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044",
                    "RECONCILE requires exactly one bound representation declared AUTHORITATIVE.")
            end
        end
    end
end

local function identity_conflict_source(representation, identity_binding, alias)
    if upper(identity_binding.kind) == "DIRECT" then
        return sql_text.quote_qualified(representation.source_schema,
            representation.source_object),
            sql_text.replace_qualified_alias(identity_binding.expression,
                representation.alias, alias)
    end
    local source_alias = "f5_conflict_src_" .. tostring(representation.id)
    local mapping = identity_binding.mapping
    local local_expression = sql_text.replace_qualified_alias(identity_binding.expression,
        representation.alias, source_alias)
    local source_sql = identity_join.semantic_key_view(query, representation,
        mapping, source_alias,
        "f5_conflict_map_" .. tostring(identity_binding.id), local_expression)
    return source_sql, identity_join.semantic_key_reference(alias)
end

local function fusion_conflict_query(left_representation, left_binding,
        right_representation, right_binding, unique_key, semantic_identity)
    local left_alias = "f4_left"
    local right_alias = "f4_right"
    local predicates = {}
    local left_source = sql_text.quote_qualified(left_representation.source_schema,
        left_representation.source_object)
    local right_source = sql_text.quote_qualified(right_representation.source_schema,
        right_representation.source_object)
    if semantic_identity ~= nil then
        local left_identity = semantic_identity.binding_by_representation[
            key(left_representation.id)]
        local right_identity = semantic_identity.binding_by_representation[
            key(right_representation.id)]
        local left_key, right_key
        left_source, left_key = identity_conflict_source(left_representation,
            left_identity, left_alias)
        right_source, right_key = identity_conflict_source(right_representation,
            right_identity, right_alias)
        predicates[#predicates + 1] = left_key .. " = " .. right_key
    else
        for _, column in ipairs(unique_key.columns or {}) do
            local left_column, left_error = resolved_source_column_name(
                left_representation, column.column_name)
            local right_column, right_error = resolved_source_column_name(
                right_representation, column.column_name)
            if left_column == nil or right_column == nil then
                return nil, left_error or right_error
            end
            predicates[#predicates + 1] = left_alias .. "." .. sql_text.quote_ident(left_column)
                .. " = " .. right_alias .. "." .. sql_text.quote_ident(right_column)
        end
    end
    local left_expression = sql_text.replace_qualified_alias(left_binding.expression,
        left_representation.alias, left_alias)
    local right_expression = sql_text.replace_qualified_alias(right_binding.expression,
        right_representation.alias, right_alias)
    return "SELECT COUNT(*) AS PROBE_COUNT FROM "
        .. left_source .. " " .. left_alias
        .. " JOIN " .. right_source .. " " .. right_alias
        .. " ON " .. table.concat(predicates, " AND ")
        .. " WHERE (" .. left_expression .. ") IS NOT NULL"
        .. " AND (" .. right_expression .. ") IS NOT NULL"
        .. " AND (" .. left_expression .. ") <> (" .. right_expression .. ")", nil
end

local function validate_fusion_conflicts(ctx)
    if (ctx.error_count or 0) > 0 then return end
    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    for _, policy in ipairs(ctx.attribute_fusion_policies or {}) do
        local strategy = upper(policy.strategy)
        if strategy == "COALESCE" or strategy == "RECONCILE" then
            local attribute = fusion_attribute(ctx, policy)
            local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
            local bindings = ctx.bindings_by_attribute[attribute_key] or {}
            local unique_key = attribute and grain_graph.physical_unique_key(ctx.unique_keys_by_entity[key(attribute.entity_id)]) or nil
            local entity = attribute and ctx.entity_by_id[key(attribute.entity_id)] or nil
            local semantic_identity = entity and complete_semantic_identity(ctx, entity) or nil
            local conflict_count = 0
            local probe_error = nil
            for left_index = 1, #bindings - 1 do
                for right_index = left_index + 1, #bindings do
                    local left_binding = bindings[left_index]
                    local right_binding = bindings[right_index]
                    local left_representation = representation_by_id[key(left_binding.representation_id)]
                    local right_representation = representation_by_id[key(right_binding.representation_id)]
                    if left_representation ~= nil and right_representation ~= nil
                        and key(left_representation.id) ~= key(right_representation.id) then
                        local sql_text, build_error = fusion_conflict_query(
                            left_representation, left_binding, right_representation,
                            right_binding, unique_key, semantic_identity)
                        if sql_text == nil then
                            probe_error = build_error
                        else
                            local count, count_error = probe_count(sql_text)
                            if count_error ~= nil then probe_error = count_error
                            else conflict_count = conflict_count + count end
                        end
                    end
                end
            end
            if probe_error ~= nil then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_044", "Could not evaluate representation conflicts: "
                        .. tostring(probe_error) .. ".")
            elseif conflict_count > 0 and strategy == "COALESCE" then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_045", "COALESCE found " .. tostring(conflict_count)
                        .. " overlapping key value(s) with conflicting non-null values; use RECONCILE with one AUTHORITATIVE representation or correct the sources.")
            elseif conflict_count > 0 then
                add_issue(ctx, "WARNING", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_046", "RECONCILE resolved " .. tostring(conflict_count)
                        .. " overlapping key value conflict(s) using the AUTHORITATIVE representation.")
            end
        end
    end
end

-- One trust class for every physical relation the planner may emit into SQL.
--
-- Representations and materializations ask the same question -- is this relation
-- inside the set the layer vouches for? -- and used to be governed by different
-- rules. That is how a materialization built over the raw mart could silently
-- void a representation's row-level security: each was checked on its own terms,
-- neither was compared with the other. One derivation, one table, one answer.
--
-- What this can and cannot prove is worth stating, because the difference is the
-- whole honesty of the feature. It can prove that a view stands between the
-- caller and the base tables, and that a materialization reads the same base
-- tables as the representations it would replace. It cannot prove that the
-- view's predicate is the right policy. Proving the former and claiming the
-- latter is exactly the error the SENSITIVITY_LABEL columns already make.
local function relation_key(schema, object)
    return upper(tostring(schema or "")) .. "." .. upper(tostring(object or ""))
end

local function load_relation_graph()
    local graph = {edges = {}, views = {}}
    -- Only views have dependencies worth walking, and only views can stand
    -- between a caller and a base table. Two bulk reads beat one round trip per
    -- hop: a single dependency lookup measured 127 ms.
    local view_rows = query([[
        SELECT UPPER(VIEW_SCHEMA) AS VIEW_SCHEMA, UPPER(VIEW_NAME) AS VIEW_NAME
        FROM SYS.EXA_ALL_VIEWS
    ]])
    for _, row in ipairs(view_rows or {}) do
        graph.views[relation_key(row_value(row, "VIEW_SCHEMA", 1),
                                row_value(row, "VIEW_NAME", 2))] = true
    end
    local edge_rows = query([[
        SELECT UPPER(OBJECT_SCHEMA) AS OBJECT_SCHEMA, UPPER(OBJECT_NAME) AS OBJECT_NAME,
               UPPER(REFERENCED_OBJECT_SCHEMA) AS REFERENCED_OBJECT_SCHEMA,
               UPPER(REFERENCED_OBJECT_NAME) AS REFERENCED_OBJECT_NAME
        FROM SYS.EXA_ALL_DEPENDENCIES
        WHERE OBJECT_TYPE = 'VIEW'
    ]])
    for _, row in ipairs(edge_rows or {}) do
        local from = relation_key(row_value(row, "OBJECT_SCHEMA", 1),
                                  row_value(row, "OBJECT_NAME", 2))
        local to = relation_key(row_value(row, "REFERENCED_OBJECT_SCHEMA", 3),
                                row_value(row, "REFERENCED_OBJECT_NAME", 4))
        graph.edges[from] = graph.edges[from] or {}
        table.insert(graph.edges[from], to)
    end
    return graph
end

-- Walk to the base tables. Returns the sorted set, and whether the walk was
-- complete: a view with no recorded dependencies is not the same as a table, and
-- answering UNKNOWN is the only honest reply.
local function resolve_base_relations(graph, start_key)
    local bases, seen, pending, resolved = {}, {}, {start_key}, true
    local guard = 0
    while #pending > 0 do
        guard = guard + 1
        if guard > 200 then
            return nil, false
        end
        local current = table.remove(pending)
        if not seen[current] then
            seen[current] = true
            if graph.views[current] then
                local edges = graph.edges[current]
                if edges == nil or #edges == 0 then
                    resolved = false
                else
                    for _, next_key in ipairs(edges) do
                        table.insert(pending, next_key)
                    end
                end
            else
                bases[#bases + 1] = current
            end
        end
    end
    table.sort(bases)
    return bases, resolved
end

local function derive_source_trust(ctx)
    query([[
        DELETE FROM SYS_SEMANTIC.SOURCE_TRUST
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    local governed_mode = upper(tostring(ctx.governance_mode or "OPEN")) == "GOVERNED"
    local graph = load_relation_graph()
    local classified = {}

    local function classify(kind, id, name, schema, object)
        local start_key = relation_key(schema, object)
        local bases, complete = resolve_base_relations(graph, start_key)
        local trust_class
        if bases == nil or not complete then
            trust_class = "UNKNOWN"
        elseif graph.views[start_key] then
            trust_class = "GOVERNED"
        else
            trust_class = "RAW"
        end
        local entry = {kind = kind, id = id, name = name, schema = schema,
                       object = object, bases = bases or {}, class = trust_class}
        classified[#classified + 1] = entry
        return entry
    end

    local representation_bases = {}
    local any_governed_representation = false
    for _, representation in ipairs(ctx.representations or {}) do
        local entry = classify("REPRESENTATION", representation.id, representation.name,
                               representation.source_schema, representation.source_object)
        if entry.class == "GOVERNED" then
            any_governed_representation = true
        end
        for _, base in ipairs(entry.bases) do
            representation_bases[base] = true
        end
    end

    local materialization_rows = query([[
        SELECT MATERIALIZATION_ID, MATERIALIZATION_NAME, PHYSICAL_SCHEMA, PHYSICAL_OBJECT
        FROM SYS_SEMANTIC.MATERIALIZATIONS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(materialization_rows or {}) do
        local entry = classify("MATERIALIZATION",
            row_value(row, "MATERIALIZATION_ID", 1), row_value(row, "MATERIALIZATION_NAME", 2),
            row_value(row, "PHYSICAL_SCHEMA", 3), row_value(row, "PHYSICAL_OBJECT", 4))
        -- A materialization substitutes for a proven branch. If it reads
        -- anything the representations do not, it is not carrying their policy,
        -- whatever else it is: that is how a rollup over the raw mart returned
        -- every region to a principal entitled to one.
        if entry.class ~= "UNKNOWN" then
            for _, base in ipairs(entry.bases) do
                if not representation_bases[base] then
                    entry.class = "DIVERGENT"
                    entry.divergent_base = base
                    break
                end
            end
        end
    end

    for _, entry in ipairs(classified) do
        query([[
            INSERT INTO SYS_SEMANTIC.SOURCE_TRUST (
              MODEL_ID, VERSION_ID, RELATION_KIND, RELATION_ID, RELATION_NAME,
              PHYSICAL_SCHEMA, PHYSICAL_OBJECT, TRUST_CLASS, BASE_RELATIONS
            ) VALUES (
              :model_id, :version_id, :kind, :id, :name,
              :schema, :object, :class, :bases
            )
        ]], {model_id = ctx.model_id, version_id = ctx.version_id,
             kind = entry.kind, id = entry.id, name = entry.name or "",
             schema = entry.schema, object = entry.object, class = entry.class,
             bases = table.concat(entry.bases, ",")})

        local where = entry.kind == "REPRESENTATION" and "representation" or "materialization"
        local label = tostring(entry.name or entry.object)
        -- Divergence is always recorded, but it only costs something when there
        -- is policy to lose. A model whose representations read base tables
        -- directly has none, so warning about a pre-aggregate there would be
        -- noise -- and a warning that means nothing in the common case is how
        -- the one that means something gets ignored.
        if entry.class == "DIVERGENT" and (governed_mode or any_governed_representation) then
            add_issue(ctx, governed_mode and "ERROR" or "WARNING", "MATERIALIZATION", label,
                "SEMANTIC_MODEL_065",
                "Materialization '" .. label .. "' reads "
                .. tostring(entry.divergent_base) .. ", which none of this model's"
                .. " representations read. Substituting it drops whatever row or"
                .. " column policy those representations carry, silently and for"
                .. " every caller. Build it over the same relations the"
                .. " representations use, or retire it with"
                .. " SET_MATERIALIZATION_STATUS.")
        elseif entry.class == "UNKNOWN" then
            add_issue(ctx, governed_mode and "ERROR" or "WARNING", "SOURCE", label,
                "SEMANTIC_MODEL_066",
                "Cannot resolve what " .. where .. " '" .. label .. "' ("
                .. relation_key(entry.schema, entry.object) .. ") reads, so its trust"
                .. " class is unknown. A virtual-schema relation or a view whose"
                .. " dependencies Exasol does not record will do this.")
        elseif entry.class == "RAW" and governed_mode and entry.kind == "REPRESENTATION" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", label,
                "SEMANTIC_MODEL_064",
                "Representation '" .. label .. "' reads the base table "
                .. relation_key(entry.schema, entry.object) .. " directly, and this"
                .. " model runs in GOVERNED mode, where every representation must"
                .. " resolve through a view that can carry row and column policy."
                .. " Point it at a governed view, or set the model back to OPEN"
                .. " with SET_MODEL_GOVERNANCE_MODE.")
        end
    end
end

local function extract_metric_dependencies(ctx)
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID IN (
          SELECT METRIC_ID
          FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id
            AND VERSION_ID = :version_id
        )
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    ctx.metric_edges = {}
    local dependency_seen = {}
    local function add_dependency(metric, object_type, object_id)
        local dep_key = key(metric.id) .. "|" .. object_type .. "|" .. key(object_id)
        if dependency_seen[dep_key] then
            return
        end
        dependency_seen[dep_key] = true
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_DEPENDENCIES (
              METRIC_ID, DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID, DEPENDENCY_KIND
            ) VALUES (
              :metric_id, :object_type, :object_id, 'EXPRESSION'
            )
        ]], {metric_id = metric.id, object_type = object_type, object_id = object_id})
        if object_type == "METRIC" then
            local metric_key = key(metric.id)
            ctx.metric_edges[metric_key] = ctx.metric_edges[metric_key] or {}
            table.insert(ctx.metric_edges[metric_key], key(object_id))
        end
    end

    for _, metric in ipairs(ctx.metrics) do
        for normalized, original in pairs(dependency_tokens(metric.expression)) do
            local fact = ctx.fact_by_name[normalized]
            local dependency_metric = ctx.metric_by_name[normalized]
            if fact ~= nil then
                add_dependency(metric, "FACT", fact.id)
            elseif dependency_metric ~= nil then
                add_dependency(metric, "METRIC", dependency_metric.id)
            else
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_011",
                    "Metric expression references unknown fact or metric: " .. tostring(original) .. ".")
            end
        end
    end
end

local function detect_metric_cycles(ctx)
    local state = {}
    local cycle_seen = {}

    local function visit(metric_id)
        local metric_key = key(metric_id)
        if state[metric_key] == "visiting" then
            if not cycle_seen[metric_key] then
                cycle_seen[metric_key] = true
                local metric = ctx.metric_by_id[metric_key]
                add_issue(ctx, "ERROR", "METRIC", metric and metric.name or metric_key, "SEMANTIC_MODEL_012",
                    "Cyclic metric dependency detected.")
            end
            return
        end
        if state[metric_key] == "visited" then
            return
        end
        state[metric_key] = "visiting"
        for _, next_id in ipairs(ctx.metric_edges[metric_key] or {}) do
            visit(next_id)
        end
        state[metric_key] = "visited"
    end

    for _, metric in ipairs(ctx.metrics) do
        visit(metric.id)
    end
end

local function validate_agent_metadata(ctx)
    local certified_synonyms = query([[
        SELECT UPPER(s.SYNONYM) AS SYNONYM_TEXT, COUNT(*) AS SYNONYM_COUNT
        FROM SYS_SEMANTIC.SYNONYMS s
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON s.OBJECT_TYPE = 'DIMENSION'
         AND d.DIMENSION_ID = s.OBJECT_ID
         AND d.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON s.OBJECT_TYPE = 'FACT'
         AND f.FACT_ID = s.OBJECT_ID
         AND f.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.METRICS mt
          ON s.OBJECT_TYPE = 'METRIC'
         AND mt.METRIC_ID = s.OBJECT_ID
         AND mt.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON s.OBJECT_TYPE = 'SEMANTIC_OBJECT'
         AND so.OBJECT_ID = s.OBJECT_ID
        WHERE s.MODEL_ID = :model_id
          AND s.VERSION_ID = :version_id
          AND (
            d.DIMENSION_ID IS NOT NULL
            OR f.FACT_ID IS NOT NULL
            OR mt.METRIC_ID IS NOT NULL
            OR so.OBJECT_ID IS NOT NULL
          )
        GROUP BY UPPER(s.SYNONYM)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(certified_synonyms or {}) do
        add_issue(ctx, "ERROR", "SYNONYM", row_value(row, "SYNONYM_TEXT", 1), "SEMANTIC_MODEL_021",
            "Certified synonym is ambiguous across multiple semantic objects.")
    end

    for _, metric in ipairs(ctx.metrics) do
        local public_metric = tostring(metric.is_private) ~= "true"
        if public_metric and missing(metric.description) then
            add_issue(ctx, "WARNING", "METRIC", metric.name, "SEMANTIC_MODEL_020",
                "Public metric is missing a description.")
        end
        local numeric_type = string.find(upper(metric.data_type), "DECIMAL") ~= nil
            or string.find(upper(metric.data_type), "DOUBLE") ~= nil
            or string.find(upper(metric.data_type), "INT") ~= nil
            or string.find(upper(metric.data_type), "NUMBER") ~= nil
        if public_metric and numeric_type and missing(metric.unit_hint) and missing(metric.format_hint) then
            add_issue(ctx, "WARNING", "METRIC", metric.name, "SEMANTIC_MODEL_022",
                "Public numeric metric is missing a unit or format hint.")
        end
    end

    local verified_query_rows = query([[
        SELECT vq.VERIFIED_QUERY_ID, vq.QUERY_NAME, vq.OBJECT_ID, vq.REQUEST_JSON
        FROM SYS_SEMANTIC.VERIFIED_QUERIES vq
        LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = vq.OBJECT_ID
         AND so.MODEL_ID = vq.MODEL_ID
         AND so.VERSION_ID = vq.VERSION_ID
        WHERE vq.MODEL_ID = :model_id
          AND vq.VERSION_ID = :version_id
          AND vq.STATUS = 'ACTIVE'
          AND vq.OBJECT_ID IS NOT NULL
          AND so.OBJECT_ID IS NULL
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(verified_query_rows or {}) do
        if not missing(row_value(row, "OBJECT_ID", 3)) then
            add_issue(ctx, "ERROR", "VERIFIED_QUERY", row_value(row, "QUERY_NAME", 2), "SEMANTIC_MODEL_023",
                "Verified query references a missing semantic object.")
        end
    end

    local metric_synonyms = {}
    local dimension_synonyms = {}
    local synonym_rows = query([[
        SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM
        FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE IN ('DIMENSION', 'METRIC')
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(synonym_rows or {}) do
        local object_type = upper(row_value(row, "OBJECT_TYPE", 1))
        local object_id = row_value(row, "OBJECT_ID", 2)
        local synonym = upper(row_value(row, "SYNONYM", 3))
        local index = object_type == "METRIC" and metric_synonyms or dimension_synonyms
        local active = object_type == "METRIC"
            and ctx.metric_by_id[key(object_id)] ~= nil
            or object_type == "DIMENSION" and ctx.dimension_by_id[key(object_id)] ~= nil
        if active then
            index[synonym] = index[synonym] or {}
            index[synonym][key(object_id)] = true
        end
    end

    local function reference_status(canonical, synonyms, name)
        local normalized = upper(name)
        if canonical[normalized] ~= nil then
            return "FOUND"
        end
        local count = 0
        for _ in pairs(synonyms[normalized] or {}) do
            count = count + 1
        end
        if count == 1 then
            return "FOUND"
        elseif count > 1 then
            return "AMBIGUOUS"
        end
        return "UNKNOWN"
    end

    local request_rows = query([[
        SELECT QUERY_NAME, REQUEST_JSON
        FROM SYS_SEMANTIC.VERIFIED_QUERIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(request_rows or {}) do
        local query_name = row_value(row, "QUERY_NAME", 1)
        local request_json = row_value(row, "REQUEST_JSON", 2)
        for _, metric_name in ipairs(extract_json_array_values(request_json, "metrics")) do
            local status = reference_status(ctx.metric_by_name, metric_synonyms, metric_name)
            if status == "UNKNOWN" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown metric: " .. metric_name .. ".")
            elseif status == "AMBIGUOUS" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references ambiguous metric synonym: " .. metric_name .. ".")
            end
        end
        for _, dimension_name in ipairs(extract_json_array_values(request_json, "dimensions")) do
            local status = reference_status(ctx.dimension_by_name, dimension_synonyms, dimension_name)
            if status == "UNKNOWN" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown dimension: " .. dimension_name .. ".")
            elseif status == "AMBIGUOUS" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references ambiguous dimension synonym: " .. dimension_name .. ".")
            end
        end
    end

    local instruction_rows = query([[
        SELECT INSTRUCTION_ID, SCOPE_TYPE, INSTRUCTION_KIND
        FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(instruction_rows or {}) do
        local scope_type = upper(row_value(row, "SCOPE_TYPE", 2))
        local kind = upper(row_value(row, "INSTRUCTION_KIND", 3))
        if not VALID_AGENT_SCOPE_TYPES[scope_type] then
            add_issue(ctx, "ERROR", "AGENT_INSTRUCTION", tostring(row_value(row, "INSTRUCTION_ID", 1)), "SEMANTIC_MODEL_024",
                "Agent instruction has unsupported scope type: " .. scope_type .. ".")
        end
        if not VALID_AGENT_INSTRUCTION_KINDS[kind] then
            add_issue(ctx, "ERROR", "AGENT_INSTRUCTION", tostring(row_value(row, "INSTRUCTION_ID", 1)), "SEMANTIC_MODEL_025",
                "Agent instruction has unsupported instruction kind: " .. kind .. ".")
        end
    end
end

-- Path rendering and unsafe-edge annotation live in the shared graph module so
-- validator provenance and compiler refusals cannot drift apart.
local function attempted_path(all_edges, from_id, to_id)
    return grain_graph.attempted_path(all_edges, from_id, to_id)
end

-- Mirrors the compiler's requirement that an object root can reach a metric
-- base without traversing from one-side to many-side.
local function metric_reachable_from_any_root(ctx, metric, safe_edges, all_edges)
    if #ctx.semantic_objects == 0 then
        return true, nil
    end
    local diagnostic_path = nil
    for _, obj in ipairs(ctx.semantic_objects) do
        local ok, _, _ = find_path(safe_edges, obj.root_entity_id, metric.base_entity_id, true)
        if ok then
            return true, nil
        end
        if diagnostic_path == nil then
            diagnostic_path = attempted_path(all_edges, obj.root_entity_id, metric.base_entity_id)
        end
    end
    return false, diagnostic_path
end

-- Safe paths that lost to the selected one, cached per entity pair.
--
-- A path proof measures ambiguity as "more than one shortest path" and rejects
-- that outright (AMBIGUOUS_RELATIONSHIP_PATH). An alternative of a different
-- length passes the same gate: the shortest path wins, silently. Length is not
-- a statement about meaning, so the model has to say the choice exists.
local function path_alternatives(ctx, safe_edges, from_id, to_id)
    ctx.path_alternatives_cache = ctx.path_alternatives_cache or {}
    local cache_key = key(from_id) .. ">" .. key(to_id)
    local cached = ctx.path_alternatives_cache[cache_key]
    if cached == nil then
        cached = grain_graph.safe_path_alternatives(safe_edges, from_id, to_id)
        ctx.path_alternatives_cache[cache_key] = cached
    end
    return cached
end

-- Definition-time plannability gate.
--
-- A metric whose aggregate has no mergeable state, or whose input grain the
-- planner cannot determine, compiles to nothing: COUNT(*) has no fact input
-- (METRIC_INPUT_GRAIN_MISSING) and AVG on a partitioned entity has no mergeable
-- state. Both used to validate clean, publish, and be reported ready by every
-- agent surface, failing only when someone finally queried them -- and taking
-- SELECT * on the whole object with them.
--
-- The classification is the planner's own (ESV_METRIC_PLAN.build_dag), so the
-- gate cannot drift from what the compiler will decide. It judges each metric
-- alone: a metric that cannot be planned by itself can never be queried, while
-- a combination that only fails together is a request-time concern.
local function entity_is_partitioned(ctx, entity)
    for _, representation in ipairs(representations_for_entity(ctx, entity)) do
        if not missing(representation.coverage_predicate)
            or not missing(representation.valid_from)
            or not missing(representation.valid_to) then
            return true
        end
    end
    return false
end

local function row_count_remedy(metric)
    if upper(metric.aggregation_function) ~= "COUNT"
        and not string.find(upper(tostring(metric.expression or "")), "COUNT", 1, true) then
        return ""
    end
    return " A row count needs something to count: use COUNT(<fact>) over a"
        .. " non-null fact, or declare FACT <name> AS 1 and use SUM(<name>)."
end

-- Leaf (fact) entities of a metric, from the planner's own DAG, cached per
-- validation run. The matrix needs them to tell a metric's own partitioned
-- entity from one it merely joins to.
local function metric_leaf_entities(ctx, metric)
    ctx._metric_leaves = ctx._metric_leaves or {}
    local cached = ctx._metric_leaves[key(metric.id)]
    if cached ~= nil then return cached end
    local fact_by_id = {}
    for _, fact in ipairs(ctx.facts or {}) do
        fact_by_id[key(fact.id)] = fact
    end
    local dag = metric_plan.build_dag(
        {metric_by_id = ctx.metric_by_id, fact_by_id = fact_by_id}, {metric})
    local node = dag ~= nil and dag.node_by_id[key(metric.id)] or nil
    local leaves = {}
    for _, entity_id in ipairs(node ~= nil and node.leaf_entity_ids or {}) do
        leaves[key(entity_id)] = true
    end
    ctx._metric_leaves[key(metric.id)] = leaves
    return leaves
end

local function validate_metric_plannability(ctx)
    if #(ctx.metrics or {}) == 0 then return end
    -- A metric that already failed a structural rule (an unknown fact, a
    -- missing base entity) has no inputs to classify, and the precise error is
    -- already reported. Running the gate on top would add a second, vaguer
    -- diagnostic for the same defect.
    if (ctx.error_count or 0) > 0 then return end
    local fact_by_id = {}
    for _, fact in ipairs(ctx.facts or {}) do
        fact_by_id[key(fact.id)] = fact
    end
    -- The positional ADD_METRIC API records no structured inputs, so the
    -- planner falls back to METRIC_DEPENDENCIES, which extract_metric_dependencies
    -- has just written from the expression text. Read them back and hand the
    -- classification the same fallback the compiler uses, or every metric
    -- authored through that API would look input-less here.
    for _, metric in ipairs(ctx.metrics) do
        metric.dependencies = {}
    end
    for _, row in ipairs(query([[
        SELECT md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md
        JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = md.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id}) or {}) do
        local metric = ctx.metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.dependencies[#metric.dependencies + 1] = {
                object_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 2),
                object_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 3),
            }
        end
    end
    local snapshot = {metric_by_id = ctx.metric_by_id, fact_by_id = fact_by_id}

    -- A metric renders its facts' expressions against its *base* entity's FROM
    -- clause, and nothing brings a fact's own entity into that plan. So a metric
    -- whose base entity is not its facts' entity compiles to SQL that references
    -- an alias it never joins:
    --
    --   SELECT SUM((o.freight_amount)) FROM "MART"."ORDER_LINES" ol
    --
    -- STATUS = OK, validation clean, and `object O.FREIGHT_AMOUNT not found` at
    -- execution. Both directions fail the same way -- a coarser fact under a
    -- finer base and a finer fact under a coarser base -- so this is not about
    -- fan-out safety, which the grain proofs already cover; it is that the
    -- metric's declared grain and its inputs' grain must be the same entity.
    -- Every legitimate metric in the corpus already satisfies it.
    for _, metric in ipairs(ctx.metrics) do
        if not missing(metric.base_entity_id) then
            for _, dependency in ipairs(metric.dependencies or {}) do
                if upper(dependency.object_type) == "FACT" then
                    local fact = fact_by_id[key(dependency.object_id)]
                    if fact ~= nil and not missing(fact.entity_id)
                        and key(fact.entity_id) ~= key(metric.base_entity_id) then
                        local base_entity = ctx.entity_by_id[key(metric.base_entity_id)]
                        local fact_entity = ctx.entity_by_id[key(fact.entity_id)]
                        add_issue(ctx, "ERROR", "METRIC", metric.name,
                            "SEMANTIC_MODEL_061",
                            "Metric is based on entity '"
                                .. tostring(base_entity and base_entity.name
                                    or metric.base_entity_id)
                                .. "' but aggregates fact '" .. tostring(fact.name)
                                .. "', which belongs to entity '"
                                .. tostring(fact_entity and fact_entity.name
                                    or fact.entity_id)
                                .. "'. The fact's expression would be rendered"
                                .. " against the base entity's source without"
                                .. " joining its own, producing SQL that references"
                                .. " an alias it never joins. Base the metric on '"
                                .. tostring(fact_entity and fact_entity.name
                                    or fact.entity_id)
                                .. "', or aggregate a fact that belongs to '"
                                .. tostring(base_entity and base_entity.name
                                    or metric.base_entity_id) .. "'.")
                    end
                end
            end
        end
    end

    for _, metric in ipairs(ctx.metrics) do
        local dag = metric_plan.build_dag(snapshot, {metric})
        local node = dag ~= nil and dag.node_by_id[key(metric.id)] or nil
        if node ~= nil then
            if node.invalid_reason == "METRIC_INPUT_GRAIN_MISSING" then
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_056",
                    "Metric aggregates no fact, so the planner cannot determine its input"
                        .. " grain (METRIC_INPUT_GRAIN_MISSING) and the metric can never be"
                        .. " compiled." .. row_count_remedy(metric))
            elseif node.invalid_reason == "METRIC_INPUT_GRAIN_AMBIGUOUS" then
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_056",
                    "Metric aggregates facts from more than one entity in a single"
                        .. " aggregate state (METRIC_INPUT_GRAIN_AMBIGUOUS), so its input"
                        .. " grain is undefined. Split it into one metric per fact entity"
                        .. " and combine them with a DERIVED metric.")
            elseif node.node_kind == "UNSUPPORTED" or node.node_kind == "LEGACY_AGGREGATE" then
                -- A non-mergeable aggregate is still valid on the single-branch
                -- renderer. It is unqueryable only when the metric's own leaves
                -- force state merging: a partitioned leaf, or more than one.
                local partitioned_name = nil
                for _, entity_id in ipairs(node.leaf_entity_ids or {}) do
                    local entity = ctx.entity_by_id[key(entity_id)]
                    if entity ~= nil and entity_is_partitioned(ctx, entity) then
                        partitioned_name = tostring(entity.name)
                        break
                    end
                end
                local aggregate = tostring(metric.aggregation_function
                    or node.state_class or "this aggregate")
                if partitioned_name ~= nil then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_057",
                        "Metric uses " .. aggregate .. ", which has no mergeable aggregate"
                            .. " state; entity '" .. partitioned_name .. "' is partitioned"
                            .. " (partition fusion supports SUM and COUNT), so the metric can"
                            .. " never be"
                            .. " compiled. Express it with mergeable SUM/COUNT states -- a"
                            .. " RATIO of two such metrics is exact.")
                elseif #(node.leaf_entity_ids or {}) > 1 then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_057",
                        "Metric uses " .. aggregate .. ", which has no mergeable aggregate"
                            .. " state, over facts from " .. tostring(#node.leaf_entity_ids)
                            .. " entities. Multi-entity metrics merge aggregate states, so"
                            .. " the metric can never be compiled. Express it with mergeable"
                            .. " SUM/COUNT states.")
                end
            end
        end
    end
end

-- The partitioned entity a metric/dimension pair would have to join *through*.
--
-- F3 expands partitions only where the entity is a metric's own leaf: that
-- branch is duplicated per partition and the mergeable states are merged.
-- Everywhere else the entity is rendered from its PRIMARY representation, which
-- silently drops the other partitions' rows. The pair-level guard above is keyed
-- on the dimension's own entity, so it never saw an entity that is merely a hop
-- on the way to a dimension beyond it -- and neither did the query-time guard.
-- That is BUG-G01: order_line -> order(F3) -> customer, grouped by a customer
-- attribute, returned 43 700.32 of a true 412 907.22 on a validated, published
-- model.
--
-- The dimension's own entity is excluded here because the caller reports that
-- case separately, with a message about the dimension rather than the traversal.
local function partitioned_join_hop(ctx, metric, proof, dimension_entity_id)
    if proof == nil then return nil end
    local leaves = metric_leaf_entities(ctx, metric)
    for _, edge in ipairs(proof.edges or {}) do
        for _, entity_id in ipairs({edge.from_id, edge.to_id}) do
            local entity_key = key(entity_id)
            if entity_key ~= key(dimension_entity_id)
                and not leaves[entity_key] then
                local entity = ctx.entity_by_id[entity_key]
                if entity ~= nil and entity_is_partitioned(ctx, entity) then
                    return entity
                end
            end
        end
    end
    return nil
end

local function compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    local matrix = {}
    for _, metric in ipairs(ctx.metrics) do
        matrix[key(metric.id)] = {}
        -- Pre-check: the compiler starts joins from the semantic object root. If the
        -- metric base entity is unreachable from any root via safe edges, every
        -- metric/dimension combination is invalid (compiler will return SEMANTIC_REQUEST_042).
        local root_can_reach_metric, root_path = metric_reachable_from_any_root(
            ctx, metric, safe_edges, all_edges)
        for _, dimension in ipairs(ctx.dimensions) do
            local is_valid = false
            local reason_code = "OK"
            local path = nil
            local alternates = nil
            local partition_hop_name = nil
            if not root_can_reach_metric then
                reason_code = "NO_SAFE_JOIN_PATH"
                path = root_path
            elseif ctx.entity_name_by_id[key(metric.base_entity_id)] == nil then
                reason_code = "MISSING_BASE_ENTITY"
            elseif ctx.entity_name_by_id[key(dimension.entity_id)] == nil then
                reason_code = "MISSING_DIMENSION_ENTITY"
            else
                local ok, reason, relationship_path, proof = find_path(safe_edges, metric.base_entity_id, dimension.entity_id, true)
                local dimension_entity = ctx.entity_by_id[key(dimension.entity_id)]
                local hop_entity = ok
                    and partitioned_join_hop(ctx, metric, proof, dimension.entity_id)
                    or nil
                if ok and dimension_entity ~= nil
                    and entity_is_partitioned(ctx, dimension_entity)
                    and not metric_leaf_entities(ctx, metric)[key(dimension.entity_id)] then
                    -- F3 partitions a metric-leaf entity. Reached as a joined
                    -- dimension by a metric based elsewhere, every request for
                    -- the pair is refused by the compiler
                    -- (SEMANTIC_REQUEST_074), so the pair is not valid however
                    -- safe the join path is. Declaring coverage on an entity a
                    -- second object reaches this way used to break that object's
                    -- published dimensions silently.
                    reason_code = "FUSION_PARTITION_DIMENSION_UNSUPPORTED"
                    path = relationship_path
                elseif hop_entity ~= nil then
                    -- BUG-G01: the entity is not where the dimension lives, it
                    -- is on the way there. Same defect, and the one the
                    -- dimension-keyed check above cannot see.
                    reason_code = "FUSION_PARTITION_JOIN_UNSUPPORTED"
                    path = relationship_path
                    partition_hop_name = hop_entity.name
                elseif ok then
                    is_valid = true
                    reason_code = "OK"
                    path = relationship_path
                    alternates = path_alternatives(
                        ctx, safe_edges, metric.base_entity_id, dimension.entity_id)
                else
                    local blocked_path, blocked_reason = attempted_path(
                        all_edges, metric.base_entity_id, dimension.entity_id)
                    path = blocked_path
                    reason_code = blocked_path ~= nil and blocked_reason or reason
                end
            end
            matrix[key(metric.id)][key(dimension.id)] = {
                is_valid = is_valid,
                reason_code = reason_code,
                path = path,
                partition_hop_name = partition_hop_name,
                alternate_paths = alternates ~= nil
                    and #alternates.alternates > 0 and alternates.alternates or nil,
            }
            query([[
                INSERT INTO SYS_SEMANTIC.METRIC_DIMENSION_MATRIX (
                  MODEL_ID, VERSION_ID, METRIC_ID, DIMENSION_ID, IS_VALID,
                  REASON_CODE, RELATIONSHIP_PATH, VALIDATION_RUN_ID, UPDATED_AT
                ) VALUES (
                  :model_id, :version_id, :metric_id, :dimension_id, :is_valid,
                  :reason_code, :relationship_path, :validation_run_id, CURRENT_TIMESTAMP
                )
            ]], {
                model_id = ctx.model_id,
                version_id = ctx.version_id,
                metric_id = metric.id,
                dimension_id = dimension.id,
                is_valid = is_valid,
                reason_code = reason_code,
                relationship_path = null_if_missing(path),
                validation_run_id = ctx.validation_run_id,
            })
        end
    end
    ctx.matrix = matrix
end

-- A semantic object with metrics but no dimensions publishes as a single
-- aggregate column. That is legal, and occasionally intended, but far more
-- often it is the visible symptom of dimensions that were refused while the
-- object was authored (a name already taken elsewhere in the model, say) --
-- and PUBLISH_MODEL only refuses at *zero* columns, so it shipped quietly.
local function validate_object_dimension_coverage(ctx)
    for _, row in ipairs(query([[
        SELECT so.OBJECT_NAME,
               SUM(CASE WHEN oc.COLUMN_KIND = 'DIMENSION' THEN 1 ELSE 0 END) AS DIMENSION_COUNT,
               SUM(CASE WHEN oc.COLUMN_KIND = 'METRIC' THEN 1 ELSE 0 END) AS METRIC_COUNT
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        LEFT JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc
          ON oc.OBJECT_ID = so.OBJECT_ID
         AND oc.IS_VISIBLE = TRUE
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND so.STATUS = 'ACTIVE'
        GROUP BY so.OBJECT_NAME
        ORDER BY so.OBJECT_NAME
    ]], {model_id = ctx.model_id, version_id = ctx.version_id}) or {}) do
        local object_name = row_value(row, "OBJECT_NAME", 1)
        local dimension_count = tonumber(row_value(row, "DIMENSION_COUNT", 2) or 0) or 0
        local metric_count = tonumber(row_value(row, "METRIC_COUNT", 3) or 0) or 0
        if dimension_count == 0 and metric_count > 0 then
            add_issue(ctx, "WARNING", "SEMANTIC_OBJECT", object_name,
                "SEMANTIC_MODEL_058",
                "Semantic view exposes " .. tostring(metric_count)
                    .. " metric(s) and no dimensions, so it publishes as a single"
                    .. " grand-total column and can only be grouped by nothing."
                    .. " If dimensions were meant to be here, check whether they"
                    .. " were refused while authoring -- dimension names are"
                    .. " unique per model (SEMANTIC_ADMIN_019).")
        end
    end
end

-- A metric aggregates at its base entity's grain; the object root decides the
-- grain the aggregate is evaluated at. compute_metric_dimension_matrix proves
-- the root can *reach* the base, which is the attribution question a dimension
-- asks. Aggregation asks the opposite question, and for a MANY_TO_ONE the
-- answers differ: when several root rows share one base row, the join repeats
-- that row and every additive aggregate is multiplied by the fan-out.
--
-- Nothing checked that direction. The matrix reports only through a
-- metric/dimension pair, so a view whose dimensions all sit on safe branches --
-- or which has no dimensions at all -- validated clean, published, and returned
-- an inflated number through both query paths, with every agent surface calling
-- the metric valid. An order-grain freight metric in a line-grain view returns
-- 149 against a truth of 105.25.
--
-- The test is the metric's own base entity, not the fact entities its DAG
-- bottoms out in. Those are different for the multi-fact pattern: a public
-- DERIVED metric based at the root composes private state metrics based at each
-- sibling fact's own grain, and the planner aggregates each in its own branch
-- before joining, so nothing fans out. Walking to the DAG's leaves would refuse
-- that shape -- grain_d1's ticket_count and payment_total reach ticket_fact and
-- payment_fact through the conformed customer dimension -- while the shape is
-- exactly how fan-out is meant to be avoided. The private state metrics are not
-- checked at all: they are not exposed columns, and their whole purpose is to
-- aggregate off-root in a branch of their own.
--
-- The remedy is object membership, not a relationship declaration: FANOUT_POLICY
-- records intent for a many-to-many traversal and is explicitly not an
-- allocation proof (SEMANTIC_MODEL_053 says so for the mirror-image case), so
-- the message points at the root instead of implying a declaration would help.
--
-- The walk is the shared graph's, base -> root, so this cannot drift from the
-- edge-safety rules the compiler plans with.
local function validate_visible_metric_grain(ctx, safe_edges, all_edges)
    local rows = query([[
        SELECT
          so.OBJECT_NAME,
          so.OBJECT_ID,
          mt.METRIC_ID,
          mt.METRIC_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS metric_col
          ON metric_col.OBJECT_ID = so.OBJECT_ID
         AND metric_col.COLUMN_KIND = 'METRIC'
         AND metric_col.IS_VISIBLE = TRUE
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = metric_col.OBJECT_REF_ID
         AND mt.STATUS = 'ACTIVE'
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND so.STATUS = 'ACTIVE'
        ORDER BY so.OBJECT_NAME, mt.METRIC_NAME
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    for _, row in ipairs(rows or {}) do
        local object = ctx.semantic_object_by_id[key(row_value(row, "OBJECT_ID", 2))]
        local metric = ctx.metric_by_id[key(row_value(row, "METRIC_ID", 3))]
        if object ~= nil and metric ~= nil
            and not missing(object.root_entity_id) then
            local root_key = key(object.root_entity_id)
            local root_name = ctx.entity_name_by_id[root_key]
                or tostring(object.root_entity_id)
            local base_key = key(metric.base_entity_id)
            if not missing(metric.base_entity_id) and base_key ~= root_key
                and not find_path(safe_edges, metric.base_entity_id,
                    object.root_entity_id, true) then
                local base_name = ctx.entity_name_by_id[base_key] or base_key
                local attempted = attempted_path(all_edges, metric.base_entity_id,
                    object.root_entity_id)
                local detail = missing(attempted) and ""
                    or " via " .. tostring(attempted)
                add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", object.name,
                    "SEMANTIC_MODEL_059",
                    "Visible metric " .. tostring(metric.name)
                        .. " aggregates at entity '" .. base_name
                        .. "', which is coarser than the root '" .. root_name
                        .. "' of object '" .. tostring(object.name)
                        .. "'" .. detail .. ". Several '" .. root_name
                        .. "' rows share one '" .. base_name .. "' row, so the"
                        .. " join repeats that row and the aggregate is"
                        .. " multiplied by the fan-out -- the number is"
                        .. " silently too high, not merely unprovable. No"
                        .. " relationship declaration makes a fanning"
                        .. " aggregation safe. Expose this metric in a"
                        .. " semantic object rooted at '" .. base_name
                        .. "', or remove it from object '"
                        .. tostring(object.name) .. "'.")
            end
        end
    end
end

local function validate_visible_metric_dimension_pairs(ctx)
    local pairs = query([[
        SELECT
          so.OBJECT_NAME,
          mt.METRIC_ID,
          mt.METRIC_NAME,
          d.DIMENSION_ID,
          d.DIMENSION_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS metric_col
          ON metric_col.OBJECT_ID = so.OBJECT_ID
         AND metric_col.COLUMN_KIND = 'METRIC'
         AND metric_col.IS_VISIBLE = TRUE
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = metric_col.OBJECT_REF_ID
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS dimension_col
          ON dimension_col.OBJECT_ID = so.OBJECT_ID
         AND dimension_col.COLUMN_KIND = 'DIMENSION'
         AND dimension_col.IS_VISIBLE = TRUE
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = dimension_col.OBJECT_REF_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    for _, row in ipairs(pairs or {}) do
        local metric_id = row_value(row, "METRIC_ID", 2)
        local dimension_id = row_value(row, "DIMENSION_ID", 4)
        local matrix_row = ctx.matrix[key(metric_id)] and ctx.matrix[key(metric_id)][key(dimension_id)]
        if matrix_row ~= nil and matrix_row.is_valid
            and matrix_row.alternate_paths ~= nil then
            -- Keyed on the entity pair, not the metric/dimension pair: every
            -- metric on the same base and every dimension on the same entity
            -- share the one choice, and add_issue dedupes the identical text.
            local metric = ctx.metric_by_id[key(metric_id)]
            local dimension = ctx.dimension_by_id[key(dimension_id)]
            local from_name = metric ~= nil
                and (ctx.entity_name_by_id[key(metric.base_entity_id)]
                    or tostring(metric.base_entity_id)) or "?"
            local to_name = dimension ~= nil
                and (ctx.entity_name_by_id[key(dimension.entity_id)]
                    or tostring(dimension.entity_id)) or "?"
            local alternates = {}
            for _, alternate in ipairs(matrix_row.alternate_paths) do
                alternates[#alternates + 1] = tostring(alternate.path)
            end
            add_issue(ctx, "WARNING", "SEMANTIC_OBJECT", row_value(row, "OBJECT_NAME", 1),
                "SEMANTIC_MODEL_055",
                "Entity " .. from_name .. " reaches entity " .. to_name
                    .. " by more than one safe relationship path. Compilation"
                    .. " selects " .. tostring(matrix_row.path)
                    .. " because it is the shortest; not selected: "
                    .. table.concat(alternates, ", ")
                    .. ". The paths can attribute a row of " .. from_name
                    .. " to a different row of " .. to_name .. ", so the choice"
                    .. " decides the number, and path length is not a statement"
                    .. " about meaning. Remove the redundant relationship, or"
                    .. " model the paths as separate entities with their own"
                    .. " dimensions. A tie in length is rejected"
                    .. " (SEMANTIC_MODEL_030 / AMBIGUOUS_RELATIONSHIP_PATH) and"
                    .. " proof mode STRICT_GRAIN refuses either shape.")
        end
        if matrix_row ~= nil and not matrix_row.is_valid then
            local object_name = row_value(row, "OBJECT_NAME", 1)
            local path_detail = missing(matrix_row.path)
                and "" or " via " .. tostring(matrix_row.path)
            local message = "Visible metric " .. tostring(row_value(row, "METRIC_NAME", 3))
                .. " cannot be grouped or filtered by dimension " .. tostring(row_value(row, "DIMENSION_NAME", 5))
                .. ": " .. tostring(matrix_row.reason_code) .. path_detail .. "."
            -- Name the remedy that exists. A fanning traversal has none at
            -- the relationship level, whatever FANOUT_POLICY says, so point at
            -- object membership instead of implying a declaration would help.
            local metric = ctx.metric_by_id[key(metric_id)]
            local dimension = ctx.dimension_by_id[key(dimension_id)]
            local base_name = metric ~= nil
                and (ctx.entity_name_by_id[key(metric.base_entity_id)]
                    or tostring(metric.base_entity_id))
                or nil
            if matrix_row.reason_code == "NO_SAFE_JOIN_PATH" then
                if base_name ~= nil then
                    message = message .. " Declare a semantic object rooted at '"
                        .. base_name .. "', or remove this metric from object '"
                        .. tostring(object_name) .. "'."
                end
            elseif matrix_row.reason_code == "FUSION_PARTITION_JOIN_UNSUPPORTED" then
                local hop = matrix_row.partition_hop_name or "an intermediate entity"
                message = message .. " Entity '" .. tostring(hop)
                    .. "' carries temporal coverage and sits on the join path"
                    .. " between them. Partition fusion expands partitions only"
                    .. " where the"
                    .. " entity is a metric's own leaf, so joining through it"
                    .. " would read its primary partition alone and silently omit"
                    .. " the others. Expose this dimension alongside metrics"
                    .. " based at '" .. tostring(hop) .. "', in this or a"
                    .. " separate semantic object, or remove the coverage"
                    .. " declarations from that entity."
            elseif matrix_row.reason_code == "FUSION_PARTITION_DIMENSION_UNSUPPORTED" then
                local dimension_entity_name = dimension ~= nil
                    and (ctx.entity_name_by_id[key(dimension.entity_id)]
                        or tostring(dimension.entity_id)) or "the dimension's entity"
                message = message .. " Entity '" .. dimension_entity_name
                    .. "' carries temporal coverage, which applies only to an"
                    .. " entity a metric is based on. Expose this dimension only"
                    .. " alongside metrics based at '" .. dimension_entity_name
                    .. "', in this or a separate semantic object, or remove the"
                    .. " coverage declarations from that entity."
            elseif FANOUT_REASONS[tostring(matrix_row.reason_code)] and base_name ~= nil then
                message = message .. " No relationship declaration makes a fanning"
                    .. " traversal safe. Expose this metric only alongside dimensions"
                    .. " reachable from '" .. base_name .. "' without fan-out, in this"
                    .. " or a separate semantic object, or remove one of the two from"
                    .. " object '" .. tostring(object_name) .. "'."
            end
            add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", object_name,
                "SEMANTIC_MODEL_030", message)
        end
    end
end

-- Lead with the cause, not a consequence.
--
-- Every admin DDL wrapper reports validation_errors[1], so this order decides
-- which single sentence a refused authoring call shows. A representation
-- registered without its identity binding makes every attribute, key and
-- expression check fail against it, and those knock-ons come from rules that run
-- earlier -- so the actionable error sat second or later and the caller was
-- pointed at a dimension that was never wrong (BUG-G04).
--
-- Only that one condition is promoted. It used to live under
-- SEMANTIC_MODEL_047, alongside thirteen other identity defects that are causes
-- in their own right but not causes *of other issues* -- so this function had to
-- find it by searching the message text for "no binding for active
-- representation", which is a sentence anyone could reword. Giving the condition
-- its own code, SEMANTIC_MODEL_060, is what lets the test below be a comparison.
-- Stable within each group, so a model without a missing binding keeps its order
-- exactly.
local function order_root_cause_first(issues)
    local leading, trailing = {}, {}
    for _, issue in ipairs(issues or {}) do
        if issue.rule_code == "SEMANTIC_MODEL_060" then
            leading[#leading + 1] = issue
        else
            trailing[#trailing + 1] = issue
        end
    end
    if #leading == 0 then return issues end
    for _, issue in ipairs(trailing) do leading[#leading + 1] = issue end
    return leading
end

function M.validate_model(model_name_arg)
    local ctx = {
        issues = {},
        issue_seen = {},
        error_count = 0,
        precondition_count = 0,
        warning_count = 0,
    }

    local model_loaded = load_model(ctx, model_name_arg)
    if model_loaded then
        load_catalog(ctx)
        validate_catalog_integrity(ctx)
        validate_structural_rules(ctx)
        validate_custom_extensions(ctx)
        validate_semantic_identities(ctx)
        validate_unique_keys(ctx)
        validate_relationship_key_mappings(ctx)
        local safe_edges, all_edges = relationship_edges(ctx)
        validate_expressions(ctx, safe_edges)
        validate_fusion_policies(ctx)
        validate_null_placeholder_bindings(ctx)
        extract_metric_dependencies(ctx)
        derive_source_trust(ctx)
        detect_metric_cycles(ctx)
        validate_agent_metadata(ctx)
        validate_metric_plannability(ctx)
        validate_object_dimension_coverage(ctx)
        compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
        validate_visible_metric_grain(ctx, safe_edges, all_edges)
        validate_visible_metric_dimension_pairs(ctx)
        -- Remote equivalence proofs are full data scans. Do not launch them
        -- for a model that is already invalid on local catalog metadata.
        if ctx.error_count == 0 and validate_representation_probe_timeout(ctx) then
            validate_representation_data_equivalence(ctx)
            validate_semantic_identity_data(ctx)
            validate_fusion_conflicts(ctx)
        end
        -- Every admin DDL script (ADD_*, REMOVE_*, PUBLISH_MODEL) calls
        -- VALIDATE_MODEL after mutating the catalog. Invalidating compile-cache
        -- entries here gives all those callers cache-coherent compile results
        -- without each one needing its own DELETE.
        query([[
            DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
            WHERE MODEL_VERSION_ID = :version_id
        ]], {version_id = ctx.version_id})
    end

    ctx.issues = order_root_cause_first(ctx.issues)
    finish_validation_run(ctx)
    return ctx.issues
end

validate_model = M.validate_model

-- Test-only pure helpers. See the equivalent compiler block for why this is
-- gated instead of becoming part of the installed runtime contract.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_VALIDATOR_TEST_API = {
        relation_key = relation_key,
        resolve_base_relations = resolve_base_relations,
        derive_source_trust = derive_source_trust,
        valid_json_text = valid_json_text,
        strip_string_literals = sql_text.strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        column_refs_in_expression = column_refs_in_expression,
        schema_qualified_functions = schema_qualified_functions,
        unsupported_functions = unsupported_functions,
        dependency_tokens = dependency_tokens,
        extract_json_array_values = extract_json_array_values,
        source_object_exists = source_object_exists,
        source_column_exists = source_column_exists,
        validate_catalog_integrity = validate_catalog_integrity,
        validate_structural_rules = validate_structural_rules,
        validate_partition_coverage = validate_partition_coverage,
        parse_partition_predicate = parse_partition_predicate,
        validate_partition_attribute_bindings = validate_partition_attribute_bindings,
        entity_has_base_metric = entity_has_base_metric,
        validate_custom_extensions = validate_custom_extensions,
        validate_unique_keys = validate_unique_keys,
        validate_representation_probe_timeout = validate_representation_probe_timeout,
        validate_representation_data_equivalence = validate_representation_data_equivalence,
        validate_semantic_identities = validate_semantic_identities,
        validate_semantic_identity_data = validate_semantic_identity_data,
        validate_fusion_policies = validate_fusion_policies,
        validate_null_placeholder_bindings = validate_null_placeholder_bindings,
        validate_fusion_conflicts = validate_fusion_conflicts,
        validate_relationship_key_mappings = validate_relationship_key_mappings,
        relationship_edges = relationship_edges,
        find_path = find_path,
        validate_expressions = validate_expressions,
        extract_metric_dependencies = extract_metric_dependencies,
        detect_metric_cycles = detect_metric_cycles,
        validate_agent_metadata = validate_agent_metadata,
        validate_metric_plannability = validate_metric_plannability,
        validate_object_dimension_coverage = validate_object_dimension_coverage,
        alternate_representation_remedy = alternate_representation_remedy,
        order_root_cause_first = order_root_cause_first,
        compute_metric_dimension_matrix = compute_metric_dimension_matrix,
        validate_visible_metric_dimension_pairs = validate_visible_metric_dimension_pairs,
        validate_visible_metric_grain = validate_visible_metric_grain,
    }
end
