local H = SCRIPT_BODY
local run, test_script = H.for_script("add_fact")

test_script("requires EXPRESSION", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: EXPRESSION is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
