local H = SCRIPT_BODY
local run, test_script = H.for_script("attribute_with_bindings")

test_script("rejects invalid ATTRIBUTE_TYPE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT", {"SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)

test_script("uses the requested primary binding priority", function()
    local fixture = H.supported({
        H.step("FROM SYS_SEMANTIC.MODELS", {{1, 2}}),
        H.step("SELECT ENTITY_ID", {{3}}),
        H.step("SELECT COUNT(*) FROM SYS_SEMANTIC.FACTS", {{0}}),
        H.step("FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS",
            {{10, "primary", "PRIMARY"}}),
        H.step("INSERT INTO SYS_SEMANTIC.FACTS"),
        H.step("SELECT FACT_ID FROM SYS_SEMANTIC.FACTS", {{20}}),
        H.step("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
        H.step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL"),
        H.step("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE"),
    })
    fixture.imports["SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"] = {
        decode_json = ESV_JSON.decode,
    }
    local result = run({
        ATTRIBUTE_TYPE = "FACT", MODEL_NAME = "sales", ENTITY_NAME = "orders",
        ATTRIBUTE_NAME = "net_revenue", EXPRESSION = "o.amount",
        DATA_TYPE = "DECIMAL(18,2)", ADDITIVE_POLICY = "ADDITIVE",
        BINDINGS_JSON = '[{"representation_name":"primary",'
            .. '"binding_role":"FALLBACK","binding_priority":7}]',
    }, fixture)
    assert_equal(result.calls[7].bindings.binding_role, "FALLBACK")
    assert_equal(result.calls[7].bindings.binding_priority, 7)
    assert_equal(result.rows[1][1], 20)
end)
