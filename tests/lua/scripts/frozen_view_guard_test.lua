local H = SCRIPT_BODY
local run, test_script = H.for_script("frozen_view_guard")

test_script("rejects a retired view", function()
    run({}, H.refusal("SEMANTIC_SURFACE_015", {}))
end)
