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
