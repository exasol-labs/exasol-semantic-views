local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("describe_semantic_object")

test_script("forwards arguments and result columns", function()
    local supplied = {MODEL_NAME = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "describe_semantic_object", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "MODEL_NAME ")
end)
