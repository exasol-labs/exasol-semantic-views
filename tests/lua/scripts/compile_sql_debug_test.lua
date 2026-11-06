local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("compile_sql_debug")

test_script("ends the result with the query log id", function()
    local supplied = {ORIGINAL_SQL = "SELECT revenue FROM SEMANTIC_SALES.ORDERS", CLIENT_NAME = "unit"}
    local fixture = delegate("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compile_sql_debug", supplied,
        {status = "OK", generated_sql = "SELECT 1", query_log_id = 91})
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][9], 91)
    assert_contains(result.columns, "QUERY_LOG_ID DECIMAL")
end)
