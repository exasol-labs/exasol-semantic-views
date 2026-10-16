-- Take a semantic view out of a model.
--
-- Until this existed there was no way to. ADD_SEMANTIC_OBJECT had no counterpart,
-- the DDL edits the *interior* of an object and cannot remove the object itself,
-- and no apply path reconciles a model by deleting one. The only remedy was
-- DROP_MODEL, which takes the entities, relationships, published views, grants,
-- materializations and frozen-view records with it.
--
-- That mattered because a stray object is not inert: PUBLISH_MODEL refuses an
-- object with no visible columns (SEMANTIC_SURFACE_014), so a single mistyped
-- ADD_SEMANTIC_OBJECT left a model that could not be published and could not be
-- repaired. Filling the object in instead is not a way out either -- its
-- dimensions would need new names, because names are unique per model
-- (SEMANTIC_ADMIN_019), so the typo would be permanent in a different way.
--
-- What it removes: the object, the dimensions and metrics it exposes, and the
-- rows that hang off those. What it keeps: facts and entities. A fact is
-- declared on an *entity*, not on an object, and may feed metrics in other
-- objects; an entity is the model's graph. Removing either because one view was
-- deleted would be a surprise, and both have their own operations.
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

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")

local models = query([[
    SELECT MODEL_ID, ACTIVE_VERSION_ID, PUBLISHED_SCHEMA
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if models == nil or #models == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = models[1][1]
local version_id = models[1][2]
local published_schema = models[1][3]

local objects = query([[
    SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(OBJECT_NAME) = UPPER(:object_name)
]], {model_id = model_id, version_id = version_id, object_name = object_name})
if objects == nil or #objects == 0 then
    error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
end
local object_id = objects[1][1]

-- The columns this view exposes, split by kind. Facts appear here too and are
-- deliberately left alone.
local metric_ids, dimension_ids = {}, {}
for _, row in ipairs(query([[
    SELECT COLUMN_KIND, OBJECT_REF_ID
    FROM SYS_SEMANTIC.OBJECT_COLUMNS
    WHERE OBJECT_ID = :object_id
]], {object_id = object_id}) or {}) do
    local kind = string.upper(tostring(row[1]))
    if kind == "METRIC" then
        metric_ids[#metric_ids + 1] = row[2]
    elseif kind == "DIMENSION" then
        dimension_ids[#dimension_ids + 1] = row[2]
    end
end

local function id_list(ids)
    local parts = {}
    for index, id in ipairs(ids) do parts[index] = tostring(id) end
    return table.concat(parts, ", ")
end

-- Refused rather than cascaded: a metric of another view built on one of these
-- would be left referring to a metric that no longer exists, and the author
-- would find out at the next validation rather than here.
--
-- Read from METRIC_DEPENDENCIES, which VALIDATE_MODEL derives, and not from
-- METRIC_INPUTS -- that table records the inputs an admin call declared, and a
-- metric whose *expression* names another metric leaves no row in it at all. The
-- consequence of the derivation is that this answer is as fresh as the last
-- validation: a dependency added since then is not seen here, and the next
-- VALIDATE_MODEL reports the broken metric instead. That is the same bargain the
-- compiler makes when it binds to the latest successful run.
if #metric_ids > 0 then
    local borrowed = query([[
        SELECT DISTINCT other.METRIC_NAME, so.OBJECT_NAME
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md
        JOIN SYS_SEMANTIC.METRICS other
          ON other.METRIC_ID = md.METRIC_ID
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc
          ON oc.COLUMN_KIND = 'METRIC' AND oc.OBJECT_REF_ID = other.METRIC_ID
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        WHERE md.DEPENDS_ON_OBJECT_TYPE = 'METRIC'
          AND md.DEPENDS_ON_OBJECT_ID IN (]] .. id_list(metric_ids) .. [[)
          AND oc.OBJECT_ID <> :object_id
    ]], {object_id = object_id})
    if borrowed ~= nil and #borrowed > 0 then
        local names = {}
        for _, row in ipairs(borrowed) do
            names[#names + 1] = tostring(row[2]) .. "." .. tostring(row[1])
        end
        -- Its own code: SEMANTIC_ADMIN_021 already means "attribute not found"
        -- and "duplicate metric", and a third meaning would make it useless for
        -- telling them apart.
        error("SEMANTIC_ADMIN_099: semantic object " .. object_name
            .. " cannot be removed: " .. table.concat(names, ", ")
            .. " depend(s) on a metric it exposes. Remove or rewrite those first.")
    end
end

local function purge(sql, params)
    query(sql, params or {})
end

if #metric_ids > 0 then
    local ids = id_list(metric_ids)
    purge("DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID IN (" .. ids .. ")")
    -- Both directions: rows this metric owns, and rows that point at it.
    purge("DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES WHERE METRIC_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES"
        .. " WHERE DEPENDS_ON_OBJECT_TYPE = 'METRIC' AND DEPENDS_ON_OBJECT_ID IN ("
        .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX WHERE METRIC_ID IN ("
        .. ids .. ")")
    -- Discriminated: OBJECT_ID means a metric only where OBJECT_TYPE says so, and
    -- a dimension elsewhere can share the number.
    purge("DELETE FROM SYS_SEMANTIC.SYNONYMS WHERE OBJECT_TYPE = 'METRIC'"
        .. " AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS"
        .. " WHERE OBJECT_TYPE = 'METRIC' AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS"
        .. " WHERE SCOPE_TYPE = 'METRIC' AND SCOPE_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS"
        .. " WHERE SCOPE_TYPE = 'METRIC' AND SCOPE_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.MODEL_EVOLUTION_SUGGESTIONS"
        .. " WHERE OBJECT_TYPE = 'METRIC' AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRICS WHERE METRIC_ID IN (" .. ids .. ")")
end

if #dimension_ids > 0 then
    local ids = id_list(dimension_ids)
    purge("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS"
        .. " WHERE ATTRIBUTE_TYPE = 'DIMENSION' AND ATTRIBUTE_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES"
        .. " WHERE ATTRIBUTE_TYPE = 'DIMENSION' AND ATTRIBUTE_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX WHERE DIMENSION_ID IN ("
        .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES"
        .. " WHERE DEPENDS_ON_OBJECT_TYPE = 'DIMENSION' AND DEPENDS_ON_OBJECT_ID IN ("
        .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.SYNONYMS WHERE OBJECT_TYPE = 'DIMENSION'"
        .. " AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS"
        .. " WHERE OBJECT_TYPE = 'DIMENSION' AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS"
        .. " WHERE SCOPE_TYPE = 'DIMENSION' AND SCOPE_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.MODEL_EVOLUTION_SUGGESTIONS"
        .. " WHERE OBJECT_TYPE = 'DIMENSION' AND OBJECT_ID IN (" .. ids .. ")")
    purge("DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE DIMENSION_ID IN (" .. ids .. ")")
end

-- Scoped to the object itself. SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS is the
-- list these came from: two of them reach the object through SCOPE_ID rather
-- than a column named for it, and grepping for OBJECT_ID would have missed both.
purge([[DELETE FROM SYS_SEMANTIC.VERIFIED_QUERIES WHERE OBJECT_ID = :object_id]],
    {object_id = object_id})
purge([[DELETE FROM SYS_SEMANTIC.MODEL_EVOLUTION_SUGGESTIONS
        WHERE OBJECT_TYPE = 'SEMANTIC_OBJECT' AND OBJECT_ID = :object_id]],
    {object_id = object_id})
purge([[DELETE FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS
        WHERE SCOPE_TYPE = 'SEMANTIC_OBJECT' AND SCOPE_ID = :object_id]],
    {object_id = object_id})
purge([[DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id]],
    {object_id = object_id})
purge([[DELETE FROM SYS_SEMANTIC.SEMANTIC_OBJECTS WHERE OBJECT_ID = :object_id]],
    {object_id = object_id})

-- The published view has to go with it. PUBLISH_MODEL only ever issues
-- CREATE OR REPLACE VIEW, so it would never notice the object was gone and the
-- view would keep answering from the SQL it was compiled with -- which is the
-- frozen-view hazard, arrived at by accident.
local dropped_view = false
if not missing(published_schema) then
    local present = query([[
        SELECT 1 FROM SYS.EXA_ALL_VIEWS
        WHERE UPPER(VIEW_SCHEMA) = UPPER(:schema_name)
          AND UPPER(VIEW_NAME) = UPPER(:object_name)
    ]], {schema_name = published_schema, object_name = object_name})
    if present ~= nil and #present > 0 then
        query("DROP VIEW " .. quote_ident(published_schema)
            .. "." .. quote_ident(object_name))
        dropped_view = true
    end
end

-- Statements compiled against this view must stop being served from the cache.
purge([[DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id]],
    {version_id = version_id})

exit({{model_name, object_name, #dimension_ids, #metric_ids, dropped_view,
       "Removed. Facts and entities are kept -- a fact belongs to an entity and"
       .. " may feed other views. Run VALIDATE_MODEL, then PUBLISH_MODEL."}}, [[
  MODEL_NAME VARCHAR(128),
  OBJECT_NAME VARCHAR(128),
  DIMENSIONS_REMOVED DECIMAL(18,0),
  METRICS_REMOVED DECIMAL(18,0),
  VIEW_DROPPED BOOLEAN,
  NEXT_STEP VARCHAR(512)
]])
