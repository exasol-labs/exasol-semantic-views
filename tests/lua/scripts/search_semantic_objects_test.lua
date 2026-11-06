local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("search_semantic_objects")

test_script("forwards arguments and result columns", function()
    local supplied = {QUERY_TEXT = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "search_semantic_objects", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "RESULT_TYPE ")
end)
