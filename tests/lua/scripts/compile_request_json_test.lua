local H = SCRIPT_BODY
local run = H.for_script("compile_request_json")
test("script body: compile_request_json maps the compiler envelope and columns", function()
    local request = '{"model":"sales"}'
    local result = run({REQUEST_JSON = request}, {
        imports = { ["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_request_json = function(value)
                assert_equal(value, request)
                return {status = "OK", generated_sql = "SELECT 1", validation_run_id = 7}
            end,
        }},
    })
    H.same(result.rows[1], {"OK", null, null, null, "SELECT 1", null, null, 7, null}, "compile row")
    assert_contains(result.columns, "AGENT_REQUEST_ID DECIMAL")
    assert_equal(result.imports[1][2], "compiler")
end)

test("script body: compile_request_json retains a refusal", function()
    local result = run({REQUEST_JSON = null}, {
        imports = { ["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_request_json = function(value)
                assert_equal(value, null)
                return {status = "ERROR", error_code = "SEMANTIC_QUERY_001", error_message = "invalid"}
            end,
        }},
    })
    assert_equal(result.rows[1][2], "SEMANTIC_QUERY_001")
end)
