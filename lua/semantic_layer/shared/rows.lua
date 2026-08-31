-- Reading a driver result row, once.
--
-- Every runtime opened with the same four helpers, and the copies had drifted in
-- one way that matters: `row[name] or row[lower] or row[position]` treats a
-- boolean FALSE as absent and falls through to an ordinal that is usually nil,
-- so a FALSE read out of a row could arrive as NULL. shared/catalog_rollback.lua
-- was given an explicit nil test when it was extracted; the other six modules
-- kept the `or` chain. This is that fix, in the one place it can now be made.
--
-- The bigger reason for the module is what `row_value`'s third argument is.
--
-- Exasol returns named rows, so production reads `row[name]`. The offline test
-- harness stubs `query` with positional arrays (`{{"CUSTOMER_ID"}}`), so tests
-- read `row[position]`. Both branches are covered; the *agreement* between them
-- was not, across 763 call sites carrying a hand-counted ordinal. Worse, a
-- misspelled name in production does not fail -- it falls through to the ordinal
-- and returns whatever column happens to sit there.
--
-- ESV_TEST_MODE makes that reachable. A row that carries names is what
-- production sees; asking such a row for a name it does not have is the defect,
-- and the ordinal fallback is what hides it. A row with no names at all is a
-- positional stub, where the ordinal is the only thing there is. So the check is
-- not "the ordinal was used" -- it is "the ordinal was used on a row that could
-- have answered by name".

local M = {}

-- Everything below is inside a `do` block so this module costs the runtime one
-- main-chunk local instead of five. Exasol caps a function at 200 locals and a
-- generated runtime script is every source concatenated into one chunk, so a
-- shared module's top-level names are spent from the same budget as its
-- callers' -- see CLAUDE.md, "The 200-Local Ceiling Applies to the Sum".
do

    local json = assert(ESV_JSON, "shared JSON runtime is required")
    local STRICT = rawget(_G, "ESV_TEST_MODE") == true

    -- A SQL NULL parameter reaches an Exasol Lua script as *userdata*, and userdata
    -- is truthy, so `value or default` silently yields the address. `null` is the
    -- script-context global for it; comparing against it is the only reliable test.
    -- json.NULL is here too because a decoded document's explicit null means the
    -- same thing as an omitted key everywhere in this runtime.
    function M.missing(value)
        return value == nil or value == null or value == json.NULL
            or tostring(value) == ""
    end

    function M.null_if_missing(value)
        if M.missing(value) then
            return null
        end
        return value
    end

    -- Does this row know its own column names?
    --
    -- A named row has at least one string key. A positional row has only integers.
    -- Both shapes reach this module: the first from Exasol, the second from a test
    -- stub, and telling them apart is what makes the strict check safe to turn on.
    local function is_named(row)
        for key, _ in pairs(row) do
            if type(key) ~= "number" then return true end
        end
        return false
    end

    local function lookup(row, name, position)
        local value = row[name]
        if value == nil then value = row[string.lower(name)] end
        if value ~= nil then return value, true end
        return row[position], false
    end

    -- One column of one row, by name, with its ordinal as the fallback.
    function M.row_value(row, name, position)
        if row == nil then return nil end
        local value, by_name = lookup(row, name, position)
        -- The defect is narrower than "the ordinal was used". A named row that has
        -- neither the name nor the ordinal yields nil either way -- no ambiguity, and
        -- a partially-populated test fixture is allowed to do that. What loses data
        -- is a named row that lacks the name while *something* sits at the ordinal:
        -- the caller then gets a different column's value and cannot tell.
        if STRICT and not by_name and value ~= nil and is_named(row) then
            error("row_value: row has named columns but not '" .. tostring(name)
                .. "', so ordinal " .. tostring(position) .. " returned a different "
                .. "column's value. Fix the name, or the SELECT that was supposed to "
                .. "project it.", 2)
        end
        return value
    end

    -- The first column of the first row of a single-value query.
    --
    -- Deliberately not strict: it probes three conventional aliases before falling
    -- back to the ordinal, because `SELECT MAX(x)` names its column after the
    -- expression and no caller wants to spell that out. Missing names are the normal
    -- case here, which is exactly why it cannot use M.row_value.
    function M.scalar(sql_text, params)
        local rows = query(sql_text, params or {})
        if rows == nil or #rows == 0 then
            return nil
        end
        local row = rows[1]
        for _, name in ipairs({"VALUE", "COUNT", "MAX"}) do
            local value = row[name]
            if value == nil then value = row[string.lower(name)] end
            if value ~= nil then return value end
        end
        return row[1]
    end

end

ESV_ROWS = M
