local H = SCRIPT_BODY
local run, test_script = H.for_script("add_dimension_with_bindings")

test_script("delegates a dimension and reports its binding count", function()
    local supplied = {MODEL_NAME = "sales", OBJECT_NAME = "orders", ENTITY_NAME = "orders",
        DIMENSION_NAME = "region", EXPRESSION = "o.region", DATA_TYPE = "VARCHAR(50)"}
    local fixture = {sql = {
        H.step("ATTRIBUTE_WITH_BINDINGS(\n      'DIMENSION'", nil,
            {model_name = "sales", object_name = "orders", entity_name = "orders",
                attribute_name = "region", expression = "o.region", data_type = "VARCHAR(50)",
                display_name = null, description = null, format_hint = null,
                is_certified = null, bindings_json = null}),
        H.step("FROM SYS_SEMANTIC.DIMENSIONS", {{41, "sales", "orders", "DIMENSION", "region", 2}},
            {model_name = "sales", attribute_name = "region"}),
    }}
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][6], 2)
    assert_contains(result.columns, "BINDING_COUNT DECIMAL")
end)
