local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("apply_fusion_declaration_or_fail")

test_script("raises a returned fusion refusal", function()
    local supplied = {MODEL_NAME = "sales", DECLARATION_JSON = "{}"}
    local fixture = delegate("SEMANTIC_ADMIN.FUSION_RUNTIME", "apply_fusion_declaration",
        supplied, {{"ERROR", "SEMANTIC_FUSION_090", "invalid fusion"}})
    fixture.error = "SEMANTIC_FUSION_090: invalid fusion"
    run(supplied, fixture)
end)
