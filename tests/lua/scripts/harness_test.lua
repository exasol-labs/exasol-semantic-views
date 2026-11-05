local H = SCRIPT_BODY
local supported = H.supported
test("script harness rejects unexpected queries", function()
    local missing_query = supported()
    assert_error(function()
        H.run("create_model", {MODEL_NAME = "sales", PUBLISHED_SCHEMA = "SEMANTIC_SALES"},
            missing_query)
    end, "unexpected query")
end)

test("script harness isolates imports from the global environment", function()
    H.run("compile_request_json", {REQUEST_JSON = "{}"}, {
        imports = {["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_request_json = function() return {status = "OK"} end,
        }},
    })
    assert_equal(rawget(_G, "compiler"), nil)
end)

test("script harness rejects unexpected imports", function()
    assert_error(function() H.run("compile_request_json", {REQUEST_JSON = "{}"}) end,
        "unexpected import")
end)
