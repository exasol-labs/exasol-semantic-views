local H = SCRIPT_BODY
local step = H.step
test("script body: publish_model records a successful publish", function()
    local discovery = '"SEMANTIC_SALES"."SEMANTIC_DISCOVERY"'
    local fixture = {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", 12, "SEMANTIC_SALES", null}},
            {model_name = "sales"}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", {}, {model_name = "sales"}),
        step("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE", nil, {version_id = 12}),
        step('CREATE SCHEMA IF NOT EXISTS "SEMANTIC_SALES"'),
        step('COMMENT ON SCHEMA "SEMANTIC_SALES"'),
        step("CREATE TABLE IF NOT EXISTS " .. discovery),
        step("COMMENT ON TABLE " .. discovery),
        step("DELETE FROM " .. discovery),
        step("VALUES ('MODEL_NAME'"),
        step("VALUES ('MODEL_DESCRIPTION'"),
        step("VALUES ('QUERY_ENTRYPOINT'"),
        step("VALUES ('MCP_GUIDANCE'"),
        step("VALUES ('FIELD_DISCOVERY_QUERY'"),
        step("VALUES ('COMPATIBILITY_QUERY'"),
        step("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", {{21, "orders", "Orders"}}),
        step("VALUES ('SEMANTIC_OBJECT'"),
        step("VALUES ('SEMANTIC_OBJECT_DESCRIPTION'"),
        step("VALUES ('SEMANTIC_SELECT_EXAMPLE'"),
        step("FROM SYS_SEMANTIC.OBJECT_COLUMNS", {
            {"revenue", "METRIC", "DECIMAL(18,2)", 1, "Revenue", 2, "UNION"},
        }, {object_id = 21, version_id = 12}),
        step('CREATE OR REPLACE VIEW "SEMANTIC_SALES"."orders"'),
        step("UPDATE SYS_SEMANTIC.MODELS", nil, {model_id = 11}),
        step("UPDATE SYS_SEMANTIC.MODEL_VERSIONS", nil, {version_id = 12}),
        step("SELECT VERSION_NUMBER", {{2}}, {version_id = 12}),
        step("NEXT_PUBLISH_NUMBER", {{3}}, {model_id = 11}),
        step("INSERT INTO SYS_SEMANTIC.MODEL_PUBLISH_HISTORY", nil,
            {model_id = 11, version_id = 12, version_number = 2, publish_number = 3}),
        step("FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS", {}),
    }}
    local result = H.run("publish_model", {MODEL_NAME = "sales"}, fixture)
    assert_equal(result.rows[1][3], "orders")
    assert_equal(result.rows[1][4], 1)
    assert_contains(result.columns, "PUBLISHED_SCHEMA VARCHAR")
    assert_contains(result.calls[20].sql, "SEMANTIC_ADMIN.SEMANTIC_GUARD() IS NOT NULL")
    assert_contains(result.calls[20].sql, "Fused across 2 temporal partitions")
    assert_equal(#result.calls, 26)
end)

test("script body: publish_model refuses invalid validation", function()
    local fixture = {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", 12, "SEMANTIC_SALES", null}}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", {
            {"ERROR", "MODEL", "sales", "SEMANTIC_MODEL_001", "invalid"},
        }),
    }, error = "SEMANTIC_SURFACE_013"}
    H.run("publish_model", {MODEL_NAME = "sales"}, fixture)
    H.run("publish_model", {MODEL_NAME = null}, {error = "MODEL_NAME is required"})
end)
