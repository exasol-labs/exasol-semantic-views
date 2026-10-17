--- Records a role grant for a model, grants SELECT on its published schema and SEMANTIC_USER; returns one row with the status.
-- @script SEMANTIC_ADMIN.GRANT_MODEL_ROLE
-- @param MODEL_NAME
-- @param ROLE_NAME Database role to grant to (identifier, upper-cased); repeat grants report ALREADY_GRANTED.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end
local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_200: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_201: invalid " .. label .. ": " .. name)
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
    error("SEMANTIC_ADMIN_202: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local model_name_actual = row_value(model_rows[1], "MODEL_NAME", 2)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 3)

local dup_rows = query([[
    SELECT GRANT_ID FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS
    WHERE MODEL_ID = :model_id AND UPPER(ROLE_NAME) = UPPER(:role_name) AND STATUS = 'ACTIVE'
    LIMIT 1
]], {model_id = model_id, role_name = role_name})
local grant_status = 'GRANTED'
if dup_rows ~= nil and #dup_rows > 0 then
    grant_status = 'ALREADY_GRANTED'
else
    query([[
        INSERT INTO SYS_SEMANTIC.MODEL_ROLE_GRANTS (MODEL_ID, MODEL_NAME, ROLE_NAME, PUBLISHED_SCHEMA)
        VALUES (:model_id, :model_name, :role_name, :published_schema)
    ]], {model_id = model_id, model_name = model_name_actual, role_name = role_name, published_schema = published_schema})
end

-- Grant the published schema only when it is actually there. A model can be
-- granted before it is published -- the seed does exactly that -- and this used
-- to raise "object SEMANTIC_X does not exist" *after* writing the grant row,
-- leaving the caller an error and the catalog a grant. That was survivable while
-- nothing read MODEL_ROLE_GRANTS; now that authorization does, a half-applied
-- grant silently makes a model private. PUBLISH_MODEL grants the schema to every
-- role already holding the model, so the ordering no longer matters either way.
local schema_present = false
if published_schema ~= nil and tostring(published_schema) ~= "" then
    local schema_rows = query([[
        SELECT 1 FROM EXA_ALL_SCHEMAS WHERE UPPER(SCHEMA_NAME) = UPPER(:schema_name)
    ]], {schema_name = published_schema})
    schema_present = schema_rows ~= nil and #schema_rows > 0
end
if schema_present then
    query("GRANT SELECT ON SCHEMA " .. quote_ident(published_schema) .. " TO " .. quote_ident(role_name))
end

-- The role also needs to be able to *use* the layer: read the principal-scoped
-- catalog and call the compiler. Without this, granting a model produced a role
-- that could see the published views and nothing else, and the first compile
-- failed on a privilege the caller had no way to know it needed. Best effort --
-- a deployment that manages the baseline itself, or has already granted it,
-- should not have GRANT_MODEL_ROLE fail on the second call.
pcall(query, "GRANT SEMANTIC_USER TO " .. quote_ident(role_name))

exit({{ model_name_actual, role_name, published_schema, grant_status }}, [[
    MODEL_NAME VARCHAR(256),
    ROLE_NAME VARCHAR(256),
    PUBLISHED_SCHEMA VARCHAR(256),
    STATUS VARCHAR(32)
]])
