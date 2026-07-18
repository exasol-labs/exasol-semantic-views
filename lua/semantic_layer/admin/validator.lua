local M = {}

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
    MAX = true,
    MIN = true,
    MONTH = true,
    NULLIF = true,
    ROUND = true,
    SUM = true,
    TO_CHAR = true,
    TO_DATE = true,
    YEAR = true,
}

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or row_value(rows[1], "COUNT", 1) or row_value(rows[1], "MAX", 1) or rows[1][1]
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

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function parse_json_text(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function is_digit(c)
        return string.match(c, "^%d$") ~= nil
    end

    local function is_hex(c)
        return string.match(c, "^[0-9A-Fa-f]$") ~= nil
    end

    local function read_digits()
        local count = 0
        while is_digit(peek()) do
            count = count + 1
            pos = pos + 1
        end
        return count
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return true
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" or e == "b" or e == "f"
                    or e == "n" or e == "r" or e == "t" then
                    pos = pos + 2
                elseif e == "u" then
                    for offset = 2, 5 do
                        if not is_hex(string.sub(text, pos + offset, pos + offset)) then
                            error("invalid unicode escape at byte " .. tostring(pos))
                        end
                    end
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            elseif c == "" or string.byte(c) < 32 then
                error("invalid control character in string at byte " .. tostring(pos))
            else
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        if peek() == "-" then
            pos = pos + 1
        end
        if peek() == "0" then
            pos = pos + 1
        elseif string.match(peek(), "^[1-9]$") then
            read_digits()
        else
            error("invalid number at byte " .. tostring(start_pos))
        end
        if peek() == "." then
            pos = pos + 1
            if read_digits() == 0 then
                error("invalid number fraction at byte " .. tostring(pos))
            end
        end
        local c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            if read_digits() == 0 then
                error("invalid number exponent at byte " .. tostring(pos))
            end
        end
        return true
    end

    local function parse_array()
        pos = pos + 1
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return true
        end
        while true do
            parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return true
        end
        while true do
            skip_ws()
            parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or is_digit(c) then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return true
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return true
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return true
end

local function valid_json_text(text)
    local ok, _ = pcall(parse_json_text, text)
    return ok
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
          WHERE TABLE_SCHEMA = UPPER(:schema_name)
            AND TABLE_NAME = UPPER(:object_name)
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE VIEW_SCHEMA = UPPER(:schema_name)
            AND VIEW_NAME = UPPER(:object_name)
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name}) > 0
end

local function source_column_exists(schema_name, object_name, column_name)
    return count_query([[
        SELECT COUNT(*)
        FROM SYS.EXA_ALL_COLUMNS
        WHERE COLUMN_SCHEMA = UPPER(:schema_name)
          AND COLUMN_TABLE = UPPER(:object_name)
          AND COLUMN_NAME = UPPER(:column_name)
    ]], {schema_name = schema_name, object_name = object_name, column_name = column_name}) > 0
end

local function strip_string_literals(text)
    local out = {}
    local in_quote = false
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                out[#out + 1] = " "
                out[#out + 1] = " "
                i = i + 2
            else
                in_quote = not in_quote
                out[#out + 1] = " "
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = " "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function aliases_in_expression(expression)
    local aliases = {}
    if missing(expression) then
        return aliases
    end
    local text = strip_string_literals(tostring(expression))
    local pos = 1
    while true do
        local start_pos, end_pos, alias = string.find(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.[%s]*[A-Za-z_][A-Za-z0-9_]*", pos)
        if start_pos == nil then
            break
        end
        local next_char = string.sub(text, end_pos + 1, end_pos + 1)
        if next_char ~= "(" then
            aliases[upper(alias)] = true
        end
        pos = end_pos + 1
    end
    return aliases
end

local function column_refs_in_expression(expression)
    local refs = {}
    if missing(expression) then
        return refs
    end
    local text = strip_string_literals(tostring(expression))
    for alias, column_name in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)") do
        local after = string.sub(text, string.find(text, alias .. "%s*%.%s*" .. column_name, 1) or 1)
        refs[#refs + 1] = {alias = upper(alias), column_name = upper(column_name)}
    end
    return refs
end

local function schema_qualified_functions(expression)
    local functions = {}
    if missing(expression) then
        return functions
    end
    local text = strip_string_literals(tostring(expression))
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
    local text = strip_string_literals(tostring(expression))
    local qualified = schema_qualified_functions(expression)
    for fn in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
        local normalized = upper(fn)
        local schema_qualified = false
        for qualified_name, _ in pairs(qualified) do
            if string.match(qualified_name, "%." .. normalized .. "$") then
                schema_qualified = true
                break
            end
        end
        if not schema_qualified and not ALLOWED_FUNCTIONS[normalized] then
            found[normalized] = true
        end
    end
    return found
end

local function dependency_tokens(expression)
    local tokens = {}
    if missing(expression) then
        return tokens
    end
    local text = strip_string_literals(tostring(expression))
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
          mv.VERSION_NUMBER
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
    start_validation_run(ctx)

    if missing(ctx.version_id) then
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_002", "Model has no active version.")
        return false
    end
    return true
end

local function load_catalog(ctx)
    ctx.entities = {}
    ctx.entity_by_id = {}
    ctx.entity_alias_by_id = {}
    ctx.entity_name_by_id = {}
    ctx.entity_id_by_name = {}
    local entity_rows = query([[
        SELECT ENTITY_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local id = row_value(row, "ENTITY_ID", 1)
        local entity = {
            id = id,
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
        }
        table.insert(ctx.entities, entity)
        ctx.entity_by_id[key(id)] = entity
        ctx.entity_alias_by_id[key(id)] = upper(entity.alias)
        ctx.entity_name_by_id[key(id)] = tostring(entity.name)
        ctx.entity_id_by_name[upper(entity.name)] = id
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

    ctx.metrics = {}
    ctx.metric_by_id = {}
    ctx.metric_by_name = {}
    local metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION, FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DESCRIPTION, UNIT_HINT, FORMAT_HINT,
               IS_PRIVATE, IS_CERTIFIED
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
        }
        table.insert(ctx.metrics, metric)
        ctx.metric_by_id[key(id)] = metric
        ctx.metric_by_name[upper(metric.name)] = metric
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
        }
        table.insert(ctx.relationships, relationship)
        ctx.relationship_by_id[key(id)] = relationship
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

local function validate_structural_rules(ctx)
    for _, entity in ipairs(ctx.entities) do
        if not source_object_exists(entity.source_schema, entity.source_object) then
            add_issue(ctx, "ERROR", "ENTITY", entity.name, "SEMANTIC_MODEL_001",
                "Source object is not visible: " .. tostring(entity.source_schema) .. "." .. tostring(entity.source_object) .. ".")
        end
    end

    local duplicate_alias_rows = query([[
        SELECT UPPER(SOURCE_ALIAS) AS SOURCE_ALIAS, COUNT(*) AS ALIAS_COUNT
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        GROUP BY UPPER(SOURCE_ALIAS)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(duplicate_alias_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "SOURCE_ALIAS", 1), "SEMANTIC_MODEL_003",
            "Entity alias is not unique within the model version.")
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
        if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
                "Unique key expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
                    if not source_column_exists(entity.source_schema, entity.source_object, column_name) then
                        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                            "Unique key column references unknown source column: " .. tostring(column_name) .. ".")
                    end
                else
                    validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, column_object_name)
                end
            end
        end
    end
end

local function relationship_edges(ctx)
    local edges = {}
    local all_edges = {}
    local function add_edge(target, from_id, to_id, relationship, safe, reason)
        local from_key = key(from_id)
        target[from_key] = target[from_key] or {}
        table.insert(target[from_key], {
            to_id = to_id,
            name = relationship.name,
            safe = safe,
            reason = reason,
        })
    end

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

        if cardinality == "MANY_TO_MANY" and missing(relationship.fanout_policy) then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_010",
                "Many-to-many relationship requires an explicit fanout policy.")
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

        if from_exists and to_exists and VALID_CARDINALITIES[cardinality] then
            if cardinality == "ONE_TO_ONE" then
                add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, "OK")
            elseif cardinality == "MANY_TO_ONE" then
                add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            elseif cardinality == "ONE_TO_MANY" then
                add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            elseif cardinality == "MANY_TO_MANY" then
                local safe = not missing(relationship.fanout_policy)
                local reason = safe and "OK" or "MANY_TO_MANY_REQUIRES_FANOUT"
                if safe then
                    add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, reason)
                    add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, reason)
                end
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, safe, reason)
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, safe, reason)
            end

            if cardinality ~= "MANY_TO_MANY" then
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            end
        end
    end

    return edges, all_edges
end

local function find_path(edge_map, from_id, to_id, require_safe)
    if missing(from_id) or missing(to_id) then
        return false, "MISSING_ENTITY", nil
    end
    if key(from_id) == key(to_id) then
        return true, "OK", "SELF"
    end

    local queue = {{id = from_id, path = {}}}
    local seen = {[key(from_id)] = true}
    local first_blocked_reason = nil
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        for _, edge in ipairs(edge_map[key(current.id)] or {}) do
            if require_safe and not edge.safe then
                first_blocked_reason = first_blocked_reason or edge.reason
            else
                local next_key = key(edge.to_id)
                if not seen[next_key] then
                    local next_path = {}
                    for _, name in ipairs(current.path) do
                        table.insert(next_path, name)
                    end
                    table.insert(next_path, edge.name)
                    if next_key == key(to_id) then
                        return true, "OK", table.concat(next_path, " > ")
                    end
                    seen[next_key] = true
                    table.insert(queue, {id = edge.to_id, path = next_path})
                end
            end
        end
    end
    return false, first_blocked_reason or "NO_RELATIONSHIP_PATH", nil
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
        if entity ~= nil then
            for _, ref in ipairs(column_refs_in_expression(dimension.expression)) do
                if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_017",
                        "Dimension expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
        if entity ~= nil then
            for _, ref in ipairs(column_refs_in_expression(fact.expression)) do
                if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_017",
                        "Fact expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
                if source_entity ~= nil and not source_column_exists(source_entity.source_schema, source_entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_017",
                        "Metric filter references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
                end
            end
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
            if ctx.metric_by_name[upper(metric_name)] == nil then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown metric: " .. metric_name .. ".")
            end
        end
        for _, dimension_name in ipairs(extract_json_array_values(request_json, "dimensions")) do
            if ctx.dimension_by_name[upper(dimension_name)] == nil then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown dimension: " .. dimension_name .. ".")
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

-- Returns true if metric.base_entity_id is reachable via safe_edges from at least one
-- semantic object root entity. Mirrors the compiler join-resolution starting point.
local function metric_reachable_from_any_root(ctx, metric, safe_edges)
    if #ctx.semantic_objects == 0 then
        return true  -- no objects loaded, skip the check
    end
    for _, obj in ipairs(ctx.semantic_objects) do
        local ok, _, _ = find_path(safe_edges, obj.root_entity_id, metric.base_entity_id, true)
        if ok then
            return true
        end
    end
    return false
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
        local root_can_reach_metric = metric_reachable_from_any_root(ctx, metric, safe_edges)
        for _, dimension in ipairs(ctx.dimensions) do
            local is_valid = false
            local reason_code = "OK"
            local path = nil
            if not root_can_reach_metric then
                reason_code = "NO_SAFE_JOIN_PATH"
            elseif ctx.entity_name_by_id[key(metric.base_entity_id)] == nil then
                reason_code = "MISSING_BASE_ENTITY"
            elseif ctx.entity_name_by_id[key(dimension.entity_id)] == nil then
                reason_code = "MISSING_DIMENSION_ENTITY"
            else
                local ok, reason, relationship_path = find_path(safe_edges, metric.base_entity_id, dimension.entity_id, true)
                if ok then
                    is_valid = true
                    reason_code = "OK"
                    path = relationship_path
                else
                    local connected = find_path(all_edges, metric.base_entity_id, dimension.entity_id, false)
                    reason_code = connected and "FANOUT_REQUIRES_POLICY" or reason
                end
            end
            matrix[key(metric.id)][key(dimension.id)] = {
                is_valid = is_valid,
                reason_code = reason_code,
                path = path,
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
        if matrix_row ~= nil and not matrix_row.is_valid then
            add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", row_value(row, "OBJECT_NAME", 1), "SEMANTIC_MODEL_030",
                "Visible metric " .. tostring(row_value(row, "METRIC_NAME", 3))
                .. " cannot be grouped or filtered by dimension " .. tostring(row_value(row, "DIMENSION_NAME", 5))
                .. ": " .. tostring(matrix_row.reason_code) .. ".")
        end
    end
end

function M.validate_model(model_name_arg)
    local ctx = {
        issues = {},
        issue_seen = {},
        error_count = 0,
        warning_count = 0,
    }

    local model_loaded = load_model(ctx, model_name_arg)
    if model_loaded then
        load_catalog(ctx)
        validate_structural_rules(ctx)
        validate_custom_extensions(ctx)
        validate_unique_keys(ctx)
        local safe_edges, all_edges = relationship_edges(ctx)
        validate_expressions(ctx, safe_edges)
        extract_metric_dependencies(ctx)
        detect_metric_cycles(ctx)
        validate_agent_metadata(ctx)
        compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
        validate_visible_metric_dimension_pairs(ctx)
        -- Every admin DDL script (ADD_*, REMOVE_*, PUBLISH_MODEL) calls
        -- VALIDATE_MODEL after mutating the catalog. Invalidating compile-cache
        -- entries here gives all those callers cache-coherent compile results
        -- without each one needing its own DELETE.
        query([[
            DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
            WHERE MODEL_VERSION_ID = :version_id
        ]], {version_id = ctx.version_id})
    end

    finish_validation_run(ctx)
    return ctx.issues
end

validate_model = M.validate_model

-- Test-only pure helpers. See the equivalent compiler block for why this is
-- gated instead of becoming part of the installed runtime contract.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_VALIDATOR_TEST_API = {
        parse_json_text = parse_json_text,
        valid_json_text = valid_json_text,
        strip_string_literals = strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        column_refs_in_expression = column_refs_in_expression,
        schema_qualified_functions = schema_qualified_functions,
        unsupported_functions = unsupported_functions,
        dependency_tokens = dependency_tokens,
        extract_json_array_values = extract_json_array_values,
        validate_structural_rules = validate_structural_rules,
        validate_custom_extensions = validate_custom_extensions,
        validate_unique_keys = validate_unique_keys,
        relationship_edges = relationship_edges,
        find_path = find_path,
        validate_expressions = validate_expressions,
        extract_metric_dependencies = extract_metric_dependencies,
        detect_metric_cycles = detect_metric_cycles,
        validate_agent_metadata = validate_agent_metadata,
        compute_metric_dimension_matrix = compute_metric_dimension_matrix,
        validate_visible_metric_dimension_pairs = validate_visible_metric_dimension_pairs,
    }
end
