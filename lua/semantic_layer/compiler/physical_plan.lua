-- Typed physical planning for proven multi-branch aggregate-state plans.

local M = {
    VERSION = 6,
    DEFAULT_MAX_BRANCHES = 8,
    DEFAULT_MAX_SQL_BYTES = 1000000,
}

local function key(value) return tostring(value) end
local function upper(value) return string.upper(tostring(value or "")) end
local function missing(value) return value == nil or value == null or tostring(value) == "" end

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function sql_string(value)
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

local function sql_literal(value, data_type)
    if value == nil or value == null then return "NULL" end
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "TRUE" or "FALSE" end
    local text = tostring(value)
    local dtype = upper(data_type)
    if string.sub(dtype, 1, 4) == "DATE"
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
        return "DATE " .. sql_string(text)
    end
    if string.find(dtype, "TIMESTAMP", 1, true) == 1
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d") then
        return "TIMESTAMP " .. sql_string(text)
    end
    if string.find(dtype, "DECIMAL", 1, true)
        or string.find(dtype, "INT", 1, true)
        or string.find(dtype, "NUMBER", 1, true)
        or string.find(dtype, "DOUBLE", 1, true) then
        if string.match(text, "^%-?%d+%.?%d*$") then return text end
    end
    return sql_string(text)
end

local function is_text_type(data_type)
    local dtype = upper(data_type)
    return string.find(dtype, "CHAR", 1, true) ~= nil
        or string.find(dtype, "VARCHAR", 1, true) ~= nil
end

local function stable_token(value)
    local token = string.gsub(key(value), "[^%w_]", "_")
    if token == "" then token = "empty" end
    return token
end

local function replace_identifiers(text, replace_fn)
    local out = {}
    local value = tostring(text or "")
    local index = 1
    local in_quote = false
    while index <= #value do
        local char = string.sub(value, index, index)
        if char == "'" then
            out[#out + 1] = char
            local next_char = string.sub(value, index + 1, index + 1)
            if in_quote and next_char == "'" then
                out[#out + 1] = next_char
                index = index + 2
            else
                in_quote = not in_quote
                index = index + 1
            end
        elseif in_quote then
            out[#out + 1] = char
            index = index + 1
        elseif string.match(char, "[A-Za-z_]") then
            local finish = index + 1
            while finish <= #value
                and string.match(string.sub(value, finish, finish), "[A-Za-z0-9_]") do
                finish = finish + 1
            end
            local token = string.sub(value, index, finish - 1)
            out[#out + 1] = replace_fn(token) or token
            index = finish
        else
            out[#out + 1] = char
            index = index + 1
        end
    end
    return table.concat(out)
end

local function sorted_copy(values, field)
    local result = {}
    for _, value in ipairs(values or {}) do result[#result + 1] = value end
    table.sort(result, function(left, right)
        return key(left[field]) < key(right[field])
    end)
    return result
end

local function fail(reason_code, details)
    details = details or {}
    details.reason_code = reason_code
    return nil, details
end

local function source_sql(entity)
    if entity == nil or missing(entity.source_schema) or missing(entity.source_object)
        or missing(entity.alias) then
        return nil
    end
    return quote_qualified(entity.source_schema, entity.source_object)
        .. " " .. tostring(entity.alias)
end

local function predicate_sql(filter, dimension)
    local expression = dimension and dimension.expression
    if missing(expression) then return nil, "DIMENSION_EXPRESSION_MISSING" end
    local operator = upper(filter.operator)
    local rhs = filter.value_sql or sql_literal(filter.value, filter.data_type)
    if operator == "IS NULL" or operator == "IS NOT NULL" then
        return tostring(expression) .. " " .. operator
    end
    if operator == "IN" then
        local values = filter.value
        if type(values) ~= "table" or #values == 0 then
            return nil, "FILTER_VALUE_INVALID"
        end
        local literals = {}
        for _, value in ipairs(values) do
            local literal = sql_literal(value, filter.data_type)
            if is_text_type(filter.data_type) then literal = "UPPER(" .. literal .. ")" end
            literals[#literals + 1] = literal
        end
        local lhs = tostring(expression)
        if is_text_type(filter.data_type) then lhs = "UPPER(" .. lhs .. ")" end
        return lhs .. " IN (" .. table.concat(literals, ", ") .. ")"
    end
    if operator == "BETWEEN" then
        local values = filter.value
        if type(values) ~= "table" or #values ~= 2 then
            return nil, "FILTER_VALUE_INVALID"
        end
        return tostring(expression) .. " BETWEEN "
            .. sql_literal(values[1], filter.data_type) .. " AND "
            .. sql_literal(values[2], filter.data_type)
    end
    if operator == "=" or operator == "!=" or operator == "<>"
        or operator == ">" or operator == ">=" or operator == "<"
        or operator == "<=" or operator == "LIKE" then
        local lhs = tostring(expression)
        if is_text_type(filter.data_type)
            and (operator == "=" or operator == "!=" or operator == "<>"
                or operator == "LIKE") then
            lhs = "UPPER(" .. lhs .. ")"
            rhs = "UPPER(" .. rhs .. ")"
        end
        return lhs .. " " .. operator .. " " .. rhs
    end
    return nil, "FILTER_OPERATOR_UNSUPPORTED"
end

local function state_filter_sql(node)
    local predicates = {}
    for _, filter in ipairs(node.local_filters or {}) do
        local expression = filter.resolved_sql_expr
        if missing(expression) then return nil, "METRIC_FILTER_EXPRESSION_MISSING" end
        predicates[#predicates + 1] = tostring(expression)
    end
    if #predicates == 0 and not missing(node.legacy_filter_expr) then
        predicates[1] = tostring(node.legacy_filter_expr)
    end
    for _, input in ipairs(node.inputs or {}) do
        if not missing(input.filter_expr) then
            predicates[#predicates + 1] = tostring(input.filter_expr)
        end
    end
    if #predicates == 0 then return nil end
    return table.concat(predicates, " AND ")
end

local function state_expression(state, fact_expression, filter_expression)
    local value_expression = tostring(fact_expression)
    if filter_expression ~= nil then
        value_expression = "CASE WHEN (" .. filter_expression .. ") THEN "
            .. value_expression .. " ELSE NULL END"
    end
    if state.state_kind == "SUM" then return "SUM(" .. value_expression .. ")" end
    if state.state_kind == "COUNT" then return "COUNT(" .. value_expression .. ")" end
    return nil
end

local function collect_states(logical_plan, snapshot)
    local states = {}
    local aliases = {}
    for _, node in ipairs(logical_plan.metric_stages or {}) do
        if node.node_kind == "AGGREGATE_STATE" then
            if node.state_spec == nil or missing(node.state_spec.data_type) then
                return fail("METRIC_STATE_TYPE_INCOMPATIBLE", {
                    metric_id = node.metric_id,
                    state_id = node.node_id,
                })
            end
            local fact_input = nil
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "FACT" then
                    if fact_input ~= nil then
                        return fail("METRIC_INPUT_GRAIN_AMBIGUOUS", {
                            metric_id = node.metric_id,
                            state_id = node.node_id,
                        })
                    end
                    fact_input = input
                end
            end
            local fact = fact_input and (snapshot.fact_by_id or {})[key(fact_input.id)]
            if fact == nil or missing(fact.expression) then
                return fail("PHYSICAL_BINDING_INCOMPLETE", {
                    binding_kind = "FACT_EXPRESSION",
                    metric_id = node.metric_id,
                    fact_id = fact_input and fact_input.id,
                    state_id = node.node_id,
                })
            end
            local state_id = "state:metric:" .. key(node.metric_id)
            local alias = "__esv_s_" .. stable_token(node.metric_id)
            if aliases[alias] ~= nil and aliases[alias] ~= state_id then
                return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                    state_id = state_id,
                    conflicting_state_id = aliases[alias],
                })
            end
            aliases[alias] = state_id
            local filter_expression, filter_error = state_filter_sql(node)
            if filter_error ~= nil then
                return fail("PHYSICAL_BINDING_INCOMPLETE", {
                    binding_kind = "METRIC_FILTER_EXPRESSION",
                    detail = filter_error,
                    metric_id = node.metric_id,
                    state_id = node.node_id,
                })
            end
            states[#states + 1] = {
                state_id = state_id,
                node_id = node.node_id,
                metric_id = node.metric_id,
                metric = node.name,
                leaf_entity_id = node.leaf_entity_ids[1],
                state_kind = node.state_spec.state_kind,
                merge_operator = node.state_spec.merge_operator,
                empty_behavior = node.state_spec.empty_behavior,
                data_type = node.state_spec.data_type,
                source_fact_id = fact.id,
                source_expression = fact.expression,
                filter_expression = filter_expression,
                column_alias = alias,
                placeholder_expression = "CAST(NULL AS "
                    .. tostring(node.state_spec.data_type) .. ")",
            }
        end
    end
    table.sort(states, function(left, right) return left.state_id < right.state_id end)
    for ordinal, state in ipairs(states) do state.ordinal = ordinal end
    return states, nil
end

local function collect_dimensions(logical_plan, snapshot)
    local dimensions = {}
    local aliases = {}
    for _, reference in ipairs(logical_plan.bound_query.selected_dimensions or {}) do
        local dimension = (snapshot.dimension_by_id or {})[key(reference.id)]
        if dimension == nil or missing(dimension.expression) then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "DIMENSION_EXPRESSION",
                dimension_id = reference.id,
            })
        end
        local alias = "__esv_d_" .. stable_token(reference.id)
        if aliases[alias] ~= nil and aliases[alias] ~= key(reference.id) then
            return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                dimension_id = reference.id,
                conflicting_dimension_id = aliases[alias],
            })
        end
        aliases[alias] = key(reference.id)
        dimensions[#dimensions + 1] = {
            dimension_id = reference.id,
            name = reference.name,
            entity_id = dimension.entity_id,
            data_type = dimension.data_type,
            expression = dimension.expression,
            column_alias = alias,
            ordinal = #dimensions + 1,
        }
    end
    return dimensions, nil
end

local function append_fusion_joins(joins, joined_fusion_joins, entity)
    for _, fusion_join in ipairs(entity and entity.fusion_joins or {}) do
        local join_id = "join:fusion:" .. key(entity.id) .. ":"
            .. key(fusion_join.alias)
        if not joined_fusion_joins[join_id] then
            local target_sql = fusion_join.source_sql
            if missing(target_sql) and fusion_join.representation ~= nil then
                target_sql = quote_qualified(
                    fusion_join.representation.source_schema,
                    fusion_join.representation.source_object)
            end
            if missing(target_sql) or missing(fusion_join.alias)
                or #(fusion_join.predicates or {}) == 0 then
                return fail("PHYSICAL_BINDING_INCOMPLETE", {
                    binding_kind = "FUSION_JOIN",
                    entity_id = entity.id,
                })
            end
            joins[#joins + 1] = {
                join_id = join_id,
                fusion = true,
                entity_id = entity.id,
                join_type = "LEFT",
                target_sql = target_sql .. " " .. tostring(fusion_join.alias),
                condition = table.concat(fusion_join.predicates, " AND "),
            }
            joined_fusion_joins[join_id] = true
        end
    end
    return joins, nil
end

local function branch_joins(branch, snapshot)
    local joins = {}
    local joined_relationships = {}
    local joined_fusion_joins = {}
    local joined_entities = {[key(branch.leaf_entity_id)] = true}
    local leaf = (snapshot.entity_by_id or {})[key(branch.leaf_entity_id)]
    local fusion_error
    joins, fusion_error = append_fusion_joins(
        joins, joined_fusion_joins, leaf)
    if joins == nil then return nil, fusion_error end
    for _, proof in ipairs(branch.proofs or {}) do
        for _, proof_edge in ipairs(proof.edges or {}) do
            local relationship = (snapshot.relationship_by_id or {})[
                key(proof_edge.relationship_id)]
            local target = (snapshot.entity_by_id or {})[key(proof_edge.to_entity_id)]
            if relationship == nil or target == nil then
                return fail("PHYSICAL_PROOF_INVALID", {
                    issue = "REFERENCE_MISSING",
                    branch_id = branch.branch_id,
                    proof_id = proof.proof_id,
                    relationship_id = proof_edge.relationship_id,
                })
            end
            if not joined_entities[key(proof_edge.from_entity_id)] then
                return fail("PHYSICAL_PROOF_INVALID", {
                    issue = "PATH_DISCONNECTED",
                    branch_id = branch.branch_id,
                    proof_id = proof.proof_id,
                    relationship_id = proof_edge.relationship_id,
                })
            end
            if not joined_relationships[key(relationship.id)] then
                local target_sql = source_sql(target)
                if target_sql == nil or missing(relationship.join_condition) then
                    return fail("PHYSICAL_BINDING_INCOMPLETE", {
                        binding_kind = "RELATIONSHIP_JOIN",
                        branch_id = branch.branch_id,
                        relationship_id = relationship.id,
                    })
                end
                joins[#joins + 1] = {
                    join_id = "join:relationship:" .. key(relationship.id),
                    relationship_id = relationship.id,
                    from_entity_id = proof_edge.from_entity_id,
                    to_entity_id = proof_edge.to_entity_id,
                    join_type = upper(relationship.join_type or "LEFT"),
                    target_sql = target_sql,
                    condition = relationship.join_condition,
                }
                joined_relationships[key(relationship.id)] = true
                joined_entities[key(proof_edge.to_entity_id)] = true
                joins, fusion_error = append_fusion_joins(
                    joins, joined_fusion_joins, target)
                if joins == nil then return nil, fusion_error end
            end
        end
    end
    return joins, nil
end

local function global_predicates(logical_plan, snapshot)
    local predicates = {}
    for _, filter in ipairs(logical_plan.bound_query.global_filters or {}) do
        local dimension = (snapshot.dimension_by_id or {})[key(filter.field_id)]
        local expression, reason = predicate_sql(filter, dimension)
        if expression == nil then
            return fail("PHYSICAL_FILTER_INVALID", {
                issue = reason,
                dimension_id = filter.field_id,
            })
        end
        predicates[#predicates + 1] = {
            filter_id = "global-filter:dimension:" .. key(filter.field_id)
                .. ":" .. key(#predicates + 1),
            dimension_id = filter.field_id,
            expression = expression,
            operator = filter.operator,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    return predicates, nil
end

local function metric_column_alias(metric_id)
    return "__esv_m_" .. stable_token(metric_id)
end

local function qualified_column(source_alias, column_alias)
    return tostring(source_alias) .. "." .. quote_ident(column_alias)
end

local function collect_finalization(logical_plan, states, dimensions, options)
    local finalization = {
        base = {
            cte_id = "cte:metrics:0",
            cte_alias = "__esv_metrics_0",
            source_alias = "ms",
            metric_columns = {},
        },
        layers = {},
        outputs = {dimensions = {}, metrics = {}},
        having_predicates = {},
        order_by = options.output_order_by or {},
        limit = options.limit,
    }
    local metric_columns = {}
    local metric_names = {}
    for _, state in ipairs(states) do
        local column_alias = metric_column_alias(state.metric_id)
        local state_reference = qualified_column(finalization.base.source_alias,
            state.column_alias)
        local expression = state_reference
        if state.empty_behavior == "ZERO" then
            expression = "COALESCE(" .. state_reference .. ", 0)"
        end
        local column = {
            metric_id = state.metric_id,
            metric = state.metric,
            data_type = state.data_type,
            column_alias = column_alias,
            expression = expression,
            source_state_id = state.state_id,
            empty_behavior = state.empty_behavior,
        }
        finalization.base.metric_columns[#finalization.base.metric_columns + 1] = column
        metric_columns[key(state.metric_id)] = column
        metric_names[upper(state.metric)] = column
    end

    local previous_cte_alias = finalization.base.cte_alias
    local layer_ordinal = 0
    for _, node in ipairs(logical_plan.metric_stages or {}) do
        if node.node_kind == "SCALAR_FINALIZER" then
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "METRIC" and metric_columns[key(input.id)] == nil then
                    return fail("PHYSICAL_FINALIZER_INVALID", {
                        issue = "DEPENDENCY_NOT_AVAILABLE",
                        metric_id = node.metric_id,
                        dependency_metric_id = input.id,
                    })
                end
            end
            if missing(node.expression) then
                return fail("PHYSICAL_FINALIZER_INVALID", {
                    issue = "EXPRESSION_MISSING",
                    metric_id = node.metric_id,
                })
            end
            layer_ordinal = layer_ordinal + 1
            local source_alias = "p"
            local input_aliases = {}
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "METRIC" and not missing(input.expression_alias) then
                    input_aliases[upper(input.expression_alias)] =
                        metric_columns[key(input.id)]
                end
            end
            local expression = replace_identifiers(node.expression, function(token)
                local dependency = input_aliases[upper(token)]
                    or metric_names[upper(token)]
                if dependency ~= nil then
                    return "(" .. qualified_column(source_alias,
                        dependency.column_alias) .. ")"
                end
                return nil
            end)
            local column = {
                metric_id = node.metric_id,
                metric = node.name,
                data_type = node.data_type,
                column_alias = metric_column_alias(node.metric_id),
                expression = expression,
            }
            local layer = {
                layer_id = "finalizer:metric:" .. key(node.metric_id),
                cte_id = "cte:metrics:" .. key(layer_ordinal),
                cte_alias = "__esv_metrics_" .. key(layer_ordinal),
                input_cte_alias = previous_cte_alias,
                source_alias = source_alias,
                metric_column = column,
            }
            finalization.layers[#finalization.layers + 1] = layer
            previous_cte_alias = layer.cte_alias
            metric_columns[key(node.metric_id)] = column
            metric_names[upper(node.name)] = column
        end
    end
    finalization.result_cte_alias = previous_cte_alias
    finalization.result_source_alias = "f"

    for _, dimension in ipairs(dimensions) do
        finalization.outputs.dimensions[#finalization.outputs.dimensions + 1] = {
            dimension_id = dimension.dimension_id,
            name = dimension.name,
            source_expression = qualified_column(finalization.result_source_alias,
                dimension.column_alias),
            output_alias = dimension.name,
        }
    end
    for _, reference in ipairs(logical_plan.bound_query.selected_metrics or {}) do
        local column = metric_columns[key(reference.id)]
        if column == nil then
            return fail("PHYSICAL_FINALIZER_INVALID", {
                issue = "OUTPUT_METRIC_NOT_AVAILABLE",
                metric_id = reference.id,
            })
        end
        finalization.outputs.metrics[#finalization.outputs.metrics + 1] = {
            metric_id = reference.id,
            name = reference.name,
            source_expression = qualified_column(finalization.result_source_alias,
                column.column_alias),
            output_alias = reference.name,
        }
    end
    for _, filter in ipairs(logical_plan.bound_query.having_filters or {}) do
        local column = metric_columns[key(filter.metric_id)]
        if column == nil then
            return fail("PHYSICAL_FINALIZER_INVALID", {
                issue = "HAVING_METRIC_NOT_AVAILABLE",
                metric_id = filter.metric_id,
            })
        end
        local expression, reason = predicate_sql(filter, {
            expression = qualified_column(finalization.result_source_alias,
                column.column_alias),
        })
        if expression == nil then
            return fail("PHYSICAL_FILTER_INVALID", {
                issue = reason,
                metric_id = filter.metric_id,
                scope = "HAVING",
            })
        end
        finalization.having_predicates[#finalization.having_predicates + 1] = {
            filter_id = "having:metric:" .. key(filter.metric_id) .. ":"
                .. key(#finalization.having_predicates + 1),
            metric_id = filter.metric_id,
            expression = expression,
        }
    end
    return finalization, nil
end

function M.build(logical_plan, snapshot, options)
    options = options or {}
    if logical_plan == nil or logical_plan.plan_kind ~= "MULTI_BRANCH" then
        return fail("PHYSICAL_MULTI_BRANCH_PLAN_REQUIRED")
    end
    if logical_plan.failure ~= nil then
        return fail("LOGICAL_PLAN_NOT_VALID")
    end
    local branches = sorted_copy(logical_plan.branches, "branch_id")
    local max_branches = tonumber(options.max_branches) or M.DEFAULT_MAX_BRANCHES
    if #branches > max_branches then
        return fail("PLANNER_BRANCH_LIMIT_EXCEEDED", {
            branch_count = #branches,
            branch_limit = max_branches,
        })
    end

    local dimensions, dimension_error = collect_dimensions(logical_plan, snapshot)
    if dimensions == nil then return nil, dimension_error end
    local states, state_error = collect_states(logical_plan, snapshot)
    if states == nil then return nil, state_error end
    local predicates, predicate_error = global_predicates(logical_plan, snapshot)
    if predicates == nil then return nil, predicate_error end

    local physical = {
        physical_plan_version = M.VERSION,
        plan_kind = "MULTI_BRANCH_QUERY",
        logical_plan_version = logical_plan.plan_version,
        dimensions = dimensions,
        states = states,
        global_filters = predicates,
        branches = {},
        union = {
            cte_id = "cte:unioned-states",
            cte_alias = "__esv_unioned_states",
        },
        merge = {
            cte_id = "cte:merged-states",
            cte_alias = "__esv_merged_states",
            group_dimension_ids = {},
            state_ids = {},
        },
        safeguards = {
            branch_count = #branches,
            branch_limit = max_branches,
            sql_size_limit = tonumber(options.max_sql_bytes) or M.DEFAULT_MAX_SQL_BYTES,
        },
        execution = {
            status = "PLANNING_ONLY",
            reason_code = "MULTI_BRANCH_EXECUTION_NOT_ENABLED",
        },
    }
    for _, dimension in ipairs(dimensions) do
        physical.merge.group_dimension_ids[#physical.merge.group_dimension_ids + 1] =
            dimension.dimension_id
    end
    for _, state in ipairs(states) do
        physical.merge.state_ids[#physical.merge.state_ids + 1] = state.state_id
    end

    local finalization, finalization_error = collect_finalization(
        logical_plan, states, dimensions, options)
    if finalization == nil then return nil, finalization_error end
    physical.finalization = finalization

    local branch_aliases = {}
    local state_owner_counts = {}
    for _, state in ipairs(states) do state_owner_counts[state.state_id] = 0 end
    for _, branch in ipairs(branches) do
        local entity = (snapshot.entity_by_id or {})[key(branch.leaf_entity_id)]
        local from_sql = source_sql(entity)
        if from_sql == nil then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "SOURCE",
                branch_id = branch.branch_id,
                leaf_entity_id = branch.leaf_entity_id,
            })
        end
        local joins, join_error = branch_joins(branch, snapshot)
        if joins == nil then return nil, join_error end
        local cte_alias = "__esv_b_" .. stable_token(branch.leaf_entity_id)
        if branch_aliases[cte_alias] ~= nil
            and branch_aliases[cte_alias] ~= branch.branch_id then
            return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                branch_id = branch.branch_id,
                conflicting_branch_id = branch_aliases[cte_alias],
            })
        end
        branch_aliases[cte_alias] = branch.branch_id
        local physical_branch = {
            branch_id = branch.branch_id,
            cte_id = "cte:" .. branch.branch_id,
            cte_alias = cte_alias,
            leaf_entity_id = branch.leaf_entity_id,
            source = {
                source_kind = "BASE",
                entity_id = entity.id,
                entity_name = entity.name,
                representation_id = entity.primary_representation
                    and entity.primary_representation.id or nil,
                representation_name = entity.primary_representation
                    and entity.primary_representation.name or nil,
                physical_schema = entity.source_schema,
                physical_object = entity.source_object,
            },
            from_sql = from_sql,
            joins = joins,
            dimensions = dimensions,
            where_predicates = predicates,
            state_columns = {},
        }
        for _, state in ipairs(states) do
            local column = {
                state_id = state.state_id,
                column_alias = state.column_alias,
                data_type = state.data_type,
                owner = key(state.leaf_entity_id) == key(branch.leaf_entity_id),
                source_fact_id = state.source_fact_id,
                state_kind = state.state_kind,
                filter_expression = state.filter_expression,
            }
            if column.owner then
                state_owner_counts[state.state_id] =
                    state_owner_counts[state.state_id] + 1
                column.expression = state_expression(state, state.source_expression,
                    state.filter_expression)
                if column.expression == nil then
                    return fail("METRIC_STATE_UNSUPPORTED", {
                        branch_id = branch.branch_id,
                        state_id = state.state_id,
                    })
                end
            else
                column.expression = state.placeholder_expression
            end
            physical_branch.state_columns[#physical_branch.state_columns + 1] = column
        end
        physical.branches[#physical.branches + 1] = physical_branch
    end
    for _, state in ipairs(states) do
        if state_owner_counts[state.state_id] ~= 1 then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "STATE_OWNER",
                state_id = state.state_id,
                owner_count = state_owner_counts[state.state_id],
            })
        end
    end
    return physical, nil
end

local function clone(value, seen)
    if type(value) ~= "table" or value == null then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}
    seen[value] = out
    for child_key, child in pairs(value) do out[child_key] = clone(child, seen) end
    return out
end

local function candidate_binding(candidate, attribute_type, attribute_id)
    return (candidate.bindings or {})[attribute_type .. ":" .. key(attribute_id)]
end

local function rebind_partition_predicate(predicate, candidate)
    local binding = candidate_binding(candidate, "DIMENSION", predicate.dimension_id)
    if binding == nil then return predicate, nil end
    local expression, reason = predicate_sql(predicate, {expression = binding.expression})
    if expression == nil then return nil, reason end
    local rebound = clone(predicate)
    rebound.expression = expression
    return rebound, nil
end

-- Expand a grain-proven leaf into disjoint representation partitions. Each
-- partition computes mergeable aggregate state independently; the existing
-- UNION/merge pipeline combines those states without joining partition rows.
function M.apply_partitioned_sources(physical_plan, snapshot)
    local expanded = {}
    local fusion_partitions = {}
    local max_branches = physical_plan.safeguards.branch_limit
    for _, branch in ipairs(physical_plan.branches or {}) do
        local entity = (snapshot.entity_by_id or {})[key(branch.leaf_entity_id)]
        local candidates = entity and entity.fusion_candidates or nil
        if upper(entity and entity.fusion_strategy) ~= "UNION" then
            expanded[#expanded + 1] = branch
        else
            if candidates == nil or #candidates < 2 then
                return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                    entity_id = branch.leaf_entity_id,
                })
            end
            for _, candidate in ipairs(candidates) do
                local representation = candidate.representation
                local partition = clone(branch)
                partition.branch_id = branch.branch_id .. ":representation:"
                    .. key(representation.id)
                partition.cte_id = "cte:" .. partition.branch_id
                partition.cte_alias = "__esv_b_" .. stable_token(branch.leaf_entity_id)
                    .. "_r_" .. stable_token(representation.id)
                partition.source = {
                    source_kind = "REPRESENTATION_PARTITION",
                    entity_id = entity.id,
                    entity_name = entity.name,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    physical_schema = representation.source_schema,
                    physical_object = representation.source_object,
                    coverage_predicate = representation.coverage_predicate,
                    valid_from = representation.valid_from,
                    valid_to = representation.valid_to,
                }
                partition.from_sql = quote_qualified(representation.source_schema,
                    representation.source_object) .. " " .. tostring(representation.alias)
                for _, dimension in ipairs(partition.dimensions or {}) do
                    if key(dimension.entity_id) == key(entity.id) then
                        local binding = candidate_binding(candidate, "DIMENSION",
                            dimension.dimension_id)
                        if binding == nil then
                            return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                                entity_id = entity.id,
                                representation_id = representation.id,
                                dimension_id = dimension.dimension_id,
                            })
                        end
                        dimension.expression = binding.expression
                    end
                end
                local predicates = {}
                for _, predicate in ipairs(partition.where_predicates or {}) do
                    local rebound, reason = rebind_partition_predicate(predicate, candidate)
                    if rebound == nil then
                        return fail("PHYSICAL_FILTER_INVALID", {
                            branch_id = partition.branch_id,
                            dimension_id = predicate.dimension_id,
                            issue = reason,
                        })
                    end
                    predicates[#predicates + 1] = rebound
                end
                predicates[#predicates + 1] = {
                    filter_id = "coverage:representation:" .. key(representation.id),
                    expression = representation.coverage_predicate,
                    predicate_kind = "COVERAGE",
                }
                partition.where_predicates = predicates
                for _, state_column in ipairs(partition.state_columns or {}) do
                    if state_column.owner then
                        local binding = candidate_binding(candidate, "FACT",
                            state_column.source_fact_id)
                        if binding == nil then
                            return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                                entity_id = entity.id,
                                representation_id = representation.id,
                                fact_id = state_column.source_fact_id,
                            })
                        end
                        state_column.expression = state_expression(state_column,
                            binding.expression, state_column.filter_expression)
                    end
                end
                expanded[#expanded + 1] = partition
                fusion_partitions[#fusion_partitions + 1] = {
                    branch_id = partition.branch_id,
                    entity_id = entity.id,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    coverage_predicate = representation.coverage_predicate,
                    valid_from = representation.valid_from,
                    valid_to = representation.valid_to,
                }
            end
        end
    end
    if #expanded > max_branches then
        return fail("PLANNER_BRANCH_LIMIT_EXCEEDED", {
            branch_count = #expanded,
            branch_limit = max_branches,
        })
    end
    physical_plan.branches = expanded
    physical_plan.safeguards.branch_count = #expanded
    if #fusion_partitions > 0 then
        physical_plan.fusion_plan = {
            fusion_plan_version = 1,
            strategy = "UNION",
            partitions = fusion_partitions,
        }
    end
    return physical_plan, nil
end

local function materialized_column_expression(source_alias, column)
    return tostring(source_alias) .. "." .. quote_ident(column.physical_column)
end

-- Rebind only complete, pre-selected leaf sources. The selector is deliberately
-- separate from physical construction so an ineligible candidate leaves the
-- proven base branch byte-for-byte intact.
function M.apply_branch_sources(physical_plan, selections)
    for _, branch in ipairs(physical_plan.branches or {}) do
        local selected = selections and selections[key(branch.branch_id)]
        if selected ~= nil then
            local candidate = selected.candidate
            local source_alias = "mat_" .. stable_token(candidate.materialization_id)
            branch.source = {
                source_kind = "MATERIALIZATION",
                materialization_id = candidate.materialization_id,
                materialization_name = candidate.materialization_name,
                physical_schema = candidate.physical_schema,
                physical_object = candidate.physical_object,
                extra_dimension_count = selected.extra_dimension_count,
            }
            branch.from_sql = quote_qualified(candidate.physical_schema,
                candidate.physical_object) .. " " .. source_alias
            branch.joins = {}

            local rebound_dimensions = {}
            for _, dimension in ipairs(branch.dimensions or {}) do
                local column = selected.dimension_columns[
                    "DIMENSION:" .. key(dimension.dimension_id)]
                if column == nil then
                    return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                        branch_id = branch.branch_id,
                        dimension_id = dimension.dimension_id,
                    })
                end
                local rebound = {}
                for name, value in pairs(dimension) do rebound[name] = value end
                rebound.expression = materialized_column_expression(source_alias,
                    column)
                rebound.source_column = column.physical_column
                rebound_dimensions[#rebound_dimensions + 1] = rebound
            end
            branch.dimensions = rebound_dimensions

            local rebound_predicates = {}
            for _, predicate in ipairs(branch.where_predicates or {}) do
                local column = selected.dimension_columns[
                    "DIMENSION:" .. key(predicate.dimension_id)]
                if column == nil then
                    return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                        branch_id = branch.branch_id,
                        dimension_id = predicate.dimension_id,
                        binding_kind = "FILTER_DIMENSION",
                    })
                end
                local expression, reason = predicate_sql(predicate, {
                    expression = materialized_column_expression(source_alias,
                        column),
                })
                if expression == nil then
                    return fail("PHYSICAL_FILTER_INVALID", {
                        branch_id = branch.branch_id,
                        dimension_id = predicate.dimension_id,
                        issue = reason,
                    })
                end
                rebound_predicates[#rebound_predicates + 1] = {
                    filter_id = predicate.filter_id,
                    dimension_id = predicate.dimension_id,
                    expression = expression,
                    operator = predicate.operator,
                    value = predicate.value,
                    value_sql = predicate.value_sql,
                    data_type = predicate.data_type,
                }
            end
            branch.where_predicates = rebound_predicates

            for _, state_column in ipairs(branch.state_columns or {}) do
                if state_column.owner then
                    local column = selected.state_columns[key(state_column.state_id)]
                    if column == nil then
                        return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                            branch_id = branch.branch_id,
                            state_id = state_column.state_id,
                            binding_kind = "STATE_COLUMN",
                        })
                    end
                    state_column.expression = "SUM("
                        .. materialized_column_expression(source_alias, column)
                        .. ")"
                    state_column.source_column = column.physical_column
                    state_column.source_rollup_policy = upper(column.rollup_policy)
                end
            end
        end
    end
    return physical_plan, nil
end

function M.check_sql_size(physical_plan, sql_text)
    local actual = #tostring(sql_text or "")
    physical_plan.safeguards.sql_size_bytes = actual
    if actual > physical_plan.safeguards.sql_size_limit then
        return false, {
            reason_code = "PLANNER_SQL_SIZE_LIMIT_EXCEEDED",
            sql_size_bytes = actual,
            sql_size_limit = physical_plan.safeguards.sql_size_limit,
        }
    end
    return true, nil
end

ESV_PHYSICAL_PLAN = M
