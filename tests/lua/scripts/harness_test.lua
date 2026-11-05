local H = SCRIPT_BODY
local supported = H.supported
local run_create_model = H.for_script("create_model")
local run_compile_request_json = H.for_script("compile_request_json")
test("script harness rejects unexpected queries", function()
    local missing_query = supported()
    assert_error(function()
        run_create_model({MODEL_NAME = "sales", PUBLISHED_SCHEMA = "SEMANTIC_SALES"},
            missing_query)
    end, "unexpected query")
end)

test("script harness isolates imports from the global environment", function()
    run_compile_request_json({REQUEST_JSON = "{}"}, {
        imports = {["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_request_json = function() return {status = "OK"} end,
        }},
    })
    assert_equal(rawget(_G, "compiler"), nil)
end)

test("script harness rejects unexpected imports", function()
    assert_error(function() run_compile_request_json({REQUEST_JSON = "{}"}) end,
        "unexpected import")
end)
