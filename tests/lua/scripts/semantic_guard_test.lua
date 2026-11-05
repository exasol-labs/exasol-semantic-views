local H = SCRIPT_BODY
local run = H.for_script("semantic_guard")
test("script body: semantic_guard refuses execution", function()
    run({}, {error = "SEMANTIC_SURFACE_001"})
end)
