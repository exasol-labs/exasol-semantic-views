local H = SCRIPT_BODY
local run, test_script = H.for_script("attribute_with_bindings")

test_script("rejects invalid ATTRIBUTE_TYPE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT", {"SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
