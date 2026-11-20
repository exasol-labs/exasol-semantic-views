local H = SCRIPT_BODY
local run, test_script = H.for_script("add_dimension")

test_script("requires EXPRESSION", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: EXPRESSION is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)

test_script("refuses a taken name, naming its views and the DDL that shares it", function()
    local supplied = {MODEL_NAME = "sales", OBJECT_NAME = "SHIPPING", ENTITY_NAME = "orders",
        DIMENSION_NAME = "ship_mode", EXPRESSION = "o.ship_mode", DATA_TYPE = "VARCHAR(20)"}
    local fixture = H.supported({
        H.step("FROM SYS_SEMANTIC.MODELS", {{1, 2}}),
        H.step("FROM SYS_SEMANTIC.ENTITIES", {{20}}),
        H.step("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", {{10}}),
        H.step("FROM SYS_SEMANTIC.DIMENSIONS", {{1}}),
        H.step("LEFT JOIN SYS_SEMANTIC.OBJECT_COLUMNS", {{"OPS", "orders"}, {"SALES", "orders"}}),
    })
    fixture.error = "SEMANTIC_ADMIN_019: duplicate dimension: ship_mode."
    local result = run(supplied, fixture)
    assert_contains(result.error, "exposed by semantic view(s): OPS, SALES")
    assert_contains(result.error, "ALTER SEMANTIC VIEW sales.SHIPPING ADD OR REPLACE DIMENSION"
        .. " ship_mode ON ENTITY")
    assert_contains(result.error, "APPLY_SEMANTIC_DEFINITION")
end)
