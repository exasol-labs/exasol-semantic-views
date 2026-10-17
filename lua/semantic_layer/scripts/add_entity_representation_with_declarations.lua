--- Registers an alternate representation with optional authority, coverage, identity and attribute bindings in one call; returns one row.
-- @script SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity that must already have an active PRIMARY representation.
-- @param REPRESENTATION_NAME New representation name, unique per entity.
-- @param SOURCE_KIND
-- @param SOURCE_SCHEMA Schema of the source table or view (identifier).
-- @param SOURCE_OBJECT Table or view name in SOURCE_SCHEMA (identifier).
-- @param PRIORITY Positive integer; NULL defaults to 100.
-- @param FRESHNESS_POLICY Optional freshness policy text; NULL stores none.
-- @param DECLARATIONS_JSON Object, keys optional: authority, coverage [..], identity {..}, attribute_bindings [..]. NULL/{} = plain registration.
-- @returns TABLE

-- One entry point for registering a representation with whatever has to be
-- declared alongside it.
--
-- The four earlier forms are each one-dimensional -- plain, _WITH_AUTHORITY,
-- _WITH_COVERAGE, _WITH_IDENTITY_BINDING -- while authority x coverage x
-- identity is eight combinations. BUG-G04 was the report of a missing fifth: F5
-- identity is what unlocks F4 authority across mismatched keys, so combining them
-- is the documented use case and no single call did it. Adding a fifth script
-- would have picked one more point in that space; this covers all of it.
--
-- DECLARATIONS_JSON is a closed object:
--   {"authority": "AUTHORITATIVE" | "PREFER" | "SUPPLEMENTAL",
--    "coverage":  [ ... as ADD_ENTITY_REPRESENTATION_WITH_COVERAGE's COVERAGE_JSON ... ],
--    "identity":  {"identity_name": ..., "source_expression": ...,
--                  "binding_kind": "DIRECT" | "MAPPED", "mapping": { ... }}}
-- Every key is optional; an empty object registers a plain representation.
--
-- This *dispatches* to the existing forms instead of merging them, which is the
-- whole point. _WITH_COVERAGE and _WITH_IDENTITY_BINDING deliberately stage their
-- declaration before validating, because a representation is invalid until it
-- carries one -- reimplementing that staging is how a half-declared model gets
-- shipped. Authority is the one aspect that can be applied afterwards, because an
-- undeclared authority defaults to PREFER and validates, so it composes onto any
-- of them; if it is refused the representation is unwound, so the pair either
-- both land or neither does.
--
-- coverage together with identity is refused rather than unimplemented:
-- SEMANTIC_MODEL_047 already rejects an F5 identity combined with F3 coverage on
-- the same entity, so every *valid* combination is reachable through this call.
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
-- NULL is userdata here, not nil, and it is truthy: `tostring(value or "")`
-- renders it as "userdata: 0x..." and would forward that as a name. The
-- one-dimensional forms report SEMANTIC_ADMIN_001 for an absent name, and
-- passing "" on makes their own `missing` check produce exactly that.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
-- Same shape as ADD_ENTITY_REPRESENTATION's, because the staged path below
-- does that script's job and has to refuse the same inputs it would.
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

local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)

local declarations = {}
if not missing(DECLARATIONS_JSON) and upper(DECLARATIONS_JSON) ~= "NULL" then
    local decoded_ok, decoded = pcall(semantic_definition.decode_json,
        tostring(DECLARATIONS_JSON))
    if not decoded_ok or type(decoded) ~= "table" then
        error("SEMANTIC_ADMIN_214: DECLARATIONS_JSON must be a JSON object with any"
            .. " of the keys: authority, coverage, identity, attribute_bindings.")
    end
    -- A JSON array decodes to a table too, and would otherwise be reported as
    -- an unknown key named "1".
    if decoded[1] ~= nil then
        error("SEMANTIC_ADMIN_214: DECLARATIONS_JSON must be a JSON object, not an"
            .. " array. Allowed keys: authority, coverage, identity,"
            .. " attribute_bindings.")
    end
    declarations = decoded
end

-- Closed contract, like the compile request: a misspelled key must not be
-- silently ignored, or the call reports success without doing what was asked.
local allowed = {authority = true, coverage = true, identity = true,
    attribute_bindings = true}
local unknown = {}
for declaration_key, _ in pairs(declarations) do
    if not allowed[tostring(declaration_key)] then
        unknown[#unknown + 1] = tostring(declaration_key)
    end
end
if #unknown > 0 then
    table.sort(unknown)
    error("SEMANTIC_ADMIN_214: unknown DECLARATIONS_JSON key(s): "
        .. table.concat(unknown, ", ") .. ". Allowed keys: authority, coverage,"
        .. " identity, attribute_bindings.")
end

local authority = declarations.authority
local coverage = declarations.coverage
local identity = declarations.identity
local bindings = declarations.attribute_bindings
local has_authority = not missing(authority)
local has_coverage = type(coverage) == "table"
local has_identity = type(identity) == "table"
local has_bindings = type(bindings) == "table" and #bindings > 0
if bindings ~= nil and not has_bindings then
    error("SEMANTIC_ADMIN_216: attribute_bindings must be a non-empty JSON array"
        .. " of {attribute_type, attribute_name, source_expression} objects.")
end

if has_coverage and has_identity then
    error("SEMANTIC_ADMIN_215: coverage and identity cannot be declared on the"
        .. " same representation. Temporal coverage and a semantic identity"
        .. " on one entity are rejected by SEMANTIC_MODEL_047, so this combination"
        .. " has no valid outcome. Declare one of them.")
end

-- Staging the representation here, rather than dispatching, is the only way a
-- declared binding can be part of the same candidate.
--
-- Every representation-registering script inserts the row, then runs
-- VALIDATE_MODEL, then -- if the model is PUBLISHED -- deletes the row again
-- when validation failed. The bindings that make a *narrower* supplemental
-- source valid have to exist between that insert and that validation, and there
-- is no seam to reach in from outside. So when attribute_bindings are declared
-- this script does the insert itself and hands a complete candidate to the
-- coverage/identity/authority steps, which then validate against something that
-- can actually pass.
--
-- Without this, the canonical F4 shape -- a supplemental source that does not
-- carry every column the primary's dimensions reference -- was unreachable on a
-- published model by any route: the plain form fails SEMANTIC_MODEL_017, the
-- collapsed form fails SEMANTIC_MODEL_040 on the seeded binding, and a
-- document's entity-level bindings arrive after the representation has already
-- been validated and rolled back.
local declared = {}
local added_row
local staged_representation_id = nil
local staged_status = nil
if has_bindings then
    local model_name_checked = normalize_name(model_name, "MODEL_NAME")
    local entity_name_checked = normalize_name(entity_name, "ENTITY_NAME")
    local representation_checked =
        normalize_name(representation_name, "REPRESENTATION_NAME")
    local source_schema_checked = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
    local source_object_checked = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
    local source_kind_checked = missing(SOURCE_KIND) and "RELATION"
        or upper(SOURCE_KIND)
    if source_kind_checked ~= "RELATION" and source_kind_checked ~= "VIRTUAL_SCHEMA" then
        error("SEMANTIC_ADMIN_003: invalid SOURCE_KIND: " .. tostring(SOURCE_KIND))
    end
    local priority_checked = missing(PRIORITY) and 100 or tonumber(PRIORITY)
    if priority_checked == nil or priority_checked < 1
        or priority_checked % 1 ~= 0 then
        error("SEMANTIC_ADMIN_003: PRIORITY must be a positive integer")
    end

    local context = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, p.SOURCE_ALIAS, m.STATUS
        FROM SYS_SEMANTIC.MODELS m
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
         AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS p
          ON p.ENTITY_ID = e.ENTITY_ID AND p.REPRESENTATION_ROLE = 'PRIMARY'
         AND p.STATUS = 'ACTIVE'
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name_checked, entity_name = entity_name_checked})
    if context == nil or #context == 0 then
        error("SEMANTIC_ADMIN_014: entity or active primary representation not"
            .. " found: " .. entity_name_checked)
    end
    local model_id = row_value(context[1], "MODEL_ID", 1)
    local version_id = row_value(context[1], "ACTIVE_VERSION_ID", 2)
    local entity_id = row_value(context[1], "ENTITY_ID", 3)
    local source_alias = row_value(context[1], "SOURCE_ALIAS", 4)
    local model_status = upper(row_value(context[1], "STATUS", 5))
    staged_status = model_status

    local duplicate = query([[
        SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        WHERE ENTITY_ID = :entity_id
          AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
    ]], {entity_id = entity_id, representation_name = representation_checked})
    if tonumber(tostring(row_value(duplicate[1], "COUNT", 1) or 0)) > 0 then
        error("SEMANTIC_ADMIN_046: duplicate representation name: "
            .. representation_checked)
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
        representation_name = representation_checked,
        source_kind = source_kind_checked, source_schema = source_schema_checked,
        source_object = source_object_checked, source_alias = source_alias,
        priority = priority_checked,
        freshness_policy = missing(FRESHNESS_POLICY) and null
            or tostring(FRESHNESS_POLICY)})
    local staged = query([[
        SELECT REPRESENTATION_ID FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        WHERE ENTITY_ID = :entity_id
          AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
    ]], {entity_id = entity_id, representation_name = representation_checked})
    staged_representation_id = row_value(staged[1], "REPRESENTATION_ID", 1)

    -- Seed from the governed expressions, exactly as _WITH_COVERAGE does, so
    -- every attribute of the entity resolves on the new source by default.
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
    ]], {representation_id = staged_representation_id, model_id = model_id,
        version_id = version_id, entity_id = entity_id})

    -- Then overwrite the ones the caller declared. This is the whole point: a
    -- CAST(NULL AS ...) FALLBACK is how a source says "no opinion about this
    -- attribute", and it has to replace the seeded governed expression before
    -- anything validates.
    for index, binding in ipairs(bindings) do
        if type(binding) ~= "table" then
            error("SEMANTIC_ADMIN_216: attribute_bindings[" .. index
                .. "] must be a JSON object")
        end
        local attribute_type = upper(binding.attribute_type)
        if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
            error("SEMANTIC_ADMIN_216: attribute_bindings[" .. index
                .. "].attribute_type must be DIMENSION or FACT")
        end
        local attribute_name = trim(binding.attribute_name)
        local expression = trim(binding.source_expression)
        if attribute_name == "" or expression == "" then
            error("SEMANTIC_ADMIN_216: attribute_bindings[" .. index
                .. "] requires attribute_name and source_expression")
        end
        local role = upper(binding.binding_role)
        if role ~= "PREFER" and role ~= "FALLBACK" then role = "PREFER" end
        local binding_priority = tonumber(tostring(binding.binding_priority or 1)) or 1
        query([[
            UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            SET SOURCE_EXPRESSION = :expression, BINDING_ROLE = :role,
                BINDING_PRIORITY = :binding_priority,
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE REPRESENTATION_ID = :representation_id
              AND ATTRIBUTE_TYPE = :attribute_type
              AND ATTRIBUTE_ID IN (
                SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS
                WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
                  AND UPPER(DIMENSION_NAME) = UPPER(:attribute_name)
                  AND :attribute_type = 'DIMENSION'
                UNION ALL
                SELECT FACT_ID FROM SYS_SEMANTIC.FACTS
                WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
                  AND UPPER(FACT_NAME) = UPPER(:attribute_name)
                  AND :attribute_type = 'FACT'
              )
        ]], {expression = expression, role = role,
            binding_priority = binding_priority,
            representation_id = staged_representation_id,
            attribute_type = attribute_type, attribute_name = attribute_name,
            model_id = model_id, version_id = version_id})
        local present = query([[
            SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b
            LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
              ON b.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = b.ATTRIBUTE_ID
            LEFT JOIN SYS_SEMANTIC.FACTS f
              ON b.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = b.ATTRIBUTE_ID
            WHERE b.REPRESENTATION_ID = :representation_id
              AND UPPER(b.ATTRIBUTE_TYPE) = UPPER(:attribute_type)
              AND UPPER(COALESCE(d.DIMENSION_NAME, f.FACT_NAME)) = UPPER(:attribute_name)
              AND b.SOURCE_EXPRESSION = :expression
        ]], {representation_id = staged_representation_id,
            attribute_type = attribute_type, attribute_name = attribute_name,
            expression = expression})
        if tonumber(tostring(row_value(present[1], "COUNT", 1) or 0)) == 0 then
            query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS"
                .. " WHERE REPRESENTATION_ID = :representation_id",
                {representation_id = staged_representation_id})
            query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS"
                .. " WHERE REPRESENTATION_ID = :representation_id",
                {representation_id = staged_representation_id})
            error("SEMANTIC_ADMIN_217: attribute_bindings names an attribute the"
                .. " entity does not have, or one not bound to this"
                .. " representation: " .. attribute_type .. " "
                .. attribute_name .. ". Nothing was registered.")
        end
    end
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
    ]], {model_id = model_id, version_id = version_id})
    added_row = {staged_representation_id}
    declared[#declared + 1] = "attribute_bindings"
elseif has_identity then
    local mapping_json = null
    if type(identity.mapping) == "table" then
        mapping_json = semantic_definition.encode_json(identity.mapping)
    end
    local added = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING(
            :model_name, :entity_name, :representation_name, :source_kind,
            :source_schema, :source_object, :priority, :freshness_policy,
            :identity_name, :source_expression, :binding_kind, :mapping_json)
    ]], {model_name = model_name, entity_name = entity_name,
        representation_name = representation_name, source_kind = SOURCE_KIND,
        source_schema = SOURCE_SCHEMA, source_object = SOURCE_OBJECT,
        priority = PRIORITY, freshness_policy = FRESHNESS_POLICY,
        identity_name = identity.identity_name,
        source_expression = identity.source_expression,
        binding_kind = identity.binding_kind, mapping_json = mapping_json})
    added_row = added ~= nil and added[1] or nil
    declared[#declared + 1] = "identity"
elseif has_coverage then
    local added = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE(
            :model_name, :entity_name, :representation_name, :source_kind,
            :source_schema, :source_object, :priority, :freshness_policy,
            :coverage_json)
    ]], {model_name = model_name, entity_name = entity_name,
        representation_name = representation_name, source_kind = SOURCE_KIND,
        source_schema = SOURCE_SCHEMA, source_object = SOURCE_OBJECT,
        priority = PRIORITY, freshness_policy = FRESHNESS_POLICY,
        coverage_json = semantic_definition.encode_json(coverage)})
    added_row = added ~= nil and added[1] or nil
    declared[#declared + 1] = "coverage"
else
    local added = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION(
            :model_name, :entity_name, :representation_name, :source_kind,
            :source_schema, :source_object, :priority, :freshness_policy)
    ]], {model_name = model_name, entity_name = entity_name,
        representation_name = representation_name, source_kind = SOURCE_KIND,
        source_schema = SOURCE_SCHEMA, source_object = SOURCE_OBJECT,
        priority = PRIORITY, freshness_policy = FRESHNESS_POLICY})
    added_row = added ~= nil and added[1] or nil
end
if added_row == nil then
    error("SEMANTIC_ADMIN_046: representation was not registered: "
        .. representation_name)
end

local function unwind_staged()
    if staged_representation_id == nil then return end
    pcall(query, "DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS"
        .. " WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = staged_representation_id})
    pcall(query, "DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS"
        .. " WHERE REPRESENTATION_ID = :representation_id",
        {representation_id = staged_representation_id})
end

-- In the staged path the remaining declarations go on top of a candidate whose
-- bindings already resolve, so each of these sub-calls validates against
-- something that can pass -- which is exactly what they cannot do when the
-- representation arrives on its own.
if has_bindings and has_coverage then
    local applied, coverage_error = pcall(query, [[
        EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH(
            :model_name, :entity_name, :coverage_json)
    ]], {model_name = model_name, entity_name = entity_name,
        coverage_json = semantic_definition.encode_json(coverage)})
    if not applied then
        unwind_staged()
        error("SEMANTIC_ADMIN_094: representation candidate rejected and restored;"
            .. " the coverage declaration failed: " .. tostring(coverage_error))
    end
    declared[#declared + 1] = "coverage"
end

if has_bindings and has_identity then
    local applied, identity_error = pcall(function()
        query([[
            EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
                :model_name, :identity_name, :representation_name,
                :source_expression, :binding_kind)
        ]], {model_name = model_name, identity_name = identity.identity_name,
            representation_name = representation_name,
            source_expression = identity.source_expression,
            binding_kind = identity.binding_kind})
        if type(identity.mapping) == "table" then
            local mapping = identity.mapping
            query([[
                EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION(
                    :model_name, :identity_name, :representation_name,
                    :source_schema, :source_object, :source_local_column,
                    :semantic_key_column, :certification_status)
            ]], {model_name = model_name, identity_name = identity.identity_name,
                representation_name = representation_name,
                source_schema = mapping.source_schema,
                source_object = mapping.source_object,
                source_local_column = mapping.source_local_column,
                semantic_key_column = mapping.semantic_key_column,
                certification_status = missing(mapping.certification_status)
                    and "CERTIFIED" or upper(mapping.certification_status)})
        end
    end)
    if not applied then
        unwind_staged()
        error("SEMANTIC_ADMIN_094: representation candidate rejected and restored;"
            .. " the identity declaration failed: " .. tostring(identity_error))
    end
    declared[#declared + 1] = "identity"
end

local authority_role = null
if has_authority then
    authority_role = upper(authority)
    local applied, authority_error = pcall(query, [[
        EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
            :model_name, :entity_name, :representation_name, :authority_role)
    ]], {model_name = model_name, entity_name = entity_name,
        representation_name = representation_name, authority_role = authority_role})
    if not applied then
        -- Unwind, so a refused authority declaration does not leave a
        -- representation the caller did not ask for on its own.
        pcall(query, [[
            EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION(
                :model_name, :entity_name, :representation_name)
        ]], {model_name = model_name, entity_name = entity_name,
            representation_name = representation_name})
        error("SEMANTIC_ADMIN_094: representation candidate rejected and restored;"
            .. " the authority declaration failed: " .. tostring(authority_error))
    end
    declared[#declared + 1] = "authority"
end

-- One proof for the whole candidate. The dispatched paths validate inside their
-- sub-script; the staged path has to do it here, and unwind the same way.
if has_bindings then
    local blocking = {}
    for _, row in ipairs(query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name}) or {}) do
        local severity = upper(row_value(row, "SEVERITY", 1))
        if severity == "ERROR" or severity == "PRECONDITION" then
            blocking[#blocking + 1] = tostring(row_value(row, "RULE_CODE", 4))
                .. " [" .. tostring(row_value(row, "OBJECT_TYPE", 2)) .. " "
                .. tostring(row_value(row, "OBJECT_NAME", 3)) .. "] "
                .. tostring(row_value(row, "MESSAGE", 5))
        end
    end
    if staged_status == "PUBLISHED" and #blocking > 0 then
        unwind_staged()
        pcall(query, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
            {model_name = model_name})
        error("SEMANTIC_ADMIN_094: published representation-with-bindings candidate"
            .. " rejected and restored; candidate introduced "
            .. tostring(#blocking) .. " validation error(s): "
            .. table.concat(blocking, "; "))
    end
    -- The staged path marked VALIDATION_RUNS stale on its way in, and the
    -- candidate has just been proved. Recertify so the compile cache is usable
    -- again rather than leaving a published model with no current validation --
    -- which is the contract the older representation scripts predate.
    pcall(query, "EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
        {model_name = model_name})
end

exit({{
    row_value(added_row, "REPRESENTATION_ID", 1),
    model_name,
    entity_name,
    representation_name,
    #declared > 0 and table.concat(declared, ",") or null,
    authority_role,
}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  DECLARED VARCHAR(256),
  AUTHORITY_ROLE VARCHAR(32)
]])
