local H = SCRIPT_BODY
local run, test_script = H.for_script("add_metric")
local step = H.step
local supported = H.supported

local metric_args = {MODEL_NAME = "sales", OBJECT_NAME = "orders", METRIC_NAME = "revenue",
    EXPRESSION = "SUM(o.amount)", METRIC_TYPE = "ADDITIVE", BASE_ENTITY_NAME = "orders",
    DATA_TYPE = "DECIMAL(18,2)"}
local function metric_steps(validation_rows)
    return {
        step("FROM SYS_SEMANTIC.MODELS", {{11, 12}}),
        step("SELECT OBJECT_ID", {{21}}),
        step("SELECT ENTITY_ID", {{31}}),
        step("FROM SYS_SEMANTIC.METRICS", {{0}}),
        step("FROM SYS_SEMANTIC.OBJECT_COLUMNS", {{0}}),
        step("INSERT INTO SYS_SEMANTIC.METRICS"),
        step("SELECT METRIC_ID", {{41}}),
        step("FROM SYS_SEMANTIC.OBJECT_COLUMNS", {{0}}),
        step("SELECT COALESCE(MAX(ORDINAL_POSITION)", {{1}}),
        step("INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS"),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", validation_rows),
    }
end
test_script("rolls back a failed validation", function()
    local steps = metric_steps({{"ERROR", "METRIC", "revenue", "SEMANTIC_MODEL_073", "bad type"}})
    steps[#steps + 1] = step("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS")
    steps[#steps + 1] = step("DELETE FROM SYS_SEMANTIC.METRICS")
    steps[#steps + 1] = step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL")
    local fixture = supported(steps)
    fixture.error = "SEMANTIC_ADMIN_090: metric rejected"
    local result = run(metric_args, fixture)
    assert_equal(result.calls[12].bindings.metric_id, 41)
end)

test_script("requires an expression", function()
    local fixture = supported()
    fixture.error = "EXPRESSION is required"
    run({EXPRESSION = null, DATA_TYPE = "DECIMAL"},
        fixture)
end)

test_script("registers a valid metric", function()
    local fixture = supported(metric_steps({}))
    local supplied = {}
    for key, value in pairs(metric_args) do supplied[key] = value end
    supplied.IS_CERTIFIED = "true"
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], 41)
    assert_equal(result.rows[1][7], true)
    assert_equal(result.calls[6].bindings.is_certified, true)
end)
