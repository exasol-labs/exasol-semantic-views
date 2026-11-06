local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("add_agent_instruction")

test_script("forwards arguments and result columns", function()
    local supplied = {MODEL_NAME = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "add_agent_instruction", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "INSTRUCTION_ID ")
end)
