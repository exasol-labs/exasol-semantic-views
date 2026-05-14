local M = {}

local JSON_NULL = {}

local function missing(value)
    return value == nil or value == null or value == JSON_NULL or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
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

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_AGENT_001: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_AGENT_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_AGENT_001: " .. label .. " is required")
    end
    local choice = upper(trim(value))
    if allowed[choice] then
        return choice
    end
    local choices = {}
    for allowed_value, _ in pairs(allowed) do
        choices[#choices + 1] = allowed_value
    end
    table.sort(choices)
    error("SEMANTIC_AGENT_003: invalid " .. label .. ": " .. tostring(value)
        .. ". Valid values: " .. table.concat(choices, ", "))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1" or text == "yes"
end

local function json_escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
end

local function is_array(value)
    if type(value) ~= "table" or value == JSON_NULL then
        return false
    end
    local max_index = 0
    local count = 0
    for k, _ in pairs(value) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max_index then
            max_index = k
        end
        count = count + 1
    end
    return max_index == count
end

local function json_encode(value)
    local value_type = type(value)
    if value == nil or value == null or value == JSON_NULL then
        return "null"
    elseif value_type == "string" then
        return '"' .. json_escape(value) .. '"'
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "table" then
        local parts = {}
        if is_array(value) then
            for i = 1, #value do
                parts[#parts + 1] = json_encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_encode(tostring(value))
end

local function rows_to_objects(rows, columns)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local item = {}
        for index, column_name in ipairs(columns) do
            item[string.lower(column_name)] = null_if_missing(row_value(row, column_name, index))
        end
        out[#out + 1] = item
    end
    return out
end

local function model_row(model_name)
    local rows = query([[
        SELECT MODEL_ID, MODEL_NAME, ACTIVE_VERSION_ID AS VERSION_ID, PUBLISHED_SCHEMA
        FROM SYS_SEMANTIC.MODELS
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_AGENT_010: model not found: " .. tostring(model_name))
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        model_name = row_value(rows[1], "MODEL_NAME", 2),
        version_id = row_value(rows[1], "VERSION_ID", 3),
        published_schema = row_value(rows[1], "PUBLISHED_SCHEMA", 4),
    }
end

local function visible_model_name(model_name)
    local rows = query([[
        SELECT MODEL_NAME
        FROM SEMANTIC_AGENT.MODELS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_AGENT_010: model not visible: " .. tostring(model_name))
    end
    return row_value(rows[1], "MODEL_NAME", 1)
end

local function object_row(model, object_name)
    local rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_AGENT_011: semantic object not found: " .. tostring(object_name))
    end
    return {
        object_id = row_value(rows[1], "OBJECT_ID", 1),
        object_name = row_value(rows[1], "OBJECT_NAME", 2),
    }
end

local function scoped_object_id(model, scope_type, scope_name)
    if scope_type == "MODEL" then
        return model.model_id
    end
    if missing(scope_name) then
        error("SEMANTIC_AGENT_001: SCOPE_NAME is required for " .. scope_type)
    end
    local table_name
    local id_column
    local name_column
    if scope_type == "SEMANTIC_OBJECT" then
        table_name = "SYS_SEMANTIC.SEMANTIC_OBJECTS"
        id_column = "OBJECT_ID"
        name_column = "OBJECT_NAME"
    elseif scope_type == "ENTITY" then
        table_name = "SYS_SEMANTIC.ENTITIES"
        id_column = "ENTITY_ID"
        name_column = "ENTITY_NAME"
    elseif scope_type == "DIMENSION" then
        table_name = "SYS_SEMANTIC.DIMENSIONS"
        id_column = "DIMENSION_ID"
        name_column = "DIMENSION_NAME"
    elseif scope_type == "FACT" then
        table_name = "SYS_SEMANTIC.FACTS"
        id_column = "FACT_ID"
        name_column = "FACT_NAME"
    elseif scope_type == "METRIC" then
        table_name = "SYS_SEMANTIC.METRICS"
        id_column = "METRIC_ID"
        name_column = "METRIC_NAME"
    else
        error("SEMANTIC_AGENT_003: invalid SCOPE_TYPE: " .. tostring(scope_type))
    end
    local id = scalar("SELECT " .. id_column .. " FROM " .. table_name ..
        " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(" .. name_column .. ") = UPPER(:scope_name)",
        {model_id = model.model_id, version_id = model.version_id, scope_name = scope_name})
    if id == nil then
        error("SEMANTIC_AGENT_012: scope object not found: " .. tostring(scope_name))
    end
    return id
end

local function latest_id(table_name, id_column)
    return scalar("SELECT MAX(" .. id_column .. ") FROM " .. table_name .. " WHERE CREATED_BY = CURRENT_USER")
end

local function latest_verified_query_id()
    return scalar("SELECT MAX(VERIFIED_QUERY_ID) FROM SYS_SEMANTIC.VERIFIED_QUERIES WHERE VERIFIED_BY = CURRENT_USER")
end

local STOP_WORDS = {
    A = true,
    AN = true,
    AND = true,
    BY = true,
    FIELD = true,
    FIELDS = true,
    FIND = true,
    FOR = true,
    LIST = true,
    MEASURE = true,
    MEASURES = true,
    METRIC = true,
    METRICS = true,
    OF = true,
    QUERY = true,
    SHOW = true,
    THE = true,
    VALUE = true,
    VALUES = true,
}

local function search_term(value)
    local text = trim(value or "")
    local best = nil
    for token in string.gmatch(text, "[A-Za-z0-9_]+") do
        local normalized = upper(token)
        if not STOP_WORDS[normalized] then
            if best == nil or #token > #best then
                best = token
            end
        end
    end
    return best or text
end

local function like_pattern(value)
    local text = upper(trim(value or ""))
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, "%%", "\\%%")
    text = string.gsub(text, "_", "\\_")
    if text == "" then
        return "%"
    end
    return "%" .. text .. "%"
end

function M.add_agent_instruction(model_name_arg, scope_type_arg, scope_name_arg, instruction_kind_arg, instruction_text_arg, applies_to_role_arg, priority_arg)
    local model_name = normalize_name(model_name_arg, "MODEL_NAME")
    local scope_type = normalize_choice(scope_type_arg, "SCOPE_TYPE", {
        MODEL = true,
        SEMANTIC_OBJECT = true,
        ENTITY = true,
        DIMENSION = true,
        FACT = true,
        METRIC = true,
    })
    local instruction_kind = normalize_choice(instruction_kind_arg, "INSTRUCTION_KIND", {
        AMBIGUITY = true,
        DEFINITION = true,
        GENERAL = true,
        POLICY = true,
        PREFERENCE = true,
        SAFETY = true,
        STYLE = true,
    })
    if missing(instruction_text_arg) then
        error("SEMANTIC_AGENT_001: INSTRUCTION_TEXT is required")
    end
    local model = model_row(model_name)
    local scope_id = scoped_object_id(model, scope_type, scope_name_arg)
    local priority = tonumber(priority_arg)
    if priority == nil then
        priority = 100
    end
    query([[
        INSERT INTO SYS_SEMANTIC.AGENT_INSTRUCTIONS (
          MODEL_ID, VERSION_ID, SCOPE_TYPE, SCOPE_ID, INSTRUCTION_KIND,
          INSTRUCTION_TEXT, APPLIES_TO_ROLE, PRIORITY, STATUS
        ) VALUES (
          :model_id, :version_id, :scope_type, :scope_id, :instruction_kind,
          :instruction_text, :applies_to_role, :priority, 'ACTIVE'
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        scope_type = scope_type,
        scope_id = scope_id,
        instruction_kind = instruction_kind,
        instruction_text = tostring(instruction_text_arg),
        applies_to_role = optional_text(applies_to_role_arg),
        priority = priority,
    })
    local instruction_id = latest_id("SYS_SEMANTIC.AGENT_INSTRUCTIONS", "INSTRUCTION_ID")
    return {{
        instruction_id,
        model.model_name,
        scope_type,
        null_if_missing(scope_name_arg),
        instruction_kind,
        "ACTIVE",
    }}
end

function M.add_verified_query(model_name_arg, object_name_arg, query_name_arg, natural_language_text_arg, request_json_arg, expected_result_shape_arg, is_onboarding_example_arg)
    local model_name = normalize_name(model_name_arg, "MODEL_NAME")
    local object_name = normalize_name(object_name_arg, "OBJECT_NAME")
    if missing(query_name_arg) then
        error("SEMANTIC_AGENT_001: QUERY_NAME is required")
    end
    if missing(natural_language_text_arg) then
        error("SEMANTIC_AGENT_001: NATURAL_LANGUAGE_TEXT is required")
    end
    if missing(request_json_arg) then
        error("SEMANTIC_AGENT_001: REQUEST_JSON is required")
    end
    local model = model_row(model_name)
    local object = object_row(model, object_name)
    local compiled = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(:request_json)
    ]], {request_json = tostring(request_json_arg)})
    if compiled == nil or #compiled == 0 or row_value(compiled[1], "STATUS", 1) ~= "OK" then
        local code = compiled and compiled[1] and row_value(compiled[1], "ERROR_CODE", 2) or "SEMANTIC_AGENT_020"
        local message = compiled and compiled[1] and row_value(compiled[1], "ERROR_MESSAGE", 3) or "verified query did not compile"
        error("SEMANTIC_AGENT_020: verified query compile failed: " .. tostring(code) .. " " .. tostring(message))
    end
    local generated_sql = row_value(compiled[1], "GENERATED_SQL", 4)
    query([[
        INSERT INTO SYS_SEMANTIC.VERIFIED_QUERIES (
          MODEL_ID, VERSION_ID, OBJECT_ID, QUERY_NAME, NATURAL_LANGUAGE_TEXT,
          REQUEST_JSON, GENERATED_SQL, EXPECTED_RESULT_SHAPE,
          IS_ONBOARDING_EXAMPLE, STATUS
        ) VALUES (
          :model_id, :version_id, :object_id, :query_name, :natural_language_text,
          :request_json, :generated_sql, :expected_result_shape,
          :is_onboarding_example, 'ACTIVE'
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        object_id = object.object_id,
        query_name = tostring(query_name_arg),
        natural_language_text = tostring(natural_language_text_arg),
        request_json = tostring(request_json_arg),
        generated_sql = generated_sql,
        expected_result_shape = optional_text(expected_result_shape_arg),
        is_onboarding_example = bool_value(is_onboarding_example_arg, false),
    })
    local verified_query_id = latest_verified_query_id()
    return {{
        verified_query_id,
        model.model_name,
        object.object_name,
        tostring(query_name_arg),
        "ACTIVE",
        generated_sql,
    }}
end

function M.search_semantic_objects(query_text_arg, model_name_arg)
    local model_filter = null
    if not missing(model_name_arg) then
        model_filter = normalize_name(model_name_arg, "MODEL_NAME")
    end
    local term = search_term(query_text_arg)
    local pattern = like_pattern(term)
    local rows = query([[
        SELECT *
        FROM (
          SELECT
            'FIELD' AS RESULT_TYPE,
            MODEL_NAME,
            OBJECT_NAME,
            FIELD_KIND,
            FIELD_NAME,
            DISPLAY_NAME,
            DESCRIPTION,
            FIELD_NAME AS MATCH_TEXT,
            CASE
              WHEN UPPER(FIELD_NAME) = UPPER(:query_text) THEN 100
              WHEN UPPER(DISPLAY_NAME) = UPPER(:query_text) THEN 90
              WHEN UPPER(FIELD_NAME) LIKE :pattern ESCAPE '\' THEN 70
              WHEN UPPER(DISPLAY_NAME) LIKE :pattern ESCAPE '\' THEN 60
              ELSE 40
            END AS SCORE,
            IS_CERTIFIED
          FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
          WHERE (:model_name IS NULL OR UPPER(MODEL_NAME) = UPPER(:model_name))
            AND (
              UPPER(FIELD_NAME) LIKE :pattern ESCAPE '\'
              OR UPPER(DISPLAY_NAME) LIKE :pattern ESCAPE '\'
              OR UPPER(DESCRIPTION) LIKE :pattern ESCAPE '\'
            )
          UNION ALL
          SELECT
            'SYNONYM' AS RESULT_TYPE,
            f.MODEL_NAME,
            f.OBJECT_NAME,
            f.FIELD_KIND,
            f.FIELD_NAME,
            f.DISPLAY_NAME,
            f.DESCRIPTION,
            s.SYNONYM AS MATCH_TEXT,
            CASE WHEN UPPER(s.SYNONYM) = UPPER(:query_text) THEN 95 ELSE 65 END AS SCORE,
            f.IS_CERTIFIED
          FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT f
          JOIN SYS_SEMANTIC.SYNONYMS s
            ON s.MODEL_ID = f.MODEL_ID
           AND s.VERSION_ID = f.VERSION_ID
           AND s.OBJECT_TYPE = f.FIELD_KIND
           AND s.OBJECT_ID = f.FIELD_ID
          WHERE (:model_name IS NULL OR UPPER(f.MODEL_NAME) = UPPER(:model_name))
            AND UPPER(s.SYNONYM) LIKE :pattern ESCAPE '\'
          UNION ALL
          SELECT
            'VERIFIED_QUERY' AS RESULT_TYPE,
            MODEL_NAME,
            OBJECT_NAME,
            'QUERY' AS FIELD_KIND,
            QUERY_NAME AS FIELD_NAME,
            QUERY_NAME AS DISPLAY_NAME,
            NATURAL_LANGUAGE_TEXT AS DESCRIPTION,
            NATURAL_LANGUAGE_TEXT AS MATCH_TEXT,
            50 AS SCORE,
            TRUE AS IS_CERTIFIED
          FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT
          WHERE (:model_name IS NULL OR UPPER(MODEL_NAME) = UPPER(:model_name))
            AND (
              UPPER(QUERY_NAME) LIKE :pattern ESCAPE '\'
              OR UPPER(NATURAL_LANGUAGE_TEXT) LIKE :pattern ESCAPE '\'
            )
        )
        ORDER BY SCORE DESC, RESULT_TYPE, FIELD_NAME
        LIMIT 50
    ]], {query_text = term, pattern = pattern, model_name = model_filter})
    local out = {}
    for _, row in ipairs(rows or {}) do
        out[#out + 1] = {
            row_value(row, "RESULT_TYPE", 1),
            row_value(row, "MODEL_NAME", 2),
            row_value(row, "OBJECT_NAME", 3),
            row_value(row, "FIELD_KIND", 4),
            row_value(row, "FIELD_NAME", 5),
            row_value(row, "DISPLAY_NAME", 6),
            row_value(row, "DESCRIPTION", 7),
            row_value(row, "MATCH_TEXT", 8),
            row_value(row, "SCORE", 9),
            row_value(row, "IS_CERTIFIED", 10),
        }
    end
    return out
end

function M.describe_semantic_object(model_name_arg, object_name_arg)
    local model_name = normalize_name(model_name_arg, "MODEL_NAME")
    local object_name = normalize_name(object_name_arg, "OBJECT_NAME")
    visible_model_name(model_name)
    local rows = {}
    local object_rows = query([[
        SELECT MODEL_NAME, OBJECT_NAME, PUBLISHED_SCHEMA, PUBLISHED_OBJECT_NAME,
               ROOT_ENTITY_NAME, DESCRIPTION, AGENT_READINESS,
               LATEST_VALIDATION_RUN_ID, PREPROCESSOR_QUALIFIED_NAME, QUERY_MODES
        FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_name = model_name, object_name = object_name})
    if object_rows == nil or #object_rows == 0 then
        error("SEMANTIC_AGENT_011: semantic object not visible: " .. object_name)
    end
    local object = object_rows[1]
    rows[#rows + 1] = {
        row_value(object, "MODEL_NAME", 1),
        row_value(object, "OBJECT_NAME", 2),
        "OBJECT",
        null,
        null,
        null,
        null,
        row_value(object, "DESCRIPTION", 6),
        json_encode({
            published_schema = row_value(object, "PUBLISHED_SCHEMA", 3),
            published_object = row_value(object, "PUBLISHED_OBJECT_NAME", 4),
            root_entity = row_value(object, "ROOT_ENTITY_NAME", 5),
            agent_readiness = row_value(object, "AGENT_READINESS", 7),
            latest_validation_run_id = row_value(object, "LATEST_VALIDATION_RUN_ID", 8),
            preprocessor = row_value(object, "PREPROCESSOR_QUALIFIED_NAME", 9),
            query_modes = row_value(object, "QUERY_MODES", 10),
        }),
    }
    local field_rows = query([[
        SELECT MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME, SQL_COLUMN_NAME,
               DATA_TYPE, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT,
               SENSITIVITY_LABEL, IS_CERTIFIED, FILTER_EXPRESSION, SQL_FILTER_EXPRESSION
        FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
        ORDER BY ORDINAL_POSITION
    ]], {model_name = model_name, object_name = object_name})
    for _, field in ipairs(field_rows or {}) do
        rows[#rows + 1] = {
            row_value(field, "MODEL_NAME", 1),
            row_value(field, "OBJECT_NAME", 2),
            "FIELD",
            row_value(field, "FIELD_KIND", 3),
            row_value(field, "FIELD_NAME", 4),
            row_value(field, "SQL_COLUMN_NAME", 5),
            row_value(field, "DATA_TYPE", 6),
            row_value(field, "DESCRIPTION", 8),
            json_encode({
                display_name = row_value(field, "DISPLAY_NAME", 7),
                format_hint = row_value(field, "FORMAT_HINT", 9),
                unit_hint = row_value(field, "UNIT_HINT", 10),
                sensitivity_label = row_value(field, "SENSITIVITY_LABEL", 11),
                is_certified = row_value(field, "IS_CERTIFIED", 12),
                filter_expression = row_value(field, "FILTER_EXPRESSION", 13),
                sql_filter_expression = row_value(field, "SQL_FILTER_EXPRESSION", 14),
            }),
        }
    end
    return rows
end

function M.get_business_glossary(model_name_arg, object_name_arg, query_mode_arg)
    local model_name = normalize_name(model_name_arg, "MODEL_NAME")
    local object_name = normalize_name(object_name_arg, "OBJECT_NAME")
    visible_model_name(model_name)
    local query_mode = "STRUCTURED_REQUEST"
    if not missing(query_mode_arg) then
        query_mode = upper(trim(query_mode_arg))
    end
    if query_mode ~= "STRUCTURED_REQUEST" and query_mode ~= "SEMANTIC_SQL" then
        error("SEMANTIC_AGENT_003: invalid QUERY_MODE: " .. tostring(query_mode_arg))
    end
    local object_rows = query([[
        SELECT MODEL_NAME, OBJECT_NAME, PUBLISHED_SCHEMA, PUBLISHED_OBJECT_NAME,
               PREPROCESSOR_QUALIFIED_NAME, AGENT_READINESS
        FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_name = model_name, object_name = object_name})
    if object_rows == nil or #object_rows == 0 then
        error("SEMANTIC_AGENT_011: semantic object not visible: " .. object_name)
    end
    local object = object_rows[1]
    local fields = query([[
        SELECT FIELD_KIND, FIELD_NAME, DISPLAY_NAME, DESCRIPTION, DATA_TYPE,
               FILTER_EXPRESSION
        FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
        ORDER BY FIELD_KIND, FIELD_NAME
    ]], {model_name = model_name, object_name = object_name}) or {}
    local instructions = query([[
        SELECT INSTRUCTION_KIND, INSTRUCTION_TEXT
        FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
        ORDER BY PRIORITY, INSTRUCTION_ID
        LIMIT 10
    ]], {model_name = model_name}) or {}
    local verified = query([[
        SELECT QUERY_NAME, NATURAL_LANGUAGE_TEXT
        FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
        ORDER BY IS_ONBOARDING_EXAMPLE DESC, VERIFIED_QUERY_ID
        LIMIT 5
    ]], {model_name = model_name, object_name = object_name}) or {}

    local lines = {}
    lines[#lines + 1] = "Model " .. row_value(object, "MODEL_NAME", 1) .. ", object " .. row_value(object, "OBJECT_NAME", 2) .. "."
    lines[#lines + 1] = "Readiness: " .. tostring(row_value(object, "AGENT_READINESS", 6)) .. "."
    if query_mode == "STRUCTURED_REQUEST" then
        lines[#lines + 1] = "Use COMPILE_REQUEST_JSON with metrics, dimensions, filters, order_by, and limit. Do not write joins or aggregate formulas."
    else
        lines[#lines + 1] = "Use semantic SQL against " .. row_value(object, "PUBLISHED_SCHEMA", 3) .. "." .. row_value(object, "PUBLISHED_OBJECT_NAME", 4) .. " with selected dimensions in GROUP BY."
        lines[#lines + 1] = "Enable " .. row_value(object, "PREPROCESSOR_QUALIFIED_NAME", 5) .. " for BI-style execution or call COMPILE_SQL explicitly."
    end
    lines[#lines + 1] = "Fields:"
    for _, field in ipairs(fields) do
        lines[#lines + 1] = "- " .. row_value(field, "FIELD_KIND", 1) .. " " .. row_value(field, "FIELD_NAME", 2)
            .. " (" .. row_value(field, "DATA_TYPE", 5) .. "): " .. tostring(row_value(field, "DESCRIPTION", 4) or row_value(field, "DISPLAY_NAME", 3) or "")
    end
    if #instructions > 0 then
        lines[#lines + 1] = "Instructions:"
        for _, instruction in ipairs(instructions) do
            lines[#lines + 1] = "- " .. row_value(instruction, "INSTRUCTION_KIND", 1) .. ": " .. row_value(instruction, "INSTRUCTION_TEXT", 2)
        end
    end
    if #verified > 0 then
        lines[#lines + 1] = "Verified examples:"
        for _, example in ipairs(verified) do
            lines[#lines + 1] = "- " .. row_value(example, "QUERY_NAME", 1) .. ": " .. row_value(example, "NATURAL_LANGUAGE_TEXT", 2)
        end
    end

    return {{
        row_value(object, "MODEL_NAME", 1),
        row_value(object, "OBJECT_NAME", 2),
        query_mode,
        table.concat(lines, "\n"),
        json_encode({
            fields = rows_to_objects(fields, {"FIELD_KIND", "FIELD_NAME", "DISPLAY_NAME", "DESCRIPTION", "DATA_TYPE", "FILTER_EXPRESSION"}),
            instructions = rows_to_objects(instructions, {"INSTRUCTION_KIND", "INSTRUCTION_TEXT"}),
            verified_queries = rows_to_objects(verified, {"QUERY_NAME", "NATURAL_LANGUAGE_TEXT"}),
        }),
    }}
end

local function load_handle(handle_type_arg, handle_id_arg)
    local handle_type = normalize_choice(handle_type_arg, "HANDLE_TYPE", {
        AGENT_REQUEST = true,
        AGENT_REQUEST_ID = true,
        AGENT = true,
        QUERY_LOG = true,
        QUERY_LOG_ID = true,
        SQL = true,
    })
    local handle_id = tonumber(handle_id_arg)
    if handle_id == nil then
        error("SEMANTIC_AGENT_001: HANDLE_ID must be numeric")
    end
    if handle_type == "AGENT_REQUEST_ID" or handle_type == "AGENT" then
        handle_type = "AGENT_REQUEST"
    elseif handle_type == "QUERY_LOG_ID" or handle_type == "SQL" then
        handle_type = "QUERY_LOG"
    end
    local sql_text
    if handle_type == "AGENT_REQUEST" then
        sql_text = [[
            SELECT 'AGENT_REQUEST' AS HANDLE_TYPE, ar.AGENT_REQUEST_ID AS HANDLE_ID,
                   ar.MODEL_ID, m.MODEL_NAME, ar.VERSION_ID, ar.STATUS,
                   ar.ERROR_CODE, ar.ERROR_MESSAGE, ar.REQUEST_JSON AS REQUEST_TEXT,
                   ar.GENERATED_SQL, ar.PLAN_JSON, NULL AS REQUESTED_DIMENSIONS,
                   NULL AS REQUESTED_METRICS, NULL AS MATERIALIZATION_USED
            FROM SYS_SEMANTIC.AGENT_REQUEST_LOG ar
            LEFT JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = ar.MODEL_ID
            WHERE ar.AGENT_REQUEST_ID = :handle_id
        ]]
    else
        sql_text = [[
            SELECT 'QUERY_LOG' AS HANDLE_TYPE, ql.QUERY_LOG_ID AS HANDLE_ID,
                   ql.MODEL_ID, m.MODEL_NAME, ql.VERSION_ID, ql.STATUS,
                   ql.ERROR_CODE, ql.ERROR_MESSAGE, ql.ORIGINAL_SQL AS REQUEST_TEXT,
                   ql.GENERATED_SQL, ql.PLAN_JSON, ql.REQUESTED_DIMENSIONS,
                   ql.REQUESTED_METRICS, ql.MATERIALIZATION_USED
            FROM SYS_SEMANTIC.QUERY_LOG ql
            LEFT JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = ql.MODEL_ID
            WHERE ql.QUERY_LOG_ID = :handle_id
        ]]
    end
    local rows = query(sql_text, {handle_id = handle_id})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_AGENT_030: handle not found: " .. tostring(handle_type_arg) .. " " .. tostring(handle_id_arg))
    end
    return handle_type, handle_id, rows[1]
end

local function json_unescape(value)
    local text = tostring(value)
    text = string.gsub(text, '\\"', '"')
    text = string.gsub(text, "\\\\", "\\")
    return text
end

local function extract_selected_materialization(plan_json)
    if missing(plan_json) then
        return null
    end
    local match = string.match(tostring(plan_json), '"selected_materialization"%s*:%s*{.-"materialization_name"%s*:%s*"([^"]+)"')
    if match == nil then
        return null
    end
    return json_unescape(match)
end

local function extract_json_array_text(json_text, property_name)
    if missing(json_text) then
        return null
    end
    local pattern = '"' .. property_name .. '"%s*:%s*(%b[])'
    local match = string.match(tostring(json_text), pattern)
    if match == nil then
        return null
    end
    return match
end

function M.explain_compiled_sql(handle_type_arg, handle_id_arg)
    local _, _, handle = load_handle(handle_type_arg, handle_id_arg)
    local selected_materialization = row_value(handle, "MATERIALIZATION_USED", 14)
    if missing(selected_materialization) then
        selected_materialization = extract_selected_materialization(row_value(handle, "PLAN_JSON", 11))
    end
    local requested_dimensions = row_value(handle, "REQUESTED_DIMENSIONS", 12)
    local requested_metrics = row_value(handle, "REQUESTED_METRICS", 13)
    if missing(requested_dimensions) then
        requested_dimensions = extract_json_array_text(row_value(handle, "PLAN_JSON", 11), "dimensions")
    end
    if missing(requested_metrics) then
        requested_metrics = extract_json_array_text(row_value(handle, "PLAN_JSON", 11), "metrics")
    end
    return {{
        row_value(handle, "HANDLE_TYPE", 1),
        row_value(handle, "HANDLE_ID", 2),
        row_value(handle, "MODEL_NAME", 4),
        row_value(handle, "VERSION_ID", 5),
        row_value(handle, "STATUS", 6),
        row_value(handle, "ERROR_CODE", 7),
        row_value(handle, "ERROR_MESSAGE", 8),
        row_value(handle, "REQUEST_TEXT", 9),
        row_value(handle, "GENERATED_SQL", 10),
        row_value(handle, "PLAN_JSON", 11),
        requested_dimensions,
        requested_metrics,
        selected_materialization,
    }}
end

function M.record_agent_feedback(handle_type_arg, handle_id_arg, verdict_arg, comment_text_arg, proposed_change_json_arg)
    local handle_type, handle_id, handle = load_handle(handle_type_arg, handle_id_arg)
    local verdict = normalize_choice(verdict_arg, "VERDICT", {
        ACCEPTED = true,
        HELPFUL = true,
        NEEDS_CHANGE = true,
        NOT_HELPFUL = true,
        REJECTED = true,
    })
    local agent_request_id = null
    local query_log_id = null
    if handle_type == "AGENT_REQUEST" then
        agent_request_id = handle_id
    else
        query_log_id = handle_id
    end
    query([[
        INSERT INTO SYS_SEMANTIC.AGENT_FEEDBACK (
          AGENT_REQUEST_ID, QUERY_LOG_ID, FEEDBACK_KIND, VERDICT, COMMENT_TEXT,
          PROPOSED_CHANGE_JSON, REVIEW_STATUS
        ) VALUES (
          :agent_request_id, :query_log_id, :feedback_kind, :verdict, :comment_text,
          :proposed_change_json, 'PENDING'
        )
    ]], {
        agent_request_id = agent_request_id,
        query_log_id = query_log_id,
        feedback_kind = handle_type,
        verdict = verdict,
        comment_text = optional_text(comment_text_arg),
        proposed_change_json = optional_text(proposed_change_json_arg),
    })
    local feedback_id = latest_id("SYS_SEMANTIC.AGENT_FEEDBACK", "FEEDBACK_ID")
    local suggestion_id = null
    if not missing(proposed_change_json_arg) then
        query([[
            INSERT INTO SYS_SEMANTIC.AGENT_SUGGESTIONS (
              MODEL_ID, VERSION_ID, AGENT_REQUEST_ID, QUERY_LOG_ID, FEEDBACK_ID,
              SUGGESTION_KIND, OBJECT_TYPE, OBJECT_ID, PROPOSED_CHANGE_JSON,
              RATIONALE, REVIEW_STATUS
            ) VALUES (
              :model_id, :version_id, :agent_request_id, :query_log_id, :feedback_id,
              'PROPOSED_CHANGE', NULL, NULL, :proposed_change_json,
              :rationale, 'PENDING'
            )
        ]], {
            model_id = null_if_missing(row_value(handle, "MODEL_ID", 3)),
            version_id = null_if_missing(row_value(handle, "VERSION_ID", 5)),
            agent_request_id = agent_request_id,
            query_log_id = query_log_id,
            feedback_id = feedback_id,
            proposed_change_json = tostring(proposed_change_json_arg),
            rationale = optional_text(comment_text_arg),
        })
        suggestion_id = latest_id("SYS_SEMANTIC.AGENT_SUGGESTIONS", "SUGGESTION_ID")
    end
    return {{
        feedback_id,
        suggestion_id,
        handle_type,
        handle_id,
        verdict,
        "PENDING",
    }}
end

add_agent_instruction = M.add_agent_instruction
add_verified_query = M.add_verified_query
search_semantic_objects = M.search_semantic_objects
describe_semantic_object = M.describe_semantic_object
get_business_glossary = M.get_business_glossary
explain_compiled_sql = M.explain_compiled_sql
record_agent_feedback = M.record_agent_feedback
