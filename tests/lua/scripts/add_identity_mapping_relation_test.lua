local H = SCRIPT_BODY
local run, test_script = H.for_script("add_identity_mapping_relation")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, identity, representation, mapping source, and mapping columns are required", {}))
end)
