local H = SCRIPT_BODY
local run, test_script = H.for_script("set_attribute_fusion_policy")

test_script("rejects invalid ATTRIBUTE_TYPE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_003: ATTRIBUTE_TYPE must be DIMENSION or FACT", {}))
end)
