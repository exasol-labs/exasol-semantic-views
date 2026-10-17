--- Records a materialization refresh time, current row count and snapshot, and clears the compile cache; returns one row.
-- @script SEMANTIC_ADMIN.MARK_MATERIALIZATION_REFRESHED
-- @param MODEL_NAME
-- @param MATERIALIZATION_NAME Materialization to mark; required, must exist in the active version.
-- @param REFRESHED_AT Timestamp of the refresh; must parse and not be in the future. NULL means now.
-- @param SOURCE_SNAPSHOT Optional source snapshot label stored as text; NULL clears it.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local models = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
    FROM SYS_SEMANTIC.MODELS m
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if models == nil or #models == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = row_value(models[1], "MODEL_ID", 1)
local version_id = row_value(models[1], "VERSION_ID", 2)

local rows = query([[
    SELECT MATERIALIZATION_ID, PHYSICAL_SCHEMA, PHYSICAL_OBJECT
    FROM SYS_SEMANTIC.MATERIALIZATIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {model_id = model_id, version_id = version_id,
     materialization_name = materialization_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_032: materialization not found: " .. materialization_name)
end
local materialization_id = row_value(rows[1], "MATERIALIZATION_ID", 1)
local physical_schema = tostring(row_value(rows[1], "PHYSICAL_SCHEMA", 2))
local physical_object = tostring(row_value(rows[1], "PHYSICAL_OBJECT", 3))

-- Resolved by the database, so any timestamp literal it accepts is accepted.
local refreshed_at
if missing(REFRESHED_AT) then
    refreshed_at = query("SELECT CURRENT_TIMESTAMP AS TS")[1][1]
else
    local ok, parsed = pcall(query, [[
        SELECT CAST(:refreshed_at AS TIMESTAMP) AS TS,
               CAST(:refreshed_at AS TIMESTAMP) > CURRENT_TIMESTAMP AS IN_FUTURE
    ]], {refreshed_at = tostring(REFRESHED_AT)})
    if not ok then
        error("SEMANTIC_ADMIN_222: REFRESHED_AT is not a timestamp: " .. tostring(REFRESHED_AT))
    end
    if parsed[1][2] == true then
        error("SEMANTIC_ADMIN_222: REFRESHED_AT is in the future: " .. tostring(REFRESHED_AT)
            .. ". Pass when the refresh happened, or NULL for now.")
    end
    refreshed_at = parsed[1][1]
end

local quoted = '"' .. physical_schema:upper():gsub('"', '""') .. '"."'
    .. physical_object:upper():gsub('"', '""') .. '"'
local counted, counts = pcall(query, "SELECT COUNT(*) AS ROW_COUNT FROM " .. quoted)
if not counted then
    error("SEMANTIC_ADMIN_223: materialization " .. materialization_name
        .. " cannot be read to measure it: " .. physical_schema .. "." .. physical_object
        .. " -- " .. tostring(counts))
end
local row_count = counts[1][1]

query([[
    UPDATE SYS_SEMANTIC.MATERIALIZATIONS
    SET LAST_REFRESHED_AT = :refreshed_at,
        REFRESHED_ROW_COUNT = :row_count,
        SOURCE_SNAPSHOT = :source_snapshot
    WHERE MATERIALIZATION_ID = :materialization_id
]], {refreshed_at = refreshed_at, row_count = row_count,
     source_snapshot = missing(SOURCE_SNAPSHOT) and null or tostring(SOURCE_SNAPSHOT),
     materialization_id = materialization_id})
-- Freshness decides whether the selector may choose it, so cached compiles
-- for this version no longer describe what a compile would do.
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = version_id})

local result = query([[
    SELECT MATERIALIZATION_NAME, STATUS, LAST_REFRESHED_AT, REFRESHED_ROW_COUNT,
           SOURCE_SNAPSHOT, FRESHNESS_POLICY
    FROM SYS_SEMANTIC.MATERIALIZATIONS
    WHERE MATERIALIZATION_ID = :materialization_id
]], {materialization_id = materialization_id})
local row = result[1]
exit({{row[1], row[2], row[3], row[4], row[5], row[6]}},
    "MATERIALIZATION_NAME VARCHAR(256), STATUS VARCHAR(32), LAST_REFRESHED_AT TIMESTAMP,"
    .. " REFRESHED_ROW_COUNT DECIMAL(18,0), SOURCE_SNAPSHOT VARCHAR(512),"
    .. " FRESHNESS_POLICY VARCHAR(512)")
