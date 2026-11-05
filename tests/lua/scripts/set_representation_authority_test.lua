local H = SCRIPT_BODY
local run, test_script = H.for_script("set_representation_authority")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, entity, and representation names are required", {}))
end)
