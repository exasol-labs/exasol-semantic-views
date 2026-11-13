local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("adopt_view")

test_script("forwards arguments and result columns", function()
    local supplied = {MODEL_NAME = "finance", VIEW_SCHEMA = "MART_SEMANTIC", VIEW_NAME = "PNL"}
    local fixture = delegate("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "adopt_view", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "DDL VARCHAR")
end)
