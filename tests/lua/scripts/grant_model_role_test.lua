local H = SCRIPT_BODY
local run, test_script = H.for_script("grant_model_role")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_200: MODEL_NAME is required", {}))
end)
