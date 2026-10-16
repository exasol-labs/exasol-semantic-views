local JSON_NULL = {}
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
local function json_decode(text)
    if missing(text) then error("empty JSON payload") end
    text = tostring(text)
    local pos = 1
    local function peek() return string.sub(text, pos, pos) end
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
        if peek() ~= '"' then error("expected string at byte " .. tostring(pos)) end
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
                else error("invalid escape at byte " .. tostring(pos)) end
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
        if peek() == "-" then pos = pos + 1 end
        while string.match(peek(), "%d") do pos = pos + 1 end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do pos = pos + 1 end
        end
        local c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then pos = pos + 1 end
            while string.match(peek(), "%d") do pos = pos + 1 end
        end
        local value = tonumber(string.sub(text, start_pos, pos - 1))
        if value == nil then error("invalid number at byte " .. tostring(start_pos)) end
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
            elseif c == "," then pos = pos + 1
            else error("expected array comma or close at byte " .. tostring(pos)) end
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
            if peek() ~= ":" then error("expected object colon at byte " .. tostring(pos)) end
            pos = pos + 1
            out[name] = parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return out
            elseif c == "," then pos = pos + 1
            else error("expected object comma or close at byte " .. tostring(pos)) end
        end
    end
    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then return parse_string()
        elseif c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == "-" or string.match(c, "%d") then return parse_number()
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
    if pos <= #text then error("unexpected trailing JSON at byte " .. tostring(pos)) end
    return value
end
local function json_field(item, name)
    local value = item[name]
    if value == JSON_NULL then return nil end
    return value
end
local function sql_value(value)
    if value == nil then return null end
    return value
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local ok, declarations = pcall(json_decode, COVERAGE_JSON)
if not ok or type(declarations) ~= "table" or #declarations == 0 then
    local detail = not ok and tostring(declarations)
        or (type(declarations) ~= "table" and "top-level value is not an array"
            or "array is empty")
    error("SEMANTIC_ADMIN_060: COVERAGE_JSON must be a non-empty JSON array: "
        .. detail)
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, er.REPRESENTATION_ID,
           er.REPRESENTATION_NAME, er.COVERAGE_PREDICATE, er.VALID_FROM, er.VALID_TO
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ORDER BY er.PRIORITY, er.REPRESENTATION_ID
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity or active representations not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local representations = {}
for _, row in ipairs(rows) do
    local name = tostring(row_value(row, "REPRESENTATION_NAME", 5))
    representations[string.upper(name)] = {
        id = row_value(row, "REPRESENTATION_ID", 4),
        name = name,
        previous_predicate = row_value(row, "COVERAGE_PREDICATE", 6) or null,
        previous_valid_from = row_value(row, "VALID_FROM", 7) or null,
        previous_valid_to = row_value(row, "VALID_TO", 8) or null,
    }
end
local seen = {}
local prepared = {}
for index, item in ipairs(declarations) do
    if type(item) ~= "table" then
        error("SEMANTIC_ADMIN_060: coverage declaration " .. tostring(index) .. " must be an object")
    end
    local representation_name = normalize_name(
        json_field(item, "representation_name"),
        "COVERAGE_JSON[" .. tostring(index) .. "].representation_name")
    local key = string.upper(representation_name)
    local representation = representations[key]
    if representation == nil then
        error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
    end
    if seen[key] then
        error("SEMANTIC_ADMIN_060: duplicate coverage declaration: " .. representation_name)
    end
    seen[key] = true
    local predicate = json_field(item, "coverage_predicate")
    local valid_from = json_field(item, "valid_from")
    local valid_to = json_field(item, "valid_to")
    if predicate ~= nil then predicate = trim(predicate) end
    if predicate == nil and (valid_from ~= nil or valid_to ~= nil) then
        error("SEMANTIC_ADMIN_003: coverage bounds require COVERAGE_PREDICATE for "
            .. representation_name)
    end
    if predicate ~= nil and valid_from == nil and valid_to == nil then
        error("SEMANTIC_ADMIN_003: UNION partition requires VALID_FROM or VALID_TO for "
            .. representation_name)
    end
    prepared[#prepared + 1] = {
        representation = representation,
        predicate = sql_value(predicate),
        valid_from = sql_value(valid_from),
        valid_to = sql_value(valid_to),
    }
end
for key, representation in pairs(representations) do
    if not seen[key] then
        error("SEMANTIC_ADMIN_060: coverage batch must declare every active representation; missing: "
            .. representation.name)
    end
end

for _, item in ipairs(prepared) do
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET COVERAGE_PREDICATE = :coverage_predicate,
            VALID_FROM = :valid_from, VALID_TO = :valid_to,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = item.representation.id,
          coverage_predicate = item.predicate,
          valid_from = item.valid_from, valid_to = item.valid_to})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

if tostring(model_status) == "PUBLISHED" then
    local candidate_validation = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name})
    for _, validation_row in ipairs(candidate_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            for _, representation in pairs(representations) do
                query([[
                    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
                    SET COVERAGE_PREDICATE = :coverage_predicate,
                        VALID_FROM = :valid_from, VALID_TO = :valid_to,
                        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
                    WHERE REPRESENTATION_ID = :representation_id
                ]], {representation_id = representation.id,
                      coverage_predicate = representation.previous_predicate,
                      valid_from = representation.previous_valid_from,
                      valid_to = representation.previous_valid_to})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_059: published coverage batch rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end

local result = {}
for _, item in ipairs(prepared) do
    result[#result + 1] = {item.representation.id, model_name, entity_name,
        item.representation.name, item.predicate == null and "NONE" or "UNION",
        item.predicate, item.valid_from, item.valid_to}
end
exit(result, [[
  REPRESENTATION_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  FUSION_STRATEGY VARCHAR(32), COVERAGE_PREDICATE VARCHAR(2000000),
  VALID_FROM TIMESTAMP, VALID_TO TIMESTAMP
]])
