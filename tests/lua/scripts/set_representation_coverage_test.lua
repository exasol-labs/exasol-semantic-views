local H = SCRIPT_BODY
local run, test_script = H.for_script("set_representation_coverage")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {}))
end)
