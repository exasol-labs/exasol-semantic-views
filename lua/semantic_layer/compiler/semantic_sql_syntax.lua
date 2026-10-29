-- The token-level half of the Semantic SQL lane: what a statement says, before
-- anything is looked up.
--
-- Splitting a token stream at top-level separators, finding the clauses of a
-- SELECT, reading an identifier, alias or literal out of a select item, removing
-- a MEASURE()/aggregate wrapper, and parsing WHERE and ORDER BY into the request
-- shape. None of it reads the catalog: resolving a field (HAVING's metric check,
-- the select list's fields) stays in request_json.lua, which calls these.
--
-- A module of its own for two reasons. It is one job with one input, so it can
-- be read and tested without the rest of the compiler; and COMPILER_RUNTIME is
-- one Lua chunk whose top-level locals Exasol caps at 200 for every source in
-- it together. As nineteen top-level helpers in request_json.lua this cost
-- nineteen; behind the `do` block below it costs one (see CLAUDE.md, "The
-- 200-Local Ceiling Applies to the Sum").

local M = {}

do
    local sql_text = assert(ESV_SQL_TEXT, "shared SQL text runtime is required")
    local error_result = assert(ESV_COMPILE_RESULT, "compile result runtime is required").error

    local function trim(value)
        return tostring(value):match("^%s*(.-)%s*$")
    end

    local function upper(value)
        return string.upper(tostring(value))
    end

    local function token_identifier_value(token)
        if token == nil then
            return nil
        end
        if token.kind == "identifier" or token.kind == "word" then
            return token.value or token.text
        end
        return nil
    end

    local function split_top_level(tokens, start_index, end_index, separator)
        local parts = {}
        local current = {}
        local depth = 0
        for i = start_index, end_index do
            local token = tokens[i]
            if token.text == "(" then
                depth = depth + 1
            elseif token.text == ")" then
                depth = depth - 1
            end
            if depth == 0 and token.text == separator then
                parts[#parts + 1] = current
                current = {}
            else
                current[#current + 1] = token
            end
        end
        if #current > 0 then
            parts[#parts + 1] = current
        end
        return parts
    end

    -- Databricks metric views wrap measures in MEASURE(...) (or its agg() synonym)
    -- in SELECT / HAVING / ORDER BY. Unwrap that call to the bare semantic field name
    -- so the rest of the parser treats it like any other metric reference. Returns the
    -- (possibly rewritten) token list and whether a wrapper was actually removed.
    -- Wrappers a select item may put around a metric. MEASURE/AGG say "give me this
    -- metric" and carry no aggregation of their own. A named aggregate is accepted
    -- only when it is the one the metric declares -- see the select-list loop -- so
    -- that SUM(a_ratio) refuses instead of quietly returning the ratio.
    local METRIC_WRAPPERS = {
        MEASURE = true, AGG = true,
        SUM = true, COUNT = true, MIN = true, MAX = true, AVG = true,
    }

    local function unwrap_measure_part(part)
        if part == nil or #part < 4 then
            return part, false, nil
        end
        local head = sql_text.token_upper(part[1])
        if not METRIC_WRAPPERS[head] or part[2].text ~= "(" then
            return part, false, nil
        end
        local depth = 0
        local close_index = nil
        for i = 2, #part do
            local text = part[i].text
            if text == "(" then
                depth = depth + 1
            elseif text == ")" then
                depth = depth - 1
                if depth == 0 then
                    close_index = i
                    break
                end
            end
        end
        -- Require a non-empty argument and a matching close paren.
        if close_index == nil or close_index <= 3 then
            return part, false, nil
        end
        local rewritten = {}
        for i = 3, close_index - 1 do
            rewritten[#rewritten + 1] = part[i]
        end
        for i = close_index + 1, #part do
            rewritten[#rewritten + 1] = part[i]
        end
        return rewritten, true, head
    end

    -- What a semantic query cannot express in its own select list, and the
    -- pattern that does run: the governed query answers at the grain it names,
    -- and ordinary SQL -- a window, a distinct count -- runs over that result.
    M.WRAP_REMEDY = "Wrap the semantic query and apply ordinary SQL outside it:"
        .. " SELECT ..., <expression> FROM (SELECT <fields> FROM <schema>.<object>"
        .. " GROUP BY <dimensions>)."

    -- `COUNT(DISTINCT x)`. Unwrapped, the argument reads as a field `DISTINCT`
    -- aliased `x`, and the refusal sent the author looking for a column called
    -- DISTINCT. Name the construct instead.
    local function distinct_aggregate_refusal(part)
        local unwrapped, wrapped, wrapper = unwrap_measure_part(part)
        if not wrapped or unwrapped[1] == nil
            or sql_text.token_upper(unwrapped[1]) ~= "DISTINCT" then
            return nil
        end
        return error_result("SEMANTIC_QUERY_019", tostring(wrapper)
            .. "(DISTINCT ...) is not supported in a semantic query: a metric"
            .. " already declares its aggregation. " .. M.WRAP_REMEDY)
    end

    local function identifier_from_part(part)
        local wrapped
        part, wrapped = unwrap_measure_part(part)
        if #part == 0 then
            return nil
        end
        -- Never a field; see distinct_aggregate_refusal.
        if wrapped and sql_text.token_upper(part[1]) == "DISTINCT" then
            return nil
        end
        local end_index = #part
        for i, token in ipairs(part) do
            if sql_text.token_upper(token) == "AS" then
                end_index = i - 1
                break
            end
        end
        if end_index >= 3 and part[end_index - 1].text == "." then
            return token_identifier_value(part[end_index])
        end
        if end_index == 1 then
            return token_identifier_value(part[1])
        end
        if end_index >= 1 and (part[1].kind == "word" or part[1].kind == "identifier") then
            if end_index == 2 and (part[2].kind == "word" or part[2].kind == "identifier") then
                return token_identifier_value(part[1])
            end
        end
        return nil
    end

    -- The output name a select item asks for, as Exasol would name the column: an
    -- unquoted alias folds to upper case, a quoted one is kept exactly. Emitting
    -- `AS r` as "r" named the column in lower case, which a statement wrapping the
    -- compiled SQL then could not find as r (GitHub #15).
    local function alias_from_select_part(part)
        local alias
        for i, token in ipairs(part) do
            if sql_text.token_upper(token) == "AS" and part[i + 1] ~= nil then
                alias = part[i + 1]
                break
            end
        end
        if alias == nil and #part == 2 and (part[1].kind == "word" or part[1].kind == "identifier")
            and (part[2].kind == "word" or part[2].kind == "identifier") then
            alias = part[2]
        end
        if alias == nil or token_identifier_value(alias) == nil then return nil end
        return alias.kind == "word" and upper(token_identifier_value(alias))
            or token_identifier_value(alias)
    end

    local function literal_from_tokens(tokens)
        if #tokens == 1 then
            local token = tokens[1]
            if token.kind == "literal" then
                local raw = string.sub(token.text, 2, -2)
                return string.gsub(raw, "''", "'")
            elseif token.kind == "number" then
                return tonumber(token.text) or token.text
            elseif token.kind == "word" then
                return token.value
            end
        elseif #tokens == 2 and sql_text.token_upper(tokens[1]) == "DATE" and tokens[2].kind == "literal" then
            local raw = string.sub(tokens[2].text, 2, -2)
            return string.gsub(raw, "''", "'")
        elseif #tokens == 2 and sql_text.token_upper(tokens[1]) == "TIMESTAMP" and tokens[2].kind == "literal" then
            local raw = string.sub(tokens[2].text, 2, -2)
            return string.gsub(raw, "''", "'")
        end
        return nil
    end

    local function find_top_level_clauses(tokens)
        local clauses = {}
        local depth = 0
        for i, token in ipairs(tokens) do
            if token.text == "(" then
                depth = depth + 1
            elseif token.text == ")" then
                depth = depth - 1
            elseif depth == 0 then
                local u = sql_text.token_upper(token)
                if u == "FROM" or u == "WHERE" or u == "LIMIT" or u == "HAVING" then
                    clauses[u] = clauses[u] or i
                elseif u == "GROUP" and sql_text.token_upper(tokens[i + 1]) == "BY" then
                    clauses.GROUP_BY = clauses.GROUP_BY or i
                elseif u == "ORDER" and sql_text.token_upper(tokens[i + 1]) == "BY" then
                    clauses.ORDER_BY = clauses.ORDER_BY or i
                end
            end
        end
        return clauses
    end

    local function clause_end(tokens, clauses, current_name)
        local start_index = clauses[current_name]
        local best = #tokens + 1
        for _, candidate in ipairs({"FROM", "WHERE", "GROUP_BY", "HAVING", "ORDER_BY", "LIMIT"}) do
            local pos = clauses[candidate]
            if pos ~= nil and pos > start_index and pos < best then
                best = pos
            end
        end
        return best - 1
    end

    local function token_slice(tokens, first, last)
        local out = {}
        for i = first, last do
            out[#out + 1] = tokens[i]
        end
        return out
    end

    local function render_token_slice(tokens)
        local parts = {}
        for _, token in ipairs(tokens or {}) do
            parts[#parts + 1] = token.text
        end
        return table.concat(parts, " ")
    end

    local binary_predicate_operators = {
        ["IN"] = true, ["BETWEEN"] = true, ["LIKE"] = true,
        ["="] = true, ["!="] = true, ["<>"] = true,
        [">"] = true, [">="] = true, ["<"] = true, ["<="] = true,
    }

    local function predicate_operator_at(tokens, index)
        local current = sql_text.token_upper(tokens[index])
        if current == "IS" then
            if sql_text.token_upper(tokens[index + 1]) == "NULL" then
                return "IS NULL"
            end
            if sql_text.token_upper(tokens[index + 1]) == "NOT"
                and sql_text.token_upper(tokens[index + 2]) == "NULL" then
                return "IS NOT NULL"
            end
            return "IS"
        end
        if binary_predicate_operators[current] then
            return current
        end
        return nil
    end

    -- Strip parentheses that wrap a whole predicate. BI tools emit
    -- `WHERE ("t"."STATUS" = 'X')`, and without this the trailing `)` was carried
    -- into the predicate's value and rendered straight into the generated SQL,
    -- producing a statement Exasol will not parse. It went unnoticed because those
    -- queries were refused earlier, for using SUM() around a metric, before the
    -- renderer ever saw them.
    local function strip_outer_parens(tokens, first, last)
        while first < last and tokens[first].text == "(" do
            local depth = 0
            local match = nil
            for i = first, last do
                local text = tokens[i].text
                if text == "(" then
                    depth = depth + 1
                elseif text == ")" then
                    depth = depth - 1
                    if depth == 0 then
                        match = i
                        break
                    end
                end
            end
            if match ~= last then
                return first, last
            end
            first, last = first + 1, last - 1
        end
        return first, last
    end

    -- Evaluate `<number> <op> <number>`, the only predicate shape that names no
    -- field. Returns true/false for a constant comparison and nil for anything else,
    -- so a real predicate falls through untouched.
    local function constant_comparison(tokens, first, last, op_index, op)
        local left = token_slice(tokens, first, op_index - 1)
        local right = token_slice(tokens, op_index + 1, last)
        if #left ~= 1 or #right ~= 1 then return nil end
        if left[1].kind ~= "number" or right[1].kind ~= "number" then return nil end
        local a, b = tonumber(left[1].text), tonumber(right[1].text)
        if a == nil or b == nil then return nil end
        if op == "=" then return a == b end
        if op == "!=" or op == "<>" then return a ~= b end
        if op == ">" then return a > b end
        if op == ">=" then return a >= b end
        if op == "<" then return a < b end
        if op == "<=" then return a <= b end
        return nil
    end

    -- One predicate parser for both WHERE and HAVING.
    --
    -- These were two ~110-line functions whose diff was 72 lines of 123, and almost
    -- all of it was the clause noun in three messages. The top-level AND split that
    -- skips BETWEEN's own AND, the operator scan, IS NULL / IS NOT NULL / IN /
    -- BETWEEN, the literal-or-raw-SQL fallback -- all of it was written twice, so a
    -- predicate form added to one and forgotten in the other passed every test.
    --
    -- The real differences are two, and they are what `clause` carries: HAVING
    -- resolves the field and refuses anything that is not a metric, and stores the
    -- resolved name where WHERE stores what the author typed.
    local function parse_predicates(ctx, tokens, start_index, end_index, clause)
        local filters = {}
        local empty_result = false
        local chunks = {}
        -- Split on top-level AND conjunctions, but skip the AND that belongs to a
        -- BETWEEN...AND range (e.g. "field BETWEEN v1 AND v2").
        -- `WHERE (a = 1 AND b = 2)` wraps the whole clause; unwrap before splitting
        -- so the conjunction is still seen at the top level.
        start_index, end_index = strip_outer_parens(tokens, start_index, end_index)
        local current_start = start_index
        local depth = 0
        local after_between = false
        local i = start_index
        while i <= end_index do
            local token = tokens[i]
            if token.text == "(" then
                depth = depth + 1
            elseif token.text == ")" then
                depth = depth - 1
            elseif depth == 0 then
                local u = sql_text.token_upper(token)
                if u == "BETWEEN" then
                    after_between = true
                elseif u == "AND" then
                    if after_between then
                        after_between = false
                    else
                        chunks[#chunks + 1] = {current_start, i - 1}
                        current_start = i + 1
                    end
                end
            end
            i = i + 1
        end
        chunks[#chunks + 1] = {current_start, end_index}

        for _, chunk in ipairs(chunks) do
            -- and `(a = 1) AND (b = 2)` wraps each conjunct separately.
            local first, last = strip_outer_parens(tokens, chunk[1], chunk[2])
            -- A conjunct carrying its own SELECT is a subquery predicate -- `EXISTS
            -- (...)`, `IN (SELECT ...)` -- which this lane does not model. It used
            -- to find the `=` *inside* the subquery, treat the whole thing as one
            -- comparison, and emit `WHERE c.region = t0 . CUSTOMER_REGION )`: SQL
            -- that does not parse, reported to the caller as a syntax error at a
            -- line of text they never wrote. Refusing here hands the statement to
            -- reference expansion, which leaves the subquery to Exasol.
            local conjunct_depth = tokens[first] ~= nil and tokens[first].depth or 0
            for idx = first, last do
                if tokens[idx].kind == "word" and sql_text.token_upper(tokens[idx]) == "SELECT" then
                    return nil, error_result("SEMANTIC_QUERY_030", clause.unsupported)
                end
            end
            local op_index = nil
            local op = nil
            for idx = first, last do
                -- At the conjunct's own depth: an operator nested inside parentheses
                -- belongs to something this predicate is not.
                if tokens[idx].depth == conjunct_depth then
                    local candidate = predicate_operator_at(tokens, idx)
                    if candidate ~= nil then
                        op_index = idx
                        op = candidate
                        break
                    end
                end
            end
            if op_index == nil then
                return nil, error_result("SEMANTIC_QUERY_030", clause.unsupported)
            end
            -- `WHERE 1 = 0` is how JDBC/ODBC drivers ask for a result's shape
            -- without its rows, and `WHERE 1 = 1` is how some tools spell "no
            -- filter". Neither names a field, so evaluate the comparison rather than
            -- refusing it for having no subject. A false one makes the whole
            -- conjunction empty, which LIMIT 0 expresses exactly.
            local constant = constant_comparison(tokens, first, last, op_index, op)
            if constant ~= nil then
                if constant == false then
                    empty_result = true
                end
                goto continue_chunk
            end
            local subject = token_slice(tokens, first, op_index - 1)
            local field = identifier_from_part(subject)
            if field == nil then
                local distinct_refusal = distinct_aggregate_refusal(subject)
                if distinct_refusal ~= nil then return nil, distinct_refusal end
                return nil, error_result("SEMANTIC_QUERY_031", clause.subject_required)
            end
            -- WHERE keeps the author's spelling and resolves later, against the
            -- dimensions actually selected; HAVING has to resolve here, because a
            -- non-metric predicate is a different refusal rather than a lookup miss.
            if clause.resolve ~= nil then
                local resolved, resolve_error = clause.resolve(ctx, field)
                if resolve_error ~= nil then return nil, resolve_error end
                field = resolved
            end
            if op == "IS NULL" or op == "IS NOT NULL" then
                local expected_last = op_index + (op == "IS NULL" and 1 or 2)
                if last ~= expected_last then
                    return nil, error_result("SEMANTIC_QUERY_036",
                        "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
                end
                filters[#filters + 1] = {field = field, op = op}
            elseif op == "IS" then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            elseif op == "IN" then
                if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "("
                    or tokens[last].text ~= ")" then
                    return nil, error_result("SEMANTIC_QUERY_032",
                        "IN predicate requires a literal list.")
                end
                local values = {}
                for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                    local value = literal_from_tokens(part)
                    if value == nil then
                        return nil, error_result("SEMANTIC_QUERY_033",
                            "IN predicate supports literal values only.")
                    end
                    values[#values + 1] = value
                end
                filters[#filters + 1] = {field = field, op = "IN", value = values}
            elseif op == "BETWEEN" then
                local and_index = nil
                for idx = op_index + 1, last do
                    if sql_text.token_upper(tokens[idx]) == "AND" then
                        and_index = idx
                        break
                    end
                end
                if and_index == nil then
                    return nil, error_result("SEMANTIC_QUERY_034",
                        "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
                end
                local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
                local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
                if v1 == nil or v2 == nil then
                    return nil, error_result("SEMANTIC_QUERY_035",
                        "BETWEEN predicate requires two literal values.")
                end
                filters[#filters + 1] = {field = field, op = "BETWEEN", value = {v1, v2}}
            else
                local value_tokens = token_slice(tokens, op_index + 1, last)
                local value = literal_from_tokens(value_tokens)
                if value == nil then
                    local value_sql = trim(render_token_slice(value_tokens))
                    if value_sql == "" then
                        return nil, error_result("SEMANTIC_QUERY_033", clause.missing_value)
                    end
                    filters[#filters + 1] = {field = field, op = op, value = null,
                        value_sql = value_sql}
                else
                    filters[#filters + 1] = {field = field, op = op, value = value}
                end
            end
            ::continue_chunk::
        end
        return filters, nil, empty_result
    end

    -- The whole difference between the two clauses, in one place. It used to be
    -- three interpolated nouns scattered through two copies of the same 110 lines.
    local WHERE_CLAUSE = {
        unsupported = "Unsupported WHERE predicate.",
        subject_required = "WHERE predicate must start with a semantic dimension.",
        missing_value = "WHERE predicate requires a right-hand value.",
    }

    local function parse_where_filters(tokens, start_index, end_index)
        return parse_predicates(nil, tokens, start_index, end_index, WHERE_CLAUSE)
    end

    local function parse_order_by(tokens, start_index, end_index, select_aliases, selected_output)
        local order_by = {}
        for _, part in ipairs(split_top_level(tokens, start_index, end_index, ",")) do
            -- `<item> [ASC|DESC] [NULLS FIRST|LAST]`, read from the end. The null
            -- placement used to stop an ordinal being recognised at all, so
            -- Tableau's `ORDER BY 1 ASC NULLS FIRST` was refused (GitHub #14).
            local nulls
            if #part > 2 and sql_text.token_upper(part[#part - 1]) == "NULLS" then
                local placement = sql_text.token_upper(part[#part])
                if placement ~= "FIRST" and placement ~= "LAST" then
                    return nil, error_result("SEMANTIC_QUERY_060",
                        "ORDER BY supports selected semantic fields only.")
                end
                nulls = placement
                table.remove(part, #part)
                table.remove(part, #part)
            end
            local direction = "ASC"
            if #part > 1 then
                local last = sql_text.token_upper(part[#part])
                if last == "ASC" or last == "DESC" then
                    direction = last
                    table.remove(part, #part)
                end
            end
            local field = identifier_from_part(part)
            -- An ordinal names a select item: positive, whole, and within the list.
            local negative = #part == 2 and part[1].text == "-" and part[2].kind == "number"
            if field == nil and ((#part == 1 and part[1].kind == "number") or negative) then
                local ordinal = tonumber(part[#part].text)
                local count = selected_output ~= nil and #selected_output or 0
                if negative or ordinal == nil or ordinal < 1 or ordinal % 1 ~= 0 or ordinal > count then
                    return nil, error_result("SEMANTIC_QUERY_064",
                        "ORDER BY " .. (negative and "-" or "") .. tostring(part[#part].text)
                            .. " is not a position in the SELECT list, which has " .. tostring(count)
                            .. " item" .. (count == 1 and "" or "s") .. ". Use 1 to "
                            .. tostring(count) .. ", or name the field.")
                end
                field = selected_output[ordinal]
            end
            if field == nil then
                local distinct_refusal = distinct_aggregate_refusal(part)
                if distinct_refusal ~= nil then return nil, distinct_refusal end
                return nil, error_result("SEMANTIC_QUERY_060", "ORDER BY supports selected semantic fields only.")
            end
            if select_aliases ~= nil and select_aliases[upper(field)] ~= nil then
                field = select_aliases[upper(field)]
            end
            order_by[#order_by + 1] = {field = field, direction = direction, nulls = nulls}
        end
        return order_by, nil
    end

    M.token_identifier_value = token_identifier_value
    M.split_top_level = split_top_level
    M.METRIC_WRAPPERS = METRIC_WRAPPERS
    M.unwrap_measure_part = unwrap_measure_part
    M.identifier_from_part = identifier_from_part
    M.distinct_aggregate_refusal = distinct_aggregate_refusal
    M.alias_from_select_part = alias_from_select_part
    M.literal_from_tokens = literal_from_tokens
    M.find_top_level_clauses = find_top_level_clauses
    M.clause_end = clause_end
    M.token_slice = token_slice
    M.render_token_slice = render_token_slice
    M.binary_predicate_operators = binary_predicate_operators
    M.predicate_operator_at = predicate_operator_at
    M.strip_outer_parens = strip_outer_parens
    M.constant_comparison = constant_comparison
    M.parse_predicates = parse_predicates
    M.WHERE_CLAUSE = WHERE_CLAUSE
    M.parse_where_filters = parse_where_filters
    M.parse_order_by = parse_order_by
end

ESV_SEMANTIC_SQL_SYNTAX = M
