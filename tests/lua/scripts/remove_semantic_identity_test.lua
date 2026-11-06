local H = SCRIPT_BODY
local run, test_script = H.for_script("remove_semantic_identity")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, entity, and identity are required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
