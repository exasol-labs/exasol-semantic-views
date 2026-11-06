local H = SCRIPT_BODY
local run, test_script = H.for_script("add_semantic_identity_with_bindings")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, entity, identity, and data type are required", {"SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
