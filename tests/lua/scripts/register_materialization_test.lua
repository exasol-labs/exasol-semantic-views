local H = SCRIPT_BODY
local run, test_script = H.for_script("register_materialization")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME"}))
end)
