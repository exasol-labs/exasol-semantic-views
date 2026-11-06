local H = SCRIPT_BODY
local run, test_script = H.for_script("set_query_logging")

test_script("rejects invalid SCOPE", function()
    run({}, H.refusal("SEMANTIC_ADMIN_224: SCOPE must be DEPLOYMENT or SESSION.", {}))
end)
