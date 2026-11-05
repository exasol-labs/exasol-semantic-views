local H = SCRIPT_BODY
local run, test_script = H.for_script("add_or_replace_dimension")

test_script("requires EXPRESSION", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: EXPRESSION is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"}))
end)
