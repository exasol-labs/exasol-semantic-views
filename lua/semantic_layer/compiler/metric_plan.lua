-- Typed metric DAG and strict relationship proof boundary.

local M = {PLAN_VERSION = 2}
local graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")

local function key(value) return tostring(value) end
local function upper(value) return string.upper(tostring(value or "")) end
local function missing(value) return value == nil or value == null or tostring(value) == "" end

local function classification(metric)
    local kind = upper(metric.metric_kind or metric.metric_type)
    local aggregate = upper(metric.aggregation_function)
    local expression = upper(metric.expression)
    if not missing(metric.window_spec_json) or kind == "WINDOW" then
        return "UNSUPPORTED_WINDOW"
    end
    if not missing(metric.distinct_key_expr) or aggregate == "COUNT_DISTINCT"
        or string.find(expression, "DISTINCT", 1, true) then
        return "UNSUPPORTED_DISTINCT"
    end
    if not missing(metric.non_additive_dimension_id) then
        return "UNSUPPORTED_NON_ADDITIVE"
    end
    if aggregate == "SUM" or string.match(expression, "^%s*SUM%s*%(") then
        return (#(metric.filters or {}) > 0 or not missing(metric.filter_expr))
            and "FILTERED_SUM" or "SUM"
    end
    if aggregate == "COUNT" or string.match(expression, "^%s*COUNT%s*%(") then
        return (#(metric.filters or {}) > 0 or not missing(metric.filter_expr))
            and "FILTERED_COUNT" or "COUNT"
    end
    if kind == "RATIO" or string.find(expression, "/", 1, true) then return "RATIO" end
    if kind == "DERIVED" or kind == "CALCULATED" then return "DERIVED_ARITHMETIC" end
    return "LEGACY_AGGREGATE"
end

function M.build_dag(snapshot, selected_metrics)
    local nodes = {}
    local node_by_id = {}
    local metric_by_id = snapshot.metric_by_id or {}
    local fact_by_id = snapshot.fact_by_id or {}
    local visiting = {}
    local visited = {}

    local function visit(metric)
        local metric_key = key(metric.id)
        if visiting[metric_key] then
            return nil, "METRIC_DEPENDENCY_CYCLE"
        end
        if visited[metric_key] then return node_by_id[metric_key] end
        visiting[metric_key] = true
        local inputs = {}
        for _, input in ipairs(metric.inputs or {}) do
            local input_type = upper(input.object_type)
            local input_node
            if input_type == "METRIC" then
                local dependency = metric_by_id[key(input.object_id)]
                if dependency == nil then return nil, "MISSING_PRIVATE_METRIC_DEPENDENCY" end
                local dependency_node, err = visit(dependency)
                if err ~= nil then return nil, err end
                input_node = {kind = "METRIC", id = dependency.id, node_id = dependency_node.node_id}
            elseif input_type == "FACT" then
                local fact = fact_by_id[key(input.object_id)]
                if fact == nil then return nil, "MISSING_FACT_DEPENDENCY" end
                input_node = {kind = "FACT", id = fact.id, entity_id = fact.entity_id}
            else
                input_node = {kind = input_type, id = input.object_id}
            end
            input_node.role = input.role
            inputs[#inputs + 1] = input_node
        end
        for _, dependency in ipairs(metric.dependencies or {}) do
            if upper(dependency.object_type) == "METRIC" then
                local child = metric_by_id[key(dependency.object_id)]
                if child ~= nil then
                    local child_node, err = visit(child)
                    if err ~= nil then return nil, err end
                    inputs[#inputs + 1] = {
                        kind = "METRIC", id = child.id, node_id = child_node.node_id,
                    }
                end
            elseif upper(dependency.object_type) == "FACT" then
                local fact = fact_by_id[key(dependency.object_id)]
                if fact ~= nil then
                    inputs[#inputs + 1] = {
                        kind = "FACT", id = fact.id, entity_id = fact.entity_id,
                    }
                end
            end
        end
        local node = {
            node_id = "metric:" .. metric_key,
            metric_id = metric.id,
            name = metric.name,
            data_type = metric.data_type,
            state_class = classification(metric),
            base_entity_id = metric.base_entity_id,
            inputs = inputs,
            stage = (#inputs == 0) and "AGGREGATE" or "FINALIZE",
        }
        visiting[metric_key] = nil
        visited[metric_key] = true
        nodes[#nodes + 1] = node
        node_by_id[metric_key] = node
        return node
    end

    for _, metric in ipairs(selected_metrics or {}) do
        local _, err = visit(metric_by_id[key(metric.id)] or metric)
        if err ~= nil then return nil, err end
    end
    return {nodes = nodes, node_by_id = node_by_id}
end

local function mapping_has_expression(mapping)
    return not missing(mapping.from_expression) or not missing(mapping.to_expression)
end

local function keys_for(snapshot, entity_id)
    return (snapshot.unique_keys_by_entity or {})[key(entity_id)] or {}
end

local function matching_key(snapshot, relationship, side)
    local mappings = relationship.key_mappings or {}
    for _, mapping in ipairs(mappings) do
        if mapping_has_expression(mapping) then
            return nil, "EXPRESSION_KEY_PROOF_UNSUPPORTED"
        end
    end
    local expression_key_seen = false
    local column_key_seen = false
    for _, unique_key in ipairs(keys_for(snapshot,
        side == "from" and relationship.from_entity_id or relationship.to_entity_id)) do
        local has_expression = false
        for _, column in ipairs(unique_key.columns or {}) do
            if not missing(column.expression) then
                has_expression = true
            end
        end
        if has_expression then
            expression_key_seen = true
        else
            column_key_seen = true
            if graph.mapping_matches_key(mappings, side, unique_key) then return unique_key end
        end
    end
    if expression_key_seen and not column_key_seen then
        return nil, "EXPRESSION_KEY_PROOF_UNSUPPORTED"
    end
    return nil, "MISMATCHED_UNIQUE_KEY"
end

local function add_strict_edge(snapshot, edges, rejected, relationship, from_id, to_id, target_side)
    if #(relationship.key_mappings or {}) == 0 then
        rejected[#rejected + 1] = {
            relationship_id = relationship.id,
            from_entity_id = from_id,
            to_entity_id = to_id,
            reason = "MISSING_RELATIONSHIP_KEY_MAPPING",
        }
        return
    end
    local unique_key, reason = matching_key(snapshot, relationship, target_side)
    if unique_key == nil then
        rejected[#rejected + 1] = {
            relationship_id = relationship.id,
            from_entity_id = from_id,
            to_entity_id = to_id,
            reason = reason,
        }
        return
    end
    local from_key = key(from_id)
    edges[from_key] = edges[from_key] or {}
    edges[from_key][#edges[from_key] + 1] = {
        from_id = from_id,
        to_id = to_id,
        name = relationship.name,
        relationship = relationship,
        safe = true,
        reason = "OK",
        unique_key_id = unique_key.id,
        mapping_ordinals = {},
    }
    for _, mapping in ipairs(relationship.key_mappings or {}) do
        edges[from_key][#edges[from_key]].mapping_ordinals[#edges[from_key][#edges[from_key]].mapping_ordinals + 1] =
            mapping.ordinal_position
    end
end

function M.strict_edges(snapshot)
    local edges = {}
    local rejected = {}
    for _, relationship in ipairs(snapshot.relationships or {}) do
        local cardinality = upper(relationship.cardinality)
        if cardinality == "ONE_TO_ONE" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.from_entity_id, relationship.to_entity_id, "to")
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.to_entity_id, relationship.from_entity_id, "from")
        elseif cardinality == "MANY_TO_ONE" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.from_entity_id, relationship.to_entity_id, "to")
        elseif cardinality == "ONE_TO_MANY" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.to_entity_id, relationship.from_entity_id, "from")
        else
            rejected[#rejected + 1] = {
                relationship_id = relationship.id,
                reason = "MANY_TO_MANY_PROOF_UNSUPPORTED",
            }
        end
    end
    return edges, rejected
end

local function proof_json(mode, proof)
    local result = {
        mode = mode,
        status = proof.ok and "PROVEN" or "REJECTED",
        reason = proof.reason,
        candidate_paths = proof.candidate_paths or {},
        edges = {},
    }
    for _, edge in ipairs(proof.edges or {}) do
        result.edges[#result.edges + 1] = {
            relationship_id = edge.relationship and edge.relationship.id,
            relationship_name = edge.name,
            from_entity_id = edge.from_id,
            to_entity_id = edge.to_id,
            unique_key_id = edge.unique_key_id,
            mapping_ordinals = edge.mapping_ordinals or {},
        }
    end
    return result
end

function M.prove(snapshot, from_id, to_id, mode)
    mode = upper(mode)
    local edges
    local rejected = {}
    if mode == "STRICT_GRAIN" then
        edges, rejected = M.strict_edges(snapshot)
    else
        edges = graph.build_edges(snapshot.relationships or {})
        mode = "LEGACY_JOIN"
    end
    local proof = graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
        reject_any_ambiguity = mode == "STRICT_GRAIN",
    })
    local rendered = proof_json(mode, proof)
    rendered.rejected_edges = rejected
    return rendered
end

function M.logical_plan(spec, snapshot, selected_dimensions, selected_metrics, relationship_paths)
    local dag, dag_error = M.build_dag(snapshot, selected_metrics)
    if dag == nil then return nil, dag_error end
    local leaf_entities = {}
    local leaf_seen = {}
    for _, node in ipairs(dag.nodes) do
        if node.base_entity_id ~= nil and not leaf_seen[key(node.base_entity_id)] then
            leaf_seen[key(node.base_entity_id)] = true
            leaf_entities[#leaf_entities + 1] = node.base_entity_id
        end
        for _, input in ipairs(node.inputs) do
            if input.kind == "FACT" and input.entity_id ~= nil
                and not leaf_seen[key(input.entity_id)] then
                leaf_seen[key(input.entity_id)] = true
                leaf_entities[#leaf_entities + 1] = input.entity_id
            end
        end
    end
    table.sort(leaf_entities, function(left, right) return key(left) < key(right) end)
    if #leaf_entities > 1 then return nil, "MULTI_FACT_NOT_ENABLED" end

    local proofs = {}
    local root_id = snapshot.object.root_entity_id
    for _, path in ipairs(relationship_paths or {}) do
        local target_id = path.target_entity_id
        if target_id ~= nil then
            proofs[#proofs + 1] = M.prove(snapshot, root_id, target_id, spec.proof_mode)
        end
    end
    local requested_dimensions = {}
    for _, dimension in ipairs(selected_dimensions or {}) do
        requested_dimensions[#requested_dimensions + 1] = {
            id = dimension.id,
            name = dimension.name,
        }
    end
    local requested_metrics = {}
    for _, metric in ipairs(selected_metrics or {}) do
        requested_metrics[#requested_metrics + 1] = {
            id = metric.id,
            name = metric.name,
        }
    end
    return {
        plan_version = M.PLAN_VERSION,
        plan_kind = "SINGLE_BRANCH",
        query_spec_version = spec.query_spec_version,
        catalog_snapshot_version = snapshot.catalog_snapshot_version,
        proof_mode = spec.proof_mode,
        leaf_entity_ids = leaf_entities,
        metric_stages = dag.nodes,
        relationship_proofs = proofs,
        requested_dimensions = requested_dimensions,
        requested_metrics = requested_metrics,
    }
end

ESV_METRIC_PLAN = M
