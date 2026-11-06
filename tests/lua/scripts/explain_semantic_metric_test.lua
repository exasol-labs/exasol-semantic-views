local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("explain_semantic_metric")

test_script("forwards arguments and result columns", function()
    local supplied = {MODEL_NAME = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "explain_semantic_metric", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "SECTION_NAME ")
end)
