local H = SCRIPT_BODY
local run, test_script = H.for_script("add_semantic_identity")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, entity, identity, and data type are required", {}))
end)
