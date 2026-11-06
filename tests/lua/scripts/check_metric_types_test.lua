local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("check_metric_types")

test_script("preserves an incompatible compiled type", function()
    local supplied = {MODEL_NAME = "sales"}
    local metric = {object = "orders", metric = "revenue", declared_type = "DECIMAL(18,2)",
        compiled_type = "DOUBLE", compatible = false}
    local fixture = delegate("SEMANTIC_ADMIN.COMPILER_RUNTIME", "metric_result_types", supplied, {metric})
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][4], "DOUBLE")
    assert_equal(result.rows[1][5], false)
    assert_contains(result.columns, "COMPATIBLE BOOLEAN")
end)
