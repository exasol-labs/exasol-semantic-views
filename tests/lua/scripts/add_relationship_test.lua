local H = SCRIPT_BODY
local run, test_script = H.for_script("add_relationship")

test_script("requires JOIN_CONDITION", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: JOIN_CONDITION is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
