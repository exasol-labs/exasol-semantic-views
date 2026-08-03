-- Detached model-versioned catalog input for the typed planner.

local M = {VERSION = 1}

local function key(value) return tostring(value) end

local function clone(value, seen)
    if value == null then return null end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for child_key, child in pairs(value) do
        if string.sub(tostring(child_key), 1, 1) ~= "_" then
            out[child_key] = clone(child, seen)
        end
    end
    return out
end

local function index_by(values, field)
    local out = {}
    for _, value in ipairs(values or {}) do out[key(value[field])] = value end
    return out
end

local function collect_transitive(metric_by_id, metric_ids)
    local selected = {}
    local ordered = {}
    local function visit(metric_id)
        local metric_key = key(metric_id)
        if selected[metric_key] then return end
        local metric = metric_by_id[metric_key]
        if metric == nil then return end
        selected[metric_key] = true
        for _, input in ipairs(metric.inputs or {}) do
            if string.upper(tostring(input.object_type or "")) == "METRIC" then
                visit(input.object_id)
            end
        end
        for _, dependency in ipairs(metric.dependencies or {}) do
            if string.upper(tostring(dependency.object_type or "")) == "METRIC" then
                visit(dependency.object_id)
            end
        end
        ordered[#ordered + 1] = metric
    end
    for _, metric_id in ipairs(metric_ids or {}) do visit(metric_id) end
    return ordered
end

function M.from_context(ctx, selected_metrics)
    local all_metrics = ctx.all_metrics or ctx.metrics or {}
    local all_metric_by_id = ctx.all_metric_by_id or index_by(all_metrics, "id")
    local requested_ids = {}
    for _, metric in ipairs(selected_metrics or {}) do requested_ids[#requested_ids + 1] = metric.id end
    local snapshot = {
        catalog_snapshot_version = M.VERSION,
        model_id = ctx.model and ctx.model.model_id,
        version_id = ctx.model and ctx.model.version_id,
        version_number = ctx.model and ctx.model.version_number,
        object = clone(ctx.object),
        entities = clone(ctx.entities or {}),
        dimensions = clone(ctx.dimensions or {}),
        visible_metrics = clone(ctx.metrics or {}),
        metrics = clone(collect_transitive(all_metric_by_id, requested_ids)),
        facts = clone(ctx.facts or {}),
        relationships = clone(ctx.relationships or {}),
        unique_keys = clone(ctx.unique_keys or {}),
    }
    snapshot.entity_by_id = index_by(snapshot.entities, "id")
    snapshot.dimension_by_id = index_by(snapshot.dimensions, "id")
    snapshot.metric_by_id = index_by(snapshot.metrics, "id")
    snapshot.fact_by_id = index_by(snapshot.facts, "id")
    snapshot.relationship_by_id = index_by(snapshot.relationships, "id")
    snapshot.unique_keys_by_entity = {}
    for _, unique_key in ipairs(snapshot.unique_keys) do
        local entity_key = key(unique_key.entity_id)
        snapshot.unique_keys_by_entity[entity_key] =
            snapshot.unique_keys_by_entity[entity_key] or {}
        snapshot.unique_keys_by_entity[entity_key][#snapshot.unique_keys_by_entity[entity_key] + 1] =
            unique_key
    end
    snapshot.detached = true
    snapshot.immutable = true
    return snapshot
end

function M.copy(snapshot)
    return clone(snapshot)
end

ESV_CATALOG_SNAPSHOT = M
