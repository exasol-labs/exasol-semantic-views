local H = SCRIPT_BODY
local run, test_script = H.for_script("add_identity_binding")

test_script("requires SOURCE_EXPRESSION", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: SOURCE_EXPRESSION is required", {}))
end)
