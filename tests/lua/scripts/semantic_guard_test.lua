local H = SCRIPT_BODY
local run, test_script = H.for_script("semantic_guard")
test_script("refuses execution", function()
    run({}, {error = "SEMANTIC_SURFACE_001"})
end)
