local api = ESV_MATERIALIZATION_TEST_API

local function install_catalog(candidates, columns)
    query = function(sql)
        if sql:find("MATERIALIZATION_COLUMNS", 1, true) then return columns end
        if sql:find("MATERIALIZATIONS", 1, true) then return candidates end
        error("unexpected query: " .. sql)
    end
end

local ctx = {model = {model_id = 1, version_id = 2}}
local region = {kind = "DIMENSION", id = 10, name = "region"}
local month = {kind = "DIMENSION", id = 11, name = "month"}
local revenue = {kind = "METRIC", id = 20, name = "revenue", metric_type = "ADDITIVE"}
local ratio = {kind = "METRIC", id = 21, name = "ratio", metric_type = "RATIO"}

test("materialization selector chooses exact active coverage", function()
    install_catalog({{1, "sales_by_region", "MART", "SALES_REGION", "AGGREGATE", "ALWAYS", "ACTIVE"}}, {
        {1, "DIMENSION", 10, "REGION", "DIRECT"},
        {1, "METRIC", 20, "REVENUE", "DIRECT"},
    })
    local selected, diagnostics = api.select_materialization(ctx, {region}, {revenue}, {})
    assert_branch("materialization.selected", selected ~= nil, true)
    assert_branch("materialization.rollup", selected.rollup_required, false)
    assert_equal(selected.materialization_name, "sales_by_region")
    assert_equal(diagnostics.candidate_count, 1)
end)

test("materialization selector rejects missing dimensions", function()
    install_catalog({{1, "sales", "MART", "SALES", "AGGREGATE", "ALWAYS", "ACTIVE"}}, {
        {1, "METRIC", 20, "REVENUE", "DIRECT"},
    })
    local selected, diagnostics = api.select_materialization(ctx, {region}, {revenue}, {})
    assert_branch("materialization.selected", selected ~= nil, false)
    assert_equal(diagnostics.rejected_materializations[1].reason_code, "MISSING_DIMENSION")
end)

test("materialization selector requires safe additive rollup", function()
    install_catalog({
        {1, "ratio_by_region_month", "MART", "RATIO", "AGGREGATE", "MANUAL", "ACTIVE"},
        {2, "revenue_by_region_month", "MART", "REV", "AGGREGATE", "SNAPSHOT", "ACTIVE"},
    }, {
        {1, "DIMENSION", 10, "REGION", "DIRECT"}, {1, "DIMENSION", 11, "MONTH", "DIRECT"},
        {1, "METRIC", 21, "RATIO", "SUM"},
        {2, "DIMENSION", 10, "REGION", "DIRECT"}, {2, "DIMENSION", 11, "MONTH", "DIRECT"},
        {2, "METRIC", 20, "REVENUE", "SUM"},
    })
    local rejected = api.select_materialization(ctx, {region}, {ratio}, {})
    assert_true(rejected == nil)
    local selected = api.select_materialization(ctx, {region}, {revenue}, {})
    assert_equal(selected.materialization_name, "revenue_by_region_month")
    assert_branch("materialization.rollup", selected.rollup_required, true)
end)

test("materialization policies reject unknown values", function()
    assert_branch("materialization.freshness", api.supported_freshness("ALWAYS"), true)
    assert_branch("materialization.freshness", api.supported_freshness("STALE_AFTER"), false)
    assert_branch("materialization.rollup_policy", api.allowed_rollup_policy("SUM"), true)
    assert_branch("materialization.rollup_policy", api.allowed_rollup_policy("AVG"), false)
end)

test("materialization selector remains deterministic with a large registry", function()
    local candidates = {}
    for index = 1, 1000 do
        candidates[index] = {index, "candidate_" .. index, "MART", "M" .. index,
            "AGGREGATE", "ALWAYS", index == 1000 and "ACTIVE" or "INACTIVE"}
    end
    install_catalog(candidates, {
        {1000, "DIMENSION", 10, "REGION", "DIRECT"},
        {1000, "METRIC", 20, "REVENUE", "DIRECT"},
    })
    local selected, diagnostics = api.select_materialization(ctx, {region}, {revenue}, {})
    assert_equal(diagnostics.candidate_count, 1000)
    assert_equal(selected.materialization_id, 1000)
end)

local function branch_plan(filtered)
    return {
        dimensions = {{dimension_id = 10}},
        global_filters = {},
        states = {
            {state_id = "state:metric:20", metric_id = 20,
                leaf_entity_id = 1, merge_operator = "SUM",
                filter_expression = filtered and "o.status = 'COMPLETE'" or nil},
            {state_id = "state:metric:22", metric_id = 22,
                leaf_entity_id = 2, merge_operator = "SUM"},
        },
        branches = {
            {branch_id = "branch:1", leaf_entity_id = 1},
            {branch_id = "branch:2", leaf_entity_id = 2},
        },
    }
end

test("D2 selector chooses one complete state source per leaf", function()
    install_catalog({
        {1, "orders_wide", "MART", "ORDERS_WIDE", "AGGREGATE", "ALWAYS", "ACTIVE"},
        {2, "orders_exact", "MART", "ORDERS_EXACT", "AGGREGATE", "ALWAYS", "ACTIVE"},
        {3, "final_ratio_only", "MART", "RATIO", "AGGREGATE", "ALWAYS", "ACTIVE"},
    }, {
        {1, "DIMENSION", 10, "REGION", "DIRECT"},
        {1, "DIMENSION", 11, "MONTH", "DIRECT"},
        {1, "METRIC", 20, "REVENUE_STATE", "SUM"},
        {2, "DIMENSION", 10, "REGION", "DIRECT"},
        {2, "METRIC", 20, "REVENUE_STATE", "SUM"},
        {3, "DIMENSION", 10, "REGION", "DIRECT"},
        {3, "METRIC", 21, "FINAL_RATIO", "SUM"},
    })
    local selected, diagnostics = api.select_branch_sources(ctx, branch_plan(false))
    assert_equal(selected["branch:1"].candidate.materialization_name,
        "orders_exact")
    assert_equal(selected["branch:1"].extra_dimension_count, 0)
    assert_true(selected["branch:2"] == nil)
    assert_equal(diagnostics.branches[2].fallback_reason,
        "NO_ELIGIBLE_MATERIALIZATION")
    assert_equal(diagnostics.branches[2].rejected_materializations[1].reason_code,
        "MISSING_STATE")
    assert_equal(#diagnostics.selected_materializations, 1)
end)

test("D2 selector rejects filtered and unsafe state columns atomically", function()
    install_catalog({
        {1, "orders", "MART", "ORDERS", "AGGREGATE", "ALWAYS", "ACTIVE"},
    }, {
        {1, "DIMENSION", 10, "REGION", "DIRECT"},
        {1, "METRIC", 20, "REVENUE_STATE", "DIRECT"},
    })
    local selected, diagnostics = api.select_branch_sources(ctx, branch_plan(true))
    assert_true(selected["branch:1"] == nil)
    assert_equal(diagnostics.branches[1].rejected_materializations[1].reason_code,
        "FILTERED_STATE_UNSUPPORTED")

    local unfiltered = branch_plan(false)
    selected, diagnostics = api.select_branch_sources(ctx, unfiltered)
    assert_true(selected["branch:1"] == nil)
    assert_equal(diagnostics.branches[1].rejected_materializations[1].reason_code,
        "ROLLUP_POLICY_UNSAFE")
end)

test("F3 partition branches bypass materialization substitution", function()
    install_catalog({
        {1, "orders", "MART", "ORDERS", "AGGREGATE", "ALWAYS", "ACTIVE"},
    }, {
        {1, "DIMENSION", 10, "REGION", "DIRECT"},
        {1, "METRIC", 20, "REVENUE_STATE", "SUM"},
    })
    local plan = branch_plan(false)
    plan.branches[1].source = {source_kind = "REPRESENTATION_PARTITION"}
    local selected, diagnostics = api.select_branch_sources(ctx, plan)
    assert_true(selected["branch:1"] == nil)
    assert_equal(diagnostics.branches[1].candidate_count, 0)
    assert_equal(diagnostics.branches[1].fallback_reason,
        "FUSION_PARTITION_MATERIALIZATION_UNSUPPORTED")
end)
