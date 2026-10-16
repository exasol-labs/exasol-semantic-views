local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
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
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_schema = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
local source_object = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
local source_kind = missing(SOURCE_KIND) and "RELATION" or upper(SOURCE_KIND)
if source_kind ~= "RELATION" and source_kind ~= "VIRTUAL_SCHEMA" then
    error("SEMANTIC_ADMIN_003: invalid SOURCE_KIND: " .. tostring(SOURCE_KIND))
end
-- The catalog settles it, so a declared kind that disagrees is refused rather
-- than stored. SOURCE_KIND was free text: VIRTUAL_SCHEMA over an ordinary table
-- and RELATION over a virtual schema were both accepted, and the compiler treats
-- the distinction as a planning input.
do
    local declared_virtual = source_kind == "VIRTUAL_SCHEMA"
    local actually_virtual = tonumber(scalar([[
        SELECT COUNT(*) FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS
        WHERE UPPER(SCHEMA_NAME) = UPPER(:source_schema)
    ]], {source_schema = source_schema}) or 0) > 0
    if declared_virtual ~= actually_virtual then
        error("SEMANTIC_ADMIN_218: SOURCE_KIND " .. source_kind .. " disagrees with"
            .. " the catalog: " .. tostring(source_schema) .. " is "
            .. (actually_virtual and "a virtual schema" or "not a virtual schema")
            .. ". Declare " .. (actually_virtual and "VIRTUAL_SCHEMA" or "RELATION")
            .. ", or omit SOURCE_KIND and let it default.")
    end
end
local priority = missing(PRIORITY) and 100 or tonumber(PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: PRIORITY must be a positive integer")
end
if missing(COVERAGE_JSON) then
    error("SEMANTIC_ADMIN_060: COVERAGE_JSON is required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, e.ENTITY_ID,
           p.SOURCE_ALIAS
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS p
      ON p.ENTITY_ID = e.ENTITY_ID AND p.VERSION_ID = e.VERSION_ID
     AND p.REPRESENTATION_ROLE = 'PRIMARY' AND p.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity or active primary representation not found: "
        .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local entity_id = row_value(rows[1], "ENTITY_ID", 4)
local source_alias = row_value(rows[1], "SOURCE_ALIAS", 5)
local duplicate = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_046: duplicate representation name: " .. representation_name)
end
query([[
    INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
      SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
      PRIORITY, FRESHNESS_POLICY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :representation_name, :source_kind,
      :source_schema, :source_object, :source_alias, 'ALTERNATE',
      :priority, :freshness_policy, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      representation_name = representation_name, source_kind = source_kind,
      source_schema = source_schema, source_object = source_object,
      source_alias = source_alias, priority = priority,
      freshness_policy = missing(FRESHNESS_POLICY) and null or tostring(FRESHNESS_POLICY)})
local representation_id = scalar([[
    SELECT REPRESENTATION_ID FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
-- F3 compilation requires an explicit binding on every partition. Seed the
-- new representation from the governed legacy expressions; validation below
-- proves that those expressions exist on the new physical source.
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
      BINDING_PRIORITY, IS_DEFAULT, STATUS
    )
    SELECT d.MODEL_ID, d.VERSION_ID, d.ENTITY_ID, 'DIMENSION', d.DIMENSION_ID,
           :representation_id, d.EXPRESSION, 'PREFER', 1, FALSE, 'ACTIVE'
    FROM SYS_SEMANTIC.DIMENSIONS d
    WHERE d.MODEL_ID = :model_id AND d.VERSION_ID = :version_id
      AND d.ENTITY_ID = :entity_id AND d.STATUS = 'ACTIVE'
    UNION ALL
    SELECT f.MODEL_ID, f.VERSION_ID, f.ENTITY_ID, 'FACT', f.FACT_ID,
           :representation_id, f.EXPRESSION, 'PREFER', 1, FALSE, 'ACTIVE'
    FROM SYS_SEMANTIC.FACTS f
    WHERE f.MODEL_ID = :model_id AND f.VERSION_ID = :version_id
      AND f.ENTITY_ID = :entity_id AND f.STATUS = 'ACTIVE'
]], {representation_id = representation_id, model_id = model_id,
      version_id = version_id, entity_id = entity_id})
local applied, apply_result = pcall(query,
    "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
      .. ":model_name, :entity_name, :coverage_json)",
    {model_name = model_name, entity_name = entity_name,
     coverage_json = tostring(COVERAGE_JSON)})
if not applied then
    query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = representation_id})
    query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = representation_id})
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    if tostring(model_status) == "PUBLISHED" then
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
            {model_name = model_name})
    end
    error("SEMANTIC_ADMIN_061: representation-plus-coverage candidate rejected and restored: "
        .. tostring(apply_result))
end
exit({{representation_id, model_name, entity_name, representation_name,
    source_kind, source_schema, source_object, source_alias, "ALTERNATE", priority}}, [[
  REPRESENTATION_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  SOURCE_KIND VARCHAR(64), SOURCE_SCHEMA VARCHAR(256), SOURCE_OBJECT VARCHAR(256),
  SOURCE_ALIAS VARCHAR(128), REPRESENTATION_ROLE VARCHAR(64), PRIORITY DECIMAL(18,0)
]])
