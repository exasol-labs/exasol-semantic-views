local H = SCRIPT_BODY
local run, test_script = H.for_script("remove_attribute_binding")

test_script("rejects invalid ATTRIBUTE_TYPE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT", {}))
end)
