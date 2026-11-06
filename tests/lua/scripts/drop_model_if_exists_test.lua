local H = SCRIPT_BODY
local run, test_script = H.for_script("drop_model_if_exists")

test_script("reports NOT_FOUND without calling DROP_MODEL", function()
    local fixture = H.supported({
        H.step("SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS", {{0}}, {model_name = "sales"}),
    })
    local result = run({MODEL_NAME = " sales "}, fixture)
    H.same(result.rows[1], {"sales", null, false, "NOT_FOUND"}, "drop result")
    assert_contains(result.columns, "SCHEMA_DROPPED BOOLEAN")
end)
