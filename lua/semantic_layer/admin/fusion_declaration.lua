-- The fusion layer as one document.
--
-- Tier 1 -- what one source says about itself -- has a document format already:
-- Apache Ossie/OSI, one file per source, and `tools/osi.py import` to bring it
-- in. Tier 2, how those sources compose, had none. Every F1-F5 declaration was
-- reachable only through a positional script, and on a *published* model not
-- even incrementally: each of `ADD_ENTITY_REPRESENTATION`,
-- `ADD_IDENTITY_BINDING`, `ADD_IDENTITY_MAPPING_RELATION` and
-- `SET_REPRESENTATION_AUTHORITY` is refused on its own, because each alone
-- leaves the model invalid. The eight compound `_WITH_*` forms exist to get
-- around that, and they enumerate by hand a space that is a product --
-- authority x coverage x identity x bindings x primary. BUG-G04 was a report
-- that one combination had no door.
--
-- A document is the shape that matches the physics: the unit a published fusion
-- change has to arrive in is "all of it", so make that the unit the caller
-- writes. This module owns the format, both directions:
--
--   M.export_fusion_declaration(model, entity)  catalog  -> document
--   M.apply_fusion_declaration(model, json, dry) document -> catalog
--
-- Round-trip is the contract: exporting, applying and exporting again must
-- produce the identical document, which is what makes the file safe to keep in
-- source control and re-apply.
--
-- Deliberately *not* in here: anything tier 1 owns (entities, dimensions,
-- facts, metrics, relationships, keys -- those are OSI and Semantic DDL), and
-- materializations, which are physical acceleration of an object rather than a
-- statement about how sources compose.

local json = assert(ESV_JSON, "shared JSON runtime is required")
local rollback = assert(ESV_CATALOG_ROLLBACK,
    "shared catalog rollback runtime is required")

local M = {}

-- A SQL NULL parameter reaches an Exasol Lua script as *userdata*, and userdata
-- is truthy -- so `value == nil` alone lets a NULL through as the string
-- "userdata: 0x...". `null` is the script-context global for it, and comparing
-- against it is the only reliable test. Getting this wrong here silently
-- filtered every export to an entity literally named "userdata: 0x...".
-- json.NULL is in the list because this module reads a *decoded document*: an
-- explicit `"authority": null` arrives as the decoder's sentinel table, which is
-- neither nil nor Exasol's `null` and whose tostring is "table: 0x...". Before
-- the JSON codec was shared this module had no way to name that value, so an
-- explicit null read as a present declaration and rendered its own address into
-- the catalog. An omitted key and an explicit null now mean the same thing,
-- which is what the round-trip contract requires -- the exporter omits absent
-- keys rather than writing them as null.
local function missing(value)
    return value == nil or value == null or value == json.NULL
        or tostring(value) == ""
end

local function trim(value)
    if missing(value) then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(trim(value))
end

local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end

-- Absent keys are omitted from the document rather than written as null: the
-- round-trip compares documents, and `{"a": null}` and `{}` must not be two
-- spellings of the same model.
local function put(target, key, value)
    if missing(value) then return end
    target[key] = tostring(value)
end

local function put_number(target, key, value)
    if missing(value) then return end
    target[key] = tonumber(tostring(value))
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

local function load_model(query_fn, model_name)
    local rows = query_fn([[
        SELECT MODEL_ID, ACTIVE_VERSION_ID, MODEL_NAME, STATUS
        FROM SYS_SEMANTIC.MODELS
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_FUSION_001: model not found: " .. tostring(model_name))
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2),
        model_name = row_value(rows[1], "MODEL_NAME", 3),
        status = upper(row_value(rows[1], "STATUS", 4)),
    }
end

-- Every active representation of every entity, with the coverage and authority
-- that hang off it. Coverage is three columns *on* the representation rather
-- than its own table, so F1 and F3 come back in one read.
local function representation_rows(query_fn, model, entity_name)
    return query_fn([[
        SELECT e.ENTITY_NAME, r.REPRESENTATION_ID, r.REPRESENTATION_NAME,
               r.SOURCE_KIND, r.SOURCE_SCHEMA, r.SOURCE_OBJECT, r.SOURCE_ALIAS,
               r.REPRESENTATION_ROLE, r.PRIORITY, r.FRESHNESS_POLICY,
               r.COVERAGE_PREDICATE, r.VALID_FROM, r.VALID_TO,
               a.AUTHORITY_ROLE
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = r.ENTITY_ID
        LEFT JOIN SYS_SEMANTIC.REPRESENTATION_AUTHORITIES a
          ON a.REPRESENTATION_ID = r.REPRESENTATION_ID
         AND a.STATUS = 'ACTIVE'
        WHERE r.MODEL_ID = :model_id
          AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE'
          AND e.STATUS = 'ACTIVE'
          AND (:entity_name IS NULL
               OR UPPER(e.ENTITY_NAME) = UPPER(:entity_name))
        ORDER BY e.ENTITY_NAME, r.PRIORITY, r.REPRESENTATION_NAME
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
end

local function identity_rows(query_fn, model, entity_name)
    return query_fn([[
        SELECT e.ENTITY_NAME, i.IDENTITY_NAME, i.IDENTITY_KIND, i.DATA_TYPE,
               i.DESCRIPTION
        FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES i
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = i.ENTITY_ID
        WHERE i.MODEL_ID = :model_id
          AND i.VERSION_ID = :version_id
          AND i.STATUS = 'ACTIVE'
          AND e.STATUS = 'ACTIVE'
          AND (:entity_name IS NULL
               OR UPPER(e.ENTITY_NAME) = UPPER(:entity_name))
        ORDER BY e.ENTITY_NAME, i.IDENTITY_NAME
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
end

local function identity_binding_rows(query_fn, model, entity_name)
    return query_fn([[
        SELECT e.ENTITY_NAME, r.REPRESENTATION_NAME, b.SOURCE_EXPRESSION,
               b.BINDING_KIND, m.SOURCE_SCHEMA, m.SOURCE_OBJECT,
               m.SOURCE_LOCAL_COLUMN, m.SEMANTIC_KEY_COLUMN,
               m.CERTIFICATION_STATUS
        FROM SYS_SEMANTIC.IDENTITY_BINDINGS b
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = b.ENTITY_ID
        LEFT JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS m
          ON m.IDENTITY_BINDING_ID = b.IDENTITY_BINDING_ID
         AND m.STATUS = 'ACTIVE'
        WHERE b.MODEL_ID = :model_id
          AND b.VERSION_ID = :version_id
          AND b.STATUS = 'ACTIVE'
          AND r.STATUS = 'ACTIVE'
          AND (:entity_name IS NULL
               OR UPPER(e.ENTITY_NAME) = UPPER(:entity_name))
        ORDER BY e.ENTITY_NAME, r.REPRESENTATION_NAME
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
end

-- Per-representation bindings, excluding each attribute's own default on the
-- primary (IS_DEFAULT = TRUE) -- that one is the attribute's expression, not a
-- fusion decision, and exporting it would make the document a copy of the
-- attribute list.
--
-- Bindings the compound forms *seeded* on an alternate are included, because the
-- catalog records no provenance to tell them from hand-declared ones and
-- re-applying either is a no-op. That is the honest read: the document describes
-- the fusion state, not the sequence of calls that produced it.
local function attribute_binding_rows(query_fn, model, entity_name)
    return query_fn([[
        SELECT e.ENTITY_NAME, b.ATTRIBUTE_TYPE,
               COALESCE(d.DIMENSION_NAME, f.FACT_NAME) AS ATTRIBUTE_NAME,
               r.REPRESENTATION_NAME, b.SOURCE_EXPRESSION, b.BINDING_ROLE,
               b.BINDING_PRIORITY
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = b.ENTITY_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON b.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = b.ATTRIBUTE_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON b.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = b.ATTRIBUTE_ID
        WHERE b.MODEL_ID = :model_id
          AND b.VERSION_ID = :version_id
          AND b.STATUS = 'ACTIVE'
          AND b.IS_DEFAULT = FALSE
          AND r.STATUS = 'ACTIVE'
          AND (:entity_name IS NULL
               OR UPPER(e.ENTITY_NAME) = UPPER(:entity_name))
        ORDER BY e.ENTITY_NAME, b.ATTRIBUTE_TYPE, 3, r.REPRESENTATION_NAME
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
end

local function attribute_policy_rows(query_fn, model, entity_name)
    return query_fn([[
        SELECT e.ENTITY_NAME, p.ATTRIBUTE_TYPE,
               COALESCE(d.DIMENSION_NAME, f.FACT_NAME) AS ATTRIBUTE_NAME,
               p.FUSION_STRATEGY
        FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES p
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = p.ENTITY_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON p.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = p.ATTRIBUTE_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON p.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = p.ATTRIBUTE_ID
        WHERE p.MODEL_ID = :model_id
          AND p.VERSION_ID = :version_id
          AND p.STATUS = 'ACTIVE'
          AND (:entity_name IS NULL
               OR UPPER(e.ENTITY_NAME) = UPPER(:entity_name))
        ORDER BY e.ENTITY_NAME, p.ATTRIBUTE_TYPE, 3
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
end

local function entity_slot(document, entity_name)
    local name = trim(entity_name)
    if document.entities[name] == nil then
        document.entities[name] = {representations = {}}
        document.entity_order[#document.entity_order + 1] = name
    end
    return document.entities[name]
end

-- An entity with exactly one representation, no identity, no authority and no
-- declared bindings has no fusion to describe. Leaving it out is what keeps the
-- document proportional to the fusion, not to the model.
local function is_fused(entity)
    if #entity.representations > 1 then return true end
    if entity.identity ~= nil then return true end
    if entity.attribute_bindings ~= nil then return true end
    if entity.attribute_policies ~= nil then return true end
    for _, representation in ipairs(entity.representations) do
        if representation.authority ~= nil or representation.coverage ~= nil
            or representation.identity_binding ~= nil then
            return true
        end
    end
    return false
end

function M.build_document(query_fn, model_name, entity_name_arg)
    local model = load_model(query_fn, model_name)
    -- `null`, not nil: Exasol refuses a query whose bind variable is undefined,
    -- so "every entity" has to be an explicit SQL NULL for the
    -- `:entity_name IS NULL` branch of each read.
    local entity_name = trim(entity_name_arg)
    if entity_name == "" then entity_name = null end

    local document = {model = model.model_name, entities = {}, entity_order = {}}
    local by_representation = {}

    for _, row in ipairs(representation_rows(query_fn, model, entity_name) or {}) do
        local entity = entity_slot(document, row_value(row, "ENTITY_NAME", 1))
        local representation = {}
        put(representation, "name", row_value(row, "REPRESENTATION_NAME", 3))
        put(representation, "role", row_value(row, "REPRESENTATION_ROLE", 8))
        put(representation, "source_kind", row_value(row, "SOURCE_KIND", 4))
        put(representation, "source_schema", row_value(row, "SOURCE_SCHEMA", 5))
        put(representation, "source_object", row_value(row, "SOURCE_OBJECT", 6))
        put(representation, "source_alias", row_value(row, "SOURCE_ALIAS", 7))
        put_number(representation, "priority", row_value(row, "PRIORITY", 9))
        put(representation, "freshness_policy", row_value(row, "FRESHNESS_POLICY", 10))
        put(representation, "authority", row_value(row, "AUTHORITY_ROLE", 14))

        local predicate = row_value(row, "COVERAGE_PREDICATE", 11)
        local valid_from = row_value(row, "VALID_FROM", 12)
        local valid_to = row_value(row, "VALID_TO", 13)
        if not (missing(predicate) and missing(valid_from) and missing(valid_to)) then
            local coverage = {}
            put(coverage, "predicate", predicate)
            put(coverage, "valid_from", valid_from)
            put(coverage, "valid_to", valid_to)
            representation.coverage = coverage
        end

        entity.representations[#entity.representations + 1] = representation
        local key = trim(row_value(row, "ENTITY_NAME", 1)) .. "\1"
            .. trim(row_value(row, "REPRESENTATION_NAME", 3))
        by_representation[key] = representation
    end

    for _, row in ipairs(identity_rows(query_fn, model, entity_name) or {}) do
        local entity = entity_slot(document, row_value(row, "ENTITY_NAME", 1))
        local identity = {}
        put(identity, "name", row_value(row, "IDENTITY_NAME", 2))
        put(identity, "kind", row_value(row, "IDENTITY_KIND", 3))
        put(identity, "data_type", row_value(row, "DATA_TYPE", 4))
        put(identity, "description", row_value(row, "DESCRIPTION", 5))
        entity.identity = identity
    end

    for _, row in ipairs(identity_binding_rows(query_fn, model, entity_name) or {}) do
        local key = trim(row_value(row, "ENTITY_NAME", 1)) .. "\1"
            .. trim(row_value(row, "REPRESENTATION_NAME", 2))
        local representation = by_representation[key]
        if representation ~= nil then
            local binding = {}
            put(binding, "source_expression", row_value(row, "SOURCE_EXPRESSION", 3))
            put(binding, "binding_kind", row_value(row, "BINDING_KIND", 4))
            local schema = row_value(row, "SOURCE_SCHEMA", 5)
            if not missing(schema) then
                local mapping = {}
                put(mapping, "source_schema", schema)
                put(mapping, "source_object", row_value(row, "SOURCE_OBJECT", 6))
                put(mapping, "source_local_column", row_value(row, "SOURCE_LOCAL_COLUMN", 7))
                put(mapping, "semantic_key_column", row_value(row, "SEMANTIC_KEY_COLUMN", 8))
                put(mapping, "certification_status", row_value(row, "CERTIFICATION_STATUS", 9))
                binding.mapping = mapping
            end
            representation.identity_binding = binding
        end
    end

    for _, row in ipairs(attribute_binding_rows(query_fn, model, entity_name) or {}) do
        local entity = entity_slot(document, row_value(row, "ENTITY_NAME", 1))
        entity.attribute_bindings = entity.attribute_bindings or {}
        local binding = {}
        put(binding, "attribute_type", row_value(row, "ATTRIBUTE_TYPE", 2))
        put(binding, "attribute_name", row_value(row, "ATTRIBUTE_NAME", 3))
        put(binding, "representation", row_value(row, "REPRESENTATION_NAME", 4))
        put(binding, "source_expression", row_value(row, "SOURCE_EXPRESSION", 5))
        put(binding, "binding_role", row_value(row, "BINDING_ROLE", 6))
        put_number(binding, "binding_priority", row_value(row, "BINDING_PRIORITY", 7))
        entity.attribute_bindings[#entity.attribute_bindings + 1] = binding
    end

    for _, row in ipairs(attribute_policy_rows(query_fn, model, entity_name) or {}) do
        local entity = entity_slot(document, row_value(row, "ENTITY_NAME", 1))
        entity.attribute_policies = entity.attribute_policies or {}
        local policy = {}
        put(policy, "attribute_type", row_value(row, "ATTRIBUTE_TYPE", 2))
        put(policy, "attribute_name", row_value(row, "ATTRIBUTE_NAME", 3))
        put(policy, "strategy", row_value(row, "FUSION_STRATEGY", 4))
        entity.attribute_policies[#entity.attribute_policies + 1] = policy
    end

    local fused = {}
    local order = {}
    for _, name in ipairs(document.entity_order) do
        local entity = document.entities[name]
        if is_fused(entity) then
            fused[name] = entity
            order[#order + 1] = name
        end
    end
    return {model = document.model, entities = fused, entity_order = order}
end

-- Assembled here rather than handed to encode_json whole, for two reasons the
-- round trip depends on.
--
-- `entities` must be a JSON *object* even when empty: an empty Lua table
-- serialises as `[]`, so a consumer would have to handle two types for the same
-- field. And `model` must always be present -- SEMANTIC_FUSION_015 refuses a
-- document applied to the wrong model by reading that key, and the first version
-- of this export emitted it only when there was no fusion, so the guard could
-- never fire on an exported-then-reapplied file: exactly the workflow it exists
-- for.
local function document_json(model_name, entities, order)
    local parts = {}
    for _, name in ipairs(order) do
        parts[#parts + 1] = json.encode(name) .. ":"
            .. json.encode(entities[name])
    end
    return '{"entities":{' .. table.concat(parts, ",") .. '},"model":'
        .. json.encode(model_name) .. "}"
end

-- One row, always: the whole tier-2 layer of the model as one document, which is
-- what the docs promise and what makes it re-appliable without a client-side
-- merge. Asking for a single entity returns that entity's slice, still as a
-- complete document.
function M.export_fusion_declaration(model_name, entity_name)
    local document = M.build_document(query, model_name, entity_name)
    local representation_count = 0
    for _, name in ipairs(document.entity_order) do
        representation_count = representation_count
            + #document.entities[name].representations
    end
    local scope_kind = "MODEL"
    local scope_name = document.model
    if not missing(entity_name) then
        scope_kind = "ENTITY"
        scope_name = trim(entity_name)
    end
    return {{scope_kind, scope_name, representation_count,
        document_json(document.model, document.entities, document.entity_order)}}
end

function M.export_document_json(model_name, entity_name)
    local document = M.build_document(query, model_name, entity_name)
    return document_json(document.model, document.entities, document.entity_order)
end


-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------

-- Closed contracts. An unknown key is refused by name rather than ignored,
-- because a silently-dropped `authority` is a governance change nobody sees.
local ENTITY_KEYS = {identity = true, representations = true,
    attribute_bindings = true, attribute_policies = true}
local REPRESENTATION_KEYS = {name = true, role = true, source_kind = true,
    source_schema = true, source_object = true, source_alias = true,
    priority = true, freshness_policy = true, authority = true,
    coverage = true, identity_binding = true, attribute_bindings = true}
local IDENTITY_KEYS = {name = true, kind = true, data_type = true,
    description = true}
local BINDING_KEYS = {source_expression = true, binding_kind = true,
    mapping = true}
local MAPPING_KEYS = {source_schema = true, source_object = true,
    source_local_column = true, semantic_key_column = true,
    certification_status = true}
local ATTRIBUTE_BINDING_KEYS = {attribute_type = true, attribute_name = true,
    representation = true, source_expression = true, binding_role = true,
    binding_priority = true}
-- Inside a representation the enclosing object *is* the representation, so
-- naming it again would be a second place to get it wrong.
local REPRESENTATION_BINDING_KEYS = {attribute_type = true, attribute_name = true,
    source_expression = true, binding_role = true, binding_priority = true}
local ATTRIBUTE_POLICY_KEYS = {attribute_type = true, attribute_name = true,
    strategy = true}

local function reject_unknown(table_value, allowed, label)
    -- The decoded null is a table, so `type` alone would let an explicit
    -- `"identity": null` through as an empty object -- a declaration silently
    -- read as "declare nothing" instead of being named as malformed.
    if type(table_value) ~= "table" or table_value == json.NULL then
        error("SEMANTIC_FUSION_010: " .. label .. " must be a JSON object")
    end
    if table_value[1] ~= nil then
        error("SEMANTIC_FUSION_010: " .. label .. " must be a JSON object, not an array")
    end
    local unknown = {}
    for key, _ in pairs(table_value) do
        if not allowed[tostring(key)] then unknown[#unknown + 1] = tostring(key) end
    end
    if #unknown > 0 then
        table.sort(unknown)
        local names = {}
        for name, _ in pairs(allowed) do names[#names + 1] = name end
        table.sort(names)
        error("SEMANTIC_FUSION_011: unknown " .. label .. " key(s): "
            .. table.concat(unknown, ", ") .. ". Allowed: "
            .. table.concat(names, ", ") .. ".")
    end
end

local function required(value, label)
    if missing(value) then
        error("SEMANTIC_FUSION_012: " .. label .. " is required")
    end
    return trim(value)
end

-- The seven tables the fusion layer lives in, parent to child. A partial
-- sequence has to be undoable, and the dispatched scripts each unwind only
-- themselves. Column lists come from the catalog, not from here -- see
-- shared/catalog_rollback.lua.
local MODEL_SCOPE = "MODEL_ID = :model_id AND VERSION_ID = :version_id"
local SNAPSHOT_TABLES = {
    {name = "ENTITY_REPRESENTATIONS", where = MODEL_SCOPE},
    {name = "REPRESENTATION_AUTHORITIES", where = MODEL_SCOPE},
    {name = "SEMANTIC_IDENTITIES", where = MODEL_SCOPE},
    {name = "IDENTITY_BINDINGS", where = MODEL_SCOPE},
    {name = "IDENTITY_MAPPING_RELATIONS", where = MODEL_SCOPE},
    {name = "ATTRIBUTE_BINDINGS", where = MODEL_SCOPE},
    {name = "ATTRIBUTE_FUSION_POLICIES", where = MODEL_SCOPE},
}

local function model_scope(model)
    return {model_id = model.model_id, version_id = model.version_id}
end

local function snapshot_fusion_state(query_fn, model)
    return rollback.snapshot(query_fn, SNAPSHOT_TABLES, model_scope(model),
        "SEMANTIC_FUSION_013")
end

local function restore_fusion_state(query_fn, model, snapshot)
    rollback.restore(query_fn, SNAPSHOT_TABLES, snapshot, model_scope(model))
    -- The dispatched scripts each clear the compile cache when they mutate, but
    -- this restore writes SYS_SEMANTIC directly -- so entries compiled during
    -- the attempt being abandoned would otherwise survive it and answer from a
    -- plan built against fusion metadata that no longer exists.
    query_fn([[
        DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
        WHERE MODEL_VERSION_ID IN (
          SELECT VERSION_ID FROM SYS_SEMANTIC.MODEL_VERSIONS
          WHERE MODEL_ID = :model_id
        )
    ]], {model_id = model.model_id})
end

local function call_script(query_fn, statement, params)
    query_fn("EXECUTE SCRIPT SEMANTIC_ADMIN." .. statement, params or {})
end

local function existing_representations(query_fn, model, entity_name)
    local rows = query_fn([[
        SELECT r.REPRESENTATION_NAME
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
        JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = r.ENTITY_ID
        WHERE r.MODEL_ID = :model_id AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE' AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
    local present = {}
    for _, row in ipairs(rows or {}) do
        present[upper(row_value(row, "REPRESENTATION_NAME", 1))] = true
    end
    return present
end

local function attribute_binding_present(query_fn, model, attribute_type,
        attribute_name, representation_name)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON b.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = b.ATTRIBUTE_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON b.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = b.ATTRIBUTE_ID
        WHERE b.MODEL_ID = :model_id AND b.VERSION_ID = :version_id
          AND b.STATUS = 'ACTIVE'
          AND UPPER(b.ATTRIBUTE_TYPE) = UPPER(:attribute_type)
          AND UPPER(COALESCE(d.DIMENSION_NAME, f.FACT_NAME)) = UPPER(:attribute_name)
          AND UPPER(r.REPRESENTATION_NAME) = UPPER(:representation_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        attribute_type = attribute_type, attribute_name = attribute_name,
        representation_name = representation_name})
    return rows ~= nil and #rows > 0
end

local function identity_binding_present(query_fn, model, entity_name, representation_name)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.IDENTITY_BINDINGS b
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = b.ENTITY_ID
        WHERE b.MODEL_ID = :model_id AND b.VERSION_ID = :version_id
          AND b.STATUS = 'ACTIVE'
          AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
          AND UPPER(r.REPRESENTATION_NAME) = UPPER(:representation_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name, representation_name = representation_name})
    return rows ~= nil and #rows > 0
end

local function mapping_relation_present(query_fn, model, entity_name, representation_name)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS m
        JOIN SYS_SEMANTIC.IDENTITY_BINDINGS b
          ON b.IDENTITY_BINDING_ID = m.IDENTITY_BINDING_ID
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = b.ENTITY_ID
        WHERE m.MODEL_ID = :model_id AND m.VERSION_ID = :version_id
          AND m.STATUS = 'ACTIVE' AND b.STATUS = 'ACTIVE'
          AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
          AND UPPER(r.REPRESENTATION_NAME) = UPPER(:representation_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name, representation_name = representation_name})
    return rows ~= nil and #rows > 0
end

local function authority_matches(query_fn, model, entity_name, representation_name, role)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES a
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = a.REPRESENTATION_ID
        JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = a.ENTITY_ID
        WHERE a.MODEL_ID = :model_id AND a.VERSION_ID = :version_id
          AND a.STATUS = 'ACTIVE'
          AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
          AND UPPER(r.REPRESENTATION_NAME) = UPPER(:representation_name)
          AND UPPER(a.AUTHORITY_ROLE) = UPPER(:role)
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name, representation_name = representation_name,
        role = role})
    return rows ~= nil and #rows > 0
end

local function attribute_binding_matches(query_fn, model, attribute_type,
        attribute_name, representation_name, source_expression)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r
          ON r.REPRESENTATION_ID = b.REPRESENTATION_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON b.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = b.ATTRIBUTE_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON b.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = b.ATTRIBUTE_ID
        WHERE b.MODEL_ID = :model_id AND b.VERSION_ID = :version_id
          AND b.STATUS = 'ACTIVE'
          AND UPPER(b.ATTRIBUTE_TYPE) = UPPER(:attribute_type)
          AND UPPER(COALESCE(d.DIMENSION_NAME, f.FACT_NAME)) = UPPER(:attribute_name)
          AND UPPER(r.REPRESENTATION_NAME) = UPPER(:representation_name)
          AND b.SOURCE_EXPRESSION = :source_expression
    ]], {model_id = model.model_id, version_id = model.version_id,
        attribute_type = attribute_type, attribute_name = attribute_name,
        representation_name = representation_name,
        source_expression = source_expression})
    return rows ~= nil and #rows > 0
end

local function attribute_policy_matches(query_fn, model, attribute_type,
        attribute_name, strategy)
    local rows = query_fn([[
        SELECT 1
        FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES p
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON p.ATTRIBUTE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = p.ATTRIBUTE_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON p.ATTRIBUTE_TYPE = 'FACT' AND f.FACT_ID = p.ATTRIBUTE_ID
        WHERE p.MODEL_ID = :model_id AND p.VERSION_ID = :version_id
          AND p.STATUS = 'ACTIVE'
          AND UPPER(p.ATTRIBUTE_TYPE) = UPPER(:attribute_type)
          AND UPPER(COALESCE(d.DIMENSION_NAME, f.FACT_NAME)) = UPPER(:attribute_name)
          AND UPPER(p.FUSION_STRATEGY) = UPPER(:strategy)
    ]], {model_id = model.model_id, version_id = model.version_id,
        attribute_type = attribute_type, attribute_name = attribute_name,
        strategy = strategy})
    return rows ~= nil and #rows > 0
end

local function entity_exists(query_fn, model, entity_name)
    local rows = query_fn([[
        SELECT 1 FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE' AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_name = entity_name})
    return rows ~= nil and #rows > 0
end

local function identity_exists(query_fn, model, identity_name)
    local rows = query_fn([[
        SELECT 1 FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE' AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
    ]], {model_id = model.model_id, version_id = model.version_id,
        identity_name = identity_name})
    return rows ~= nil and #rows > 0
end

-- Turn one entity's declaration into an ordered operation list.
--
-- Order is not a style choice. The identity has to exist before a
-- representation can bind to it; a representation has to exist before an
-- attribute binds to it or a policy names its attribute; and on a published
-- model each operation is validated on its own, so every step has to leave the
-- model valid. That is why each representation arrives through
-- ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS carrying everything it needs at
-- once, rather than as four calls that are each individually refused.
local function plan_entity(query_fn, model, entity_name, entity)
    reject_unknown(entity, ENTITY_KEYS, "entity '" .. entity_name .. "'")
    local operations = {}

    local identity_name = nil
    if entity.identity ~= nil then
        local identity = entity.identity
        reject_unknown(identity, IDENTITY_KEYS,
            "entity '" .. entity_name .. "' identity")
        identity_name = required(identity.name, "identity.name")
        if not identity_exists(query_fn, model, identity_name) then
            operations[#operations + 1] = {
                label = "ADD_SEMANTIC_IDENTITY " .. identity_name,
                statement = "ADD_SEMANTIC_IDENTITY(:model_name, :entity_name,"
                    .. " :identity_name, :identity_kind, :data_type, :description)",
                params = {model_name = model.model_name, entity_name = entity_name,
                    identity_name = identity_name,
                    identity_kind = upper(identity.kind) ~= "" and upper(identity.kind) or "GLOBAL",
                    data_type = required(identity.data_type, "identity.data_type"),
                    description = trim(identity.description)},
            }
        end
    end

    local present = existing_representations(query_fn, model, entity_name)
    local declared_primary = nil
    for _, representation in ipairs(entity.representations or {}) do
        reject_unknown(representation, REPRESENTATION_KEYS,
            "entity '" .. entity_name .. "' representation")
        local name = required(representation.name, "representation.name")
        if upper(representation.role) == "PRIMARY" then
            declared_primary = name
        end

        local declarations = {}
        if not missing(representation.authority) then
            declarations.authority = upper(representation.authority)
        end
        if representation.coverage ~= nil then
            local coverage = representation.coverage
            declarations.coverage = {{
                valid_from = trim(coverage.valid_from) ~= "" and trim(coverage.valid_from) or nil,
                valid_to = trim(coverage.valid_to) ~= "" and trim(coverage.valid_to) or nil,
                coverage_predicate = trim(coverage.predicate) ~= "" and trim(coverage.predicate) or nil,
            }}
        end
        -- Bindings declared on the representation travel with it into the one
        -- call that registers it, because a supplemental source narrower than
        -- the primary is invalid until they land -- and on a published model
        -- there is no later.
        if representation.attribute_bindings ~= nil then
            if type(representation.attribute_bindings) ~= "table"
                or #representation.attribute_bindings == 0 then
                error("SEMANTIC_FUSION_017: representation '" .. name
                    .. "' attribute_bindings must be a non-empty array")
            end
            for _, binding in ipairs(representation.attribute_bindings) do
                reject_unknown(binding, REPRESENTATION_BINDING_KEYS,
                    "entity '" .. entity_name .. "' representation '" .. name
                    .. "' attribute binding")
            end
            declarations.attribute_bindings = representation.attribute_bindings
        end
        if representation.identity_binding ~= nil then
            local binding = representation.identity_binding
            reject_unknown(binding, BINDING_KEYS,
                "entity '" .. entity_name .. "' identity_binding")
            if identity_name == nil then
                error("SEMANTIC_FUSION_014: representation '" .. name
                    .. "' declares an identity_binding but entity '" .. entity_name
                    .. "' declares no identity")
            end
            local identity_declaration = {
                identity_name = identity_name,
                source_expression = required(binding.source_expression,
                    "identity_binding.source_expression"),
                binding_kind = upper(binding.binding_kind) ~= "" and upper(binding.binding_kind) or "DIRECT",
            }
            if binding.mapping ~= nil then
                reject_unknown(binding.mapping, MAPPING_KEYS,
                    "entity '" .. entity_name .. "' identity_binding mapping")
                identity_declaration.mapping = binding.mapping
            end
            declarations.identity = identity_declaration
        end

        if present[upper(name)] then
            -- The primary is created by ADD_ENTITY, so it is normally already
            -- here. Its authority and identity binding still have to be
            -- declared, and those have their own idempotent scripts.
            if declarations.authority ~= nil then
                local wanted_authority = declarations.authority
                operations[#operations + 1] = {
                    label = "SET_REPRESENTATION_AUTHORITY " .. name,
                    statement = "SET_REPRESENTATION_AUTHORITY(:model_name,"
                        .. " :entity_name, :representation_name, :authority_role)",
                    params = {model_name = model.model_name, entity_name = entity_name,
                        representation_name = name,
                        authority_role = wanted_authority},
                    skip_fn = function(runtime_query, runtime_model)
                        return authority_matches(runtime_query, runtime_model,
                            entity_name, name, wanted_authority)
                    end,
                }
            end
            if declarations.identity ~= nil then
                operations[#operations + 1] = {
                    label = "ADD_IDENTITY_BINDING " .. name,
                    statement = "ADD_IDENTITY_BINDING(:model_name, :identity_name,"
                        .. " :representation_name, :source_expression, :binding_kind)",
                    params = {model_name = model.model_name,
                        identity_name = identity_name,
                        representation_name = name,
                        source_expression = declarations.identity.source_expression,
                        binding_kind = declarations.identity.binding_kind},
                    skip_fn = function(runtime_query, runtime_model)
                        return identity_binding_present(runtime_query, runtime_model,
                            entity_name, name)
                    end,
                }
                if declarations.identity.mapping ~= nil then
                    local mapping = declarations.identity.mapping
                    operations[#operations + 1] = {
                        label = "ADD_IDENTITY_MAPPING_RELATION " .. name,
                        statement = "ADD_IDENTITY_MAPPING_RELATION(:model_name,"
                            .. " :identity_name, :representation_name, :source_schema,"
                            .. " :source_object, :source_local_column,"
                            .. " :semantic_key_column, :certification_status)",
                        params = {model_name = model.model_name,
                            identity_name = identity_name,
                            representation_name = name,
                            source_schema = required(mapping.source_schema, "mapping.source_schema"),
                            source_object = required(mapping.source_object, "mapping.source_object"),
                            source_local_column = required(mapping.source_local_column,
                                "mapping.source_local_column"),
                            semantic_key_column = required(mapping.semantic_key_column,
                                "mapping.semantic_key_column"),
                            certification_status = upper(mapping.certification_status) ~= ""
                                and upper(mapping.certification_status) or "CERTIFIED"},
                        skip_fn = function(runtime_query, runtime_model)
                            return mapping_relation_present(runtime_query, runtime_model,
                                entity_name, name)
                        end,
                    }
                end
            end
        else
            operations[#operations + 1] = {
                label = "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS " .. name,
                statement = "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS(:model_name,"
                    .. " :entity_name, :representation_name, :source_kind,"
                    .. " :source_schema, :source_object, :priority,"
                    .. " :freshness_policy, :declarations_json)",
                params = {model_name = model.model_name, entity_name = entity_name,
                    representation_name = name,
                    source_kind = upper(representation.source_kind) ~= ""
                        and upper(representation.source_kind) or "RELATION",
                    source_schema = required(representation.source_schema,
                        "representation.source_schema"),
                    source_object = required(representation.source_object,
                        "representation.source_object"),
                    priority = tonumber(tostring(representation.priority or 10)) or 10,
                    freshness_policy = trim(representation.freshness_policy) ~= ""
                        and trim(representation.freshness_policy) or "MANUAL",
                    declarations_json = json.encode(declarations)},
            }
        end
    end

    for _, binding in ipairs(entity.attribute_bindings or {}) do
        reject_unknown(binding, ATTRIBUTE_BINDING_KEYS,
            "entity '" .. entity_name .. "' attribute binding")
        -- ADD_ or REPLACE_ has to be decided when the operation *runs*, not when
        -- it is planned. The compound representation forms seed a binding for
        -- every attribute of the entity, so a document that creates a
        -- representation and then declares a binding on it is replacing a row
        -- that did not exist at plan time. ADD_ATTRIBUTE_BINDING refuses a
        -- duplicate with SEMANTIC_ADMIN_024, and that refusal is right -- which
        -- is why the choice is deferred rather than the error swallowed.
        local want_type = upper(required(binding.attribute_type, "attribute_type"))
        local want_name = required(binding.attribute_name, "attribute_name")
        local want_rep = required(binding.representation, "representation")
        local want_expr = required(binding.source_expression, "source_expression")
        operations[#operations + 1] = {
            label = "attribute binding " .. want_name .. " -> " .. want_rep,
            skip_fn = function(runtime_query, runtime_model)
                return attribute_binding_matches(runtime_query, runtime_model,
                    want_type, want_name, want_rep, want_expr)
            end,
            statement_fn = function(runtime_query, runtime_model, params)
                local verb = "ADD_ATTRIBUTE_BINDING"
                if attribute_binding_present(runtime_query, runtime_model,
                        params.attribute_type, params.attribute_name,
                        params.representation_name) then
                    verb = "REPLACE_ATTRIBUTE_BINDING"
                end
                return verb .. "(:model_name, :attribute_type,"
                    .. " :attribute_name, :representation_name, :source_expression,"
                    .. " :binding_role, :binding_priority)"
            end,
            params = {model_name = model.model_name,
                attribute_type = upper(required(binding.attribute_type, "attribute_type")),
                attribute_name = required(binding.attribute_name, "attribute_name"),
                representation_name = required(binding.representation, "representation"),
                source_expression = required(binding.source_expression, "source_expression"),
                binding_role = upper(binding.binding_role) ~= "" and upper(binding.binding_role) or "PREFER",
                binding_priority = tonumber(tostring(binding.binding_priority or 1)) or 1},
        }
    end

    for _, policy in ipairs(entity.attribute_policies or {}) do
        reject_unknown(policy, ATTRIBUTE_POLICY_KEYS,
            "entity '" .. entity_name .. "' attribute policy")
        local policy_type = upper(required(policy.attribute_type, "attribute_type"))
        local policy_attribute = required(policy.attribute_name, "attribute_name")
        local policy_strategy = upper(required(policy.strategy, "strategy"))
        operations[#operations + 1] = {
            label = "SET_ATTRIBUTE_FUSION_POLICY " .. policy_attribute,
            statement = "SET_ATTRIBUTE_FUSION_POLICY(:model_name, :attribute_type,"
                .. " :attribute_name, :fusion_strategy)",
            params = {model_name = model.model_name, attribute_type = policy_type,
                attribute_name = policy_attribute,
                fusion_strategy = policy_strategy},
            -- Without this the policy was re-executed unconditionally, so an
            -- exported document never converged: five of six operations reported
            -- "already matches" and this one kept APPLIED_COUNT at 1 forever,
            -- which turns a CI check for "no drift" into a permanent false
            -- positive.
            skip_fn = function(runtime_query, runtime_model)
                return attribute_policy_matches(runtime_query, runtime_model,
                    policy_type, policy_attribute, policy_strategy)
            end,
        }
    end

    -- Last: promoting a different representation to PRIMARY is only valid once
    -- every representation it will answer beside exists.
    if declared_primary ~= nil and not present[upper(declared_primary)] then
        operations[#operations + 1] = {
            label = "SET_PRIMARY_REPRESENTATION " .. declared_primary,
            statement = "SET_PRIMARY_REPRESENTATION(:model_name, :entity_name,"
                .. " :representation_name)",
            params = {model_name = model.model_name, entity_name = entity_name,
                representation_name = declared_primary},
        }
    end
    return operations
end

function M.plan_document(query_fn, model_name, declaration_json)
    local declaration_text = required(declaration_json, "DECLARATION_JSON")
    local decoded_ok, document = pcall(json.decode,
        declaration_text)
    if not decoded_ok or type(document) ~= "table" then
        error("SEMANTIC_FUSION_010: DECLARATION_JSON must be a JSON object with"
            .. " an 'entities' key")
    end
    reject_unknown(document, {model = true, entities = true}, "document")
    if document.entities == nil then
        required(nil, "document.entities")
    end
    if type(document.entities) ~= "table" then
        error("SEMANTIC_FUSION_016: document.entities must be a JSON object keyed"
            .. " by entity name")
    end
    if not missing(document.model)
        and upper(document.model) ~= upper(model_name) then
        error("SEMANTIC_FUSION_015: document declares model '"
            .. trim(document.model) .. "' but was applied to '"
            .. trim(model_name) .. "'")
    end

    local model = load_model(query_fn, model_name)
    local names = {}
    for entity_name, _ in pairs(document.entities) do
        names[#names + 1] = tostring(entity_name)
    end
    table.sort(names)
    local unknown = {}
    for _, entity_name in ipairs(names) do
        if not entity_exists(query_fn, model, entity_name) then
            unknown[#unknown + 1] = entity_name
        end
    end
    if #unknown > 0 then
        error("SEMANTIC_FUSION_018: document names entit"
            .. (#unknown == 1 and "y" or "ies") .. " that model '"
            .. tostring(model.model_name) .. "' does not have: "
            .. table.concat(unknown, ", ")
            .. ". Fusion declares how existing entities compose; create the"
            .. " entity first with ADD_ENTITY.")
    end
    local operations = {}
    for _, entity_name in ipairs(names) do
        for _, operation in ipairs(
            plan_entity(query_fn, model, entity_name, document.entities[entity_name])) do
            operations[#operations + 1] = operation
        end
    end
    return model, operations
end

-- Upsert, not reconciliation: the document declares what it contains and leaves
-- alone what it omits. Removing a representation or an identity stays with the
-- REMOVE_* scripts, because deleting governance metadata on the strength of an
-- absent JSON key is not a mistake worth making convenient. Re-applying an
-- exported document is therefore a no-op, which is what makes it safe to keep in
-- source control and re-run.
function M.apply_fusion_declaration(model_name, declaration_json, dry_run)
    local wants_dry_run = dry_run == true or upper(dry_run) == "TRUE"

    -- Parsing refusals come back in STATUS, not as a raise, so a caller checks
    -- one column for every kind of failure. APPLY_SEMANTIC_DEFINITION behaves
    -- the same way, and splitting the two would mean callers who check the
    -- column still miss the malformed-document case.
    local plan_ok, plan = pcall(function()
        local planned_model, planned_operations =
            M.plan_document(query, model_name, declaration_json)
        return {model = planned_model, operations = planned_operations}
    end)
    if not plan_ok then
        local message = tostring(plan)
        return {{"ERROR",
            string.match(message, "(SEMANTIC_[A-Z_]+_%d+)") or "SEMANTIC_FUSION_090",
            message, 0, 0}}
    end
    local model, operations = plan.model, plan.operations

    local applied = {}
    local snapshot = snapshot_fusion_state(query, model)
    local ok, failure = pcall(function()
        for _, operation in ipairs(operations) do
            -- Evaluated here, not at plan time: an operation earlier in the same
            -- document may be what makes this one unnecessary.
            local skip = false
            if operation.skip_fn ~= nil then
                skip = operation.skip_fn(query, model) == true
            end
            if not skip then
                local statement = operation.statement
                if operation.statement_fn ~= nil then
                    statement = operation.statement_fn(query, model, operation.params)
                end
                call_script(query, statement, operation.params)
                applied[#applied + 1] = operation.label
            end
        end
    end)

    if not ok then
        restore_fusion_state(query, model, snapshot)
        local message = tostring(failure)
        local code = string.match(message, "(SEMANTIC_[A-Z_]+_%d+)")
        return {{"ERROR", code or "SEMANTIC_FUSION_090", message,
            #operations, #applied}}
    end

    local validation = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model.model_name}) or {}
    local blocking = {}
    for _, row in ipairs(validation) do
        local severity = upper(row_value(row, "SEVERITY", 1))
        if severity == "ERROR" or severity == "PRECONDITION" then
            blocking[#blocking + 1] = tostring(row_value(row, "RULE_CODE", 4))
                .. " [" .. tostring(row_value(row, "OBJECT_NAME", 3)) .. "]: "
                .. tostring(row_value(row, "MESSAGE", 5))
        end
    end

    if #blocking > 0 then
        restore_fusion_state(query, model, snapshot)
        return {{"ERROR", "SEMANTIC_FUSION_091",
            "Fusion declaration rejected; validation failed: "
            .. table.concat(blocking, "; ") .. ". Catalog state was restored.",
            #operations, #applied}}
    end

    if wants_dry_run then
        restore_fusion_state(query, model, snapshot)
        return {{"DRY_RUN", null,
            "Dry-run applied and validated " .. tostring(#applied)
            .. " operation(s); no catalog changes were committed.",
            #operations, #applied}}
    end

    return {{"OK", null, "Fusion declaration applied: "
        .. (#applied == 0 and "nothing to do, the catalog already matches."
            or table.concat(applied, "; ") .. "."),
        #operations, #applied}}
end

-- Published as globals, because Exasol's `import(script, alias)` exposes the
-- imported script's globals under the alias -- there is no returned table, and a
-- top-level `return` would end the concatenated chunk.
export_fusion_declaration = M.export_fusion_declaration
export_document_json = M.export_document_json
apply_fusion_declaration = M.apply_fusion_declaration

ESV_FUSION_DECLARATION = M

if rawget(_G, "ESV_TEST_MODE") then
    ESV_FUSION_DECLARATION_TEST_API = {
        build_document = M.build_document,
        plan_document = M.plan_document,
        reject_unknown = reject_unknown,
        snapshot_fusion_state = snapshot_fusion_state,
        restore_fusion_state = restore_fusion_state,
        is_fused = is_fused,
    }
end
