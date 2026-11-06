local H = SCRIPT_BODY
local run, test_script = H.for_script("remove_unique_key_with_columns")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: model, entity, and key names are required", {}))
end)
