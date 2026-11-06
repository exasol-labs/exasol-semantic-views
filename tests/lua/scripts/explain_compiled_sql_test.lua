local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("explain_compiled_sql")

test_script("forwards arguments and result columns", function()
    local supplied = {HANDLE_TYPE = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "explain_compiled_sql", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "HANDLE_TYPE ")
end)
