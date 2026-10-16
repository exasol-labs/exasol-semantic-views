local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end
local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_210: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_211: invalid " .. label .. ": " .. name)
    end
    return string.upper(name)
end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local role_name = normalize_name(ROLE_NAME, "ROLE_NAME")

local model_rows = query([[
    SELECT MODEL_ID, MODEL_NAME, PUBLISHED_SCHEMA
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_212: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local model_name_actual = row_value(model_rows[1], "MODEL_NAME", 2)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 3)

query([[
    UPDATE SYS_SEMANTIC.MODEL_ROLE_GRANTS
    SET STATUS = 'REVOKED'
    WHERE MODEL_ID = :model_id AND UPPER(ROLE_NAME) = UPPER(:role_name) AND STATUS = 'ACTIVE'
]], {model_id = model_id, role_name = role_name})

if published_schema ~= nil and tostring(published_schema) ~= "" then
    query("REVOKE SELECT ON SCHEMA " .. quote_ident(published_schema) .. " FROM " .. quote_ident(role_name))
end

exit({{ model_name_actual, role_name, published_schema, 'REVOKED' }}, [[
    MODEL_NAME VARCHAR(256),
    ROLE_NAME VARCHAR(256),
    PUBLISHED_SCHEMA VARCHAR(256),
    STATUS VARCHAR(32)
]])
