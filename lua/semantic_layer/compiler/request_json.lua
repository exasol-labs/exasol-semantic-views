local M = {}

if type(import) == "function" then
    import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
elseif type(exa) == "table" and type(exa.import) == "function" then
    exa.import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
end

local materialization_runtime = materializations

local JSON_NULL = {}
local MAX_LIMIT = 10000

local function missing(value)
    return value == nil or value == null or value == JSON_NULL or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
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

local function json_escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
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

local function json_decode(text)
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

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" then
                    out[#out + 1] = e
                    pos = pos + 2
                elseif e == "b" then
                    out[#out + 1] = "\b"
                    pos = pos + 2
                elseif e == "f" then
                    out[#out + 1] = "\f"
                    pos = pos + 2
                elseif e == "n" then
                    out[#out + 1] = "\n"
                    pos = pos + 2
                elseif e == "r" then
                    out[#out + 1] = "\r"
                    pos = pos + 2
                elseif e == "t" then
                    out[#out + 1] = "\t"
                    pos = pos + 2
                elseif e == "u" then
                    out[#out + 1] = "?"
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        local c = peek()
        if c == "-" then
            pos = pos + 1
        end
        while string.match(peek(), "%d") do
            pos = pos + 1
        end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        local raw = string.sub(text, start_pos, pos - 1)
        local value = tonumber(raw)
        if value == nil then
            error("invalid number at byte " .. tostring(start_pos))
        end
        return value
    end

    local function parse_array()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return out
        end
        while true do
            out[#out + 1] = parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return out
        end
        while true do
            skip_ws()
            local name = parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            out[name] = parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return out
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
        elseif c == "-" or string.match(c, "%d") then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    local value = parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return value
end

local function quote_ident(name)
    local text = tostring(name)
    text = string.gsub(text, '"', '""')
    return '"' .. text .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function quote_column(alias, column_name)
    return tostring(alias) .. "." .. quote_ident(column_name)
end

local function quote_alias(name)
    return quote_ident(name)
end

local function sql_string(value)
    local text = tostring(value)
    text = string.gsub(text, "'", "''")
    return "'" .. text .. "'"
end

local function sql_literal(value, data_type)
    if value == JSON_NULL or value == nil or value == null then
        return "NULL"
    end
    local value_type = type(value)
    if value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "TRUE" or "FALSE"
    end
    local text = tostring(value)
    local dtype = upper(data_type or "")
    if string.sub(dtype, 1, 4) == "DATE" and string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
        return "DATE " .. sql_string(text)
    end
    if string.find(dtype, "TIMESTAMP", 1, true) == 1 and string.match(text, "^%d%d%d%d%-%d%d%-%d%d") then
        return "TIMESTAMP " .. sql_string(text)
    end
    if string.find(dtype, "DECIMAL", 1, true) or string.find(dtype, "INT", 1, true) or string.find(dtype, "NUMBER", 1, true) or string.find(dtype, "DOUBLE", 1, true) then
        if string.match(text, "^%-?%d+%.?%d*$") then
            return text
        end
    end
    return sql_string(text)
end

local function is_text_type(data_type)
    local dtype = upper(data_type or "")
    return string.find(dtype, "CHAR", 1, true) ~= nil
        or string.find(dtype, "CLOB", 1, true) ~= nil
        or string.find(dtype, "VARCHAR", 1, true) ~= nil
end

local function as_array(value, field_name)
    if missing(value) then
        return {}
    end
    if not is_array(value) then
        error(field_name .. " must be an array")
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error(label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("invalid " .. label .. ": " .. name)
    end
    return name
end

local function boolish(value)
    return value == true or tostring(value) == "true" or tostring(value) == "TRUE" or tostring(value) == "1"
end

local function error_result(code, message, clarification)
    return {
        status = clarification and "NEEDS_CLARIFICATION" or "ERROR",
        error_code = code,
        error_message = message,
        generated_sql = nil,
        plan_json = nil,
        clarification_json = clarification and json_encode(clarification) or nil,
        validation_run_id = nil,
        agent_request_id = nil,
        query_log_id = nil,
    }
end

local function unchanged_result(sql_text)
    return {
        status = "UNCHANGED",
        error_code = nil,
        error_message = nil,
        generated_sql = sql_text,
        plan_json = nil,
        clarification_json = nil,
        validation_run_id = nil,
        agent_request_id = nil,
        query_log_id = nil,
    }
end

local function recode_error_prefix(result, prefix)
    if type(result) == "table" and type(result.error_code) == "string" then
        result.error_code = string.gsub(result.error_code, "^SEMANTIC_REQUEST", prefix)
    end
    return result
end

local function plan_materialization_name(plan)
    if type(plan) ~= "table" or plan.selected_materialization == nil or plan.selected_materialization == JSON_NULL then
        return nil
    end
    if type(plan.selected_materialization) == "table" then
        return plan.selected_materialization.materialization_name
    end
    return tostring(plan.selected_materialization)
end

local function ok_result(sql_text, plan, validation_run_id)
    return {
        status = "OK",
        error_code = nil,
        error_message = nil,
        generated_sql = sql_text,
        plan_json = json_encode(plan),
        clarification_json = nil,
        validation_run_id = validation_run_id,
        agent_request_id = nil,
        query_log_id = nil,
        materialization_used = plan_materialization_name(plan),
    }
end

local function load_model(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID, mv.VERSION_NUMBER
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2),
        version_number = row_value(rows[1], "VERSION_NUMBER", 3),
        model_name = model_name,
    }
end

local function validate_model(model)
    local rows = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)
    ]], {model_name = model.model_name})
    local errors = {}
    for _, row in ipairs(rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            errors[#errors + 1] = {
                code = row_value(row, "RULE_CODE", 4),
                object_type = row_value(row, "OBJECT_TYPE", 2),
                object = row_value(row, "OBJECT_NAME", 3),
                message = row_value(row, "MESSAGE", 5),
            }
        end
    end
    local validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    return errors, validation_run_id
end

local function collect_referenced_validation_objects(ctx, metrics, dimensions)
    local referenced = {
        DIMENSION = {},
        FACT = {},
        METRIC = {},
    }
    for _, dimension in ipairs(dimensions or {}) do
        referenced.DIMENSION[upper(dimension.name)] = true
    end
    local function add_metric(metric, seen)
        local metric_key = key(metric.id)
        if seen[metric_key] then
            return
        end
        seen[metric_key] = true
        referenced.METRIC[upper(metric.name)] = true
        local dep_rows = query([[
            SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
            FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
            WHERE METRIC_ID = :metric_id
        ]], {metric_id = metric.id})
        for _, row in ipairs(dep_rows or {}) do
            local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
            local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
            if dep_type == "FACT" then
                local fact = ctx.fact_by_id[key(dep_id)]
                if fact ~= nil then
                    referenced.FACT[upper(fact.name)] = true
                end
            elseif dep_type == "METRIC" then
                local dep_metric = ctx.metric_by_id[key(dep_id)]
                if dep_metric ~= nil then
                    add_metric(dep_metric, seen)
                end
            end
        end
    end
    for _, metric in ipairs(metrics or {}) do
        add_metric(metric, {})
    end
    return referenced
end

local function validation_error_applies(error_row, referenced)
    local object_type = upper(error_row.object_type or "")
    local object_name = upper(error_row.object or "")
    if object_type == "DIMENSION" or object_type == "FACT" or object_type == "METRIC" then
        return referenced[object_type] ~= nil and referenced[object_type][object_name] == true
    end
    if object_type == "SYNONYM" then
        return false
    end
    return true
end

local function load_catalog(model, object_name)
    local object_rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if object_rows == nil or #object_rows == 0 then
        return nil, "SEMANTIC_REQUEST_012", "Semantic object not found: " .. tostring(object_name)
    end

    local ctx = {
        model = model,
        object = {
            id = row_value(object_rows[1], "OBJECT_ID", 1),
            name = row_value(object_rows[1], "OBJECT_NAME", 2),
            root_entity_id = row_value(object_rows[1], "ROOT_ENTITY_ID", 3),
        },
        entities = {},
        entity_by_id = {},
        entity_by_alias = {},
        dimensions = {},
        dimension_by_id = {},
        metrics = {},
        metric_by_id = {},
        facts = {},
        fact_by_id = {},
        fact_by_name = {},
        relationships = {},
        canonical_fields = {},
        synonym_fields = {},
    }

    local entity_rows = query([[
        SELECT ENTITY_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local entity = {
            id = row_value(row, "ENTITY_ID", 1),
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
        }
        ctx.entities[#ctx.entities + 1] = entity
        ctx.entity_by_id[key(entity.id)] = entity
        ctx.entity_by_alias[upper(entity.alias)] = entity
    end

    local dimension_rows = query([[
        SELECT d.DIMENSION_ID, d.DIMENSION_NAME, d.ENTITY_ID, d.EXPRESSION,
               d.DATA_TYPE, d.DISPLAY_NAME
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'DIMENSION'
          AND oc.IS_VISIBLE = TRUE
          AND d.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(dimension_rows or {}) do
        local dimension = {
            kind = "DIMENSION",
            id = row_value(row, "DIMENSION_ID", 1),
            name = row_value(row, "DIMENSION_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            display_name = row_value(row, "DISPLAY_NAME", 6),
        }
        ctx.dimensions[#ctx.dimensions + 1] = dimension
        ctx.dimension_by_id[key(dimension.id)] = dimension
        ctx.canonical_fields[upper(dimension.name)] = dimension
    end

    local metric_rows = query([[
        SELECT mt.METRIC_ID, mt.METRIC_NAME, mt.BASE_ENTITY_ID, mt.EXPRESSION,
               COALESCE(mt.SQL_FILTER_EXPR, mt.FILTER_EXPR) AS FILTER_EXPR,
               mt.METRIC_TYPE, mt.DATA_TYPE, mt.DISPLAY_NAME,
               COALESCE(mt.METRIC_KIND, mt.METRIC_TYPE) AS METRIC_KIND
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'METRIC'
          AND oc.IS_VISIBLE = TRUE
          AND mt.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(metric_rows or {}) do
        local metric = {
            kind = "METRIC",
            id = row_value(row, "METRIC_ID", 1),
            name = row_value(row, "METRIC_NAME", 2),
            base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            filter_expr = row_value(row, "FILTER_EXPR", 5),
            metric_type = row_value(row, "METRIC_TYPE", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            display_name = row_value(row, "DISPLAY_NAME", 8),
            metric_kind = row_value(row, "METRIC_KIND", 9),
        }
        ctx.metrics[#ctx.metrics + 1] = metric
        ctx.metric_by_id[key(metric.id)] = metric
        ctx.canonical_fields[upper(metric.name)] = metric
    end

    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY FACT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(fact_rows or {}) do
        local fact = {
            id = row_value(row, "FACT_ID", 1),
            name = row_value(row, "FACT_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
        }
        ctx.facts[#ctx.facts + 1] = fact
        ctx.fact_by_id[key(fact.id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

    local relationship_rows = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY,
               PATH_PRIORITY
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY PATH_PRIORITY, RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationship_rows or {}) do
        ctx.relationships[#ctx.relationships + 1] = {
            id = row_value(row, "RELATIONSHIP_ID", 1),
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
        }
    end

    local synonym_rows = query([[
        SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM
        FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE IN ('DIMENSION', 'METRIC')
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(synonym_rows or {}) do
        local object_type = row_value(row, "OBJECT_TYPE", 1)
        local object_id = row_value(row, "OBJECT_ID", 2)
        local synonym = upper(row_value(row, "SYNONYM", 3))
        local field = nil
        if object_type == "DIMENSION" then
            field = ctx.dimension_by_id[key(object_id)]
        elseif object_type == "METRIC" then
            field = ctx.metric_by_id[key(object_id)]
        end
        if field ~= nil then
            ctx.synonym_fields[synonym] = ctx.synonym_fields[synonym] or {}
            ctx.synonym_fields[synonym][#ctx.synonym_fields[synonym] + 1] = field
        end
    end

    return ctx
end

local function add_unique(list, seen, item)
    local item_key = item.kind .. ":" .. key(item.id)
    if not seen[item_key] then
        seen[item_key] = true
        list[#list + 1] = item
    end
end

local function resolve_field(ctx, field_name, expected_kind)
    if missing(field_name) then
        return nil, error_result("SEMANTIC_REQUEST_020", "Field name is required.")
    end
    local normalized = upper(trim(field_name))
    local exact = ctx.canonical_fields[normalized]
    if exact ~= nil then
        if expected_kind ~= nil and exact.kind ~= expected_kind then
            return nil, error_result("SEMANTIC_REQUEST_022", "Field " .. tostring(field_name) .. " is not a " .. expected_kind .. ".")
        end
        return exact, nil
    end

    local candidates = ctx.synonym_fields[normalized] or {}
    local filtered = {}
    for _, candidate in ipairs(candidates) do
        if expected_kind == nil or candidate.kind == expected_kind then
            filtered[#filtered + 1] = candidate
        end
    end
    if #filtered == 1 then
        return filtered[1], nil
    elseif #filtered > 1 then
        local names = {}
        for _, candidate in ipairs(filtered) do
            names[#names + 1] = candidate.name
        end
        return nil, error_result("SEMANTIC_REQUEST_021", "Ambiguous semantic field: " .. tostring(field_name), {
            message = "Ambiguous semantic field.",
            field = tostring(field_name),
            candidates = names,
            clarification_question = "Which field did you mean for " .. tostring(field_name) .. "?",
        })
    end
    return nil, error_result("SEMANTIC_REQUEST_020", "Unknown semantic field: " .. tostring(field_name) .. ".")
end

local function relationship_edges(ctx)
    local edges = {}
    local function add_edge(from_id, to_id, relationship)
        local from_key = key(from_id)
        edges[from_key] = edges[from_key] or {}
        edges[from_key][#edges[from_key] + 1] = {
            to_id = to_id,
            relationship = relationship,
        }
    end
    for _, relationship in ipairs(ctx.relationships) do
        local cardinality = upper(relationship.cardinality)
        if cardinality == "ONE_TO_ONE" then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        elseif cardinality == "MANY_TO_ONE" then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
        elseif cardinality == "ONE_TO_MANY" then
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        elseif cardinality == "MANY_TO_MANY" and not missing(relationship.fanout_policy) then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        end
    end
    return edges
end

local function find_path(ctx, from_id, to_id)
    if key(from_id) == key(to_id) then
        return {}
    end
    local edges = ctx._edges
    if edges == nil then
        edges = relationship_edges(ctx)
        ctx._edges = edges
    end
    local queue = {{id = from_id, path = {}}}
    local seen = {[key(from_id)] = true}
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        for _, edge in ipairs(edges[key(current.id)] or {}) do
            local next_key = key(edge.to_id)
            if not seen[next_key] then
                local next_path = {}
                for _, path_edge in ipairs(current.path) do
                    next_path[#next_path + 1] = path_edge
                end
                next_path[#next_path + 1] = {
                    from_entity_id = current.id,
                    to_entity_id = edge.to_id,
                    relationship = edge.relationship,
                }
                if next_key == key(to_id) then
                    return next_path
                end
                seen[next_key] = true
                queue[#queue + 1] = {id = edge.to_id, path = next_path}
            end
        end
    end
    return nil
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
    for alias in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.") do
        aliases[upper(alias)] = true
    end
    return aliases
end

local function replace_identifiers(text, replace_fn)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = c
            i = i + 1
        elseif string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local token = string.sub(text, i, j - 1)
            out[#out + 1] = replace_fn(token) or token
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function collect_metric_entities(ctx, metric, needed_entities, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then
        return
    end
    seen_metrics[metric_key] = true
    needed_entities[key(metric.base_entity_id)] = true
    for alias, _ in pairs(aliases_in_expression(metric.filter_expr)) do
        local entity = ctx.entity_by_alias[alias]
        if entity ~= nil then
            needed_entities[key(entity.id)] = true
        end
    end
    local dep_rows = query([[
        SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID = :metric_id
        ORDER BY DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
    ]], {metric_id = metric.id})
    for _, row in ipairs(dep_rows or {}) do
        local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
        local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
        if dep_type == "FACT" then
            local fact = ctx.fact_by_id[key(dep_id)]
            if fact ~= nil then
                needed_entities[key(fact.entity_id)] = true
            end
        elseif dep_type == "METRIC" then
            local dep_metric = ctx.metric_by_id[key(dep_id)]
            if dep_metric ~= nil then
                collect_metric_entities(ctx, dep_metric, needed_entities, seen_metrics)
            end
        end
    end
end

local function apply_metric_filter(expression, filter_expr)
    if missing(filter_expr) then
        return expression
    end
    local inner = string.match(expression, "^%s*SUM%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "SUM(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE 0 END)"
    end
    inner = string.match(expression, "^%s*COUNT%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "COUNT(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE NULL END)"
    end
    return "CASE WHEN " .. tostring(filter_expr) .. " THEN " .. expression .. " ELSE NULL END"
end

local function expand_metric(ctx, metric, stack)
    stack = stack or {}
    local metric_key = key(metric.id)
    if stack[metric_key] then
        error("Cyclic metric dependency detected while expanding " .. tostring(metric.name))
    end
    stack[metric_key] = true
    local expanded = replace_identifiers(tostring(metric.expression), function(token)
        local normalized = upper(token)
        local fact = ctx.fact_by_name[normalized]
        if fact ~= nil then
            return "(" .. tostring(fact.expression) .. ")"
        end
        for _, candidate in ipairs(ctx.metrics) do
            if upper(candidate.name) == normalized then
                return "(" .. expand_metric(ctx, candidate, stack) .. ")"
            end
        end
        return nil
    end)
    stack[metric_key] = nil
    return apply_metric_filter(expanded, metric.filter_expr)
end

local function build_dimension_predicate(expression, op, value, data_type, value_sql)
    local rhs = value_sql or sql_literal(value, data_type)
    local text_compare = value_sql == nil and is_text_type(data_type)
    if op == "=" or op == "!=" or op == "<>" or op == ">" or op == ">=" or op == "<" or op == "<=" or op == "LIKE" then
        if text_compare and (op == "=" or op == "!=" or op == "<>" or op == "LIKE") then
            return "UPPER(" .. expression .. ") " .. op .. " UPPER(" .. rhs .. ")"
        end
        return expression .. " " .. op .. " " .. rhs
    elseif op == "IN" then
        local values = as_array(value, "filter.value")
        if #values == 0 then
            return nil, error_result("SEMANTIC_REQUEST_032", "IN filter requires at least one value.")
        end
        local literals = {}
        for _, item in ipairs(values) do
            local literal = sql_literal(item, data_type)
            if is_text_type(data_type) then
                literal = "UPPER(" .. literal .. ")"
            end
            literals[#literals + 1] = literal
        end
        if is_text_type(data_type) then
            return "UPPER(" .. expression .. ") IN (" .. table.concat(literals, ", ") .. ")", nil
        end
        return expression .. " IN (" .. table.concat(literals, ", ") .. ")", nil
    elseif op == "BETWEEN" then
        local values = as_array(value, "filter.value")
        if #values ~= 2 then
            return nil, error_result("SEMANTIC_REQUEST_032", "BETWEEN filter requires exactly two values.")
        end
        return expression .. " BETWEEN " .. sql_literal(values[1], data_type) .. " AND " .. sql_literal(values[2], data_type), nil
    end
    return nil, error_result("SEMANTIC_REQUEST_033", "Unsupported filter operator: " .. tostring(op) .. ". Supported operators: =, !=, <>, >, >=, <, <=, LIKE, IN, BETWEEN.")
end

local function build_filters(ctx, request_filters, selected_dimensions, needed_entities)
    local filters = {}
    local filter_dimensions = {}
    local filter_seen = {}
    for _, filter in ipairs(as_array(request_filters, "filters")) do
        if type(filter) ~= "table" then
            return nil, nil, error_result("SEMANTIC_REQUEST_030", "Each filter must be an object.")
        end
        local filter_field = filter.field or filter.dimension or filter.column or filter.name
        if missing(filter_field) then
            return nil, nil, error_result("SEMANTIC_REQUEST_020", "Filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local field, err = resolve_field(ctx, filter_field, nil)
        if err ~= nil then
            return nil, nil, err
        end
        if field.kind ~= "DIMENSION" then
            return nil, nil, error_result("SEMANTIC_REQUEST_031", "MVP filters support dimensions only: " .. tostring(filter_field) .. ".")
        end
        local op = upper(filter.op or filter.operator or "=")
        if missing(filter.value) and missing(filter.value_sql) and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return nil, nil, error_result("SEMANTIC_REQUEST_015",
                "Filter for field '" .. tostring(field.name) .. "' requires a value or value_sql key.")
        end
        local expression = tostring(field.expression)
        local predicate, predicate_err = build_dimension_predicate(expression, op, filter.value, field.data_type, filter.value_sql)
        if predicate_err ~= nil then
            return nil, nil, predicate_err
        end
        filters[#filters + 1] = {
            field = field.name,
            field_id = field.id,
            field_kind = field.kind,
            op = op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = field.data_type,
            expression = expression,
            predicate = predicate,
        }
        needed_entities[key(field.entity_id)] = true
        add_unique(filter_dimensions, filter_seen, field)
    end
    return filters, filter_dimensions, nil
end

local function collect_intrinsic_filter_dimensions(ctx, metrics, needed_entities)
    local dimensions = {}
    local seen = {}
    for _, metric in ipairs(metrics or {}) do
        local rows = query([[
            SELECT REQUIRED_DIMENSION_ID
            FROM SYS_SEMANTIC.METRIC_FILTERS
            WHERE METRIC_ID = :metric_id
              AND REQUIRED_DIMENSION_ID IS NOT NULL
            ORDER BY ORDINAL_POSITION
        ]], {metric_id = metric.id})
        for _, row in ipairs(rows or {}) do
            local dimension = ctx.dimension_by_id[key(row_value(row, "REQUIRED_DIMENSION_ID", 1))]
            if dimension ~= nil then
                needed_entities[key(dimension.entity_id)] = true
                add_unique(dimensions, seen, dimension)
            end
        end
    end
    return dimensions
end

local function validate_metric_dimensions(ctx, metrics, dimensions)
    for _, metric in ipairs(metrics) do
        for _, dimension in ipairs(dimensions) do
            local rows = query([[
                SELECT IS_VALID, REASON_CODE, RELATIONSHIP_PATH
                FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND METRIC_ID = :metric_id
                  AND DIMENSION_ID = :dimension_id
            ]], {
                model_id = ctx.model.model_id,
                version_id = ctx.model.version_id,
                metric_id = metric.id,
                dimension_id = dimension.id,
            })
            if rows == nil or #rows == 0 then
                return error_result("SEMANTIC_REQUEST_040", "Missing validation matrix row for " .. tostring(metric.name) .. " and " .. tostring(dimension.name) .. ".")
            end
            local is_valid = row_value(rows[1], "IS_VALID", 1)
            if not boolish(is_valid) then
                return error_result("SEMANTIC_REQUEST_041", "Metric " .. tostring(metric.name) .. " cannot be grouped or filtered by dimension " .. tostring(dimension.name) .. ": " .. tostring(row_value(rows[1], "REASON_CODE", 2)) .. ".")
            end
        end
    end
    return nil
end

local function plan_joins(ctx, needed_entities)
    local root_id = ctx.object.root_entity_id
    needed_entities[key(root_id)] = true
    local joins = {}
    local joined_entities = {[key(root_id)] = true}
    local joined_relationships = {}
    local relationship_paths = {}

    local entity_ids = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(root_id) then
            entity_ids[#entity_ids + 1] = entity_id
        end
    end
    table.sort(entity_ids)

    for _, entity_id in ipairs(entity_ids) do
        local path = find_path(ctx, root_id, entity_id)
        if path == nil then
            local entity = ctx.entity_by_id[entity_id]
            return nil, nil, error_result("SEMANTIC_REQUEST_042", "No safe relationship path from semantic object root to entity " .. tostring(entity and entity.name or entity_id) .. ".")
        end
        local path_names = {}
        for _, edge in ipairs(path) do
            local relationship = edge.relationship
            path_names[#path_names + 1] = relationship.name
            local join_key = key(relationship.id)
            local to_entity_key = key(edge.to_entity_id)
            if not joined_relationships[join_key] and not joined_entities[to_entity_key] then
                joins[#joins + 1] = {
                    relationship = relationship,
                    entity = ctx.entity_by_id[to_entity_key],
                }
                joined_relationships[join_key] = true
                joined_entities[to_entity_key] = true
            end
        end
        relationship_paths[#relationship_paths + 1] = table.concat(path_names, " > ")
    end
    return joins, relationship_paths, nil
end

local function build_order_by(ctx, request_order_by, output_fields)
    local clauses = {}
    for _, item in ipairs(as_array(request_order_by, "order_by")) do
        if type(item) ~= "table" then
            return nil, error_result("SEMANTIC_REQUEST_060", "Each order_by item must be an object.")
        end
        local field, err = resolve_field(ctx, item.field, nil)
        if err ~= nil then
            return nil, err
        end
        if not output_fields[field.kind .. ":" .. key(field.id)] then
            return nil, error_result("SEMANTIC_REQUEST_061", "ORDER BY field must be selected in the MVP: " .. tostring(item.field) .. ".")
        end
        local direction = upper(item.direction or "ASC")
        if direction ~= "ASC" and direction ~= "DESC" then
            return nil, error_result("SEMANTIC_REQUEST_062", "Unsupported ORDER BY direction: " .. tostring(item.direction) .. ".")
        end
        clauses[#clauses + 1] = quote_alias(field.name) .. " " .. direction
    end
    return clauses, nil
end

local function build_sql(ctx, dimensions, metrics, filters, joins, order_by, limit, having_predicates)
    local root = ctx.entity_by_id[key(ctx.object.root_entity_id)]
    local select_parts = {}
    local group_parts = {}
    for _, dimension in ipairs(dimensions) do
        select_parts[#select_parts + 1] = tostring(dimension.expression) .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, metric in ipairs(metrics) do
        select_parts[#select_parts + 1] = expand_metric(ctx, metric) .. " AS " .. quote_alias(metric.name)
    end

    local sql_parts = {}
    sql_parts[#sql_parts + 1] = "SELECT " .. table.concat(select_parts, ", ")
    sql_parts[#sql_parts + 1] = "FROM " .. quote_qualified(root.source_schema, root.source_object) .. " " .. tostring(root.alias)
    for _, join in ipairs(joins) do
        sql_parts[#sql_parts + 1] = tostring(join.relationship.join_type or "LEFT") .. " JOIN "
            .. quote_qualified(join.entity.source_schema, join.entity.source_object)
            .. " " .. tostring(join.entity.alias)
            .. " ON " .. tostring(join.relationship.join_condition)
    end
    if #filters > 0 then
        local predicates = {}
        for _, filter in ipairs(filters) do
            predicates[#predicates + 1] = filter.predicate
        end
        sql_parts[#sql_parts + 1] = "WHERE " .. table.concat(predicates, " AND ")
    end
    if #group_parts > 0 then
        sql_parts[#sql_parts + 1] = "GROUP BY " .. table.concat(group_parts, ", ")
    end
    if having_predicates ~= nil and #having_predicates > 0 then
        sql_parts[#sql_parts + 1] = "HAVING " .. table.concat(having_predicates, " AND ")
    end
    if #order_by > 0 then
        sql_parts[#sql_parts + 1] = "ORDER BY " .. table.concat(order_by, ", ")
    end
    if limit ~= nil then
        sql_parts[#sql_parts + 1] = "LIMIT " .. tostring(limit)
    end
    return table.concat(sql_parts, "\n")
end

local function build_materialized_sql(ctx, dimensions, metrics, filters, order_by, limit, materialization)
    local alias = "mat"
    local select_parts = {}
    local group_parts = {}
    local uses_aggregate = false
    for _, dimension in ipairs(dimensions) do
        local column = materialization.columns[dimension.kind .. ":" .. key(dimension.id)]
        local expression = quote_column(alias, column.physical_column)
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = expression
    end
    for _, metric in ipairs(metrics) do
        local metric_key = metric.kind .. ":" .. key(metric.id)
        local column = materialization.columns[metric_key]
        local column_expression = quote_column(alias, column.physical_column)
        local policy = materialization.metric_rollup_policies and materialization.metric_rollup_policies[metric_key] or "DIRECT"
        local expression = column_expression
        if policy == "SUM" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MIN" then
            expression = "MIN(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MAX" then
            expression = "MAX(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "COUNT" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        end
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(metric.name)
    end

    local sql_parts = {}
    sql_parts[#sql_parts + 1] = "SELECT " .. table.concat(select_parts, ", ")
    sql_parts[#sql_parts + 1] = "FROM " .. quote_qualified(materialization.physical_schema, materialization.physical_object) .. " " .. alias
    if #filters > 0 then
        local predicates = {}
        for _, filter in ipairs(filters) do
            local column = materialization.columns[tostring(filter.field_kind) .. ":" .. key(filter.field_id)]
            local predicate, predicate_err = build_dimension_predicate(
                quote_column(alias, column.physical_column),
                filter.op,
                filter.value,
                filter.data_type,
                filter.value_sql
            )
            if predicate_err ~= nil then
                error(predicate_err.error_message or "Invalid materialized filter predicate.")
            end
            predicates[#predicates + 1] = predicate
        end
        sql_parts[#sql_parts + 1] = "WHERE " .. table.concat(predicates, " AND ")
    end
    if uses_aggregate and #group_parts > 0 then
        sql_parts[#sql_parts + 1] = "GROUP BY " .. table.concat(group_parts, ", ")
    end
    if #order_by > 0 then
        sql_parts[#sql_parts + 1] = "ORDER BY " .. table.concat(order_by, ", ")
    end
    if limit ~= nil then
        sql_parts[#sql_parts + 1] = "LIMIT " .. tostring(limit)
    end
    return table.concat(sql_parts, "\n")
end

local function log_request(result, request_json, request, model)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    local dimensions = request and request.dimensions or {}
    local metrics = request and request.metrics or {}
    query([[
        INSERT INTO SYS_SEMANTIC.AGENT_REQUEST_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, PURPOSE, REQUEST_JSON, GENERATED_SQL,
          PLAN_JSON, REQUESTED_METRICS, REQUESTED_DIMENSIONS, STATUS, ERROR_CODE, ERROR_MESSAGE, FINISHED_AT
        ) VALUES (
          :model_id, :version_id, :client_name, :purpose, :request_json, :generated_sql,
          :plan_json, :requested_metrics, :requested_dimensions, :status, :error_code, :error_message, CURRENT_TIMESTAMP
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = request and null_if_missing(request.client) or null,
        purpose = request and null_if_missing(request.purpose) or null,
        request_json = null_if_missing(request_json),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_metrics = null_if_missing(json_encode(metrics)),
        requested_dimensions = null_if_missing(json_encode(dimensions)),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
    })
    result.agent_request_id = scalar([[
        SELECT MAX(AGENT_REQUEST_ID)
        FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
        WHERE USER_NAME = CURRENT_USER
    ]])
end

local function log_query_result(result, original_sql, request, model, client_name)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    local dimensions = request and request.dimensions or {}
    local metrics = request and request.metrics or {}
    query([[
        INSERT INTO SYS_SEMANTIC.QUERY_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, ORIGINAL_SQL, GENERATED_SQL,
          PLAN_JSON, REQUESTED_DIMENSIONS, REQUESTED_METRICS, MATERIALIZATION_USED,
          STATUS, ERROR_CODE,
          ERROR_MESSAGE, FINISHED_AT
        ) VALUES (
          :model_id, :version_id, :client_name, :original_sql, :generated_sql,
          :plan_json, :requested_dimensions, :requested_metrics, :materialization_used,
          :status, :error_code,
          :error_message, CURRENT_TIMESTAMP
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = null_if_missing(client_name or "COMPILE_SQL_DEBUG"),
        original_sql = null_if_missing(original_sql),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_dimensions = null_if_missing(json_encode(dimensions)),
        requested_metrics = null_if_missing(json_encode(metrics)),
        materialization_used = null_if_missing(result.materialization_used),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
    })
    result.query_log_id = scalar([[
        SELECT MAX(QUERY_LOG_ID)
        FROM SYS_SEMANTIC.QUERY_LOG
        WHERE USER_NAME = CURRENT_USER
    ]])
end

local function latest_successful_validation(model)
    local rows = query([[
        SELECT VALIDATION_RUN_ID, STATUS, ERROR_COUNT
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'OK'
          AND ERROR_COUNT = 0
        ORDER BY VALIDATION_RUN_ID DESC
        LIMIT 1
    ]], {model_id = model.model_id, version_id = model.version_id})
    if rows == nil or #rows == 0 then
        return nil, "No validation run exists for this model version."
    end
    return row_value(rows[1], "VALIDATION_RUN_ID", 1), nil
end

local function load_model_by_published_schema(schema_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.MODEL_NAME, m.ACTIVE_VERSION_ID AS VERSION_ID, mv.VERSION_NUMBER
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.PUBLISHED_SCHEMA) = UPPER(:schema_name)
    ]], {schema_name = schema_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        model_name = row_value(rows[1], "MODEL_NAME", 2),
        version_id = row_value(rows[1], "VERSION_ID", 3),
        version_number = row_value(rows[1], "VERSION_NUMBER", 4),
    }
end

local function compile_request_table(request, options)
    options = options or {}
    local error_prefix = options.error_prefix or "SEMANTIC_REQUEST"

    local ok_model_name, model_name = pcall(normalize_name, request.model, "model")
    if not ok_model_name then
        return error_result(error_prefix .. "_002", tostring(model_name) .. ".")
    end
    local ok_object_name, object_name = pcall(normalize_name, request.object, "object")
    if not ok_object_name then
        return error_result(error_prefix .. "_003", tostring(object_name) .. ".")
    end

    local model = options.model or load_model(model_name)
    if model == nil then
        return error_result(error_prefix .. "_011", "Model not found: " .. model_name .. ".")
    end

    local ctx, load_code, load_message = load_catalog(model, object_name)
    if ctx == nil then
        return error_result(load_code, load_message)
    end

    local selected_dimensions = {}
    local selected_dimension_seen = {}
    for _, dimension_name in ipairs(as_array(request.dimensions, "dimensions")) do
        local field, err = resolve_field(ctx, dimension_name, "DIMENSION")
        if err ~= nil then
            return err
        end
        add_unique(selected_dimensions, selected_dimension_seen, field)
    end

    local selected_metrics = {}
    local selected_metric_seen = {}
    for _, metric_name in ipairs(as_array(request.metrics, "metrics")) do
        local field, err = resolve_field(ctx, metric_name, "METRIC")
        if err ~= nil then
            return err
        end
        add_unique(selected_metrics, selected_metric_seen, field)
    end
    if #selected_metrics == 0 then
        return error_result("SEMANTIC_REQUEST_023", "At least one metric is required.")
    end

    local needed_entities = {[key(ctx.object.root_entity_id)] = true}
    local all_dimensions = {}
    local all_dimension_seen = {}
    for _, dimension in ipairs(selected_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
        needed_entities[key(dimension.entity_id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        collect_metric_entities(ctx, metric, needed_entities, {})
    end

    local filters, filter_dimensions, filter_err = build_filters(ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then
        return filter_err
    end
    local filter_dimension_seen = {}
    for _, dimension in ipairs(filter_dimensions) do
        filter_dimension_seen[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    local intrinsic_filter_dimensions = collect_intrinsic_filter_dimensions(ctx, selected_metrics, needed_entities)
    for _, dimension in ipairs(intrinsic_filter_dimensions) do
        add_unique(filter_dimensions, filter_dimension_seen, dimension)
    end
    for _, dimension in ipairs(filter_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
    end

    local validation_run_id = nil
    if options.validate == false then
        local validation_message
        validation_run_id, validation_message = latest_successful_validation(model)
        if validation_run_id == nil then
            return error_result(error_prefix .. "_010", "Model validation is missing or stale: " .. validation_message)
        end
    else
        local validation_errors
        validation_errors, validation_run_id = validate_model(model)
        local referenced = collect_referenced_validation_objects(ctx, selected_metrics, all_dimensions)
        for _, validation_error in ipairs(validation_errors) do
            if validation_error_applies(validation_error, referenced) then
                return error_result(error_prefix .. "_010", "Model validation failed: " .. tostring(validation_error.code) .. " " .. tostring(validation_error.message))
            end
        end
    end

    local matrix_err = validate_metric_dimensions(ctx, selected_metrics, all_dimensions)
    if matrix_err ~= nil then
        return matrix_err
    end

    local joins, relationship_paths, join_err = plan_joins(ctx, needed_entities)
    if join_err ~= nil then
        return join_err
    end

    local limit = nil
    if not missing(request.limit) then
        limit = tonumber(request.limit)
        if limit == nil or limit < 1 or limit % 1 ~= 0 then
            return error_result("SEMANTIC_REQUEST_050", "LIMIT must be a positive integer.")
        end
        if limit > MAX_LIMIT then
            return error_result("SEMANTIC_REQUEST_051", "LIMIT exceeds maximum " .. tostring(MAX_LIMIT) .. ".")
        end
    end

    local output_fields = {}
    for _, dimension in ipairs(selected_dimensions) do
        output_fields[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        output_fields[metric.kind .. ":" .. key(metric.id)] = true
    end
    local order_by, order_err = build_order_by(ctx, request.order_by, output_fields)
    if order_err ~= nil then
        return order_err
    end

    local having_predicates = {}
    for _, having_filter in ipairs(as_array(request.having, "having")) do
        if type(having_filter) ~= "table" then
            return error_result("SEMANTIC_REQUEST_030", "Each having filter must be an object.")
        end
        local filter_field = having_filter.field or having_filter.dimension or having_filter.column or having_filter.name
        if missing(filter_field) then
            -- SEMANTIC_REQUEST_025: having filter structure error (missing field key), distinct from
            -- SEMANTIC_REQUEST_020 (unknown field name) so agents can handle each differently.
            return error_result("SEMANTIC_REQUEST_025", "Having filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local metric_field, having_err = resolve_field(ctx, filter_field, "METRIC")
        if having_err ~= nil then
            return having_err
        end
        local op = upper(having_filter.op or having_filter.operator or "=")
        local expr = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(expr, op, having_filter.value, metric_field.data_type, having_filter.value_sql)
        if predicate_err ~= nil then
            return predicate_err
        end
        having_predicates[#having_predicates + 1] = predicate
    end

    local selected_materialization = nil
    local materialization_decision = {
        candidate_count = 0,
        rejected_materializations = {},
        selected_materialization = JSON_NULL,
    }
    if materialization_runtime ~= nil and type(materialization_runtime.select_materialization) == "function" and #having_predicates == 0 then
        selected_materialization, materialization_decision = materialization_runtime.select_materialization(
            ctx,
            selected_dimensions,
            selected_metrics,
            filter_dimensions
        )
    end

    local sql_text
    if selected_materialization ~= nil then
        sql_text = build_materialized_sql(ctx, selected_dimensions, selected_metrics, filters, order_by, limit, selected_materialization)
    else
        sql_text = build_sql(ctx, selected_dimensions, selected_metrics, filters, joins, order_by, limit, having_predicates)
    end

    local plan = {
        model = model.model_name,
        version_id = model.version_id,
        version_number = model.version_number,
        object = ctx.object.name,
        metrics = {},
        metric_details = {},
        dimensions = {},
        filters = filters,
        relationship_paths = relationship_paths,
        selected_materialization = JSON_NULL,
        materialization_decision = materialization_decision,
        validation_run_id = validation_run_id,
        warnings = {},
    }
    if selected_materialization ~= nil then
        plan.selected_materialization = {
            materialization_id = selected_materialization.materialization_id,
            materialization_name = selected_materialization.materialization_name,
            physical_schema = selected_materialization.physical_schema,
            physical_object = selected_materialization.physical_object,
            materialization_type = selected_materialization.materialization_type,
            rollup_required = selected_materialization.rollup_required,
        }
    end
    for _, metric in ipairs(selected_metrics) do
        plan.metrics[#plan.metrics + 1] = metric.name
        local detail = {
            name = metric.name,
            metric_kind = metric.metric_kind or metric.metric_type,
            metric_type = metric.metric_type,
            input_roles = {},
        }
        for _, row in ipairs(query([[
            SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, EXPRESSION_ALIAS
            FROM SYS_SEMANTIC.METRIC_INPUTS
            WHERE METRIC_ID = :metric_id
            ORDER BY ORDINAL_POSITION
        ]], {metric_id = metric.id}) or {}) do
            detail.input_roles[#detail.input_roles + 1] = {
                role = row_value(row, "INPUT_ROLE", 1),
                object_type = row_value(row, "INPUT_OBJECT_TYPE", 2),
                alias = row_value(row, "EXPRESSION_ALIAS", 3),
            }
        end
        plan.metric_details[#plan.metric_details + 1] = detail
    end
    for _, dimension in ipairs(selected_dimensions) do
        plan.dimensions[#plan.dimensions + 1] = dimension.name
    end
    return ok_result(sql_text, plan, validation_run_id), request, model
end

local function compile_internal(request_json)
    local decoded, request = pcall(json_decode, request_json)
    if not decoded then
        return error_result("SEMANTIC_REQUEST_001", "Invalid request JSON: " .. tostring(request) .. ".")
    end
    if type(request) ~= "table" or is_array(request) then
        return error_result("SEMANTIC_REQUEST_001", "Request JSON must be an object.")
    end
    return compile_request_table(request, {validate = true, error_prefix = "SEMANTIC_REQUEST"})
end

local function decode_quoted_identifier(token)
    local text = tostring(token)
    if string.sub(text, 1, 1) ~= '"' then
        return text
    end
    local inner = string.sub(text, 2, -2)
    return string.gsub(inner, '""', '"')
end

local function sql_tokens(sql_text)
    local tokens = {}
    local text = tostring(sql_text)
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if string.match(c, "%s") then
            i = i + 1
        elseif c == "-" and n == "-" then
            i = i + 2
            while i <= #text and string.sub(text, i, i) ~= "\n" do
                i = i + 1
            end
        elseif c == "/" and n == "*" then
            i = i + 2
            while i <= #text - 1 and string.sub(text, i, i + 1) ~= "*/" do
                i = i + 1
            end
            i = math.min(i + 2, #text + 1)
        elseif c == "'" then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == "'" and n == "'" then
                    i = i + 2
                elseif c == "'" then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "literal"}
        elseif c == '"' then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == '"' and n == '"' then
                    i = i + 2
                elseif c == '"' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "identifier", value = decode_quoted_identifier(token_text)}
        elseif string.match(c, "[A-Za-z_]") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[A-Za-z0-9_]") do
                i = i + 1
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "word", value = token_text, upper = upper(token_text)}
        elseif string.match(c, "%d") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[0-9.]") do
                i = i + 1
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "number"}
        else
            local two = string.sub(text, i, i + 1)
            if two == ">=" or two == "<=" or two == "<>" or two == "!=" then
                tokens[#tokens + 1] = {text = two, kind = "operator", upper = two}
                i = i + 2
            else
                tokens[#tokens + 1] = {text = c, kind = "symbol", upper = c}
                i = i + 1
            end
        end
    end
    if #tokens > 0 and tokens[#tokens].text == ";" then
        table.remove(tokens, #tokens)
    end
    return tokens
end

local function token_upper(token)
    if token == nil then
        return nil
    end
    return token.upper or upper(token.text)
end

local function token_identifier_value(token)
    if token == nil then
        return nil
    end
    if token.kind == "identifier" or token.kind == "word" then
        return token.value or token.text
    end
    return nil
end

local function split_top_level(tokens, start_index, end_index, separator)
    local parts = {}
    local current = {}
    local depth = 0
    for i = start_index, end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        end
        if depth == 0 and token.text == separator then
            parts[#parts + 1] = current
            current = {}
        else
            current[#current + 1] = token
        end
    end
    if #current > 0 then
        parts[#parts + 1] = current
    end
    return parts
end

local function identifier_from_part(part)
    if #part == 0 then
        return nil
    end
    local end_index = #part
    for i, token in ipairs(part) do
        if token_upper(token) == "AS" then
            end_index = i - 1
            break
        end
    end
    if end_index >= 3 and part[end_index - 1].text == "." then
        return token_identifier_value(part[end_index])
    end
    if end_index == 1 then
        return token_identifier_value(part[1])
    end
    if end_index >= 1 and (part[1].kind == "word" or part[1].kind == "identifier") then
        if end_index == 2 and (part[2].kind == "word" or part[2].kind == "identifier") then
            return token_identifier_value(part[1])
        end
    end
    return nil
end

local function alias_from_select_part(part)
    for i, token in ipairs(part) do
        if token_upper(token) == "AS" and part[i + 1] ~= nil then
            return token_identifier_value(part[i + 1])
        end
    end
    if #part == 2 and (part[1].kind == "word" or part[1].kind == "identifier") and (part[2].kind == "word" or part[2].kind == "identifier") then
        return token_identifier_value(part[2])
    end
    return nil
end

local function literal_from_tokens(tokens)
    if #tokens == 1 then
        local token = tokens[1]
        if token.kind == "literal" then
            local raw = string.sub(token.text, 2, -2)
            return string.gsub(raw, "''", "'")
        elseif token.kind == "number" then
            return tonumber(token.text) or token.text
        elseif token.kind == "word" then
            return token.value
        end
    elseif #tokens == 2 and token_upper(tokens[1]) == "DATE" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    elseif #tokens == 2 and token_upper(tokens[1]) == "TIMESTAMP" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    end
    return nil
end

local function find_top_level_clauses(tokens)
    local clauses = {}
    local depth = 0
    for i, token in ipairs(tokens) do
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "FROM" or u == "WHERE" or u == "LIMIT" or u == "HAVING" then
                clauses[u] = clauses[u] or i
            elseif u == "GROUP" and token_upper(tokens[i + 1]) == "BY" then
                clauses.GROUP_BY = clauses.GROUP_BY or i
            elseif u == "ORDER" and token_upper(tokens[i + 1]) == "BY" then
                clauses.ORDER_BY = clauses.ORDER_BY or i
            end
        end
    end
    return clauses
end

local function clause_end(tokens, clauses, current_name)
    local start_index = clauses[current_name]
    local best = #tokens + 1
    for _, candidate in ipairs({"FROM", "WHERE", "GROUP_BY", "HAVING", "ORDER_BY", "LIMIT"}) do
        local pos = clauses[candidate]
        if pos ~= nil and pos > start_index and pos < best then
            best = pos
        end
    end
    return best - 1
end

local function token_slice(tokens, first, last)
    local out = {}
    for i = first, last do
        out[#out + 1] = tokens[i]
    end
    return out
end

local function render_token_slice(tokens)
    local parts = {}
    for _, token in ipairs(tokens or {}) do
        parts[#parts + 1] = token.text
    end
    return table.concat(parts, " ")
end

local function parse_where_filters(tokens, start_index, end_index)
    local filters = {}
    local chunks = {}
    -- Split on top-level AND conjunctions, but skip the AND that belongs to a
    -- BETWEEN...AND range (e.g. "field BETWEEN v1 AND v2").
    local current_start = start_index
    local depth = 0
    local after_between = false
    local i = start_index
    while i <= end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "BETWEEN" then
                after_between = true
            elseif u == "AND" then
                if after_between then
                    after_between = false
                else
                    chunks[#chunks + 1] = {current_start, i - 1}
                    current_start = i + 1
                end
            end
        end
        i = i + 1
    end
    chunks[#chunks + 1] = {current_start, end_index}

    for _, chunk in ipairs(chunks) do
        local first = chunk[1]
        local last = chunk[2]
        local op_index = nil
        local op = nil
        for idx = first, last do
            local u = token_upper(tokens[idx])
            if u == "IN" or u == "BETWEEN" or u == "LIKE" or u == "=" or u == "!=" or u == "<>" or u == ">" or u == ">=" or u == "<" or u == "<=" then
                op_index = idx
                op = u
                break
            end
        end
        if op_index == nil then
            return nil, error_result("SEMANTIC_QUERY_030", "Unsupported WHERE predicate.")
        end
        local field = identifier_from_part(token_slice(tokens, first, op_index - 1))
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_031", "WHERE predicate must start with a semantic dimension.")
        end
        if op == "IN" then
            if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "(" or tokens[last].text ~= ")" then
                return nil, error_result("SEMANTIC_QUERY_032", "IN predicate requires a literal list.")
            end
            local values = {}
            for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                local value = literal_from_tokens(part)
                if value == nil then
                    return nil, error_result("SEMANTIC_QUERY_033", "IN predicate supports literal values only.")
                end
                values[#values + 1] = value
            end
            filters[#filters + 1] = {field = field, op = "IN", value = values}
        elseif op == "BETWEEN" then
            local and_index = nil
            for idx = op_index + 1, last do
                if token_upper(tokens[idx]) == "AND" then
                    and_index = idx
                    break
                end
            end
            if and_index == nil then
                return nil, error_result("SEMANTIC_QUERY_034", "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
            end
            local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
            local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
            if v1 == nil or v2 == nil then
                return nil, error_result("SEMANTIC_QUERY_035", "BETWEEN predicate requires two literal values.")
            end
            filters[#filters + 1] = {field = field, op = "BETWEEN", value = {v1, v2}}
        else
            local value_tokens = token_slice(tokens, op_index + 1, last)
            local value = literal_from_tokens(value_tokens)
            if value == nil then
                local value_sql = trim(render_token_slice(value_tokens))
                if value_sql == "" then
                    return nil, error_result("SEMANTIC_QUERY_033", "WHERE predicate requires a right-hand value.")
                end
                filters[#filters + 1] = {field = field, op = op, value = null, value_sql = value_sql}
            else
                filters[#filters + 1] = {field = field, op = op, value = value}
            end
        end
    end
    return filters, nil
end

local function parse_having_filters(ctx, tokens, start_index, end_index)
    local filters = {}
    local chunks = {}
    local current_start = start_index
    local depth = 0
    local after_between = false
    local i = start_index
    while i <= end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "BETWEEN" then
                after_between = true
            elseif u == "AND" then
                if after_between then
                    after_between = false
                else
                    chunks[#chunks + 1] = {current_start, i - 1}
                    current_start = i + 1
                end
            end
        end
        i = i + 1
    end
    chunks[#chunks + 1] = {current_start, end_index}

    for _, chunk in ipairs(chunks) do
        local first = chunk[1]
        local last = chunk[2]
        local op_index = nil
        local op = nil
        for idx = first, last do
            local u = token_upper(tokens[idx])
            if u == "IN" or u == "BETWEEN" or u == "LIKE" or u == "=" or u == "!=" or u == "<>" or u == ">" or u == ">=" or u == "<" or u == "<=" then
                op_index = idx
                op = u
                break
            end
        end
        if op_index == nil then
            return nil, error_result("SEMANTIC_QUERY_030", "Unsupported HAVING predicate.")
        end
        local field = identifier_from_part(token_slice(tokens, first, op_index - 1))
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_031", "HAVING predicate must start with a semantic metric.")
        end
        local resolved, resolve_err = resolve_field(ctx, field, nil)
        if resolve_err ~= nil then
            return nil, recode_error_prefix(resolve_err, "SEMANTIC_QUERY")
        end
        if resolved.kind ~= "METRIC" then
            return nil, error_result("SEMANTIC_QUERY_040", "HAVING supports metric predicates only. Use WHERE for dimension filters.")
        end
        if op == "IN" then
            if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "(" or tokens[last].text ~= ")" then
                return nil, error_result("SEMANTIC_QUERY_032", "IN predicate requires a literal list.")
            end
            local values = {}
            for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                local value = literal_from_tokens(part)
                if value == nil then
                    return nil, error_result("SEMANTIC_QUERY_033", "IN predicate supports literal values only.")
                end
                values[#values + 1] = value
            end
            filters[#filters + 1] = {field = resolved.name, op = "IN", value = values}
        elseif op == "BETWEEN" then
            local and_index = nil
            for idx = op_index + 1, last do
                if token_upper(tokens[idx]) == "AND" then
                    and_index = idx
                    break
                end
            end
            if and_index == nil then
                return nil, error_result("SEMANTIC_QUERY_034", "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
            end
            local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
            local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
            if v1 == nil or v2 == nil then
                return nil, error_result("SEMANTIC_QUERY_035", "BETWEEN predicate requires two literal values.")
            end
            filters[#filters + 1] = {field = resolved.name, op = "BETWEEN", value = {v1, v2}}
        else
            local value_tokens = token_slice(tokens, op_index + 1, last)
            local value = literal_from_tokens(value_tokens)
            if value == nil then
                local value_sql = trim(render_token_slice(value_tokens))
                if value_sql == "" then
                    return nil, error_result("SEMANTIC_QUERY_033", "HAVING predicate requires a right-hand value.")
                end
                filters[#filters + 1] = {field = resolved.name, op = op, value = null, value_sql = value_sql}
            else
                filters[#filters + 1] = {field = resolved.name, op = op, value = value}
            end
        end
    end
    return filters, nil
end

local function parse_order_by(tokens, start_index, end_index, select_aliases, selected_output)
    local order_by = {}
    for _, part in ipairs(split_top_level(tokens, start_index, end_index, ",")) do
        local direction = "ASC"
        if #part > 1 then
            local last = token_upper(part[#part])
            if last == "ASC" or last == "DESC" then
                direction = last
                table.remove(part, #part)
            end
        end
        local field = identifier_from_part(part)
        if field == nil and #part == 1 and part[1].kind == "number" then
            local ordinal = tonumber(part[1].text)
            if selected_output ~= nil then
                field = selected_output[ordinal]
            end
        end
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_060", "ORDER BY supports selected semantic fields only.")
        end
        if select_aliases ~= nil and select_aliases[upper(field)] ~= nil then
            field = select_aliases[upper(field)]
        end
        order_by[#order_by + 1] = {field = field, direction = direction}
    end
    return order_by, nil
end

local function parse_semantic_sql(sql_text, options)
    options = options or {}
    local tokens = sql_tokens(sql_text)
    if #tokens == 0 then
        if options.unchanged_nonsemantic then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_001", "SQL text is required.")
    end
    if token_upper(tokens[1]) ~= "SELECT" then
        if options.unchanged_nonsemantic then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_009", "Only top-level SELECT semantic SQL is supported.")
    end
    local clauses = find_top_level_clauses(tokens)
    if clauses.FROM == nil then
        return nil, error_result("SEMANTIC_QUERY_002", "Semantic SQL requires a FROM clause.")
    end
    local select_end = clauses.FROM - 1
    local from_end = clause_end(tokens, clauses, "FROM")
    local from_tokens = token_slice(tokens, clauses.FROM + 1, from_end)
    if #from_tokens < 3 or from_tokens[2].text ~= "." then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local published_schema = token_identifier_value(from_tokens[1])
    local object_name = token_identifier_value(from_tokens[3])
    if published_schema == nil or object_name == nil then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local model = load_model_by_published_schema(published_schema)
    if model == nil then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_004", "No semantic model is published to schema " .. tostring(published_schema) .. ".")
    end
    if options.unchanged_unknown_schema and upper(object_name) == "SEMANTIC_DISCOVERY" then
        return unchanged_result(sql_text), nil, model
    end
    if #from_tokens > 3 then
        local alias_ok = #from_tokens == 4 and token_identifier_value(from_tokens[4]) ~= nil
        local as_alias_ok = #from_tokens == 5 and token_upper(from_tokens[4]) == "AS" and token_identifier_value(from_tokens[5]) ~= nil
        if not alias_ok and not as_alias_ok then
            return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
        end
    end

    local ctx, load_code, load_message = load_catalog(model, object_name)
    if ctx == nil then
        return nil, recode_error_prefix(error_result(load_code, load_message), "SEMANTIC_QUERY")
    end

    local request = {
        model = model.model_name,
        object = object_name,
        metrics = {},
        dimensions = {},
        filters = {},
        having = {},
        order_by = {},
        client = "semantic-sql",
        purpose = "semantic_sql",
    }
    local selected_output = {}
    local select_aliases = {}
    local selected_dimension_seen = {}
    local selected_metric_seen = {}
    local select_parts = split_top_level(tokens, 2, select_end, ",")
    local wildcard_select = #select_parts == 1 and #select_parts[1] == 1 and select_parts[1][1].text == "*"
    if wildcard_select then
        for _, field in ipairs(ctx.dimensions) do
            selected_output[#selected_output + 1] = field.name
            request.dimensions[#request.dimensions + 1] = field.name
            selected_dimension_seen[upper(field.name)] = true
        end
        for _, field in ipairs(ctx.metrics) do
            selected_output[#selected_output + 1] = field.name
            request.metrics[#request.metrics + 1] = field.name
            selected_metric_seen[upper(field.name)] = true
        end
    end
    for _, part in ipairs(wildcard_select and {} or select_parts) do
        local field_name = identifier_from_part(part)
        if field_name == nil then
            return nil, error_result("SEMANTIC_QUERY_005", "SELECT supports semantic field names or *.")
        end
        local field, bind_err = resolve_field(ctx, field_name, nil)
        if bind_err ~= nil then
            return nil, recode_error_prefix(bind_err, "SEMANTIC_QUERY")
        end
        selected_output[#selected_output + 1] = field.name
        local output_alias = alias_from_select_part(part)
        if output_alias ~= nil then
            select_aliases[upper(output_alias)] = field.name
        end
        if field.kind == "DIMENSION" then
            if not selected_dimension_seen[upper(field.name)] then
                request.dimensions[#request.dimensions + 1] = field.name
                selected_dimension_seen[upper(field.name)] = true
            end
        elseif field.kind == "METRIC" then
            if not selected_metric_seen[upper(field.name)] then
                request.metrics[#request.metrics + 1] = field.name
                selected_metric_seen[upper(field.name)] = true
            end
        else
            return nil, error_result("SEMANTIC_QUERY_006", "Unsupported semantic field kind in SELECT.")
        end
    end

    if clauses.WHERE ~= nil then
        local raw_filters, filter_err = parse_where_filters(tokens, clauses.WHERE + 1, clause_end(tokens, clauses, "WHERE"))
        if filter_err ~= nil then
            return nil, filter_err
        end
        for _, filter in ipairs(raw_filters) do
            local field, _ = resolve_field(ctx, filter.field, nil)
            if field ~= nil and field.kind == "METRIC" then
                request.having[#request.having + 1] = filter
            else
                request.filters[#request.filters + 1] = filter
            end
        end
    end

    if #request.dimensions > 0 and not wildcard_select then
        if clauses.GROUP_BY == nil then
            return nil, error_result("SEMANTIC_QUERY_007", "Semantic SQL with dimensions must GROUP BY the selected dimensions.")
        end
        local grouped = {}
        for _, part in ipairs(split_top_level(tokens, clauses.GROUP_BY + 2, clause_end(tokens, clauses, "GROUP_BY"), ",")) do
            local field_name = identifier_from_part(part)
            if field_name == nil and #part == 1 and part[1].kind == "number" then
                local ordinal = tonumber(part[1].text)
                field_name = selected_output[ordinal]
            end
            if field_name == nil then
                return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY supports selected dimensions by name or ordinal.")
            end
            local field, bind_err = resolve_field(ctx, field_name, "DIMENSION")
            if bind_err ~= nil then
                return nil, recode_error_prefix(bind_err, "SEMANTIC_QUERY")
            end
            grouped[upper(field.name)] = true
        end
        for _, dimension_name in ipairs(request.dimensions) do
            if not grouped[upper(dimension_name)] then
                return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must cover selected dimension " .. tostring(dimension_name) .. ".")
            end
        end
        local group_count = 0
        for _, _ in pairs(grouped) do
            group_count = group_count + 1
        end
        if group_count ~= #request.dimensions then
            return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must not contain dimensions outside the SELECT list.")
        end
    elseif #request.dimensions == 0 and clauses.GROUP_BY ~= nil then
        return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY is only supported for selected dimensions.")
    end

    if clauses.HAVING ~= nil then
        local having_filters, having_err = parse_having_filters(ctx, tokens, clauses.HAVING + 1, clause_end(tokens, clauses, "HAVING"))
        if having_err ~= nil then
            return nil, having_err
        end
        for _, f in ipairs(having_filters) do
            request.having[#request.having + 1] = f
        end
    end

    if clauses.ORDER_BY ~= nil then
        local order_by, order_err = parse_order_by(tokens, clauses.ORDER_BY + 2, clause_end(tokens, clauses, "ORDER_BY"), select_aliases, selected_output)
        if order_err ~= nil then
            return nil, order_err
        end
        request.order_by = order_by
    end

    if clauses.LIMIT ~= nil then
        local limit_start = clauses.LIMIT + 1
        local limit_end = clause_end(tokens, clauses, "LIMIT")
        if limit_start ~= limit_end or tokens[limit_start].kind ~= "number" then
            return nil, error_result("SEMANTIC_QUERY_050", "LIMIT must be a positive integer literal.")
        end
        request.limit = tonumber(tokens[limit_start].text)
    end
    return request, nil, model
end

local function compile_sql_internal(sql_text, options)
    options = options or {}
    local request, parse_err, model = parse_semantic_sql(sql_text, {
        unchanged_nonsemantic = options.unchanged_nonsemantic,
        unchanged_unknown_schema = options.unchanged_unknown_schema,
    })
    if parse_err ~= nil then
        return parse_err, nil, nil
    end
    if request ~= nil and request.status == "UNCHANGED" then
        return request, nil, nil
    end
    local result, compiled_request, compiled_model = compile_request_table(request, {
        model = model,
        validate = options.validate,
        error_prefix = "SEMANTIC_QUERY",
    })
    if result ~= nil and result.status ~= "OK" then
        recode_error_prefix(result, "SEMANTIC_QUERY")
    end
    return result, compiled_request, compiled_model
end

local function collision_error(msg)
    -- SEMANTIC_REQUEST_100 / SEMANTIC_QUERY_100: transient transaction collision - safe to retry.
    return string.find(msg, "GlobalTransactionRollback", 1, true) ~= nil
        or string.find(msg, "Transaction collision", 1, true) ~= nil
end

function M.compile_sql(sql_text)
    local ok, result, request, model = pcall(compile_sql_internal, sql_text, {validate = true})
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg), nil, nil
    end
    return result, request, model
end

function M.compile_sql_debug(sql_text, client_name)
    local result, request, model = M.compile_sql(sql_text)
    log_query_result(result, sql_text, request, model, client_name)
    return result, request, model
end

function M.compile_sql_for_preprocessor(sql_text)
    local upper_sql = upper(sql_text or "")
    if string.find(upper_sql, "SELECT", 1, true) == nil or string.find(upper_sql, "FROM", 1, true) == nil then
        return {status = "UNCHANGED", generated_sql = sql_text}
    end
    local ok, result = pcall(compile_sql_internal, sql_text, {
        validate = false,
        unchanged_nonsemantic = true,
        unchanged_unknown_schema = true,
    })
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg)
    end
    return result
end

function M.compile_request_json(request_json)
    local ok, result, request, model = pcall(compile_internal, request_json)
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_REQUEST_100" or "SEMANTIC_REQUEST_999"
        result = error_result(code, msg)
        request = nil
        model = nil
    end
    log_request(result, request_json, request, model)
    return result
end

compile_request_json = M.compile_request_json
compile_sql = M.compile_sql
compile_sql_debug = M.compile_sql_debug
compile_sql_for_preprocessor = M.compile_sql_for_preprocessor
