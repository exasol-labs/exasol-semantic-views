local H = SCRIPT_BODY
local run, test_script = H.for_script("remove_identity_mapping_relation")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, identity, and representation are required", {}))
end)
