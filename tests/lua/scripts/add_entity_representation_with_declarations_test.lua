local H = SCRIPT_BODY
local run, test_script = H.for_script("add_entity_representation_with_declarations")

test_script("rejects unknown declaration keys before catalog writes", function()
    local fixture = {imports = {
        ["SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"] = {
            decode_json = function() return {typo = true} end,
        },
        ["SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"] = H.support,
    }, error = "SEMANTIC_ADMIN_214: unknown DECLARATIONS_JSON key(s): typo"}
    run({DECLARATIONS_JSON = "{}"}, fixture)
end)
