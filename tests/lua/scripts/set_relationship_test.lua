local H = SCRIPT_BODY
local run, test_script = H.for_script("set_relationship")

test_script("rejects incomplete input", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required", {}))
end)
