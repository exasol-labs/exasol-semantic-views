local query_spec = ESV_QUERY_SPEC
local snapshots = ESV_CATALOG_SNAPSHOT
local planner = ESV_METRIC_PLAN
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
    assert_equal(#dag.nodes, 3)
    assert_equal(dag.nodes[1].state_class, "SUM")
    assert_equal(dag.nodes[3].state_class, "RATIO")
    assert_equal(dag.nodes[3].stage, "FINALIZE")

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

test("Logical planner blocks multi fact execution before Phase C", function()
    local ctx, public = base_context()
    ctx.facts[2].entity_id = 2
    local snapshot = snapshots.from_context(ctx, {public})
    local spec = assert(query_spec.new({
        model = "sales", object = "sales", metrics = {"margin"},
    }))
    local plan, reason = planner.logical_plan(spec, snapshot, {}, {public}, {})
    assert_equal(plan, nil)
    assert_equal(reason, "MULTI_FACT_NOT_ENABLED")
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
