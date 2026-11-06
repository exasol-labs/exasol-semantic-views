local H = SCRIPT_BODY
local run, test_script = H.for_script("add_entity_representation_with_authority")

test_script("rejects invalid AUTHORITY_ROLE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_003: AUTHORITY_ROLE must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL", {}))
end)
