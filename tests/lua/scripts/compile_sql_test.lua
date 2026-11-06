local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("compile_sql")

test_script("returns original SQL and compiled SQL in named columns", function()
    local supplied = {ORIGINAL_SQL = "SELECT revenue FROM SEMANTIC_SALES.ORDERS"}
    local fixture = delegate("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compile_sql", supplied,
        {status = "OK", generated_sql = "SELECT 1", validation_run_id = 7})
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][4], supplied.ORIGINAL_SQL)
    assert_equal(result.rows[1][5], "SELECT 1")
    assert_contains(result.columns, "AGENT_REQUEST_ID DECIMAL")
end)
