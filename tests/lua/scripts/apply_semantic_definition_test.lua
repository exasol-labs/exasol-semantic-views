local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("apply_semantic_definition")

test_script("forwards arguments and result columns", function()
    local supplied = {DEFINITION_SQL = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "apply_semantic_definition", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "STATUS ")
end)
