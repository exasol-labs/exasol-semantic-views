local H = SCRIPT_BODY
local supported = H.supported
test("script harness rejects unexpected calls and keeps imports isolated", function()
    local missing_query = supported()
    assert_error(function()
        H.run("create_model", {MODEL_NAME = "sales", PUBLISHED_SCHEMA = "SEMANTIC_SALES"},
            missing_query)
    end, "unexpected query")
    H.run("compile_request_json", {REQUEST_JSON = "{}"}, {
        imports = {["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_request_json = function() return {status = "OK"} end,
        }},
    })
    assert_error(function() H.run("compile_request_json", {REQUEST_JSON = "{}"}) end,
        "unexpected import")
end)
