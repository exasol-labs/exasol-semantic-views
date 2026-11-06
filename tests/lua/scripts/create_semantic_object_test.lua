local H = SCRIPT_BODY
local run, test_script = H.for_script("create_semantic_object")

test_script("forwards all arguments to the add script", function()
    local supplied = {MODEL_NAME = "sales", OBJECT_NAME = "orders", ROOT_ENTITY_NAME = "orders"}
    local fixture = {sql = {H.step("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT", nil,
        {model_name = "sales", object_name = "orders", root_entity_name = "orders",
            description = null})}}
    local result = run(supplied, fixture)
    assert_equal(#result.calls, 1)
    assert_equal(result.rows, nil)
end)
