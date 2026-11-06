local H = SCRIPT_BODY
local run, test_script = H.for_script("sync_frozen_views")

test_script("returns no actions when the model has no frozen views", function()
    local fixture = H.supported({
        H.step("FROM SYS_SEMANTIC.FROZEN_VIEWS", {}, {model_name = "sales"}),
    })
    local result = run({MODEL_NAME = "sales"}, fixture)
    assert_equal(#result.rows, 0)
    assert_contains(result.columns, "OUTCOME VARCHAR")
end)
