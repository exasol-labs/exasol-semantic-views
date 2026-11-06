local H = SCRIPT_BODY
local run, test_script = H.for_script("replace_attribute_binding")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {}))
end)
