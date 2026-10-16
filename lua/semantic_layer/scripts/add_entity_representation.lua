local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
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

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return row_value(rows[1], "VALUE", 1) or rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_schema = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
local source_object = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
local source_kind = missing(SOURCE_KIND) and "RELATION" or upper(trim(SOURCE_KIND))
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

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, p.SOURCE_ALIAS,
           m.STATUS
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS p
      ON p.ENTITY_ID = e.ENTITY_ID
     AND p.MODEL_ID = e.MODEL_ID
     AND p.VERSION_ID = e.VERSION_ID
     AND p.REPRESENTATION_ROLE = 'PRIMARY'
     AND p.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity or active primary representation not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local source_alias = row_value(rows[1], "SOURCE_ALIAS", 4)
local model_status = row_value(rows[1], "STATUS", 5)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
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
]], {
    model_id = model_id,
    version_id = version_id,
    entity_id = entity_id,
    representation_name = representation_name,
    source_kind = source_kind,
    source_schema = source_schema,
    source_object = source_object,
    source_alias = source_alias,
    priority = priority,
    freshness_policy = missing(FRESHNESS_POLICY) and null or tostring(FRESHNESS_POLICY),
})
local representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

-- Registering a representation seeds compatibility bindings, and a seeded
-- binding that does not hold is the single most common reason the next
-- authoring call fails. Report them here the way the F5 compound call already
-- did, instead of leaving the modeller to find them in a later VALIDATE_MODEL.
local candidate_validation = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
    {model_name = model_name})
local validation_errors = {}
local generated_binding_issues = {}
local binding_suffix = "@" .. upper(representation_name)
for _, validation_row in ipairs(candidate_validation or {}) do
    local severity = tostring(row_value(validation_row, "SEVERITY", 1))
    if severity == "ERROR" or severity == "PRECONDITION" then
        local rule_code = row_value(validation_row, "RULE_CODE", 4)
            or "SEMANTIC_MODEL_ERROR"
        local message = row_value(validation_row, "MESSAGE", 5)
            or "model validation failed"
        local object_type = row_value(validation_row, "OBJECT_TYPE", 2) or "MODEL"
        local object_name = row_value(validation_row, "OBJECT_NAME", 3) or model_name
        local detail = tostring(rule_code) .. " [" .. tostring(object_type)
            .. " " .. tostring(object_name) .. "] " .. tostring(message)
        validation_errors[#validation_errors + 1] = detail
        -- An issue belongs to this registration when it is attributed to one of
        -- its seeded bindings, to the representation itself, or when the
        -- message names it -- SEMANTIC_MODEL_017 reports "in representation(s):
        -- <name>" against the *dimension*, which is the common case.
        local normalized_object_name = upper(object_name)
        local normalized_name = upper(representation_name)
        if (upper(object_type) == "ATTRIBUTE_BINDING"
                and string.sub(normalized_object_name, -#binding_suffix) == binding_suffix)
            or (upper(object_type) == "ENTITY_REPRESENTATION"
                and string.sub(normalized_object_name, -#normalized_name - 1)
                    == "." .. normalized_name)
            or string.find(upper(message), "REPRESENTATION(S): ", 1, true) ~= nil
                and string.find(upper(message), normalized_name, 1, true) ~= nil then
            generated_binding_issues[#generated_binding_issues + 1] = detail
        end
    end
end

if tostring(model_status) == "PUBLISHED" and #validation_errors > 0 then
    query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = representation_id})
    query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = representation_id})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name})
    error("SEMANTIC_ADMIN_094: published representation change rejected and restored; "
        .. "candidate introduced validation error: " .. validation_errors[1])
end

exit({{representation_id, model_name, entity_name, representation_name,
    source_kind, source_schema, source_object, source_alias, "ALTERNATE", priority,
    #generated_binding_issues,
    #generated_binding_issues == 0 and null
        or table.concat(generated_binding_issues, "; ")}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  SOURCE_KIND VARCHAR(64),
  SOURCE_SCHEMA VARCHAR(256),
  SOURCE_OBJECT VARCHAR(256),
  SOURCE_ALIAS VARCHAR(128),
  REPRESENTATION_ROLE VARCHAR(64),
  PRIORITY DECIMAL(18,0),
  GENERATED_BINDING_ISSUE_COUNT DECIMAL(18,0),
  GENERATED_BINDING_ISSUES VARCHAR(2000000)
]])
