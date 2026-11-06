local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("record_agent_feedback")

test_script("forwards arguments and result columns", function()
    local supplied = {HANDLE_TYPE = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "record_agent_feedback", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "FEEDBACK_ID ")
end)
