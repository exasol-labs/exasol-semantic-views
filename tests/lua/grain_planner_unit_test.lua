local query_spec = ESV_QUERY_SPEC
local snapshots = ESV_CATALOG_SNAPSHOT
local planner = ESV_METRIC_PLAN
local physical_planner = ESV_PHYSICAL_PLAN
local renderer = ESV_GRAIN_SQL

local function base_context()
    local public = {
        id = 10, name = "margin", base_entity_id = 1,
        metric_kind = "RATIO", expression = "profit / revenue",
        data_type = "DECIMAL(18,2)",
        inputs = {
            {role = "NUMERATOR", object_type = "METRIC", object_id = 11},
            {role = "DENOMINATOR", object_type = "METRIC", object_id = 12},
        },
        filters = {},
    }
    local profit = {
        id = 11, name = "profit", base_entity_id = 1,
        aggregation_function = "SUM", expression = "SUM(f.profit)",
        inputs = {{role = "VALUE", object_type = "FACT", object_id = 21}},
        filters = {},
    }
    local revenue = {
        id = 12, name = "revenue", base_entity_id = 1,
        aggregation_function = "SUM", expression = "SUM(f.revenue)",
        inputs = {{role = "VALUE", object_type = "FACT", object_id = 22}},
        filters = {},
    }
    return {
        model = {model_id = 5, version_id = 6, version_number = 2},
        object = {id = 7, name = "sales", root_entity_id = 1},
        entities = {
            {id = 1, name = "orders"},
            {id = 2, name = "customers"},
            {id = 3, name = "regions"},
        },
        dimensions = {{id = 30, name = "region", entity_id = 3}},
        metrics = {public},
        all_metrics = {public, profit, revenue},
        all_metric_by_id = {["10"] = public, ["11"] = profit, ["12"] = revenue},
        facts = {
            {id = 21, name = "profit_fact", entity_id = 1},
            {id = 22, name = "revenue_fact", entity_id = 1},
        },
        relationships = {},
        unique_keys = {},
    }, public
end

local function multi_physical_fixture()
    local ctx, public = base_context()
    ctx.entities[1].source_schema = "MART"
    ctx.entities[1].source_object = "ORDERS"
    ctx.entities[1].alias = "o"
    ctx.entities[2].source_schema = "MART"
    ctx.entities[2].source_object = "TICKETS"
    ctx.entities[2].alias = "t"
    ctx.entities[3].source_schema = "MART"
    ctx.entities[3].source_object = "REGIONS"
    ctx.entities[3].alias = "r"
    ctx.dimensions[1].expression = "r.region_name"
    ctx.dimensions[1].data_type = "VARCHAR(20)"
    ctx.facts[1].expression = "o.profit"
    ctx.facts[1].data_type = "DECIMAL(18,2)"
    ctx.facts[2].entity_id = 2
    ctx.facts[2].expression = "t.revenue"
    ctx.facts[2].data_type = "DECIMAL(18,2)"
    ctx.all_metric_by_id["11"].data_type = "DECIMAL(18,2)"
    ctx.all_metric_by_id["12"].data_type = "DECIMAL(18,2)"
    ctx.all_metric_by_id["11"].filters = {{
        resolved_sql_expr = "o.status = 'CLOSED'",
        required_dimension_id = 30,
        required_entity_id = 3,
    }}
    ctx.all_metric_by_id["11"].inputs[1].filter_expr = "o.channel = 'WEB'"
    ctx.relationships = {
        {
            id = 40, name = "orders_region", from_entity_id = 1, to_entity_id = 3,
            cardinality = "MANY_TO_ONE", join_type = "LEFT",
            join_condition = "o.region_id = r.region_id",
            key_mappings = {{ordinal_position = 1, from_column_name = "region_id",
                to_column_name = "region_id"}},
        },
        {
            id = 41, name = "tickets_region", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE", join_type = "LEFT",
            join_condition = "t.region_id = r.region_id",
            key_mappings = {{ordinal_position = 1, from_column_name = "region_id",
                to_column_name = "region_id"}},
        },
    }
    ctx.unique_keys = {{
        id = 50, entity_id = 3, name = "region_pk",
        columns = {{ordinal_position = 1, column_name = "region_id"}},
    }}
    local snapshot = snapshots.from_context(ctx, {public})
    local spec = assert(query_spec.new({
        model = "sales", object = "sales", metrics = {"margin"},
        dimensions = {"region"},
    }))
    local bound = planner.bind_query(
        spec,
        {ctx.dimensions[1]},
        {public},
        {{field_id = 30, field = "region", entity_id = 3, op = "=",
            value = "West", data_type = "VARCHAR(20)"}},
        {},
        {}
    )
    local logical = assert(planner.logical_plan(spec, snapshot, bound, {public}))
    return snapshot, logical
end

test("QuerySpec canonicalizes both entrypoints without planner state", function()
    local json = assert(query_spec.new({
        model = " sales ", object = "orders", metrics = {"revenue"},
    }, "JSON"))
    local sql = assert(query_spec.new({
        model = "sales", object = "orders", metrics = {"revenue"},
    }, "SEMANTIC_SQL"))
    assert_true(query_spec.equivalent(json, sql))
    assert_equal(json.proof_mode, "LEGACY_JOIN")
    assert_equal(json.query_spec_version, 1)

    local invalid, reason = query_spec.new({metrics = "revenue"}, "JSON")
    assert_equal(invalid, nil)
    assert_equal(reason, "QUERY_SPEC_METRICS_NOT_ARRAY")
    local object_array, object_reason = query_spec.new({metrics = {name = "revenue"}}, "JSON")
    assert_equal(object_array, nil)
    assert_equal(object_reason, "QUERY_SPEC_METRICS_NOT_ARRAY")
    assert_true(not query_spec.equivalent(json, {model = "other"}))
    assert_error(function()
        local cyclic = {}
        cyclic[1] = cyclic
        query_spec.new({metrics = cyclic})
    end, "cycles")
end)

test("CatalogSnapshot includes transitive private metrics and is detached", function()
    local ctx, public = base_context()
    local snapshot = snapshots.from_context(ctx, {public})
    assert_equal(snapshot.version_id, 6)
    assert_equal(#snapshot.visible_metrics, 1)
    assert_equal(#snapshot.metrics, 3)
    assert_equal(snapshot.metrics[1].name, "profit")
    public.name = "changed"
    assert_equal(snapshot.metric_by_id["10"].name, "margin")
    local copied = snapshots.copy(snapshot)
    copied.entities[1].name = "changed"
    assert_equal(snapshot.entities[1].name, "orders")
end)

test("Typed metric DAG classifies aggregate states and orders dependencies", function()
    local ctx, public = base_context()
    local snapshot = snapshots.from_context(ctx, {public})
    local dag = assert(planner.build_dag(snapshot, {public}))
    assert_equal(#dag.nodes, 5)
    assert_equal(dag.node_by_id["11"].state_class, "SUM")
    assert_equal(dag.node_by_id["11"].node_kind, "AGGREGATE_STATE")
    assert_equal(dag.node_by_id["10"].state_class, "RATIO")
    assert_equal(dag.node_by_id["10"].stage, "FINALIZE")
    assert_equal(dag.node_by_id["fact:21"].node_kind, "FACT_INPUT")

    local distinct = {
        id = 99, name = "users", base_entity_id = 1,
        expression = "COUNT(DISTINCT user_id)", inputs = {}, filters = {},
    }
    snapshot.metrics[#snapshot.metrics + 1] = distinct
    snapshot.metric_by_id["99"] = distinct
    local distinct_dag = assert(planner.build_dag(snapshot, {distinct}))
    assert_equal(distinct_dag.nodes[1].state_class, "UNSUPPORTED_DISTINCT")

    local broken = {
        id = 100, name = "broken", base_entity_id = 1, expression = "x",
        inputs = {{object_type = "METRIC", object_id = 404}}, filters = {},
    }
    snapshot.metric_by_id["100"] = broken
    local missing, reason = planner.build_dag(snapshot, {broken})
    assert_equal(missing, nil)
    assert_equal(reason, "MISSING_PRIVATE_METRIC_DEPENDENCY")
end)

test("Strict proof requires column mapping and target uniqueness", function()
    local ctx = base_context()
    ctx.relationships = {{
        id = 40, name = "orders_customer", from_entity_id = 1, to_entity_id = 2,
        cardinality = "MANY_TO_ONE",
        key_mappings = {{
            ordinal_position = 1, from_column_name = "customer_id",
            to_column_name = "customer_id",
        }},
    }}
    ctx.unique_keys = {{
        id = 50, entity_id = 2, name = "customer_pk", kind = "PRIMARY",
        columns = {{ordinal_position = 1, column_name = "customer_id"}},
    }}
    local snapshot = snapshots.from_context(ctx, {})
    local proof = planner.prove(snapshot, 1, 2, "STRICT_GRAIN")
    assert_equal(proof.status, "PROVEN")
    assert_equal(proof.edges[1].unique_key_id, 50)
    assert_equal(proof.edges[1].mapping_ordinals[1], 1)

    snapshot.relationships[1].key_mappings = {}
    local missing = planner.prove(snapshot, 1, 2, "STRICT_GRAIN")
    assert_equal(missing.status, "REJECTED")
    assert_equal(missing.rejected_edges[1].reason, "MISSING_RELATIONSHIP_KEY_MAPPING")

    snapshot.relationships[1].key_mappings = {{
        ordinal_position = 1, from_expression = "LOWER(customer_id)",
        to_column_name = "customer_id",
    }}
    local expression = planner.prove(snapshot, 1, 2, "STRICT_GRAIN")
    assert_equal(expression.rejected_edges[1].reason, "EXPRESSION_KEY_PROOF_UNSUPPORTED")

    snapshot.relationships[1].key_mappings = {{
        ordinal_position = 1, from_column_name = "customer_id",
        to_column_name = "customer_id",
    }}
    snapshot.unique_keys[1].columns = {{
        ordinal_position = 1, expression = "LOWER(c.customer_id)",
    }}
    local expression_key = planner.prove(snapshot, 1, 2, "STRICT_GRAIN")
    assert_equal(expression_key.rejected_edges[1].reason,
        "EXPRESSION_KEY_PROOF_UNSUPPORTED")
end)

test("Strict proof rejects many to many and unequal alternative paths", function()
    local ctx = base_context()
    local function relationship(id, name, from_id, to_id)
        return {
            id = id, name = name, from_entity_id = from_id, to_entity_id = to_id,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{
                ordinal_position = 1, from_column_name = "id", to_column_name = "id",
            }},
        }
    end
    ctx.entities[#ctx.entities + 1] = {id = 4, name = "countries"}
    ctx.relationships = {
        relationship(1, "direct", 1, 3),
        relationship(2, "via_customer", 1, 2),
        relationship(3, "via_region", 2, 3),
        {
            id = 4, name = "bridge", from_entity_id = 3, to_entity_id = 4,
            cardinality = "MANY_TO_MANY", fanout_policy = "ALLOCATE",
            key_mappings = {},
        },
    }
    ctx.unique_keys = {
        {id = 12, entity_id = 2, columns = {{ordinal_position = 1, column_name = "id"}}},
        {id = 13, entity_id = 3, columns = {{ordinal_position = 1, column_name = "id"}}},
    }
    local snapshot = snapshots.from_context(ctx, {})
    local ambiguous = planner.prove(snapshot, 1, 3, "STRICT_GRAIN")
    assert_equal(ambiguous.status, "REJECTED")
    assert_equal(ambiguous.reason, "AMBIGUOUS_RELATIONSHIP_PATH")
    assert_equal(#ambiguous.candidate_paths, 2)
    local _, rejected = planner.strict_edges(snapshot)
    assert_equal(rejected[#rejected].reason, "MANY_TO_MANY_PROOF_UNSUPPORTED")
end)

test("C1 logical planner emits a planning-only multi branch plan", function()
    local ctx, public = base_context()
    ctx.facts[2].entity_id = 2
    local snapshot = snapshots.from_context(ctx, {public})
    local spec = assert(query_spec.new({
        model = "sales", object = "sales", metrics = {"margin"},
    }))
    local plan, reason = planner.logical_plan(spec, snapshot, {}, {public}, {})
    assert_equal(reason, nil)
    assert_equal(plan.plan_version, 6)
    assert_equal(plan.plan_kind, "MULTI_BRANCH")
    assert_equal(plan.proof_mode, "STRICT_GRAIN")
    assert_equal(plan.execution.status, "PLANNING_ONLY")
    assert_equal(plan.execution.reason_code, "MULTI_BRANCH_EXECUTION_NOT_ENABLED")
    assert_equal(#plan.branches, 2)
    assert_equal(plan.diagnostics[1].reason_code, "BASE_ENTITY_MISMATCH")
end)

test("C1 structured inputs are authoritative and dependencies are deduplicated", function()
    local ctx, public = base_context()
    local profit = ctx.all_metric_by_id["11"]
    profit.dependencies = {
        {object_type = "FACT", object_id = 22},
        {object_type = "FACT", object_id = 22},
    }
    local snapshot = snapshots.from_context(ctx, {public})
    local dag = assert(planner.build_dag(snapshot, {public}))
    assert_equal(dag.node_by_id["11"].input_source, "STRUCTURED_INPUTS")
    assert_equal(#dag.node_by_id["11"].inputs, 1)
    assert_equal(dag.node_by_id["11"].inputs[1].id, 21)

    local fallback = snapshot.metric_by_id["12"]
    fallback.inputs = {}
    fallback.dependencies = {
        {object_type = "FACT", object_id = 22},
        {object_type = "FACT", object_id = 22},
    }
    local fallback_dag = assert(planner.build_dag(snapshot, {fallback}))
    assert_equal(fallback_dag.node_by_id["12"].input_source, "DEPENDENCY_FALLBACK")
    assert_equal(#fallback_dag.node_by_id["12"].inputs, 1)
end)

test("C1 binds global and final filters without rendering them", function()
    local spec = assert(query_spec.new({
        model = "sales",
        object = "sales",
        metrics = {"margin"},
        dimensions = {"region"},
        order_by = {{field = "margin", direction = "DESC"}},
        limit = 10,
    }))
    local bound = planner.bind_query(
        spec,
        {{id = 30, name = "region", kind = "DIMENSION", entity_id = 3,
            data_type = "VARCHAR(20)"}},
        {{id = 10, name = "margin", kind = "METRIC", data_type = "DECIMAL(18,2)"}},
        {{field_id = 30, field = "region", entity_id = 3, op = "=",
            value = "West", data_type = "VARCHAR(20)", predicate = "ignored"}},
        {{metric_id = 10, metric = "margin", op = ">", value = 0.2,
            data_type = "DECIMAL(18,2)", predicate = "ignored"}},
        {{target_entity_id = 3}}
    )
    assert_equal(bound.bound_query_version, 1)
    assert_equal(bound.global_filters[1].scope, "GLOBAL")
    assert_equal(bound.global_filters[1].entity_id, 3)
    assert_equal(bound.having_filters[1].scope, "HAVING")
    assert_equal(bound.having_filters[1].metric_id, 10)
    assert_equal(bound.limit, 10)
    assert_equal(bound.relationship_targets[1].target_entity_id, 3)
end)

test("C1 proves every fact branch to every requested dimension", function()
    local ctx, public = base_context()
    ctx.facts[2].entity_id = 2
    ctx.all_metric_by_id["12"].filters = {{
        resolved_sql_expr = "t.priority = 'URGENT'",
        required_dimension_id = null,
        required_entity_id = null,
    }}
    ctx.relationships = {
        {
            id = 40, name = "orders_region", from_entity_id = 1, to_entity_id = 3,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{ordinal_position = 1, from_column_name = "region_id",
                to_column_name = "region_id"}},
        },
        {
            id = 41, name = "customers_region", from_entity_id = 2, to_entity_id = 3,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{ordinal_position = 1, from_column_name = "region_id",
                to_column_name = "region_id"}},
        },
    }
    ctx.unique_keys = {{
        id = 50, entity_id = 3, name = "region_pk",
        columns = {{ordinal_position = 1, column_name = "region_id"}},
    }}
    local snapshot = snapshots.from_context(ctx, {public})
    local spec = assert(query_spec.new({
        model = "sales", object = "sales", metrics = {"margin"},
        dimensions = {"region"},
    }))
    local bound = planner.bind_query(spec, {ctx.dimensions[1]}, {public}, {}, {}, {})
    local plan = assert(planner.logical_plan(spec, snapshot, bound, {public}))
    assert_equal(plan.plan_kind, "MULTI_BRANCH")
    assert_equal(#plan.relationship_proofs, 2)
    assert_equal(#plan.branches[2].requirements, 1)
    assert_equal(plan.relationship_proofs[1].status, "PROVEN")
    assert_equal(plan.relationship_proofs[2].status, "PROVEN")
    assert_equal(plan.relationship_proofs[1].requirement.scope, "SELECTED")
    assert_true(string.match(plan.relationship_proofs[1].proof_id,
        "^proof:branch:") ~= nil)
    assert_true(string.match(
        plan.relationship_proofs[1].requirement.requirement_id,
        "^branch:") ~= nil)
    assert_equal(plan.relationship_proofs[1].target_unique_key_id, 50)
    assert_equal(plan.execution.reason_code, "MULTI_BRANCH_EXECUTION_NOT_ENABLED")
end)

test("C1 reports the path-specific blocking edge", function()
    local ctx = base_context()
    ctx.relationships = {{
        id = 60, name = "order_items", from_entity_id = 1, to_entity_id = 2,
        cardinality = "ONE_TO_MANY",
        key_mappings = {{ordinal_position = 1, from_column_name = "order_id",
            to_column_name = "order_id"}},
    }}
    ctx.unique_keys = {{
        id = 61, entity_id = 1,
        columns = {{ordinal_position = 1, column_name = "order_id"}},
    }}
    local snapshot = snapshots.from_context(ctx, {})
    local proof = planner.prove_strict(snapshot, 1, 2)
    assert_equal(proof.status, "REJECTED")
    assert_equal(proof.reason_code, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
    assert_equal(proof.blocking_edge.relationship_id, 60)
    assert_equal(proof.blocking_edge.from_entity_id, 1)
    assert_equal(proof.blocking_edge.to_entity_id, 2)
end)

test("C2 physical planner binds one typed state branch per leaf", function()
    local snapshot, logical = multi_physical_fixture()
    local physical, physical_error = physical_planner.build(logical, snapshot)
    assert_true(physical ~= nil, physical_error and physical_error.reason_code)
    assert_equal(physical.physical_plan_version, 3)
    assert_equal(physical.plan_kind, "MULTI_BRANCH_QUERY")
    assert_equal(#physical.branches, 2)
    assert_equal(#physical.states, 2)
    assert_equal(physical.states[1].state_id, "state:metric:11")
    assert_equal(physical.states[1].ordinal, 1)
    assert_equal(physical.states[1].placeholder_expression,
        "CAST(NULL AS DECIMAL(18,2))")
    assert_equal(physical.branches[1].cte_id, "cte:branch:1")
    assert_equal(physical.branches[1].source.source_kind, "BASE")
    assert_equal(physical.branches[1].source.entity_id, 1)
    assert_equal(physical.branches[1].source.physical_object, "ORDERS")
    assert_equal(#physical.branches[1].joins, 1)
    assert_equal(physical.branches[1].joins[1].relationship_id, 40)
    assert_equal(physical.branches[1].state_columns[1].owner, true)
    assert_contains(physical.branches[1].state_columns[1].expression,
        "o.status = 'CLOSED' AND o.channel = 'WEB'")
    assert_equal(physical.branches[1].state_columns[2].owner, false)
    assert_equal(physical.branches[1].where_predicates[1].expression,
        "UPPER(r.region_name) = UPPER('West')")
    assert_equal(physical.merge.group_dimension_ids[1], 30)
    assert_equal(physical.merge.state_ids[2], "state:metric:12")
    assert_equal(#physical.finalization.layers, 1)
    assert_equal(physical.finalization.layers[1].metric_column.metric_id, 10)
    assert_contains(physical.finalization.layers[1].metric_column.expression,
        'p."__esv_m_11"')

    local sql = renderer.render_multi_branch(physical)
    assert_contains(sql, '"__esv_b_1" AS (')
    assert_contains(sql, "LEFT JOIN \"MART\".\"REGIONS\" r")
    assert_contains(sql, "CAST(NULL AS DECIMAL(18,2)) AS \"__esv_s_12\"")
    assert_contains(sql, "UNION ALL")
    assert_contains(sql, 'SUM("__esv_s_11") AS "__esv_s_11"')
    assert_contains(sql, 'GROUP BY "__esv_d_30"')
    assert_contains(sql, '"__esv_metrics_0" AS (')
    assert_contains(sql, 'AS "__esv_m_10"')
    assert_contains(sql, 'f."__esv_d_30" AS "region"')
    assert_contains(sql, 'f."__esv_m_10" AS "margin"')

    local within_limit = physical_planner.check_sql_size(physical, sql)
    assert_equal(within_limit, true)
    assert_equal(physical.safeguards.sql_size_bytes, #sql)
    physical.safeguards.sql_size_limit = 1
    local too_large, size_error = physical_planner.check_sql_size(physical, sql)
    assert_equal(too_large, false)
    assert_equal(size_error.reason_code, "PLANNER_SQL_SIZE_LIMIT_EXCEEDED")
end)

test("C3 finalization applies empty states having ordering and limit last", function()
    local snapshot, logical = multi_physical_fixture()
    for _, node in ipairs(logical.metric_stages) do
        if node.metric_id == 12 then
            node.state_spec.state_kind = "COUNT"
            node.state_spec.empty_behavior = "ZERO"
        end
    end
    logical.bound_query.having_filters = {{
        metric_id = 10,
        metric = "margin",
        operator = ">",
        value = 0.5,
        data_type = "DECIMAL(18,2)",
    }}
    local physical = assert(physical_planner.build(logical, snapshot, {
        output_order_by = {'"margin" DESC'},
        limit = 5,
    }))
    assert_equal(physical.states[2].empty_behavior, "ZERO")
    assert_contains(physical.finalization.base.metric_columns[2].expression,
        "COALESCE(")
    assert_equal(physical.finalization.having_predicates[1].metric_id, 10)
    local sql = renderer.render_multi_branch(physical)
    assert_contains(sql, 'WHERE f."__esv_m_10" > 0.5')
    assert_contains(sql, 'ORDER BY "margin" DESC')
    assert_contains(sql, "LIMIT 5")
    assert_true(string.find(sql, "WHERE f.", 1, true)
        > string.find(sql, '"__esv_metrics_1" AS', 1, true))
end)

test("C3 finalization resolves structured metric input aliases", function()
    local snapshot, logical = multi_physical_fixture()
    for _, node in ipairs(logical.metric_stages) do
        if node.metric_id == 10 then
            node.expression = "numerator / denominator"
            node.inputs[1].expression_alias = "numerator"
            node.inputs[2].expression_alias = "denominator"
        end
    end
    local physical = assert(physical_planner.build(logical, snapshot))
    local expression = physical.finalization.layers[1].metric_column.expression
    assert_contains(expression, 'p."__esv_m_11"')
    assert_contains(expression, 'p."__esv_m_12"')
    assert_true(string.find(expression, "numerator", 1, true) == nil)
end)

test("C2 physical planner validates boundaries and safeguards", function()
    local snapshot, logical = multi_physical_fixture()
    local missing, reason = physical_planner.build({plan_kind = "SINGLE_BRANCH"},
        snapshot)
    assert_equal(missing, nil)
    assert_equal(reason.reason_code, "PHYSICAL_MULTI_BRANCH_PLAN_REQUIRED")

    local failed_logical = snapshots.copy(logical)
    failed_logical.failure = {reason_code = "DIMENSION_NOT_CONFORMED"}
    missing, reason = physical_planner.build(failed_logical, snapshot)
    assert_equal(reason.reason_code, "LOGICAL_PLAN_NOT_VALID")

    missing, reason = physical_planner.build(logical, snapshot, {max_branches = 1})
    assert_equal(reason.reason_code, "PLANNER_BRANCH_LIMIT_EXCEEDED")
    assert_equal(reason.branch_count, 2)

    local missing_source = snapshots.copy(snapshot)
    missing_source.entity_by_id["1"].source_schema = nil
    missing, reason = physical_planner.build(logical, missing_source)
    assert_equal(reason.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(reason.binding_kind, "SOURCE")

    local missing_dimension = snapshots.copy(snapshot)
    missing_dimension.dimension_by_id["30"].expression = nil
    missing, reason = physical_planner.build(logical, missing_dimension)
    assert_equal(reason.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(reason.binding_kind, "DIMENSION_EXPRESSION")

    local missing_type = snapshots.copy(logical)
    missing_type.metric_stages[2].state_spec.data_type = nil
    missing, reason = physical_planner.build(missing_type, snapshot)
    assert_equal(reason.reason_code, "METRIC_STATE_TYPE_INCOMPATIBLE")

    local missing_fact = snapshots.copy(snapshot)
    missing_fact.fact_by_id["21"].expression = nil
    missing, reason = physical_planner.build(logical, missing_fact)
    assert_equal(reason.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(reason.binding_kind, "FACT_EXPRESSION")

    local ambiguous_input = snapshots.copy(logical)
    local aggregate = nil
    for _, node in ipairs(ambiguous_input.metric_stages) do
        if node.node_kind == "AGGREGATE_STATE" then aggregate = node break end
    end
    aggregate.inputs[#aggregate.inputs + 1] = {
        kind = "FACT", id = 22, entity_id = 2,
    }
    missing, reason = physical_planner.build(ambiguous_input, snapshot)
    assert_equal(reason.reason_code, "METRIC_INPUT_GRAIN_AMBIGUOUS")

    local missing_owner = snapshots.copy(logical)
    table.remove(missing_owner.branches, 2)
    missing, reason = physical_planner.build(missing_owner, snapshot)
    assert_equal(reason.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(reason.binding_kind, "STATE_OWNER")
end)

test("C2 physical planner keeps a deterministic three leaf layout", function()
    local snapshot, logical = multi_physical_fixture()
    local entity = {
        id = 4, name = "shipments", source_schema = "MART",
        source_object = "SHIPMENTS", alias = "s",
    }
    local fact = {
        id = 23, name = "shipment_fact", entity_id = 4,
        expression = "s.shipment_value", data_type = "DECIMAL(18,2)",
    }
    local relationship = {
        id = 42, name = "shipments_region", from_entity_id = 4, to_entity_id = 3,
        cardinality = "MANY_TO_ONE", join_type = "LEFT",
        join_condition = "s.region_id = r.region_id",
        key_mappings = {{ordinal_position = 1, from_column_name = "region_id",
            to_column_name = "region_id"}},
    }
    snapshot.entities[#snapshot.entities + 1] = entity
    snapshot.entity_by_id["4"] = entity
    snapshot.facts[#snapshot.facts + 1] = fact
    snapshot.fact_by_id["23"] = fact
    snapshot.relationships[#snapshot.relationships + 1] = relationship
    snapshot.relationship_by_id["42"] = relationship
    logical.metric_stages[#logical.metric_stages + 1] = {
        node_id = "metric:13",
        node_kind = "AGGREGATE_STATE",
        metric_id = 13,
        name = "shipment_value",
        leaf_entity_ids = {4},
        inputs = {{kind = "FACT", id = 23, entity_id = 4}},
        local_filters = {},
        state_spec = {
            state_kind = "SUM", merge_operator = "SUM",
            data_type = "DECIMAL(18,2)", empty_behavior = "NULL",
        },
    }
    logical.branches[#logical.branches + 1] = {
        branch_id = "branch:4",
        leaf_entity_id = 4,
        state_node_ids = {"metric:13"},
        requirements = {},
        proofs = {{
            proof_id = "proof:branch:4:region",
            status = "PROVEN",
            edges = {{
                relationship_id = 42,
                from_entity_id = 4,
                to_entity_id = 3,
                unique_key_id = 50,
            }},
        }},
    }
    local physical = assert(physical_planner.build(logical, snapshot))
    assert_equal(#physical.branches, 3)
    assert_equal(#physical.states, 3)
    assert_equal(physical.branches[3].branch_id, "branch:4")
    assert_equal(physical.branches[3].state_columns[3].owner, true)
    assert_equal(physical.safeguards.branch_count, 3)
end)

test("C2 physical planner binds filter variants and rejects broken proofs", function()
    local snapshot, logical = multi_physical_fixture()
    local variants = {
        {operator = "IN", value = {"West", "East"},
            expected = "UPPER(r.region_name) IN (UPPER('West'), UPPER('East'))"},
        {operator = "BETWEEN", value = {"A", "Z"},
            expected = "r.region_name BETWEEN 'A' AND 'Z'"},
        {operator = "IS NULL", value = nil,
            expected = "r.region_name IS NULL"},
    }
    for _, variant in ipairs(variants) do
        local candidate = snapshots.copy(logical)
        local filter = candidate.bound_query.global_filters[1]
        filter.operator = variant.operator
        filter.value = variant.value
        local physical, physical_error = physical_planner.build(candidate, snapshot)
        assert_true(physical ~= nil, physical_error and physical_error.reason_code)
        assert_equal(physical.branches[1].where_predicates[1].expression,
            variant.expected)
    end

    local invalid_filter = snapshots.copy(logical)
    invalid_filter.bound_query.global_filters[1].operator = "REGEXP"
    local missing, reason = physical_planner.build(invalid_filter, snapshot)
    assert_equal(reason.reason_code, "PHYSICAL_FILTER_INVALID")
    assert_equal(reason.issue, "FILTER_OPERATOR_UNSUPPORTED")

    local missing_relationship = snapshots.copy(snapshot)
    missing_relationship.relationship_by_id["40"] = nil
    missing, reason = physical_planner.build(logical, missing_relationship)
    assert_equal(reason.reason_code, "PHYSICAL_PROOF_INVALID")
    assert_equal(reason.issue, "REFERENCE_MISSING")

    local disconnected = snapshots.copy(logical)
    disconnected.branches[1].proofs[1].edges[1].from_entity_id = 999
    missing, reason = physical_planner.build(disconnected, snapshot)
    assert_equal(reason.reason_code, "PHYSICAL_PROOF_INVALID")
    assert_equal(reason.issue, "PATH_DISCONNECTED")

    local missing_join = snapshots.copy(snapshot)
    missing_join.relationship_by_id["40"].join_condition = nil
    missing, reason = physical_planner.build(logical, missing_join)
    assert_equal(reason.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(reason.binding_kind, "RELATIONSHIP_JOIN")
end)

test("Separated renderer preserves legacy single branch SQL shape", function()
    local sql = renderer.render_single_branch({
        select_parts = {"c.region AS \"region\"", "SUM(o.amount) AS \"revenue\""},
        from_sql = '"SALES"."ORDERS" o',
        join_sql = {'LEFT JOIN "SALES"."CUSTOMERS" c ON o.customer_id = c.customer_id'},
        where_predicates = {"o.status = 'DONE'"},
        group_parts = {"c.region"},
        having_predicates = {"SUM(o.amount) > 10"},
        order_by = {'"revenue" DESC'},
        limit = 5,
    })
    assert_contains(sql, "SELECT c.region")
    assert_contains(sql, "LEFT JOIN")
    assert_contains(sql, "GROUP BY c.region")
    assert_contains(sql, "LIMIT 5")
end)
