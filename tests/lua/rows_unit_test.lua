local rows = ESV_ROWS

test("shared row reader prefers the name and keeps a boolean FALSE", function()
    assert_equal(rows.row_value({REGION = "EMEA"}, "REGION", 1), "EMEA")
    -- Some drivers lower-case the keys; both spellings are the same column.
    assert_equal(rows.row_value({region = "EMEA"}, "REGION", 1), "EMEA")
    assert_equal(rows.row_value(nil, "REGION", 1), nil)

    -- The bug this module was extracted to fix, in six modules at once.
    -- `row[name] or row[lower] or row[position]` treats FALSE as absent and
    -- falls through to an ordinal that is usually nil, so a restored
    -- ATTRIBUTE_BINDINGS.IS_DEFAULT or OBJECT_COLUMNS.IS_VISIBLE arrived as NULL.
    assert_equal(rows.row_value({IS_DEFAULT = false}, "IS_DEFAULT", 1), false)
    assert_equal(rows.row_value({is_visible = false}, "IS_VISIBLE", 1), false)
    -- Answered by name, and the same row asked for a column it does not carry.
    assert_branch("rows.value.named", rows.row_value({A = 1}, "A", 1) ~= nil, true)
    assert_branch("rows.value.named", rows.row_value({A = 1}, "B", 2) ~= nil, false)
end)

test("shared row reader falls back to the ordinal for a positional row", function()
    -- Exasol returns named rows; the offline harness stubs `query` with
    -- positional arrays. Both shapes are real, and a row with no names at all
    -- has nothing but its ordinals.
    assert_equal(rows.row_value({"first", "second"}, "ANYTHING", 2), "second")
    assert_equal(rows.row_value({"first"}, "ANYTHING", 9), nil)
end)

test("shared row reader refuses a named row that answers by ordinal instead", function()
    -- 763 call sites carry a hand-counted ordinal, and nothing could check one:
    -- production reads by name, the tests read by ordinal, and a misspelled name
    -- does not fail -- it falls through and returns whichever column sits at that
    -- position. In test mode that is now an error rather than a wrong value.
    local ok, message = pcall(rows.row_value,
        {ENTITY_NAME = "customer", [2] = "MART"}, "ENTITY_NAMES", 2)
    assert_true(not ok, "a mistyped column name was accepted")
    assert_contains(message, "ENTITY_NAMES")
    assert_contains(message, "ordinal 2")
    assert_branch("rows.value.mismatch", ok, false)

    -- Narrower than "the ordinal was used", deliberately. A named row missing
    -- both the name and the ordinal yields nil either way -- no ambiguity, and a
    -- partially-populated fixture is allowed to do that.
    assert_equal(rows.row_value({ENTITY_NAME = "customer"}, "SOURCE_SCHEMA", 7), nil)
    assert_branch("rows.value.mismatch", true, true)
end)

test("shared missing recognises every spelling of absent", function()
    assert_branch("rows.missing", rows.missing(nil), true)
    assert_branch("rows.missing", rows.missing("value"), false)
    assert_equal(rows.missing(null), true)
    assert_equal(rows.missing(ESV_JSON.NULL), true)
    assert_equal(rows.missing(""), true)
    assert_equal(rows.missing(0), false)
    assert_equal(rows.missing(false), false)

    assert_equal(rows.null_if_missing(nil), null)
    assert_equal(rows.null_if_missing(""), null)
    assert_equal(rows.null_if_missing(ESV_JSON.NULL), null)
    assert_equal(rows.null_if_missing("kept"), "kept")
    assert_equal(rows.null_if_missing(false), false)
end)

test("shared scalar probes conventional aliases before the ordinal", function()
    -- Not strict, and that is the point: `SELECT MAX(x)` names its column after
    -- the expression, so a missing VALUE/COUNT/MAX name is the normal case here
    -- rather than a defect. It cannot use row_value for exactly that reason.
    local original = query
    local answer = nil
    query = function() return answer end

    answer = {{VALUE = 42}}
    assert_equal(rows.scalar("SELECT 1"), 42)
    answer = {{COUNT = 7}}
    assert_equal(rows.scalar("SELECT 1"), 7)
    answer = {{max = 9}}
    assert_equal(rows.scalar("SELECT 1"), 9)
    answer = {{["MAX(METRIC_ID)"] = 3, 3}}
    assert_equal(rows.scalar("SELECT 1"), 3)
    answer = {{5}}
    assert_equal(rows.scalar("SELECT 1"), 5)

    answer = {}
    assert_branch("rows.scalar.empty", rows.scalar("SELECT 1") == nil, true)
    answer = nil
    assert_equal(rows.scalar("SELECT 1"), nil)
    answer = {{1}}
    assert_branch("rows.scalar.empty", rows.scalar("SELECT 1") == nil, false)

    query = original
end)
