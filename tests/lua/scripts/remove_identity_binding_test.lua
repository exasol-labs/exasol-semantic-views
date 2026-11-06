local H = SCRIPT_BODY
local run, test_script = H.for_script("remove_identity_binding")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, identity, and representation are required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
