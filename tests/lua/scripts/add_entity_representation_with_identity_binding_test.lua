local H = SCRIPT_BODY
local run, test_script = H.for_script("add_entity_representation_with_identity_binding")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {"SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)
