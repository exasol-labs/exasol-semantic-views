local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("apply_normalized_osi_import")

test_script("forwards arguments and result columns", function()
    local supplied = {PLAN_JSON = "{}"}
    local fixture = delegate("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "apply_normalized_osi_import", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "STATUS ")
end)
