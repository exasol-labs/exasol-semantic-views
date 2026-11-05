local H = SCRIPT_BODY
test("script body: semantic_guard refuses execution", function()
    H.run("semantic_guard", {}, {error = "SEMANTIC_SURFACE_001"})
end)
