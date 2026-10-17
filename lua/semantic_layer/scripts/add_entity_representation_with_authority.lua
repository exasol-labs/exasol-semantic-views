--- Adds an alternate entity representation and sets its authority role, undoing both if either fails; returns one row.
-- @script SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity that receives the alternate representation.
-- @param REPRESENTATION_NAME Name of the new representation; must be unique for the entity.
-- @param SOURCE_KIND
-- @param SOURCE_SCHEMA Schema of the source relation. Required.
-- @param SOURCE_OBJECT Table or view backing the representation. Required.
-- @param PRIORITY Positive integer priority; NULL defaults to 100.
-- @param FRESHNESS_POLICY Optional free-text freshness policy; NULL stores NULL.
-- @param AUTHORITY_ROLE Authority role: AUTHORITATIVE, PREFER or SUPPLEMENTAL (case-insensitive).
-- @returns TABLE

-- Register an alternate representation and declare its authority in one step.
--
-- F4 needs both: a representation with no authority declaration defaults to
-- PREFER, so the two-call sequence passes through a state that says something
-- the modeller did not mean, and on a published model each call is validated
-- separately. This composes the two, and unwinds the representation if the
-- authority declaration is refused -- so the pair either both land or neither
-- does, which is what the other compound calls guarantee.
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function upper(value) return string.upper(trim(value)) end

local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
local authority_role = upper(AUTHORITY_ROLE)
if authority_role ~= "AUTHORITATIVE" and authority_role ~= "PREFER"
    and authority_role ~= "SUPPLEMENTAL" then
    error("SEMANTIC_ADMIN_003: AUTHORITY_ROLE must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL")
end

local added = query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION(
        :model_name, :entity_name, :representation_name, :source_kind,
        :source_schema, :source_object, :priority, :freshness_policy)
]], {
    model_name = model_name,
    entity_name = entity_name,
    representation_name = representation_name,
    source_kind = SOURCE_KIND,
    source_schema = SOURCE_SCHEMA,
    source_object = SOURCE_OBJECT,
    priority = PRIORITY,
    freshness_policy = FRESHNESS_POLICY,
})
local added_row = added ~= nil and added[1] or nil
if added_row == nil then
    error("SEMANTIC_ADMIN_046: representation was not registered: " .. representation_name)
end

local ok, authority_error = pcall(query, [[
    EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
        :model_name, :entity_name, :representation_name, :authority_role)
]], {
    model_name = model_name,
    entity_name = entity_name,
    representation_name = representation_name,
    authority_role = authority_role,
})
if not ok then
    -- Unwind the half-applied pair, so a refused authority declaration does not
    -- leave a representation the caller did not ask for on its own.
    pcall(query, [[
        EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION(
            :model_name, :entity_name, :representation_name)
    ]], {
        model_name = model_name,
        entity_name = entity_name,
        representation_name = representation_name,
    })
    error("SEMANTIC_ADMIN_094: representation-with-authority candidate rejected and "
        .. "restored; the authority declaration failed: " .. tostring(authority_error))
end

exit({{
    row_value(added_row, "REPRESENTATION_ID", 1),
    model_name,
    entity_name,
    representation_name,
    row_value(added_row, "SOURCE_KIND", 5),
    row_value(added_row, "SOURCE_SCHEMA", 6),
    row_value(added_row, "SOURCE_OBJECT", 7),
    row_value(added_row, "SOURCE_ALIAS", 8),
    authority_role,
    row_value(added_row, "PRIORITY", 10),
    row_value(added_row, "GENERATED_BINDING_ISSUE_COUNT", 11),
    row_value(added_row, "GENERATED_BINDING_ISSUES", 12),
}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  SOURCE_KIND VARCHAR(64),
  SOURCE_SCHEMA VARCHAR(256),
  SOURCE_OBJECT VARCHAR(256),
  SOURCE_ALIAS VARCHAR(128),
  AUTHORITY_ROLE VARCHAR(32),
  PRIORITY DECIMAL(18,0),
  GENERATED_BINDING_ISSUE_COUNT DECIMAL(18,0),
  GENERATED_BINDING_ISSUES VARCHAR(2000000)
]])
