--- Renames an active entity representation without changing its role or bindings; returns one row saying whether it changed.
-- @script SEMANTIC_ADMIN.RENAME_ENTITY_REPRESENTATION
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity that owns the representation. Required.
-- @param REPRESENTATION_NAME Current name of the active representation. Required.
-- @param NEW_REPRESENTATION_NAME New name; must be unused for the entity. Same as current name is a no-op.
-- @returns TABLE

-- The rename SEMANTIC_ADMIN_221 has been telling callers to perform.
--
-- ADD_ENTITY mints the name 'primary' for an entity's first representation and
-- REPRESENTATION_ROLE is a separate column, so the first promotion anyone
-- performs leaves a row *named* primary holding role ALTERNATE. That is not an
-- error and the numbers stay right, so SET_PRIMARY_REPRESENTATION reports it as
-- an advisory -- which said "rename either representation to keep
-- ENTITY_REPRESENTATIONS readable", and no rename existed. A warning whose
-- remedy the product does not offer is worse than no warning: it tells the
-- reader the state is fixable and then strands them in it permanently.
--
-- This is a pure relabel, and the catalog is what makes that true.
-- REPRESENTATION_NAME occurs in exactly one column of one table, and every
-- reference to a representation -- ATTRIBUTE_BINDINGS, IDENTITY_BINDINGS,
-- REPRESENTATION_AUTHORITIES -- is by REPRESENTATION_ID. Nothing points at the
-- name, no expression embeds it, and no role, coverage, authority or binding
-- moves. So this script needs none of the candidate-and-rollback machinery its
-- neighbours carry, and it is short for a reason rather than by omission.
--
-- It clears the compile cache because cached PLAN_JSON records the old label in
-- its provenance. It deliberately does *not* mark VALIDATION_RUNS stale: a
-- relabel cannot change a verdict, and marking stale would drop a published
-- model to NEEDS_VALIDATION over a cosmetic fix. Validation results keep the
-- old name until the next run, which is the same by-design staleness 001
-- documents for VALIDATION_RESULTS.OBJECT_NAME -- results are recorded by name
-- so an issue survives its object being dropped.
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
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local new_name = normalize_name(NEW_REPRESENTATION_NAME, "NEW_REPRESENTATION_NAME")

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, er.REPRESENTATION_ID,
           er.REPRESENTATION_NAME, er.REPRESENTATION_ROLE
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
    representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_045: active representation not found: " .. representation_name)
end
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 4)
local previous_name = tostring(row_value(rows[1], "REPRESENTATION_NAME", 5))
local representation_role = tostring(row_value(rows[1], "REPRESENTATION_ROLE", 6))

local result_columns = [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  PREVIOUS_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  REPRESENTATION_ROLE VARCHAR(32),
  CHANGED BOOLEAN
]]

-- Renaming a representation to the name it already carries is a no-op, not a
-- collision with itself. Re-running an authoring script has to be safe here for
-- the same reason it is everywhere else in this API.
if string.upper(previous_name) == string.upper(new_name) then
    exit({{representation_id, model_name, entity_name, previous_name,
        previous_name, representation_role, false}}, result_columns)
end

local taken = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:new_name)
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id, new_name = new_name})
if tonumber(taken or 0) > 0 then
    error("SEMANTIC_ADMIN_046: duplicate representation name: " .. new_name)
end

query([[
    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    SET REPRESENTATION_NAME = :new_name,
        UPDATED_AT = CURRENT_TIMESTAMP,
        UPDATED_BY = CURRENT_USER
    WHERE REPRESENTATION_ID = :representation_id
]], {new_name = new_name, representation_id = representation_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})

exit({{representation_id, model_name, entity_name, previous_name, new_name,
    representation_role, true}}, result_columns)
