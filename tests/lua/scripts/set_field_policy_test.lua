local H = SCRIPT_BODY
local run, test_script = H.for_script("set_field_policy")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {}))
end)
