-- Typed metric planning and strict grain-proof boundary.

local M = {PLAN_VERSION = 8}
local graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")

local function key(value) return tostring(value) end
local function upper(value) return string.upper(tostring(value or "")) end
local function missing(value)
    return value == nil or value == null or type(value) == "userdata"
        or tostring(value) == ""
end

local function sorted_keys(values)
    local out = {}
    for value_key, present in pairs(values or {}) do
        if present then out[#out + 1] = value_key end
    end
    table.sort(out)
    return out
end

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

local function authoritative_inputs(metric)
    local source = metric.inputs or {}
    local source_kind = "STRUCTURED_INPUTS"
    if #source == 0 then
        source = metric.dependencies or {}
        source_kind = "DEPENDENCY_FALLBACK"
    end
    local inputs = {}
    local seen = {}
    for index, input in ipairs(source) do
        local object_type = upper(input.object_type)
        local object_id = input.object_id
        local role = input.role or input.input_role
        local signature = object_type .. ":" .. key(object_id) .. ":" .. upper(role)
        if not seen[signature] then
            seen[signature] = true
            inputs[#inputs + 1] = {
                object_type = object_type,
                object_id = object_id,
                role = role,
                ordinal_position = input.ordinal_position or index,
                expression_alias = input.expression_alias,
                filter_expr = input.filter_expr,
            }
        end
    end
    return inputs, source_kind
end

local function state_spec(state_class, data_type)
    if state_class == "SUM" or state_class == "FILTERED_SUM" then
        return {
            state_kind = "SUM",
            merge_operator = "SUM",
            data_type = data_type,
            empty_behavior = "NULL",
        }
    end
    if state_class == "COUNT" or state_class == "FILTERED_COUNT" then
        return {
            state_kind = "COUNT",
            merge_operator = "SUM",
            data_type = data_type,
            empty_behavior = "ZERO",
        }
    end
    return nil
end

function M.build_dag(snapshot, selected_metrics)
    local nodes = {}
    local node_by_id = {}
    local metric_by_id = snapshot.metric_by_id or {}
    local fact_by_id = snapshot.fact_by_id or {}
    local visiting = {}
    local visited = {}
    local diagnostics = {}

    local function fact_node(fact)
        local node_id = "fact:" .. key(fact.id)
        if node_by_id[node_id] == nil then
            local node = {
                node_id = node_id,
                node_kind = "FACT_INPUT",
                fact_id = fact.id,
                name = fact.name,
                entity_id = fact.entity_id,
                data_type = fact.data_type,
            }
            nodes[#nodes + 1] = node
            node_by_id[node_id] = node
        end
        return node_by_id[node_id]
    end

    local function visit(metric)
        local metric_key = key(metric.id)
        local node_id = "metric:" .. metric_key
        if visiting[metric_key] then return nil, "METRIC_DEPENDENCY_CYCLE" end
        if visited[metric_key] then return node_by_id[node_id] end
        visiting[metric_key] = true

        local normalized_inputs, input_source = authoritative_inputs(metric)
        local inputs = {}
        local leaf_set = {}
        for _, input in ipairs(normalized_inputs) do
            if input.object_type == "METRIC" then
                local dependency = metric_by_id[key(input.object_id)]
                if dependency == nil then return nil, "MISSING_PRIVATE_METRIC_DEPENDENCY" end
                local dependency_node, err = visit(dependency)
                if err ~= nil then return nil, err end
                inputs[#inputs + 1] = {
                    kind = "METRIC",
                    id = dependency.id,
                    node_id = dependency_node.node_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
                for _, entity_id in ipairs(dependency_node.leaf_entity_ids or {}) do
                    leaf_set[key(entity_id)] = entity_id
                end
            elseif input.object_type == "FACT" then
                local fact = fact_by_id[key(input.object_id)]
                if fact == nil then return nil, "MISSING_FACT_DEPENDENCY" end
                local dependency_node = fact_node(fact)
                inputs[#inputs + 1] = {
                    kind = "FACT",
                    id = fact.id,
                    node_id = dependency_node.node_id,
                    entity_id = fact.entity_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
                leaf_set[key(fact.entity_id)] = fact.entity_id
            else
                inputs[#inputs + 1] = {
                    kind = input.object_type,
                    id = input.object_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
            end
        end

        local leaf_entities = {}
        for _, entity_key in ipairs(sorted_keys(leaf_set)) do
            leaf_entities[#leaf_entities + 1] = leaf_set[entity_key]
        end
        local state_class = classification(metric)
        local state = state_spec(state_class, metric.data_type)
        local node_kind
        if state ~= nil then
            node_kind = "AGGREGATE_STATE"
        elseif state_class == "RATIO" or state_class == "DERIVED_ARITHMETIC" then
            node_kind = "SCALAR_FINALIZER"
        elseif string.sub(state_class, 1, 12) == "UNSUPPORTED_" then
            node_kind = "UNSUPPORTED"
        else
            node_kind = "LEGACY_AGGREGATE"
        end
        local node = {
            node_id = node_id,
            node_kind = node_kind,
            metric_id = metric.id,
            name = metric.name,
            expression = metric.expression,
            data_type = metric.data_type,
            state_class = state_class,
            state_spec = state,
            base_entity_id = metric.base_entity_id,
            leaf_entity_ids = leaf_entities,
            inputs = inputs,
            input_source = input_source,
            local_filters = metric.filters or {},
            legacy_filter_expr = metric.filter_expr,
            stage = node_kind == "AGGREGATE_STATE" and "AGGREGATE"
                or (node_kind == "SCALAR_FINALIZER" and "FINALIZE" or "LEGACY"),
        }
        if node_kind == "AGGREGATE_STATE" and #leaf_entities == 0 then
            node.invalid_reason = "METRIC_INPUT_GRAIN_MISSING"
        elseif node_kind == "AGGREGATE_STATE" and #leaf_entities > 1 then
            node.invalid_reason = "METRIC_INPUT_GRAIN_AMBIGUOUS"
        end
        if metric.base_entity_id ~= nil and #leaf_entities > 0 then
            local matches_base = false
            for _, entity_id in ipairs(leaf_entities) do
                if key(entity_id) == key(metric.base_entity_id) then matches_base = true end
            end
            if not matches_base then
                diagnostics[#diagnostics + 1] = {
                    reason_code = "BASE_ENTITY_MISMATCH",
                    metric_id = metric.id,
                    declared_entity_id = metric.base_entity_id,
                    leaf_entity_ids = leaf_entities,
                }
            end
        end
        visiting[metric_key] = nil
        visited[metric_key] = true
        nodes[#nodes + 1] = node
        node_by_id[node_id] = node
        node_by_id[metric_key] = node
        return node
    end

    local selected_node_ids = {}
    for _, metric in ipairs(selected_metrics or {}) do
        local node, err = visit(metric_by_id[key(metric.id)] or metric)
        if err ~= nil then return nil, err end
        selected_node_ids[#selected_node_ids + 1] = node.node_id
    end
    return {
        nodes = nodes,
        node_by_id = node_by_id,
        selected_node_ids = selected_node_ids,
        diagnostics = diagnostics,
    }
end

local function field_ref(field)
    return {
        id = field.id or field.field_id,
        name = field.name or field.field,
        kind = field.kind or field.field_kind,
        entity_id = field.entity_id,
        data_type = field.data_type,
    }
end

function M.bind_query(spec, dimensions, metrics, global_filters, having_filters, relationship_targets)
    local bound = {
        bound_query_version = 1,
        selected_dimensions = {},
        selected_metrics = {},
        global_filters = {},
        having_filters = {},
        relationship_targets = relationship_targets or {},
        order_by = spec.order_by or {},
        limit = spec.limit,
    }
    for _, dimension in ipairs(dimensions or {}) do
        bound.selected_dimensions[#bound.selected_dimensions + 1] = field_ref(dimension)
    end
    for _, metric in ipairs(metrics or {}) do
        bound.selected_metrics[#bound.selected_metrics + 1] = field_ref(metric)
    end
    for _, filter in ipairs(global_filters or {}) do
        bound.global_filters[#bound.global_filters + 1] = {
            scope = "GLOBAL",
            field_id = filter.field_id,
            field = filter.field,
            entity_id = filter.entity_id,
            operator = filter.op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    for _, filter in ipairs(having_filters or {}) do
        bound.having_filters[#bound.having_filters + 1] = {
            scope = "HAVING",
            metric_id = filter.metric_id,
            metric = filter.metric,
            operator = filter.op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    return bound
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
            if not missing(column.expression) then has_expression = true end
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
    local edge = {
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
        edge.mapping_ordinals[#edge.mapping_ordinals + 1] = mapping.ordinal_position
    end
    edges[from_key][#edges[from_key] + 1] = edge
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

local STABLE_REASONS = {
    MISSING_RELATIONSHIP_KEY_MAPPING = "RELATIONSHIP_MAPPING_MISSING",
    MISMATCHED_UNIQUE_KEY = "RELATIONSHIP_TARGET_NOT_UNIQUE",
    EXPRESSION_KEY_PROOF_UNSUPPORTED = "EXPRESSION_KEY_PROOF_UNSUPPORTED",
    MANY_TO_MANY_PROOF_UNSUPPORTED = "MANY_TO_MANY_UNSUPPORTED",
    AMBIGUOUS_RELATIONSHIP_PATH = "RELATIONSHIP_PATH_AMBIGUOUS",
}

local function strict_edge_exists(edges, edge)
    for _, candidate in ipairs(edges[key(edge.from_id)] or {}) do
        if key(candidate.to_id) == key(edge.to_id)
            and key(candidate.relationship.id) == key(edge.relationship.id) then
            return true
        end
    end
    return false
end

local function direction_reason(edge)
    local relationship = edge.relationship
    local cardinality = upper(relationship.cardinality)
    if cardinality == "MANY_TO_MANY" then return "MANY_TO_MANY_UNSUPPORTED" end
    if cardinality == "MANY_TO_ONE"
        and key(edge.from_id) == key(relationship.to_entity_id) then
        return "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"
    end
    if cardinality == "ONE_TO_MANY"
        and key(edge.from_id) == key(relationship.from_entity_id) then
        return "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"
    end
    return nil
end

local function blocking_rejection(rejected, edge)
    for _, item in ipairs(rejected or {}) do
        if key(item.relationship_id) == key(edge.relationship.id)
            and (item.from_entity_id == nil or key(item.from_entity_id) == key(edge.from_id))
            and (item.to_entity_id == nil or key(item.to_entity_id) == key(edge.to_id)) then
            return STABLE_REASONS[item.reason] or item.reason, item
        end
    end
    return direction_reason(edge), nil
end

function M.prove_strict(snapshot, from_id, to_id)
    local edges, rejected = M.strict_edges(snapshot)
    local proof = graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
        reject_any_ambiguity = true,
    })
    local rendered = proof_json("STRICT_GRAIN", proof)
    rendered.from_entity_id = from_id
    rendered.to_entity_id = to_id
    rendered.rejected_edges = rejected
    if proof.ok then return rendered end
    if proof.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
        rendered.reason_code = "RELATIONSHIP_PATH_AMBIGUOUS"
        return rendered
    end

    local _, all_edges = graph.build_edges(snapshot.relationships or {},
        {allow_many_to_many = false})
    local attempted = graph.prove_path(all_edges, from_id, to_id, {
        require_safe = false,
        reject_ambiguous = true,
        reject_any_ambiguity = true,
    })
    if attempted.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
        rendered.reason_code = "RELATIONSHIP_PATH_AMBIGUOUS"
        rendered.candidate_paths = attempted.candidate_paths or {}
        return rendered
    end
    if attempted.ok then
        rendered.attempted_path = graph.path_text(attempted.edges)
        for _, edge in ipairs(attempted.edges) do
            if not strict_edge_exists(edges, edge) then
                local reason_code, detail = blocking_rejection(rejected, edge)
                rendered.reason_code = reason_code or "DIMENSION_NOT_CONFORMED"
                rendered.blocking_edge = {
                    relationship_id = edge.relationship.id,
                    relationship_name = edge.relationship.name,
                    from_entity_id = edge.from_id,
                    to_entity_id = edge.to_id,
                    detail = detail and detail.reason or nil,
                }
                return rendered
            end
        end
    end
    rendered.reason_code = "DIMENSION_NOT_CONFORMED"
    return rendered
end

function M.prove(snapshot, from_id, to_id, mode)
    if upper(mode) == "STRICT_GRAIN" then return M.prove_strict(snapshot, from_id, to_id) end
    local edges = graph.build_edges(snapshot.relationships or {})
    local proof = graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
    })
    local rendered = proof_json("LEGACY_JOIN", proof)
    rendered.from_entity_id = from_id
    rendered.to_entity_id = to_id
    return rendered
end

local function add_requirement(requirements, seen, target_entity_id, dimension_id,
    dimension_name, scope, metric_id)
    if target_entity_id == nil then return end
    local signature = key(target_entity_id) .. ":" .. key(dimension_id) .. ":"
        .. tostring(scope) .. ":" .. key(metric_id)
    if seen[signature] then return end
    seen[signature] = true
    requirements[#requirements + 1] = {
        target_entity_id = target_entity_id,
        dimension_id = dimension_id,
        dimension_name = dimension_name,
        scope = scope,
        metric_id = metric_id,
    }
end

local function requirement_id(branch_id, requirement)
    return table.concat({
        branch_id,
        "requirement",
        tostring(requirement.scope),
        "entity",
        key(requirement.target_entity_id),
        "dimension",
        key(requirement.dimension_id),
        "metric",
        key(requirement.metric_id),
    }, ":")
end

local function entity_name(snapshot, entity_id)
    local entity = (snapshot.entity_by_id or {})[key(entity_id)]
    return entity and entity.name or nil
end

function M.logical_plan(spec, snapshot, bound_query, selected_metrics, relationship_targets)
    if bound_query == nil or bound_query.selected_dimensions == nil then
        bound_query = M.bind_query(spec, bound_query or {}, selected_metrics or {},
            {}, {}, relationship_targets or {})
    end
    local dag, dag_error = M.build_dag(snapshot, selected_metrics or snapshot.visible_metrics)
    if dag == nil then return nil, dag_error end

    local aggregate_nodes = {}
    local leaf_set = {}
    local failure = nil
    local legacy_state_failure = nil
    for _, node in ipairs(dag.nodes) do
        if node.node_kind == "UNSUPPORTED" or node.node_kind == "LEGACY_AGGREGATE" then
            if legacy_state_failure == nil then
                legacy_state_failure = {
                    reason_code = "METRIC_STATE_UNSUPPORTED",
                    metric_id = node.metric_id,
                    metric = node.name,
                    state_class = node.state_class,
                }
            end
            for _, entity_id in ipairs(node.leaf_entity_ids or {}) do
                leaf_set[key(entity_id)] = entity_id
            end
        elseif node.node_kind == "AGGREGATE_STATE" then
            aggregate_nodes[#aggregate_nodes + 1] = node
            if node.invalid_reason ~= nil and failure == nil then
                failure = {
                    reason_code = node.invalid_reason,
                    metric_id = node.metric_id,
                    metric = node.name,
                }
            end
            for _, entity_id in ipairs(node.leaf_entity_ids or {}) do
                leaf_set[key(entity_id)] = entity_id
            end
        end
    end

    local leaf_entities = {}
    for _, entity_key in ipairs(sorted_keys(leaf_set)) do
        leaf_entities[#leaf_entities + 1] = leaf_set[entity_key]
    end
    local plan_kind = #leaf_entities > 1 and "MULTI_BRANCH" or "SINGLE_BRANCH"
    -- Non-mergeable legacy aggregates remain valid on the unchanged
    -- single-branch compatibility renderer. They are rejected when a caller
    -- explicitly requests the strict typed boundary or when multiple leaves
    -- would require state merging.
    if failure == nil and legacy_state_failure ~= nil
        and (plan_kind == "MULTI_BRANCH" or spec.proof_mode == "STRICT_GRAIN") then
        failure = legacy_state_failure
    end
    local plan = {
        plan_version = M.PLAN_VERSION,
        plan_kind = plan_kind,
        query_spec_version = spec.query_spec_version,
        catalog_snapshot_version = snapshot.catalog_snapshot_version,
        bound_query = bound_query,
        proof_mode = plan_kind == "MULTI_BRANCH" and "STRICT_GRAIN" or spec.proof_mode,
        leaf_entity_ids = leaf_entities,
        metric_stages = dag.nodes,
        diagnostics = dag.diagnostics,
        branches = {},
        relationship_proofs = {},
        requested_dimensions = bound_query.selected_dimensions,
        requested_metrics = bound_query.selected_metrics,
        failure = failure,
    }

    if plan_kind == "MULTI_BRANCH" then
        for _, leaf_entity_id in ipairs(leaf_entities) do
            local branch = {
                branch_id = "branch:" .. key(leaf_entity_id),
                leaf_entity_id = leaf_entity_id,
                leaf_entity_name = entity_name(snapshot, leaf_entity_id),
                state_node_ids = {},
                requirements = {},
                proofs = {},
            }
            for _, node in ipairs(aggregate_nodes) do
                if #node.leaf_entity_ids == 1
                    and key(node.leaf_entity_ids[1]) == key(leaf_entity_id) then
                    branch.state_node_ids[#branch.state_node_ids + 1] = node.node_id
                end
            end
            local requirement_seen = {}
            for _, dimension in ipairs(bound_query.selected_dimensions or {}) do
                add_requirement(branch.requirements, requirement_seen,
                    dimension.entity_id, dimension.id, dimension.name, "SELECTED", nil)
            end
            for _, filter in ipairs(bound_query.global_filters or {}) do
                add_requirement(branch.requirements, requirement_seen,
                    filter.entity_id, filter.field_id, filter.field, "GLOBAL_FILTER", nil)
            end
            for _, node in ipairs(aggregate_nodes) do
                if #node.leaf_entity_ids == 1
                    and key(node.leaf_entity_ids[1]) == key(leaf_entity_id) then
                    for _, filter in ipairs(node.local_filters or {}) do
                        local dimension_id = not missing(filter.required_dimension_id)
                            and filter.required_dimension_id or nil
                        local dimension = dimension_id ~= nil
                            and (snapshot.dimension_by_id or {})[key(dimension_id)] or nil
                        local entity_id = not missing(filter.required_entity_id)
                            and filter.required_entity_id
                            or (dimension and dimension.entity_id)
                        -- A metric-local predicate expressed directly against
                        -- its owning leaf needs no relationship proof. Only a
                        -- semantic dimension dependency adds a branch
                        -- requirement.
                        if not missing(entity_id) then
                            add_requirement(branch.requirements, requirement_seen,
                                entity_id,
                                dimension_id,
                                dimension and dimension.name or nil,
                                "METRIC_LOCAL",
                                node.metric_id)
                        end
                    end
                end
            end
            table.sort(branch.requirements, function(left, right)
                local left_key = key(left.target_entity_id) .. ":" .. key(left.dimension_id)
                    .. ":" .. tostring(left.scope) .. ":" .. key(left.metric_id)
                local right_key = key(right.target_entity_id) .. ":" .. key(right.dimension_id)
                    .. ":" .. tostring(right.scope) .. ":" .. key(right.metric_id)
                return left_key < right_key
            end)
            for _, requirement in ipairs(branch.requirements) do
                requirement.requirement_id = requirement_id(branch.branch_id, requirement)
                local proof = M.prove_strict(snapshot, leaf_entity_id,
                    requirement.target_entity_id)
                proof.proof_id = "proof:" .. requirement.requirement_id
                proof.requirement = requirement
                if proof.status == "PROVEN" and #(proof.edges or {}) > 0 then
                    proof.target_unique_key_id =
                        proof.edges[#proof.edges].unique_key_id
                elseif proof.status ~= "PROVEN" then
                    proof.rejection_id = proof.proof_id .. ":rejection"
                end
                branch.proofs[#branch.proofs + 1] = proof
                plan.relationship_proofs[#plan.relationship_proofs + 1] = proof
                if proof.status ~= "PROVEN" and plan.failure == nil then
                    plan.failure = {
                        reason_code = proof.reason_code or "DIMENSION_NOT_CONFORMED",
                        proof_id = proof.proof_id,
                        rejection_id = proof.rejection_id,
                        branch_id = branch.branch_id,
                        leaf_entity_id = leaf_entity_id,
                        metric_id = requirement.metric_id,
                        dimension_id = requirement.dimension_id,
                        dimension = requirement.dimension_name,
                        blocking_edge = proof.blocking_edge,
                        candidate_paths = proof.candidate_paths,
                    }
                end
            end
            plan.branches[#plan.branches + 1] = branch
        end
        if plan.failure == nil then
            plan.execution = {
                status = "PLANNING_ONLY",
                reason_code = "MULTI_BRANCH_EXECUTION_NOT_ENABLED",
            }
        end
    else
        local root_id = snapshot.object.root_entity_id
        for _, target in ipairs(bound_query.relationship_targets or {}) do
            local proof = M.prove(snapshot, root_id, target.target_entity_id, spec.proof_mode)
            plan.relationship_proofs[#plan.relationship_proofs + 1] = proof
        end
    end
    return plan, nil
end

ESV_METRIC_PLAN = M
