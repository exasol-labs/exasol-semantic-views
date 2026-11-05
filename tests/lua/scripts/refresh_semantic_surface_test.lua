local H = SCRIPT_BODY
local run, test_script = H.for_script("refresh_semantic_surface")

test_script("forwards publish rows by declared column order", function()
    local fixture = {sql = {H.step("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)",
        {{MODEL_NAME = "sales", PUBLISHED_SCHEMA = "SEMANTIC_SALES", OBJECT_NAME = "orders",
            COLUMN_COUNT = 2, STATUS = "PUBLISHED"}}, {model_name = "sales"})}}
    local result = run({MODEL_NAME = "sales"}, fixture)
    H.same(result.rows[1], {"sales", "SEMANTIC_SALES", "orders", 2, "PUBLISHED"}, "publish row")
    assert_contains(result.columns, "COLUMN_COUNT DECIMAL")
end)
