local H = SCRIPT_BODY
local step = H.step
test("script body: call_admin_json uses signature order and escapes strings", function()
    local definition = "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"
    local fixture = {imports = {[definition] = {
        decode_json = function() return {MODEL_NAME = "O'Brien"} end,
        encode_json = function() return "[]" end,
    }}, sql = {
        step("FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS", {
            {1, "MODEL_NAME", 1, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL(MODEL_NAME)"},
        }, {script_name = "DROP_MODEL"}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('O''Brien')", {}),
    }}
    local result = H.run("call_admin_json", {SCRIPT_NAME = "drop_model", ARGS_JSON = "{}"}, fixture)
    assert_equal(result.rows[1][3], 0)
    H.run("call_admin_json", {SCRIPT_NAME = "CALL_ADMIN_JSON"},
        {imports = fixture.imports, error = "cannot call itself"})
end)

test("script body: call_admin_json rejects unknown named arguments", function()
    local definition = "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"
    H.run("call_admin_json", {SCRIPT_NAME = "drop_model", ARGS_JSON = "{}"}, {
        imports = {[definition] = {decode_json = function() return {UNKNOWN = 1} end}},
        sql = {step("FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS", {
            {1, "MODEL_NAME", 1, "DROP_MODEL(MODEL_NAME)"},
        })},
        error = "unknown parameter(s) for DROP_MODEL: UNKNOWN",
    })
end)
