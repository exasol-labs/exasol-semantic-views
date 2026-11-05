local H = SCRIPT_BODY
local run, test_script = H.for_script("add_fact_with_bindings")

test_script("delegates a fact and reports its binding count", function()
    local supplied = {MODEL_NAME = "sales", ENTITY_NAME = "orders", FACT_NAME = "amount",
        EXPRESSION = "o.amount", DATA_TYPE = "DECIMAL(18,2)", ADDITIVE_POLICY = "ADDITIVE"}
    local fixture = {sql = {
        H.step("ATTRIBUTE_WITH_BINDINGS(\n      'FACT'", nil,
            {model_name = "sales", entity_name = "orders", attribute_name = "amount",
                expression = "o.amount", data_type = "DECIMAL(18,2)", additive_policy = "ADDITIVE",
                display_name = null, description = null, is_private = null,
                is_certified = null, bindings_json = null}),
        H.step("FROM SYS_SEMANTIC.FACTS", {{51, "sales", "orders", "FACT", "amount", 3}},
            {model_name = "sales", attribute_name = "amount"}),
    }}
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][6], 3)
    assert_contains(result.columns, "BINDING_COUNT DECIMAL")
end)
