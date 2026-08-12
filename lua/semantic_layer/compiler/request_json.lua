local M = {}
local grain_graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")
local query_spec_runtime = assert(ESV_QUERY_SPEC, "query spec runtime is required")
local catalog_snapshot_runtime = assert(ESV_CATALOG_SNAPSHOT, "catalog snapshot runtime is required")
local metric_plan_runtime = assert(ESV_METRIC_PLAN, "metric plan runtime is required")
local physical_plan_runtime = assert(ESV_PHYSICAL_PLAN, "physical plan runtime is required")
local grain_sql_runtime = assert(ESV_GRAIN_SQL, "grain SQL runtime is required")

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
    if type(plan) ~= "table" then
        return nil
    end
    if type(plan.selected_materializations) == "table"
        and #plan.selected_materializations > 0 then
        local names = {}
        for _, selected in ipairs(plan.selected_materializations) do
            names[#names + 1] = tostring(selected.materialization_name)
        end
        return table.concat(names, ",")
    end
    if plan.selected_materialization == nil
        or plan.selected_materialization == JSON_NULL then
        return nil
    elseif type(plan.selected_materialization) == "table" then
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

local function monotonic_ms()
    if os ~= nil and type(os.clock) == "function" then
        return math.floor(os.clock() * 1000 + 0.5)
    end
    return nil
end

local function attach_planning_runtime(result, started_ms)
    local finished_ms = monotonic_ms()
    if result ~= nil and started_ms ~= nil and finished_ms ~= nil then
        result.planning_runtime_ms = math.max(0, finished_ms - started_ms)
    end
    return result
end

-- Compile-result cache (BUG-D-002). The compiler is deterministic per
-- (model_version_id, normalized request), so a successful compile is reused
-- until PUBLISH_MODEL drops cache entries for the model version. The parsed
-- request is canonicalized (strip logging-only fields, sort top-level keys)
-- and hashed with a 64-bit polynomial hash. Collisions in this space are
-- vanishingly improbable for any realistic dashboard workload.

local CACHE_IGNORED_REQUEST_KEYS = {client = true, purpose = true,
    natural_language_text = true, natural_language = true, source = true}

-- COMPILE_REQUEST_JSON is a closed contract. Silently dropping misspelled or
-- future-looking keys is unsafe for autonomous callers: a request can return
-- STATUS=OK while not doing what the caller asked. Keep this list aligned with
-- SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT.
local STRUCTURED_REQUEST_KEY_NAMES = {
    "client", "dimensions", "filters", "having", "limit", "metrics",
    "model", "natural_language_text", "object", "order_by", "proof_mode",
    "purpose",
}
local STRUCTURED_REQUEST_KEYS = {}
for _, request_key in ipairs(STRUCTURED_REQUEST_KEY_NAMES) do
    STRUCTURED_REQUEST_KEYS[request_key] = true
end

local function validate_structured_request_keys(request)
    local unknown = {}
    for request_key, _ in pairs(request) do
        if type(request_key) ~= "string" or not STRUCTURED_REQUEST_KEYS[request_key] then
            unknown[#unknown + 1] = tostring(request_key)
        end
    end
    if #unknown == 0 then
        return nil
    end
    table.sort(unknown)
    return error_result(
        "SEMANTIC_REQUEST_004",
        "Unknown top-level request key(s): " .. table.concat(unknown, ", ")
            .. ". Allowed keys: " .. table.concat(STRUCTURED_REQUEST_KEY_NAMES, ", ") .. "."
    )
end

local function canonical_value(value)
    if value == nil or value == null or value == JSON_NULL then
        return null
    end
    if type(value) == "table" then
        if is_array(value) then
            local out = {}
            for i = 1, #value do
                out[i] = canonical_value(value[i])
            end
            return out
        end
        local keys = {}
        for k, _ in pairs(value) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
            out[k] = canonical_value(value[k])
        end
        return out
    end
    return value
end

local function canonical_request_text(request)
    if type(request) ~= "table" then
        return nil
    end
    local stripped = {}
    for k, v in pairs(request) do
        if type(k) == "string" and not CACHE_IGNORED_REQUEST_KEYS[string.lower(k)] then
            stripped[k] = v
        end
    end
    local ok, encoded = pcall(json_encode, canonical_value(stripped))
    if not ok then
        return nil
    end
    return "plan=" .. tostring(metric_plan_runtime.PLAN_VERSION) .. "|" .. encoded
end

-- 64-bit polynomial hash (two parallel 32-bit polynomials with different bases
-- and primes). Pure Lua 5.1 - no bitwise ops, all arithmetic stays under 2^53
-- so doubles are exact.
local function compile_cache_key(canonical_text)
    if type(canonical_text) ~= "string" or canonical_text == "" then
        return nil
    end
    local h1, h2 = 5381, 0
    for i = 1, #canonical_text do
        local b = string.byte(canonical_text, i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function cache_lookup(model_version_id, cache_key)
    if cache_key == nil or model_version_id == nil then
        return nil
    end
    local rows = query([[
        SELECT GENERATED_SQL, PLAN_JSON, VALIDATION_RUN_ID
        FROM SYS_SEMANTIC.COMPILE_CACHE
        WHERE MODEL_VERSION_ID = :model_version_id
          AND CACHE_KEY = :cache_key
    ]], {model_version_id = model_version_id, cache_key = cache_key})
    if rows == nil or #rows == 0 then
        return nil
    end
    local row = rows[1]
    return {
        generated_sql = row_value(row, "GENERATED_SQL", 1),
        plan_json = row_value(row, "PLAN_JSON", 2),
        validation_run_id = row_value(row, "VALIDATION_RUN_ID", 3),
    }
end

local function cache_store(model_version_id, cache_key, result)
    if cache_key == nil or model_version_id == nil or result == nil
        or result.status ~= "OK" or missing(result.generated_sql) then
        return
    end
    -- Best-effort insert. A PK collision (same model_version_id + cache_key)
    -- means another concurrent compile already wrote this entry, so nothing
    -- to do. A transient transaction collision is also swallowed - the caller
    -- already has the compile result.
    pcall(query, [[
        INSERT INTO SYS_SEMANTIC.COMPILE_CACHE (
          MODEL_VERSION_ID, CACHE_KEY, GENERATED_SQL, PLAN_JSON,
          VALIDATION_RUN_ID, LAST_HIT_AT, HIT_COUNT
        ) VALUES (
          :model_version_id, :cache_key, :generated_sql, :plan_json,
          :validation_run_id, NULL, 0
        )
    ]], {
        model_version_id = model_version_id,
        cache_key = cache_key,
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        validation_run_id = null_if_missing(result.validation_run_id),
    })
end

local function cache_touch(model_version_id, cache_key)
    if cache_key == nil or model_version_id == nil then
        return
    end
    pcall(query, [[
        UPDATE SYS_SEMANTIC.COMPILE_CACHE
        SET LAST_HIT_AT = CURRENT_TIMESTAMP,
            HIT_COUNT = HIT_COUNT + 1
        WHERE MODEL_VERSION_ID = :model_version_id
          AND CACHE_KEY = :cache_key
    ]], {model_version_id = model_version_id, cache_key = cache_key})
end

local function cached_ok_result(cached)
    -- Reconstruct an ok_result payload from the cached row. plan_json comes
    -- straight from storage. materialization_used is recovered by decoding it.
    local plan = nil
    if not missing(cached.plan_json) then
        local ok, decoded = pcall(json_decode, cached.plan_json)
        if ok then plan = decoded end
    end
    return {
        status = "OK",
        error_code = nil,
        error_message = nil,
        generated_sql = cached.generated_sql,
        plan_json = cached.plan_json,
        clarification_json = nil,
        validation_run_id = cached.validation_run_id,
        agent_request_id = nil,
        query_log_id = nil,
        materialization_used = plan_materialization_name(plan),
        cache_hit = true,
        planning_runtime_ms = 0,
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
                local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
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
        representations = {},
        representations_by_entity = {},
        representation_by_id = {},
        entity_by_id = {},
        entity_by_alias = {},
        dimensions = {},
        dimension_by_id = {},
        metrics = {},
        metric_by_id = {},
        all_metrics = {},
        all_metric_by_id = {},
        facts = {},
        fact_by_id = {},
        fact_by_name = {},
        attribute_bindings = {},
        bindings_by_attribute = {},
        relationships = {},
        relationship_by_id = {},
        unique_keys = {},
        unique_key_by_id = {},
        unique_keys_by_entity = {},
        canonical_fields = {},
        synonym_fields = {},
    }

    local entity_rows = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME,
               er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
               e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION,
               er.REPRESENTATION_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.REPRESENTATION_ROLE, er.PRIORITY
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
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local entity = {
            id = row_value(row, "ENTITY_ID", 1),
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
                source_kind = row_value(row, "SOURCE_KIND", 10) or "RELATION",
                role = row_value(row, "REPRESENTATION_ROLE", 11) or "PRIMARY",
                priority = row_value(row, "PRIORITY", 12) or 1,
                source_schema = row_value(row, "SOURCE_SCHEMA", 3),
                source_object = row_value(row, "SOURCE_OBJECT", 4),
                alias = row_value(row, "SOURCE_ALIAS", 5),
            },
        }
        ctx.entities[#ctx.entities + 1] = entity
        ctx.entity_by_id[key(entity.id)] = entity
        ctx.entity_by_alias[upper(entity.alias)] = entity
    end

    local representation_rows = query([[
        SELECT REPRESENTATION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
               SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
               PRIORITY, FRESHNESS_POLICY, COVERAGE_PREDICATE, VALID_FROM, VALID_TO
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID,
          CASE WHEN REPRESENTATION_ROLE = 'PRIMARY' THEN 0 ELSE 1 END,
          PRIORITY, REPRESENTATION_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
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
        }
        ctx.representations[#ctx.representations + 1] = representation
        ctx.representation_by_id[key(representation.id)] = representation
        local entity_key = key(representation.entity_id)
        ctx.representations_by_entity[entity_key] =
            ctx.representations_by_entity[entity_key] or {}
        ctx.representations_by_entity[entity_key]
            [#ctx.representations_by_entity[entity_key] + 1] = representation
        if upper(representation.role) == "PRIMARY" and ctx.entity_by_id[entity_key] ~= nil then
            ctx.entity_by_id[entity_key].primary_representation = representation
        end
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
               COALESCE(mt.METRIC_KIND, mt.METRIC_TYPE) AS METRIC_KIND,
               mt.AGGREGATION_FUNCTION, mt.MEASURE_EXPR,
               mt.SEMANTIC_FILTER_EXPR, mt.SQL_FILTER_EXPR,
               mt.DISTINCT_KEY_EXPR, mt.NON_ADDITIVE_DIMENSION_ID,
               mt.WINDOW_SPEC_JSON, mt.TYPE_PARAMS_JSON
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
            aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
            measure_expr = row_value(row, "MEASURE_EXPR", 11),
            semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
            sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
            distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
            non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
            window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
            type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
            inputs = {},
            filters = {},
        }
        ctx.metrics[#ctx.metrics + 1] = metric
        ctx.metric_by_id[key(metric.id)] = metric
        ctx.all_metrics[#ctx.all_metrics + 1] = metric
        ctx.all_metric_by_id[key(metric.id)] = metric
        ctx.canonical_fields[upper(metric.name)] = metric
    end

    -- Planner catalog completeness is independent of field visibility.
    -- Private metrics stay absent from canonical_fields while remaining
    -- available for transitive dependency planning.
    local all_metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION,
               COALESCE(SQL_FILTER_EXPR, FILTER_EXPR) AS FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DISPLAY_NAME,
               COALESCE(METRIC_KIND, METRIC_TYPE) AS METRIC_KIND,
               AGGREGATION_FUNCTION, MEASURE_EXPR,
               SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR,
               DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_ID,
               WINDOW_SPEC_JSON, TYPE_PARAMS_JSON
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY METRIC_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(all_metric_rows or {}) do
        local metric_id = row_value(row, "METRIC_ID", 1)
        if ctx.all_metric_by_id[key(metric_id)] == nil then
            local metric = {
                kind = "METRIC",
                id = metric_id,
                name = row_value(row, "METRIC_NAME", 2),
                base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
                expression = row_value(row, "EXPRESSION", 4),
                filter_expr = row_value(row, "FILTER_EXPR", 5),
                metric_type = row_value(row, "METRIC_TYPE", 6),
                data_type = row_value(row, "DATA_TYPE", 7),
                display_name = row_value(row, "DISPLAY_NAME", 8),
                metric_kind = row_value(row, "METRIC_KIND", 9),
                aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
                measure_expr = row_value(row, "MEASURE_EXPR", 11),
                semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
                sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
                distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
                non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
                window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
                type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
                inputs = {},
                filters = {},
                dependencies = {},
                visible = false,
            }
            ctx.all_metrics[#ctx.all_metrics + 1] = metric
            ctx.all_metric_by_id[key(metric.id)] = metric
        end
    end

    local metric_input_rows = query([[
        SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE,
               mi.INPUT_OBJECT_ID, mi.EXPRESSION_ALIAS, mi.OFFSET_WINDOW,
               mi.FILTER_EXPR, mi.ORDINAL_POSITION
        FROM SYS_SEMANTIC.METRIC_INPUTS mi
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mi.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mi.METRIC_ID, mi.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_input_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.inputs[#metric.inputs + 1] = {
                role = row_value(row, "INPUT_ROLE", 2),
                object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
                object_id = row_value(row, "INPUT_OBJECT_ID", 4),
                expression_alias = row_value(row, "EXPRESSION_ALIAS", 5),
                offset_window = row_value(row, "OFFSET_WINDOW", 6),
                filter_expr = row_value(row, "FILTER_EXPR", 7),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 8),
            }
        end
    end

    local metric_filter_rows = query([[
        SELECT mf.METRIC_ID, mf.FILTER_KIND, mf.FILTER_EXPR,
               mf.RESOLVED_SQL_EXPR, mf.REQUIRED_DIMENSION_ID,
               mf.REQUIRED_ENTITY_ID, mf.ORDINAL_POSITION
        FROM SYS_SEMANTIC.METRIC_FILTERS mf
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mf.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mf.METRIC_ID, mf.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_filter_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.filters[#metric.filters + 1] = {
                kind = row_value(row, "FILTER_KIND", 2),
                expression = row_value(row, "FILTER_EXPR", 3),
                resolved_sql_expr = row_value(row, "RESOLVED_SQL_EXPR", 4),
                required_dimension_id = row_value(row, "REQUIRED_DIMENSION_ID", 5),
                required_entity_id = row_value(row, "REQUIRED_ENTITY_ID", 6),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
            }
        end
    end

    local metric_dependency_rows = query([[
        SELECT md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md
        JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = md.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_dependency_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.dependencies = metric.dependencies or {}
            metric.dependencies[#metric.dependencies + 1] = {
                object_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 2),
                object_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 3),
            }
        end
    end

    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE,
               ADDITIVE_POLICY
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
            additive_policy = row_value(row, "ADDITIVE_POLICY", 6),
        }
        ctx.facts[#ctx.facts + 1] = fact
        ctx.fact_by_id[key(fact.id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

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
    ]], {model_id = model.model_id, version_id = model.version_id})
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
            legacy = row_value(row, "IS_DEFAULT", 9) == true,
        }
        ctx.attribute_bindings[#ctx.attribute_bindings + 1] = binding
        local attribute_key = upper(binding.attribute_type) .. ":" .. key(binding.attribute_id)
        ctx.bindings_by_attribute[attribute_key] =
            ctx.bindings_by_attribute[attribute_key] or {}
        ctx.bindings_by_attribute[attribute_key]
            [#ctx.bindings_by_attribute[attribute_key] + 1] = binding
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
        local relationship = {
            id = row_value(row, "RELATIONSHIP_ID", 1),
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
        ctx.relationships[#ctx.relationships + 1] = relationship
        ctx.relationship_by_id[key(relationship.id)] = relationship
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
    ]], {model_id = model.model_id, version_id = model.version_id})
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

    local unique_key_rows = query([[
        SELECT UNIQUE_KEY_ID, ENTITY_ID, KEY_NAME, KEY_KIND, SOURCE_FORMAT
        FROM SYS_SEMANTIC.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, UNIQUE_KEY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_rows or {}) do
        local unique_key = {
            id = row_value(row, "UNIQUE_KEY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "KEY_NAME", 3),
            kind = row_value(row, "KEY_KIND", 4),
            source_format = row_value(row, "SOURCE_FORMAT", 5),
            columns = {},
        }
        ctx.unique_keys[#ctx.unique_keys + 1] = unique_key
        ctx.unique_key_by_id[key(unique_key.id)] = unique_key
        local entity_key = key(unique_key.entity_id)
        ctx.unique_keys_by_entity[entity_key] = ctx.unique_keys_by_entity[entity_key] or {}
        ctx.unique_keys_by_entity[entity_key][#ctx.unique_keys_by_entity[entity_key] + 1] = unique_key
    end

    local unique_key_column_rows = query([[
        SELECT ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION,
               ukc.COLUMN_NAME, ukc.EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
        JOIN SYS_SEMANTIC.UNIQUE_KEYS uk
          ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID
        WHERE uk.MODEL_ID = :model_id
          AND uk.VERSION_ID = :version_id
          AND uk.STATUS = 'ACTIVE'
        ORDER BY ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_column_rows or {}) do
        local unique_key = ctx.unique_key_by_id[key(row_value(row, "UNIQUE_KEY_ID", 1))]
        if unique_key ~= nil then
            unique_key.columns[#unique_key.columns + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                column_name = row_value(row, "COLUMN_NAME", 3),
                expression = row_value(row, "EXPRESSION", 4),
            }
        end
    end
    for _, unique_key in ipairs(ctx.unique_keys) do
        local canonical = grain_graph.canonical_key(unique_key)
        unique_key.columns = canonical.columns
        unique_key.kind = canonical.kind
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
    local safe_edges = grain_graph.build_edges(ctx.relationships)
    return safe_edges
end

local function find_path(ctx, from_id, to_id)
    local edges = ctx._edges
    if edges == nil then
        edges = relationship_edges(ctx)
        ctx._edges = edges
    end
    local proof = grain_graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
    })
    if not proof.ok then
        ctx._last_path_proof = proof
        return nil
    end
    local path = {}
    for _, edge in ipairs(proof.edges) do
        path[#path + 1] = {
            from_entity_id = edge.from_id,
            to_entity_id = edge.to_id,
            relationship = edge.relationship,
        }
    end
    ctx._last_path_proof = proof
    return path
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
            local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
            if dep_metric ~= nil then
                collect_metric_entities(ctx, dep_metric, needed_entities, seen_metrics)
            end
        end
    end
end

local function collect_metric_facts(ctx, metric, required, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then return end
    seen_metrics[metric_key] = true
    for _, dependency in ipairs(metric.dependencies or {}) do
        if upper(dependency.object_type) == "FACT" then
            local fact = ctx.fact_by_id[key(dependency.object_id)]
            if fact ~= nil then required["FACT:" .. key(fact.id)] = fact end
        elseif upper(dependency.object_type) == "METRIC" then
            local nested = ctx.all_metric_by_id[key(dependency.object_id)]
            if nested ~= nil then collect_metric_facts(ctx, nested, required, seen_metrics) end
        end
    end
end

local function select_attribute_bindings(ctx, dimensions, metrics, needed_entities)
    local required_by_entity = {}
    local function require_attribute(attribute_type, attribute)
        local entity_key = key(attribute.entity_id)
        required_by_entity[entity_key] = required_by_entity[entity_key] or {}
        required_by_entity[entity_key][attribute_type .. ":" .. key(attribute.id)] = attribute
    end
    for _, dimension in ipairs(dimensions or {}) do
        require_attribute("DIMENSION", dimension)
    end
    local required_facts = {}
    for _, metric in ipairs(metrics or {}) do
        collect_metric_facts(ctx, metric, required_facts, {})
    end
    for _, fact in pairs(required_facts) do require_attribute("FACT", fact) end

    ctx.selected_representations = {}
    for entity_id, _ in pairs(needed_entities or {}) do
        local entity = ctx.entity_by_id[key(entity_id)]
        if entity ~= nil then
            local attributes = required_by_entity[key(entity.id)] or {}
            local candidates = {}
            local representations = ctx.representations_by_entity[key(entity.id)] or {}
            if #representations == 0 and entity.primary_representation ~= nil then
                representations = {entity.primary_representation}
            end
            for _, representation in ipairs(representations) do
                local candidate = {
                    representation = representation,
                    bindings = {},
                    fallback_count = 0,
                    binding_priority = 0,
                    complete = true,
                    legacy_only = true,
                }
                for attribute_key, attribute in pairs(attributes) do
                    local bindings = ctx.bindings_by_attribute[attribute_key] or {}
                    local selected = nil
                    for _, binding in ipairs(bindings) do
                        if key(binding.representation_id) == key(representation.id) then
                            selected = binding
                            break
                        end
                    end
                    if selected == nil and #bindings == 0
                        and upper(representation.role) == "PRIMARY" then
                        selected = {
                            id = nil,
                            representation_id = representation.id,
                            expression = attribute.expression,
                            role = "PREFER",
                            priority = 1,
                            legacy = true,
                        }
                    end
                    if selected == nil then
                        candidate.complete = false
                        break
                    end
                    candidate.bindings[attribute_key] = selected
                    if selected.legacy ~= true then candidate.legacy_only = false end
                    if upper(selected.role) == "FALLBACK" then
                        candidate.fallback_count = candidate.fallback_count + 1
                    end
                    candidate.binding_priority = candidate.binding_priority
                        + tonumber(selected.priority or 1)
                end
                if candidate.complete then candidates[#candidates + 1] = candidate end
            end
            table.sort(candidates, function(left, right)
                if left.fallback_count ~= right.fallback_count then
                    return left.fallback_count < right.fallback_count
                end
                if left.binding_priority ~= right.binding_priority then
                    return left.binding_priority < right.binding_priority
                end
                local left_priority = tonumber(left.representation.priority or 1)
                local right_priority = tonumber(right.representation.priority or 1)
                if left_priority ~= right_priority then return left_priority < right_priority end
                return tonumber(left.representation.id) < tonumber(right.representation.id)
            end)
            local selected = candidates[1]
            if selected == nil then
                return nil, "No active representation provides every required attribute for entity '"
                    .. tostring(entity.name) .. "'. Add compatible PREFER/FALLBACK bindings."
            end
            local representation = selected.representation
            entity.source_schema = representation.source_schema
            entity.source_object = representation.source_object
            entity.alias = representation.alias
            entity.selected_representation = representation
            for attribute_key, binding in pairs(selected.bindings) do
                local attribute_type, attribute_id = string.match(attribute_key, "^([^:]+):(.+)$")
                local attribute = attribute_type == "DIMENSION"
                    and ctx.dimension_by_id[key(attribute_id)] or ctx.fact_by_id[key(attribute_id)]
                if attribute ~= nil then
                    attribute.expression = binding.expression
                    attribute.selected_binding = binding
                end
            end
            ctx.selected_representations[key(entity.id)] = {
                representation = representation,
                fallback_count = selected.fallback_count,
                binding_priority = selected.binding_priority,
                bindings = selected.bindings,
                legacy_only = selected.legacy_only,
            }
        end
    end
    return true, nil
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
        for _, candidate in ipairs(ctx.all_metrics or ctx.metrics) do
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
    if op == "IS NULL" or op == "IS NOT NULL" then
        return expression .. " " .. op, nil
    end
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
    return nil, error_result("SEMANTIC_REQUEST_033", "Unsupported filter operator: " .. tostring(op) .. ". Supported operators: =, !=, <>, >, >=, <, <=, LIKE, IN, BETWEEN, IS NULL, IS NOT NULL.")
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
            entity_id = field.entity_id,
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
            local proof = ctx._last_path_proof or {}
            if proof.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
                return nil, nil, error_result(
                    "SEMANTIC_REQUEST_042",
                    "Ambiguous safe relationship path from semantic object root to entity "
                        .. tostring(entity and entity.name or entity_id) .. ": "
                        .. table.concat(proof.candidate_paths or {}, " | ") .. "."
                )
            end
            return nil, nil, error_result("SEMANTIC_REQUEST_042",
                "No safe relationship path from semantic object root to entity "
                    .. tostring(entity and entity.name or entity_id) .. ".")
        end
        local path_names = {}
        for _, edge in ipairs(path) do
            local relationship = edge.relationship
            path_names[#path_names + 1] = relationship.name
            local join_key = key(relationship.id)
            local to_entity_key = key(edge.to_entity_id)
            needed_entities[to_entity_key] = true
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
    local join_sql = {}
    local where_predicates = {}
    for _, dimension in ipairs(dimensions) do
        select_parts[#select_parts + 1] = tostring(dimension.expression) .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, metric in ipairs(metrics) do
        select_parts[#select_parts + 1] = expand_metric(ctx, metric) .. " AS " .. quote_alias(metric.name)
    end

    for _, join in ipairs(joins) do
        join_sql[#join_sql + 1] = tostring(join.relationship.join_type or "LEFT") .. " JOIN "
            .. quote_qualified(join.entity.source_schema, join.entity.source_object)
            .. " " .. tostring(join.entity.alias)
            .. " ON " .. tostring(join.relationship.join_condition)
    end
    for _, filter in ipairs(filters) do
        where_predicates[#where_predicates + 1] = filter.predicate
    end
    return grain_sql_runtime.render_single_branch({
        select_parts = select_parts,
        from_sql = quote_qualified(root.source_schema, root.source_object)
            .. " " .. tostring(root.alias),
        join_sql = join_sql,
        where_predicates = where_predicates,
        group_parts = group_parts,
        having_predicates = having_predicates or {},
        order_by = order_by,
        limit = limit,
    })
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
          PLAN_JSON, REQUESTED_METRICS, REQUESTED_DIMENSIONS, STATUS, ERROR_CODE, ERROR_MESSAGE,
          CACHE_HIT, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :purpose, :request_json, :generated_sql,
          :plan_json, :requested_metrics, :requested_dimensions, :status, :error_code, :error_message,
          :cache_hit, CURRENT_TIMESTAMP, :runtime_ms
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
        cache_hit = result.cache_hit == true,
        runtime_ms = null_if_missing(result.planning_runtime_ms),
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
          ERROR_MESSAGE, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :original_sql, :generated_sql,
          :plan_json, :requested_dimensions, :requested_metrics, :materialization_used,
          :status, :error_code,
          :error_message, CURRENT_TIMESTAMP, :runtime_ms
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
        runtime_ms = null_if_missing(result.planning_runtime_ms),
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
          AND STATUS IN ('OK', 'WARNING')
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
    local normalized_request, query_spec_error = query_spec_runtime.new(
        request, options.source or request.source or "JSON"
    )
    if normalized_request == nil then
        return error_result(error_prefix .. "_001",
            "Invalid canonical query specification: " .. tostring(query_spec_error) .. ".")
    end
    request = normalized_request
    if request.proof_mode ~= "LEGACY_JOIN" and request.proof_mode ~= "STRICT_GRAIN" then
        return error_result(error_prefix .. "_071",
            "Unsupported proof_mode: " .. tostring(request.proof_mode) .. ".")
    end

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

    -- Compile-cache fast path: hit returns the stored GENERATED_SQL + PLAN_JSON
    -- without re-running catalog load, matrix lookup, join planning, materialization
    -- selection, or SQL emission. Cache writes happen further down the function
    -- only when the full compile succeeded (so error results never get cached).
    local cache_key = nil
    if options.cache ~= false and not missing(model.version_id) then
        cache_key = compile_cache_key(canonical_request_text(request))
        if cache_key ~= nil then
            local cached = cache_lookup(model.version_id, cache_key)
            if cached ~= nil then
                cache_touch(model.version_id, cache_key)
                local result = cached_ok_result(cached)
                if error_prefix ~= "SEMANTIC_REQUEST" then
                    recode_error_prefix(result, error_prefix)
                end
                return result, request, model
            end
        end
    end

    local planning_started_ms = monotonic_ms()
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
    -- Dimension-only discovery (BUG-D-003): allow an empty metrics list as long
    -- as dimensions is non-empty. Compiles to a deduplicated GROUP BY over the
    -- dimensions - the same shape a dashboard needs to populate facet filters
    -- without having to fake an unused metric.
    if #selected_metrics == 0 and #selected_dimensions == 0 then
        return error_result("SEMANTIC_REQUEST_023",
            "At least one metric or dimension is required.")
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
            return error_result(error_prefix .. "_010",
                "Model validation is missing or stale: " .. validation_message
                .. " Run EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('" .. tostring(model.model_name) .. "') (or PUBLISH_MODEL) before compiling.")
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
    local bound_having_filters = {}
    local planning_metrics = {}
    local planning_metric_seen = {}
    for _, metric in ipairs(selected_metrics) do
        add_unique(planning_metrics, planning_metric_seen, metric)
    end
    local having_list = as_array(request.having, "having")
    if #having_list > 0 and #selected_metrics == 0 then
        return error_result("SEMANTIC_REQUEST_026",
            "HAVING requires at least one metric in the request.")
    end
    for _, having_filter in ipairs(having_list) do
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
        add_unique(planning_metrics, planning_metric_seen, metric_field)
        collect_metric_entities(ctx, metric_field, needed_entities, {})
        local op = upper(having_filter.op or having_filter.operator or "=")
        if missing(having_filter.value) and missing(having_filter.value_sql)
            and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return error_result("SEMANTIC_REQUEST_015",
                "Having filter for field '" .. tostring(metric_field.name)
                .. "' requires a value or value_sql key.")
        end
        local expr = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(expr, op, having_filter.value, metric_field.data_type, having_filter.value_sql)
        if predicate_err ~= nil then
            return predicate_err
        end
        having_predicates[#having_predicates + 1] = predicate
        bound_having_filters[#bound_having_filters + 1] = {
            metric_id = metric_field.id,
            metric = metric_field.name,
            op = op,
            value = having_filter.value,
            value_sql = having_filter.value_sql,
            data_type = metric_field.data_type,
        }
    end


    local binding_ok, binding_error = select_attribute_bindings(
        ctx, all_dimensions, planning_metrics, needed_entities)
    if binding_ok == nil then
        return error_result(error_prefix .. "_080", binding_error)
    end

    -- Filters and HAVING expressions were resolved while discovering required
    -- attributes. Rebuild them after representation selection so fallback
    -- expressions are used consistently in WHERE and HAVING.
    filters, _, filter_err = build_filters(
        ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then return filter_err end
    having_predicates = {}
    for index, bound in ipairs(bound_having_filters) do
        local metric_field = ctx.all_metric_by_id[key(bound.metric_id)]
        local source = having_list[index]
        local expression = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(
            expression, bound.op, source.value, bound.data_type, source.value_sql)
        if predicate_err ~= nil then return predicate_err end
        having_predicates[#having_predicates + 1] = predicate
    end

    local snapshot = catalog_snapshot_runtime.from_context(ctx, planning_metrics)
    local relationship_targets = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(ctx.object.root_entity_id) then
            relationship_targets[#relationship_targets + 1] = {
                target_entity_id = entity_id,
            }
        end
    end
    table.sort(relationship_targets, function(left, right)
        return key(left.target_entity_id) < key(right.target_entity_id)
    end)
    local bound_query = metric_plan_runtime.bind_query(
        request,
        selected_dimensions,
        selected_metrics,
        filters,
        bound_having_filters,
        relationship_targets
    )
    local typed_plan, typed_plan_error = metric_plan_runtime.logical_plan(
        request,
        snapshot,
        bound_query,
        planning_metrics
    )
    if typed_plan == nil then
        return error_result(error_prefix .. "_070",
            "Typed planning failed: " .. tostring(typed_plan_error) .. ".")
    end

    local function plan_envelope(materialization_decision, selected_materialization,
        relationship_paths)
        materialization_decision = materialization_decision or {
            candidate_count = 0,
            rejected_materializations = typed_plan.plan_kind == "MULTI_BRANCH"
                and {{reason_code = "MATERIALIZATION_BRANCH_INELIGIBLE"}} or {},
            selected_materialization = JSON_NULL,
        }
        local plan = {
            plan_version = metric_plan_runtime.PLAN_VERSION,
            logical_plan = typed_plan,
            model = model.model_name,
            version_id = model.version_id,
            version_number = model.version_number,
            object = ctx.object.name,
            metrics = {},
            metric_details = {},
            dimensions = {},
            filters = filters,
            relationship_paths = relationship_paths or {},
            selected_materialization = JSON_NULL,
            selected_materializations = materialization_decision.selected_materializations
                or {},
            materialization_decision = materialization_decision,
            validation_run_id = validation_run_id,
            warnings = {},
            selected_representations = {},
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
        local representation_entity_ids = {}
        for entity_id, _ in pairs(needed_entities) do
            representation_entity_ids[#representation_entity_ids + 1] = entity_id
        end
        table.sort(representation_entity_ids, function(left, right)
            return key(left) < key(right)
        end)
        for _, entity_id in ipairs(representation_entity_ids) do
            local entity = ctx.entity_by_id[key(entity_id)]
            local selection = entity and ctx.selected_representations[key(entity.id)] or nil
            local representation = selection and selection.representation
                or entity and entity.primary_representation or nil
            if representation ~= nil then
                local selected_bindings = {}
                for attribute_key, binding in pairs(selection and selection.bindings or {}) do
                    selected_bindings[#selected_bindings + 1] = {
                        attribute = attribute_key,
                        attribute_binding_id = binding.id or JSON_NULL,
                        binding_role = binding.role,
                        binding_priority = binding.priority,
                        source_expression = binding.expression,
                        legacy = binding.legacy == true,
                    }
                end
                table.sort(selected_bindings, function(left, right)
                    return left.attribute < right.attribute
                end)
                plan.selected_representations[#plan.selected_representations + 1] = {
                    entity_id = entity.id,
                    entity_name = entity.name,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    source_kind = representation.source_kind,
                    source_schema = representation.source_schema,
                    source_object = representation.source_object,
                    selection_reason = (selection == nil or selection.legacy_only)
                        and "STATIC_PRIMARY"
                        or selection.fallback_count > 0 and "ATTRIBUTE_FALLBACK"
                        or "ATTRIBUTE_PREFER",
                    fallback_binding_count = selection and selection.fallback_count or 0,
                    binding_priority = selection and selection.binding_priority or 0,
                    selected_bindings = selected_bindings,
                }
            end
        end
        return plan
    end

    local function plan_error(code, message)
        local result = error_result(error_prefix .. code, message)
        result.plan_json = json_encode(plan_envelope())
        return result
    end

    if typed_plan.failure ~= nil then
        local reason = typed_plan.failure.reason_code or "TYPED_PLANNING_FAILED"
        local code = string.find(reason, "METRIC_", 1, true) == 1
            and "_070" or "_074"
        return plan_error(code, "Typed planning failed: " .. tostring(reason) .. ".")
    end
    if typed_plan.plan_kind == "MULTI_BRANCH" then
        local physical_plan, physical_error = physical_plan_runtime.build(
            typed_plan,
            snapshot,
            {output_order_by = order_by, limit = limit}
        )
        if physical_plan == nil then
            typed_plan.failure = physical_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(physical_error.reason_code) .. ".")
        end
        local branch_decision = nil
        if materialization_runtime ~= nil
            and type(materialization_runtime.select_branch_sources) == "function" then
            local selections
            selections, branch_decision =
                materialization_runtime.select_branch_sources(ctx, physical_plan)
            local rebound_plan, rebound_error =
                physical_plan_runtime.apply_branch_sources(physical_plan, selections)
            if rebound_plan == nil then
                typed_plan.failure = rebound_error
                return plan_error("_075", "Physical planning failed: "
                    .. tostring(rebound_error.reason_code) .. ".")
            end
            physical_plan = rebound_plan
            physical_plan.source_selection = branch_decision
        end
        typed_plan.physical_plan = physical_plan
        local internal_sql = grain_sql_runtime.render_multi_branch(physical_plan)
        local within_limit, size_error = physical_plan_runtime.check_sql_size(
            physical_plan,
            internal_sql
        )
        if not within_limit then
            typed_plan.failure = size_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(size_error.reason_code) .. ".")
        end
        typed_plan.execution = {status = "EXECUTABLE"}
        physical_plan.execution = {status = "EXECUTABLE"}
        local plan = plan_envelope(branch_decision)
        local result = attach_planning_runtime(
            ok_result(internal_sql, plan, validation_run_id), planning_started_ms)
        if cache_key ~= nil then
            cache_store(model.version_id, cache_key, result)
        end
        return result, request, model
    end
    if request.proof_mode == "STRICT_GRAIN" then
        for _, proof in ipairs(typed_plan.relationship_proofs or {}) do
            if proof.status ~= "PROVEN" then
                return plan_error("_072", "Strict grain proof failed: "
                    .. tostring(proof.reason_code or proof.reason) .. ".")
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

    local selected_materialization = nil
    local materialization_decision = {
        candidate_count = 0,
        rejected_materializations = {},
        selected_materialization = JSON_NULL,
    }
    -- Aggregate materializations exist to serve metric aggregations. A
    -- dimension-only discovery request (#selected_metrics == 0) bypasses
    -- the selector and falls through to base-source SQL so distinct
    -- dimension values come from the authoritative source.
    if materialization_runtime ~= nil
        and type(materialization_runtime.select_materialization) == "function"
        and #having_predicates == 0
        and #selected_metrics > 0 then
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

    local plan = plan_envelope(materialization_decision, selected_materialization,
        relationship_paths)
    local result = attach_planning_runtime(
        ok_result(sql_text, plan, validation_run_id), planning_started_ms)
    if cache_key ~= nil then
        cache_store(model.version_id, cache_key, result)
    end
    return result, request, model
end

local function compile_internal(request_json)
    local decoded, request = pcall(json_decode, request_json)
    if not decoded then
        return error_result("SEMANTIC_REQUEST_001", "Invalid request JSON: " .. tostring(request) .. ".")
    end
    if type(request) ~= "table" or is_array(request) then
        return error_result("SEMANTIC_REQUEST_001", "Request JSON must be an object.")
    end
    local request_key_error = validate_structured_request_keys(request)
    if request_key_error ~= nil then
        return request_key_error, request, nil
    end
    -- Compile reuses the latest successful validation run for the active model version.
    -- PUBLISH_MODEL (and VALIDATE_MODEL) own the writes to VALIDATION_RUNS,
    -- METRIC_DEPENDENCIES, and METRIC_DIMENSION_MATRIX. Re-running them on every
    -- compile produced transaction collisions under concurrent load (BUG-001).
    return compile_request_table(request, {validate = false, error_prefix = "SEMANTIC_REQUEST"})
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

-- Databricks metric views wrap measures in MEASURE(...) (or its agg() synonym)
-- in SELECT / HAVING / ORDER BY. Unwrap that call to the bare semantic field name
-- so the rest of the parser treats it like any other metric reference. Returns the
-- (possibly rewritten) token list and whether a wrapper was actually removed.
local function unwrap_measure_part(part)
    if part == nil or #part < 4 then
        return part, false
    end
    local head = token_upper(part[1])
    if (head ~= "MEASURE" and head ~= "AGG") or part[2].text ~= "(" then
        return part, false
    end
    local depth = 0
    local close_index = nil
    for i = 2, #part do
        local text = part[i].text
        if text == "(" then
            depth = depth + 1
        elseif text == ")" then
            depth = depth - 1
            if depth == 0 then
                close_index = i
                break
            end
        end
    end
    -- Require a non-empty argument and a matching close paren.
    if close_index == nil or close_index <= 3 then
        return part, false
    end
    local rewritten = {}
    for i = 3, close_index - 1 do
        rewritten[#rewritten + 1] = part[i]
    end
    for i = close_index + 1, #part do
        rewritten[#rewritten + 1] = part[i]
    end
    return rewritten, true
end

local function identifier_from_part(part)
    part = unwrap_measure_part(part)
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

local binary_predicate_operators = {
    ["IN"] = true, ["BETWEEN"] = true, ["LIKE"] = true,
    ["="] = true, ["!="] = true, ["<>"] = true,
    [">"] = true, [">="] = true, ["<"] = true, ["<="] = true,
}

local function predicate_operator_at(tokens, index)
    local current = token_upper(tokens[index])
    if current == "IS" then
        if token_upper(tokens[index + 1]) == "NULL" then
            return "IS NULL"
        end
        if token_upper(tokens[index + 1]) == "NOT"
            and token_upper(tokens[index + 2]) == "NULL" then
            return "IS NOT NULL"
        end
        return "IS"
    end
    if binary_predicate_operators[current] then
        return current
    end
    return nil
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
            local candidate = predicate_operator_at(tokens, idx)
            if candidate ~= nil then
                op_index = idx
                op = candidate
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
        if op == "IS NULL" or op == "IS NOT NULL" then
            local expected_last = op_index + (op == "IS NULL" and 1 or 2)
            if last ~= expected_last then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            end
            filters[#filters + 1] = {field = field, op = op}
        elseif op == "IS" then
            return nil, error_result("SEMANTIC_QUERY_036",
                "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
        elseif op == "IN" then
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
            local candidate = predicate_operator_at(tokens, idx)
            if candidate ~= nil then
                op_index = idx
                op = candidate
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
        if op == "IS NULL" or op == "IS NOT NULL" then
            local expected_last = op_index + (op == "IS NULL" and 1 or 2)
            if last ~= expected_last then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            end
            filters[#filters + 1] = {field = resolved.name, op = op}
        elseif op == "IS" then
            return nil, error_result("SEMANTIC_QUERY_036",
                "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
        elseif op == "IN" then
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
        local _, measure_wrapped = unwrap_measure_part(part)
        local field_name = identifier_from_part(part)
        if field_name == nil then
            return nil, error_result("SEMANTIC_QUERY_005", "SELECT supports semantic field names, MEASURE(metric), or *.")
        end
        local field, bind_err = resolve_field(ctx, field_name, nil)
        if bind_err ~= nil then
            return nil, recode_error_prefix(bind_err, "SEMANTIC_QUERY")
        end
        if measure_wrapped and field.kind ~= "METRIC" then
            return nil, error_result("SEMANTIC_QUERY_006", "MEASURE()/agg() may only wrap a metric, not '" .. tostring(field.name) .. "'.")
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

    -- Databricks idiom: GROUP BY ALL groups by every non-aggregated SELECT column.
    -- Detect the single-token ALL form and let the selected dimensions stand in for
    -- the explicit grouping list.
    local is_group_by_all = false
    if clauses.GROUP_BY ~= nil then
        local gb_start = clauses.GROUP_BY + 2
        local gb_end = clause_end(tokens, clauses, "GROUP_BY")
        is_group_by_all = (gb_end == gb_start) and token_upper(tokens[gb_start]) == "ALL"
    end

    if #request.dimensions > 0 and not wildcard_select then
        -- GROUP BY is optional: when omitted, it is inferred from the selected
        -- dimensions (build_sql emits GROUP BY from request.dimensions regardless
        -- of the typed clause). When a GROUP BY *is* supplied, it must be either
        -- GROUP BY ALL or exactly cover the selected dimensions.
        if clauses.GROUP_BY ~= nil and not is_group_by_all then
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
        end
    elseif #request.dimensions == 0 and clauses.GROUP_BY ~= nil and not is_group_by_all then
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
        source = "SEMANTIC_SQL",
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

-- Bounded retry for transient transaction collisions. After the validator-skip
-- fix (BUG-001) the residual contention is the AGENT_REQUEST_LOG / QUERY_LOG
-- insert. Two retries with a tiny busy backoff are sufficient in practice.
-- Exasol Lua has no sleep, so we burn a small amount of CPU to let the
-- competing transaction commit before retrying.
local COLLISION_RETRIES = 2

local function busy_backoff()
    local budget = 0
    for _ = 1, 200000 do
        budget = budget + 1
    end
    return budget
end

function M.compile_sql(sql_text)
    -- See compile_internal: reuse the latest successful validation run instead of
    -- re-running the validator on every compile (BUG-001).
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_sql_internal, sql_text, {validate = false})
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
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
    local options = {
        validate = false,
        unchanged_nonsemantic = true,
        unchanged_unknown_schema = true,
    }
    local ok, result
    for attempt = 0, COLLISION_RETRIES do
        ok, result = pcall(compile_sql_internal, sql_text, options)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg)
    end
    return result
end

function M.compile_request_json(request_json)
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_internal, request_json)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_REQUEST_100" or "SEMANTIC_REQUEST_999"
        result = error_result(code, msg)
        request = nil
        model = nil
    end
    -- log_request inserts into AGENT_REQUEST_LOG and can itself collide under
    -- concurrent load. Retry the same way so the caller keeps STATUS=OK and a
    -- usable agent_request_id. If it still fails, leave the compile result
    -- intact - the generated SQL is still executable.
    for attempt = 0, COLLISION_RETRIES do
        local log_ok, log_err = pcall(log_request, result, request_json, request, model)
        if log_ok then break end
        if not collision_error(tostring(log_err)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    return result
end

-- Dry-run migration assistance for legacy primary-key and equality-join
-- metadata. Suggestions are deliberately limited to unambiguous column forms.
function M.suggest_grain_metadata(model_name)
    local model = load_model(normalize_name(model_name, "model"))
    if model == nil then
        return {{"ERROR", tostring(model_name), "MODEL_NOT_FOUND", null}}
    end
    local suggestions = {}
    local entities = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME, er.SOURCE_ALIAS, e.PRIMARY_KEY_EXPR
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
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    local alias_by_id = {}
    for _, row in ipairs(entities or {}) do
        local entity_id = row_value(row, "ENTITY_ID", 1)
        local entity_name = row_value(row, "ENTITY_NAME", 2)
        local alias = row_value(row, "SOURCE_ALIAS", 3)
        local expression = row_value(row, "PRIMARY_KEY_EXPR", 4)
        alias_by_id[key(entity_id)] = alias
        local clean = tostring(expression or ""):gsub('"', "")
        local expression_alias, column_name =
            string.match(clean, "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if expression_alias ~= nil and upper(expression_alias) == upper(alias) then
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SYS_SEMANTIC.UNIQUE_KEYS
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND ENTITY_ID = :entity_id
                  AND STATUS = 'ACTIVE'
            ]], {
                model_id = model.model_id,
                version_id = model.version_id,
                entity_id = entity_id,
            })
            if tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "UNIQUE_KEY",
                    entity_name,
                    "LEGACY_PRIMARY_KEY_EXPR",
                    json_encode({
                        key_name = tostring(entity_name) .. "_pk",
                        key_kind = "PRIMARY",
                        columns = {{ordinal_position = 1, column_name = column_name}},
                    }),
                }
            end
        end
    end

    local relationships = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationships or {}) do
        local relationship_id = row_value(row, "RELATIONSHIP_ID", 1)
        local relationship_name = row_value(row, "RELATIONSHIP_NAME", 2)
        local from_entity_id = row_value(row, "FROM_ENTITY_ID", 3)
        local to_entity_id = row_value(row, "TO_ENTITY_ID", 4)
        local condition = tostring(row_value(row, "JOIN_CONDITION", 5) or ""):gsub('"', "")
        local left_alias, left_column, right_alias, right_column =
            string.match(condition,
                "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*=%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if left_alias ~= nil then
            local from_alias = alias_by_id[key(from_entity_id)]
            local to_alias = alias_by_id[key(to_entity_id)]
            local from_column
            local to_column
            if upper(left_alias) == upper(from_alias) and upper(right_alias) == upper(to_alias) then
                from_column, to_column = left_column, right_column
            elseif upper(right_alias) == upper(from_alias) and upper(left_alias) == upper(to_alias) then
                from_column, to_column = right_column, left_column
            end
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
                WHERE RELATIONSHIP_ID = :relationship_id
            ]], {relationship_id = relationship_id})
            if from_column ~= nil and tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "RELATIONSHIP_MAPPING",
                    relationship_name,
                    "SIMPLE_EQUALITY_JOIN",
                    json_encode({
                        ordinal_position = 1,
                        from_column_name = from_column,
                        to_column_name = to_column,
                    }),
                }
            end
        end
    end
    if #suggestions == 0 then
        suggestions[1] = {"NONE", model.model_name, "NO_SAFE_SUGGESTIONS", null}
    end
    return suggestions
end

compile_request_json = M.compile_request_json
compile_sql = M.compile_sql
compile_sql_debug = M.compile_sql_debug
compile_sql_for_preprocessor = M.compile_sql_for_preprocessor
suggest_grain_metadata = M.suggest_grain_metadata

-- Database-free tests opt into this deliberately small pure-function surface.
-- Exasol never defines ESV_TEST_MODE, so the installed runtime's public API is
-- unchanged. Keeping the seam here lets the unit suite exercise parser,
-- normalization, expression, and predicate behavior without mocking a whole
-- database catalog.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_COMPILER_TEST_API = {
        json_encode = json_encode,
        json_decode = json_decode,
        canonical_request_text = canonical_request_text,
        compile_cache_key = compile_cache_key,
        quote_ident = quote_ident,
        quote_qualified = quote_qualified,
        sql_literal = sql_literal,
        resolve_field = resolve_field,
        relationship_edges = relationship_edges,
        find_path = find_path,
        strip_string_literals = strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        replace_identifiers = replace_identifiers,
        expand_metric = expand_metric,
        apply_metric_filter = apply_metric_filter,
        build_dimension_predicate = build_dimension_predicate,
        build_filters = build_filters,
        plan_joins = plan_joins,
        build_order_by = build_order_by,
        build_sql = build_sql,
        build_materialized_sql = build_materialized_sql,
        sql_tokens = sql_tokens,
        split_top_level = split_top_level,
        unwrap_measure_part = unwrap_measure_part,
        identifier_from_part = identifier_from_part,
        alias_from_select_part = alias_from_select_part,
        literal_from_tokens = literal_from_tokens,
        find_top_level_clauses = find_top_level_clauses,
        render_token_slice = render_token_slice,
        parse_where_filters = parse_where_filters,
        parse_having_filters = parse_having_filters,
        parse_order_by = parse_order_by,
        collision_error = collision_error,
    }
end
