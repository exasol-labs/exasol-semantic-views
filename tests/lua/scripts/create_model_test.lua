local H = SCRIPT_BODY
local step = H.step
local supported = H.supported
test("script body: create_model writes model and version in order", function()
    local fixture = supported({
        step("SELECT COUNT(*)", {{0}}, {model_name = "sales"}),
        step("INSERT INTO SYS_SEMANTIC.MODELS", nil, {
            model_name = "sales", published_schema = "SEMANTIC_SALES",
            description = null, owner_role = null,
        }),
        step("SELECT MODEL_ID", {{11}}, {model_name = "sales"}),
        step("INSERT INTO SYS_SEMANTIC.MODEL_VERSIONS", nil, {model_id = 11}),
        step("SELECT VERSION_ID", {{12}}, {model_id = 11}),
        step("UPDATE SYS_SEMANTIC.MODELS", nil, {version_id = 12, model_id = 11}),
    })
    local result = H.run("create_model", {
        MODEL_NAME = "sales", PUBLISHED_SCHEMA = "SEMANTIC_SALES", DESCRIPTION = null,
    }, fixture)
    assert_equal(#result.calls, 6)
    H.run("create_model", {MODEL_NAME = null, PUBLISHED_SCHEMA = "SEMANTIC_SALES"},
        {imports = fixture.imports, error = "MODEL_NAME is required"})
end)
