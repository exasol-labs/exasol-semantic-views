--- Sets display policy and sensitivity label on a semantic view's dimension or metric; returns one row with the values.
-- @script SEMANTIC_ADMIN.SET_FIELD_POLICY
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic view that exposes the field.
-- @param FIELD_NAME Dimension or metric column of the view; facts are refused.
-- @param DISPLAY_POLICY Display policy text, stored trimmed; NULL clears it. Checked later by VALIDATE_MODEL.
-- @param SENSITIVITY_LABEL Sensitivity label text, stored trimmed; NULL clears it.
-- @returns TABLE

-- How a steward sets the two handling-policy columns on a field.
--
-- They had no writer. `DIMENSIONS` and `METRICS` have carried DISPLAY_POLICY and
-- SENSITIVITY_LABEL since the catalog was created, docs/governance.md presents
-- them as a control table, and docs/validation-rules.md documents
-- SEMANTIC_MODEL_069 for a bad DISPLAY_POLICY -- but the only thing in the
-- product that ever wrote either was a private helper inside the OSI document
-- importer. A steward reading the governance page had no route to MASK except a
-- direct UPDATE on SYS_SEMANTIC, which the same page tells them never to do.
--
-- Why a script and not a DDL clause beside PRIVATE. PRIVATE says what a field
-- *is* -- an invisible one -- and belongs with the field's definition. These two
-- say how a visible field must be *handled*, which is a governance decision made
-- about a model that already exists, usually by someone who did not write it.
-- That is the same shape as SET_MODEL_GOVERNANCE_MODE, and this is its
-- field-level member.
--
-- The value is not judged here. VALIDATE_MODEL owns the DISPLAY_POLICY
-- vocabulary and reports SEMANTIC_MODEL_069 against it; checking it here too
-- would put the list in two places and let them disagree. So this follows the
-- idiom SET_MODEL_GOVERNANCE_MODE states: the caller sets it, then validates,
-- and the validation tells them what it costs.
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

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local field_name = normalize_name(FIELD_NAME, "FIELD_NAME")
-- NULL clears a policy; that is the only way to remove one, and it is why these
-- two are not normalized through `missing` into a no-op.
local display_policy = missing(DISPLAY_POLICY) and null or trim(DISPLAY_POLICY)
local sensitivity_label = missing(SENSITIVITY_LABEL) and null or trim(SENSITIVITY_LABEL)

local models = query([[
    SELECT MODEL_ID, ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if models == nil or #models == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = models[1][1]
local version_id = models[1][2]

local objects = query([[
    SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(OBJECT_NAME) = UPPER(:object_name) AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, object_name = object_name})
if objects == nil or #objects == 0 then
    error("SEMANTIC_ADMIN_012: semantic object not found: " .. object_name)
end
local object_id = objects[1][1]

-- Resolved through OBJECT_COLUMNS, which is the same join the compiler uses to
-- decide what a field name means for this object. DIMENSIONS and METRICS are
-- keyed by model and entity rather than by object, so matching on the name alone
-- would reach a field of a different semantic view that happens to share it.
--
-- Deliberately not filtered on IS_VISIBLE: a field that is already private or
-- hidden is exactly one a steward may still need to label.
local columns = query([[
    SELECT COLUMN_KIND, OBJECT_REF_ID
    FROM SYS_SEMANTIC.OBJECT_COLUMNS
    WHERE OBJECT_ID = :object_id
      AND UPPER(COLUMN_NAME) = UPPER(:field_name)
]], {object_id = object_id, field_name = field_name})

if columns == nil or #columns == 0 then
    error("SEMANTIC_ADMIN_013: no dimension, metric or fact named " .. field_name
        .. " in " .. object_name)
end

local field_kind = tostring(columns[1][1])
local field_id = columns[1][2]

if field_kind == "DIMENSION" then
    query([[
        UPDATE SYS_SEMANTIC.DIMENSIONS
        SET DISPLAY_POLICY = :display_policy, SENSITIVITY_LABEL = :sensitivity_label
        WHERE DIMENSION_ID = :field_id
    ]], {display_policy = display_policy, sensitivity_label = sensitivity_label,
         field_id = field_id})
elseif field_kind == "METRIC" then
    query([[
        UPDATE SYS_SEMANTIC.METRICS
        SET DISPLAY_POLICY = :display_policy, SENSITIVITY_LABEL = :sensitivity_label
        WHERE METRIC_ID = :field_id
    ]], {display_policy = display_policy, sensitivity_label = sensitivity_label,
         field_id = field_id})
else
    -- A fact, and worth saying out loud rather than reporting as absent: it
    -- exists, and neither policy column has a reader for it, because a fact is
    -- never returned to a caller -- metrics are built from it.
    error("SEMANTIC_ADMIN_014: " .. field_name .. " is a " .. string.lower(field_kind)
        .. " of " .. object_name .. ". Display policy applies to what a caller can"
        .. " select -- a dimension or a metric -- and a " .. string.lower(field_kind)
        .. " is never returned. Set it on the metric built from this one instead.")
end

-- A cached compile was produced under the previous policy and would go on being
-- served under the new one, so the field would stay visible after being masked.
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = version_id})

exit({{model_name, object_name, field_name, field_kind,
       display_policy, sensitivity_label,
       "Set. Run VALIDATE_MODEL to check the value against the published"
       .. " vocabulary (SEMANTIC_MODEL_069) before relying on it."}}, [[
  MODEL_NAME VARCHAR(128),
  OBJECT_NAME VARCHAR(128),
  FIELD_NAME VARCHAR(128),
  FIELD_KIND VARCHAR(16),
  DISPLAY_POLICY VARCHAR(64),
  SENSITIVITY_LABEL VARCHAR(128),
  NEXT_STEP VARCHAR(512)
]])
