-- =====================================================================
-- ADOPT_VIEW: a plain SQL view as the definition of a semantic view
--
-- An aggregate view over one table -- the shape a dbt view model has -- reads
-- as a semantic view: plain select items are dimensions, aggregate items are
-- metrics, and the FROM table is the entity. Everything else is already in
-- Exasol's catalog: the view text, each output column's name, type and
-- comment, the view's comment, and the source table's columns and comment. So
-- the view needs no new grammar, and stays plain SQL anyone can run.
--
-- This is a front end, like the fusion document and the Databricks importer:
-- it expresses nothing the scripts cannot, and expands into them --
-- CREATE_MODEL, ADD_ENTITY, ADD_SEMANTIC_OBJECT, then Semantic DDL through
-- APPLY_SEMANTIC_DEFINITION, which validates. The generated statements are
-- returned, so a translation can be read and replayed by hand.
--
-- Loaded in SEMANTIC_DEFINITION_RUNTIME before semantic_definition.lua and
-- kept inside a `do` block, so its helpers cost the chunk one local. What it
-- needs from the definition module -- the interior snapshot tables and the DDL
-- clause words -- is handed in at call time rather than restated here.
-- =====================================================================

local M = {}

do
    assert(ESV_ROWS, "shared row runtime is required")
    local missing, row_value, null_if_missing, scalar =
        ESV_ROWS.missing, ESV_ROWS.row_value, ESV_ROWS.null_if_missing, ESV_ROWS.scalar
    local sql_text = assert(ESV_SQL_TEXT, "shared SQL text runtime is required")
    local source_columns = assert(ESV_SOURCE_COLUMNS, "shared source column runtime is required")
    local rollback = assert(ESV_CATALOG_ROLLBACK, "shared catalog rollback runtime is required")

    local function upper(value) return string.upper(tostring(value)) end
    local function lower(value) return string.lower(tostring(value)) end
    local function trim(value) return (tostring(value):match("^%s*(.-)%s*$")) end

    -- A comment Exasol stores as '' -- dbt writes COMMENT IS '' for every
    -- undocumented column -- is no comment.
    local function comment_of(value)
        if missing(value) or trim(value) == "" then return nil end
        return tostring(value)
    end

    local function refuse_shape(what)
        error("SEMANTIC_ADMIN_229: ADOPT_VIEW adopts SELECT <columns and aggregates>"
            .. " FROM <schema>.<table> [alias] [GROUP BY ...]; this view has " .. what
            .. ".", 0)
    end

    local function word(token)
        return token ~= nil and token.kind == "word" and upper(token.text) or nil
    end

    -- The `)` closing the `(` at `open`: the next `)` at the same depth.
    local function close_of(tokens, open)
        for index = open + 1, #tokens do
            if tokens[index].text == ")" and tokens[index].depth == tokens[open].depth then
                return index
            end
        end
        return nil
    end

    local function slice(text, tokens, first, last)
        return string.sub(text, tokens[first].start_pos, tokens[last].end_pos)
    end

    -- ---- 1. The query out of the stored DDL -------------------------------

    -- EXA_ALL_VIEWS.VIEW_TEXT is the CREATE statement as written. dbt's adds a
    -- query-comment header, with persist_docs a column list carrying COMMENT IS,
    -- the query in parentheses, and a trailing COMMENT IS for the view.
    local function extract_query(view_text)
        local text = tostring(view_text or "")
        local tokens = sql_text.tokenize(text)
        local index = 1
        if word(tokens[index]) ~= "CREATE" then
            refuse_shape("view text that is not a CREATE VIEW statement")
        end
        index = index + 1
        while word(tokens[index]) == "OR" or word(tokens[index]) == "REPLACE"
                or word(tokens[index]) == "FORCE" do
            index = index + 1
        end
        if word(tokens[index]) ~= "VIEW" then
            refuse_shape("view text that is not a CREATE VIEW statement")
        end
        index = index + 2
        while tokens[index] ~= nil and tokens[index].text == "." do index = index + 2 end
        if tokens[index] ~= nil and tokens[index].text == "(" then
            index = (close_of(tokens, index) or #tokens) + 1
        end
        if word(tokens[index]) ~= "AS" then
            refuse_shape("view text without AS after its name")
        end
        local first, last = index + 1, #tokens
        if last >= first + 2 and tokens[last].kind == "literal" and tokens[last].depth == 0
                and word(tokens[last - 1]) == "IS" and word(tokens[last - 2]) == "COMMENT" then
            last = last - 3
        end
        while first < last and tokens[first].text == "(" and close_of(tokens, first) == last do
            first, last = first + 1, last - 1
        end
        if first > last then refuse_shape("no query") end
        return slice(text, tokens, first, last)
    end

    -- ---- 2. The shape: SELECT items FROM schema.table [alias] [GROUP BY] ---

    local FOLLOWING_CLAUSES = {
        WHERE = "a WHERE clause", HAVING = "a HAVING clause", ORDER = "an ORDER BY",
        LIMIT = "a LIMIT", QUALIFY = "a QUALIFY clause", CONNECT = "CONNECT BY",
        START = "CONNECT BY", PREFERRING = "a PREFERRING clause",
        UNION = "a set operation (UNION)", INTERSECT = "a set operation (INTERSECT)",
        MINUS = "a set operation (MINUS)", EXCEPT = "a set operation (EXCEPT)",
        JOIN = "a join", INNER = "a join", LEFT = "a join", RIGHT = "a join",
        FULL = "a join", CROSS = "a join", OUTER = "a join", NATURAL = "a join",
    }

    local function split_top_level(tokens, first, last)
        local parts, start = {}, first
        for index = first, last do
            if tokens[index].text == "," and tokens[index].depth == 0 then
                if index > start then parts[#parts + 1] = {start, index - 1} end
                start = index + 1
            end
        end
        if last >= start then parts[#parts + 1] = {start, last} end
        return parts
    end

    -- An unquoted name is the identifier Exasol folds it to; a quoted one is
    -- exactly what it says.
    local function name_of(token)
        if token == nil then return nil end
        if token.kind == "word" then return upper(token.text) end
        if token.kind == "identifier" then return token.value end
        return nil
    end

    local function parse_select(query_text)
        local text = tostring(query_text)
        local tokens = sql_text.tokenize(text)
        if word(tokens[1]) == "WITH" then refuse_shape("a WITH clause") end
        if word(tokens[1]) ~= "SELECT" then refuse_shape("a query that is not a SELECT") end
        if word(tokens[2]) == "DISTINCT" then refuse_shape("SELECT DISTINCT") end
        local from = nil
        for index = 2, #tokens do
            if tokens[index].depth == 0 and word(tokens[index]) == "FROM" then
                from = index
                break
            end
        end
        if from == nil then refuse_shape("no FROM clause") end
        local item_first = word(tokens[2]) == "ALL" and 3 or 2
        if from == item_first then refuse_shape("no select items") end
        local items = {}
        for _, part in ipairs(split_top_level(tokens, item_first, from - 1)) do
            items[#items + 1] = slice(text, tokens, part[1], part[2])
        end

        local index = from + 1
        if tokens[index] ~= nil and tokens[index].text == "(" then
            refuse_shape("a subquery in FROM")
        end
        local parts = {}
        while name_of(tokens[index]) ~= nil do
            parts[#parts + 1] = name_of(tokens[index])
            if tokens[index + 1] == nil or tokens[index + 1].text ~= "." then break end
            index = index + 2
        end
        if #parts == 0 then refuse_shape("FROM without a table") end
        if #parts == 1 then
            refuse_shape("FROM " .. parts[1] .. " without its schema; write <schema>."
                .. parts[1] .. " (dbt's ref() always does)")
        end
        if #parts > 2 then refuse_shape("a FROM name of more than two parts") end
        local relation = {schema = parts[1], object = parts[2]}
        index = index + 1
        if word(tokens[index]) == "AS" then index = index + 1 end
        local alias = nil
        local alias_token = tokens[index]
        if alias_token ~= nil and (alias_token.kind == "identifier"
                or (alias_token.kind == "word" and FOLLOWING_CLAUSES[upper(alias_token.text)] == nil
                    and upper(alias_token.text) ~= "GROUP")) then
            alias = {name = name_of(alias_token), quoted = alias_token.kind == "identifier",
                     written = alias_token.text}
            index = index + 1
        end
        if tokens[index] ~= nil and tokens[index].text == "," then
            refuse_shape("a join (a second table after a comma)")
        end
        local group_by = {}
        if word(tokens[index]) == "GROUP" and word(tokens[index + 1]) == "BY" then
            local first = index + 2
            for position = first, #tokens do
                local name = word(tokens[position])
                if name == "ROLLUP" or name == "CUBE" or name == "GROUPING" then
                    refuse_shape("GROUP BY " .. name)
                end
                if tokens[position].depth == 0 and name ~= nil and FOLLOWING_CLAUSES[name] then
                    refuse_shape(FOLLOWING_CLAUSES[name])
                end
            end
            for _, part in ipairs(split_top_level(tokens, first, #tokens)) do
                group_by[#group_by + 1] = slice(text, tokens, part[1], part[2])
            end
            index = #tokens + 1
        end
        if tokens[index] ~= nil then
            local name = word(tokens[index])
            refuse_shape(name and FOLLOWING_CLAUSES[name]
                or ("'" .. tostring(tokens[index].text) .. "' after its FROM table"))
        end
        return {items = items, relation = relation, alias = alias, group_by = group_by}
    end

    -- ---- 3. One select item: its expression, and what kind of column ------

    local AGGREGATES = {SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true}
    -- Aggregates ESV does not regroup; named, so the refusal says which.
    local OTHER_AGGREGATES = {}
    for name in string.gmatch("MEDIAN STDDEV STDDEV_POP STDDEV_SAMP VARIANCE VAR_POP"
        .. " VAR_SAMP LISTAGG GROUP_CONCAT APPROXIMATE_COUNT_DISTINCT PERCENTILE_CONT"
        .. " PERCENTILE_DISC EVERY MUL CORR COVAR_POP COVAR_SAMP REGR_SLOPE"
        .. " REGR_INTERCEPT REGR_COUNT REGR_R2 REGR_AVGX REGR_AVGY REGR_SXX REGR_SYY"
        .. " REGR_SXY FIRST_VALUE LAST_VALUE GROUPING GROUPING_ID", "%S+") do
        OTHER_AGGREGATES[name] = true
    end
    -- A trailing word that ends an expression rather than naming it.
    local NOT_AN_ALIAS = {END = true, YEAR = true, MONTH = true, DAY = true, HOUR = true,
        MINUTE = true, SECOND = true}

    -- The expression of `expr [AS] alias`. The output name comes from the
    -- catalog by position, so the alias is only dropped, never read.
    local function item_expression(item_text)
        local tokens = sql_text.tokenize(item_text)
        local last = #tokens
        if last >= 2 then
            local tail, before = tokens[last], tokens[last - 1]
            if word(before) == "AS" and before.depth == 0 then
                last = last - 2
            elseif tail.depth == 0 and (tail.kind == "identifier" or (tail.kind == "word"
                    and not NOT_AN_ALIAS[upper(tail.text)]))
                    and (before.text == ")" or before.kind == "word"
                        or before.kind == "identifier" or before.kind == "number"
                        or before.kind == "literal") then
                last = last - 1
            end
        end
        if last < 1 then refuse_shape("an empty select item") end
        return trim(slice(item_text, tokens, 1, last))
    end

    -- The aggregate calls of an expression, outermost only, with their spans.
    local function aggregate_calls(expression)
        local tokens = sql_text.tokenize(expression)
        local calls = {}
        local index = 1
        while index <= #tokens do
            local token = tokens[index]
            local name = word(token)
            if token.text == "*" and (index == 1 or tokens[index - 1].text == "."
                    or tokens[index - 1].text == ",") then
                refuse_shape("SELECT *; list the columns")
            end
            if name == "OVER" then refuse_shape("a window function") end
            local opens = tokens[index + 1] ~= nil and tokens[index + 1].text == "("
            if name ~= nil and OTHER_AGGREGATES[name] and opens then
                refuse_shape("the aggregate " .. name .. ", which ADOPT_VIEW does not"
                    .. " translate (SUM, COUNT, AVG, MIN and MAX are supported)")
            end
            if name ~= nil and AGGREGATES[name] and opens then
                local open = index + 1
                local close = close_of(tokens, open)
                if close == nil then refuse_shape("an unterminated " .. name .. "(") end
                local first = open + 1
                local distinct = word(tokens[first]) == "DISTINCT"
                if distinct then first = first + 1 end
                if first >= close then refuse_shape("an empty " .. name .. "()") end
                for inner = first, close - 1 do
                    local inner_name = word(tokens[inner])
                    if inner_name ~= nil and AGGREGATES[inner_name] and tokens[inner + 1] ~= nil
                            and tokens[inner + 1].text == "(" then
                        refuse_shape("a nested aggregate in " .. name .. "(...)")
                    end
                    if tokens[inner].text == "," and tokens[inner].depth == tokens[first].depth then
                        refuse_shape(name .. " with more than one argument")
                    end
                end
                local star = first == close - 1 and tokens[first].text == "*"
                calls[#calls + 1] = {
                    name = upper(token.text), written = token.text, distinct = distinct,
                    star = star,
                    start_pos = token.start_pos, end_pos = tokens[close].end_pos,
                    argument = not star and string.sub(expression, tokens[first].start_pos,
                        tokens[close - 1].end_pos) or nil,
                }
                index = close + 1
            else
                index = index + 1
            end
        end
        return calls
    end

    -- ---- 4. Columns qualified with the entity alias -------------------------

    -- `scope` is {alias = <entity alias>, columns = {[NAME] = column},
    -- qualifiers = {[NAME] = true}, schema = <NAME>, object = <NAME>}. Every
    -- reference to a source column comes back as `<alias>.<column>`: a bare
    -- one, one qualified by the view's alias or the table's name, and a
    -- schema.table.column one. Returns the text and the references, each with
    -- its span in the input, so a caller can tell where they are.
    local function qualify(expression, scope)
        local text = tostring(expression)
        local tokens = sql_text.tokenize(text)
        local out, refs = {}, {}
        local cursor = 1
        local index = 1
        local function emit(first, last, replacement, column)
            out[#out + 1] = string.sub(text, cursor, tokens[first].start_pos - 1)
            out[#out + 1] = replacement
            cursor = tokens[last].end_pos + 1
            refs[#refs + 1] = {start_pos = tokens[first].start_pos,
                               end_pos = tokens[last].end_pos, column = column}
        end
        while index <= #tokens do
            local token = tokens[index]
            local name = name_of(token)
            local after = tokens[index + 1]
            local previous = tokens[index - 1]
            local dotted = after ~= nil and after.text == "."
            local follows_dot = previous ~= nil and previous.text == "."
            if name ~= nil and dotted and not follows_dot then
                local second = name_of(tokens[index + 2])
                local third_dot = tokens[index + 3] ~= nil and tokens[index + 3].text == "."
                local third = third_dot and name_of(tokens[index + 4]) or nil
                if third ~= nil and name == scope.schema and second == scope.object
                        and scope.columns[third] then
                    emit(index, index + 4, scope.alias .. "." .. tokens[index + 4].text,
                        third)
                    index = index + 5
                elseif second ~= nil and not third_dot and scope.qualifiers[name]
                        and scope.columns[second] then
                    emit(index, index + 2, scope.alias .. "." .. tokens[index + 2].text,
                        second)
                    index = index + 3
                else
                    index = index + 1
                end
            elseif name ~= nil and not follows_dot and not dotted
                    and not (after ~= nil and (after.text == "(" or after.kind == "literal"))
                    and word(previous) ~= "AS" and scope.columns[name] then
                emit(index, index, scope.alias .. "." .. token.text, name)
                index = index + 1
            else
                index = index + 1
            end
        end
        out[#out + 1] = string.sub(text, cursor)
        return table.concat(out), refs
    end

    -- The column an expression is, when it is nothing but one column.
    local function plain_column(expression, scope)
        local _, refs = qualify(expression, scope)
        if #refs ~= 1 then return nil end
        local text = trim(expression)
        local ref = refs[1]
        local leading = trim(string.sub(tostring(expression), 1, ref.start_pos - 1))
        local trailing = trim(string.sub(tostring(expression), ref.end_pos + 1))
        if leading == "" and trailing == "" and text ~= "" then return ref.column end
        return nil
    end

    -- ---- 5. The translation --------------------------------------------------

    local NAME_PATTERN = "^[A-Za-z][A-Za-z0-9_]*$"

    local function usable_name(name, what)
        local value = tostring(name)
        if not value:match(NAME_PATTERN) then
            error("SEMANTIC_ADMIN_232: " .. what .. " " .. string.format("%q", value)
                .. " cannot be a semantic name, which is a letter followed by letters,"
                .. " digits and underscores. Rename it in the view.", 0)
        end
        return lower(value)
    end

    -- A DDL clause is found by its words at the top level of an entry, so an
    -- expression whose own top level holds one -- a column named FORMAT or
    -- COMMENT -- would be read as that clause. Parenthesised, it cannot be.
    local function guarded(expression, clause_words)
        for _, token in ipairs(sql_text.tokenize(expression)) do
            if token.depth == 0 and clause_words[name_of(token) or ""] then
                return "(" .. expression .. ")"
            end
        end
        return expression
    end

    -- `view` is {object_name, comment, columns = {{name, type, comment}...}};
    -- `select` is parse_select's; `scope` is qualify's, plus `entity` (its
    -- name) and `existing_descriptions` ({[DIMENSION NAME] = text}).
    local function translate(view, select, scope, clause_words)
        local columns = view.columns
        if #select.items ~= #columns then
            refuse_shape(#select.items .. " select items for " .. #columns .. " columns")
        end
        local prefix = lower(view.object_name)
        local plan = {dimensions = {}, facts = {}, metrics = {}}
        local dimension_items = {}
        for position, item in ipairs(select.items) do
            local column = columns[position]
            local name = usable_name(column.name, "column")
            local expression = item_expression(item)
            local calls = aggregate_calls(expression)
            local qualified, refs = qualify(expression, scope)
            if #calls == 0 then
                local source = plain_column(expression, scope)
                plan.dimensions[#plan.dimensions + 1] = {
                    name = name, expression = qualified, data_type = column.type,
                    description = comment_of(column.comment)
                        or scope.existing_descriptions[upper(name)]
                        or (source and comment_of(scope.columns[source].comment)) or nil,
                }
                dimension_items[#dimension_items + 1] = {position = position,
                    name = upper(column.name), expression = qualified}
            else
                for _, ref in ipairs(refs) do
                    local inside = false
                    for _, call in ipairs(calls) do
                        if ref.start_pos >= call.start_pos and ref.end_pos <= call.end_pos then
                            inside = true
                        end
                    end
                    if not inside then
                        refuse_shape("the column " .. ref.column .. " outside an aggregate in "
                            .. expression .. "; aggregate it, or make it its own column")
                    end
                end
                local pieces, cursor = {}, 1
                for number, call in ipairs(calls) do
                    local fact_name = prefix .. "__" .. name .. "_" .. number
                    local fact = {name = fact_name, expression = "1",
                                  data_type = "DECIMAL(18,0)"}
                    if not call.star then
                        fact.expression = qualify(call.argument, scope)
                        local source = plain_column(call.argument, scope)
                        fact.data_type = source and scope.columns[source].type or column.type
                    end
                    plan.facts[#plan.facts + 1] = fact
                    pieces[#pieces + 1] = string.sub(expression, cursor, call.start_pos - 1)
                    pieces[#pieces + 1] = call.written .. "("
                        .. (call.distinct and "DISTINCT " or "") .. fact_name .. ")"
                    cursor = call.end_pos + 1
                end
                pieces[#pieces + 1] = string.sub(expression, cursor)
                plan.metrics[#plan.metrics + 1] = {
                    name = name, expression = table.concat(pieces), data_type = column.type,
                    description = comment_of(column.comment),
                }
            end
        end
        if #plan.metrics == 0 then
            refuse_shape("no aggregate column; a semantic view needs at least one metric")
        end
        -- Every GROUP BY entry has to be a selected column, or the view is finer
        -- than its columns: it repeats a row per value of something it hides,
        -- and the semantic view would aggregate those rows together.
        for _, entry in ipairs(select.group_by) do
            local text = trim(entry)
            local found = false
            local ordinal = tonumber(text:match("^%d+$") or "")
            local qualified = qualify(text, scope)
            for _, dimension in ipairs(dimension_items) do
                if ordinal == dimension.position
                        or (ordinal == nil and sql_text.same_expression(qualified, dimension.expression))
                        or upper(text) == dimension.name or text == '"' .. dimension.name .. '"' then
                    found = true
                end
            end
            if not found then
                refuse_shape("GROUP BY " .. text .. ", which is not one of its plain columns,"
                    .. " so it has more rows than its columns tell apart")
            end
        end
        for _, list in ipairs({plan.dimensions, plan.facts}) do
            for _, entry in ipairs(list) do
                entry.expression = guarded(entry.expression, clause_words)
            end
        end
        for _, metric in ipairs(plan.metrics) do
            metric.expression = guarded(metric.expression, clause_words)
        end
        return plan
    end

    local function comment_clause(description)
        if description == nil then return "" end
        return " COMMENT " .. sql_text.sql_string(description)
    end

    local function render_alter(model_name, object_name, entity_name, plan)
        local function block(keyword, entries)
            return keyword .. " (" .. (#entries > 0 and ("\n  " .. table.concat(entries, ",\n  ")
                .. "\n") or "") .. ")"
        end
        local dimensions, facts, metrics = {}, {}, {}
        for _, d in ipairs(plan.dimensions) do
            dimensions[#dimensions + 1] = "DIMENSION " .. d.name .. " ON ENTITY " .. entity_name
                .. " AS " .. d.expression .. " RETURNS " .. d.data_type
                .. comment_clause(d.description)
        end
        for _, f in ipairs(plan.facts) do
            facts[#facts + 1] = "FACT " .. f.name .. " ON ENTITY " .. entity_name
                .. " AS " .. f.expression .. " RETURNS " .. f.data_type .. " PRIVATE"
        end
        for _, m in ipairs(plan.metrics) do
            metrics[#metrics + 1] = "METRIC " .. m.name .. " AS " .. m.expression
                .. " ON ENTITY " .. entity_name .. " RETURNS " .. m.data_type
                .. comment_clause(m.description)
        end
        return "ALTER SEMANTIC VIEW " .. model_name .. "." .. object_name .. "\n"
            .. block("REPLACE DIMENSIONS", dimensions) .. "\n"
            .. block("REPLACE FACTS", facts) .. "\n"
            .. block("REPLACE METRICS", metrics)
    end

    -- ---- 6. Against the catalog -------------------------------------------

    local function relation_row(sql, schema_name, object_name)
        local rows = query(sql, {schema_name = schema_name, object_name = object_name}) or {}
        if #rows == 0 and (schema_name ~= upper(schema_name) or object_name ~= upper(object_name)) then
            rows = query(sql, {schema_name = upper(schema_name),
                               object_name = upper(object_name)}) or {}
        end
        return rows[1]
    end

    local function columns_of(schema_name, object_name)
        local columns = {}
        for _, row in ipairs(query([[
            SELECT COLUMN_NAME, COLUMN_TYPE, COLUMN_COMMENT
            FROM SYS.EXA_ALL_COLUMNS
            WHERE COLUMN_SCHEMA = :schema_name AND COLUMN_TABLE = :object_name
            ORDER BY COLUMN_ORDINAL_POSITION
        ]], {schema_name = schema_name, object_name = object_name}) or {}) do
            columns[#columns + 1] = {name = tostring(row_value(row, "COLUMN_NAME", 1)),
                                     type = tostring(row_value(row, "COLUMN_TYPE", 2)),
                                     comment = row_value(row, "COLUMN_COMMENT", 3)}
        end
        return columns
    end

    local function read_view(view_schema, view_name)
        local row = relation_row([[
            SELECT VIEW_SCHEMA, VIEW_NAME, VIEW_TEXT, VIEW_COMMENT
            FROM SYS.EXA_ALL_VIEWS
            WHERE VIEW_SCHEMA = :schema_name AND VIEW_NAME = :object_name
        ]], view_schema, view_name)
        if row == nil then
            error("SEMANTIC_ADMIN_228: view " .. view_schema .. "." .. view_name
                .. " does not exist or is not visible to this user. A name is matched as"
                .. " written, then in upper case, the way Exasol folds an unquoted"
                .. " identifier.", 0)
        end
        local schema_name = tostring(row_value(row, "VIEW_SCHEMA", 1))
        local object_name = tostring(row_value(row, "VIEW_NAME", 2))
        local columns = columns_of(schema_name, object_name)
        if #columns == 0 then
            -- A view's columns are filled in when it is first compiled.
            query("SELECT * FROM " .. sql_text.quote_qualified(schema_name, object_name)
                .. " WHERE FALSE")
            columns = columns_of(schema_name, object_name)
        end
        return {schema_name = schema_name, object_name = object_name,
                text = row_value(row, "VIEW_TEXT", 3),
                comment = comment_of(row_value(row, "VIEW_COMMENT", 4)), columns = columns}
    end

    local function model_of(model_name)
        local rows = query([[
            SELECT MODEL_ID, ACTIVE_VERSION_ID, STATUS FROM SYS_SEMANTIC.MODELS
            WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
        ]], {model_name = model_name}) or {}
        if rows[1] == nil then return nil end
        return {model_id = row_value(rows[1], "MODEL_ID", 1),
                version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2),
                status = row_value(rows[1], "STATUS", 3), model_name = model_name}
    end

    local function entity_for(model, relation, entity_name)
        local named, over_relation = nil, nil
        for _, row in ipairs(query([[
            SELECT ENTITY_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS
            FROM SYS_SEMANTIC.ENTITIES
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS = 'ACTIVE'
            ORDER BY ENTITY_ID
        ]], {model_id = model.model_id, version_id = model.version_id}) or {}) do
            local entity = {id = row_value(row, "ENTITY_ID", 1),
                            name = tostring(row_value(row, "ENTITY_NAME", 2)),
                            schema = tostring(row_value(row, "SOURCE_SCHEMA", 3)),
                            object = tostring(row_value(row, "SOURCE_OBJECT", 4)),
                            alias = tostring(row_value(row, "SOURCE_ALIAS", 5))}
            local same = entity.schema == relation.schema and entity.object == relation.object
            if upper(entity.name) == upper(entity_name) then named = entity end
            if same and (over_relation == nil or upper(entity.name) == upper(entity_name)) then
                over_relation = entity
            end
        end
        if over_relation == nil and named ~= nil then
            error("SEMANTIC_ADMIN_231: entity " .. named.name .. " in model "
                .. model.model_name .. " is over " .. named.schema .. "." .. named.object
                .. ", not " .. relation.schema .. "." .. relation.object .. ". ADOPT_VIEW names"
                .. " an entity after its table, so adopt this view into another model or"
                .. " rename the table.", 0)
        end
        return over_relation
    end

    -- A new entity's alias: the view's own, else one made from the table name;
    -- an identifier, not reserved, and not taken in the model.
    local function free_alias(model, wanted, relation_name)
        local function free(candidate)
            if not candidate:match(NAME_PATTERN) then return false end
            local reserved = scalar([[
                SELECT COUNT(*) FROM SYS.EXA_SQL_KEYWORDS
                WHERE UPPER(KEYWORD) = UPPER(:alias) AND RESERVED = TRUE
            ]], {alias = candidate})
            if tonumber(reserved or 0) > 0 then return false end
            local taken = scalar([[
                SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITIES
                WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
                  AND UPPER(SOURCE_ALIAS) = UPPER(:alias)
            ]], {model_id = model.model_id, version_id = model.version_id, alias = candidate})
            return tonumber(taken or 0) == 0
        end
        if wanted ~= nil and free(wanted) then return wanted end
        local base = lower(relation_name):gsub("[^a-z0-9_]", "_")
        if not base:match("^[a-z]") then base = "t_" .. base end
        if free(base) then return base end
        for number = 1, 99 do
            if free(base .. "_" .. number) then return base .. "_" .. number end
        end
        error("SEMANTIC_ADMIN_233: no free entity alias for " .. tostring(relation_name)
            .. " in model " .. tostring(model.model_name) .. ": the view's own alias and "
            .. base .. ", " .. base .. "_1 to " .. base .. "_99 are all taken or reserved."
            .. " Give the view an alias that is free.", 0)
    end

    local function object_of(model, object_name)
        local rows = query([[
            SELECT so.OBJECT_ID, e.SOURCE_SCHEMA, e.SOURCE_OBJECT
            FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
            JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = so.ROOT_ENTITY_ID
            WHERE so.MODEL_ID = :model_id AND so.VERSION_ID = :version_id
              AND UPPER(so.OBJECT_NAME) = UPPER(:object_name)
        ]], {model_id = model.model_id, version_id = model.version_id,
             object_name = object_name}) or {}
        if rows[1] == nil then return nil end
        return {id = row_value(rows[1], "OBJECT_ID", 1),
                schema = tostring(row_value(rows[1], "SOURCE_SCHEMA", 2)),
                object = tostring(row_value(rows[1], "SOURCE_OBJECT", 3))}
    end

    local function existing_descriptions(model)
        local descriptions = {}
        for _, row in ipairs(query([[
            SELECT DIMENSION_NAME, DESCRIPTION FROM SYS_SEMANTIC.DIMENSIONS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS = 'ACTIVE'
        ]], {model_id = model.model_id, version_id = model.version_id}) or {}) do
            descriptions[upper(row_value(row, "DIMENSION_NAME", 1))] =
                comment_of(row_value(row, "DESCRIPTION", 2))
        end
        return descriptions
    end

    -- What the view no longer has: the object's metrics that are not in the
    -- plan, and this view's private facts that are not. Dropped, because
    -- REPLACE only takes them out of the view: a metric would keep its
    -- model-unique name, and the facts would pile up.
    local function stale_members(model, object_id_value, prefix, plan)
        local wanted_metrics, wanted_facts = {}, {}
        for _, m in ipairs(plan.metrics) do wanted_metrics[upper(m.name)] = true end
        for _, f in ipairs(plan.facts) do wanted_facts[upper(f.name)] = true end
        local metrics, facts = {}, {}
        for _, row in ipairs(query([[
            SELECT mt.METRIC_NAME FROM SYS_SEMANTIC.METRICS mt
            JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc
              ON oc.COLUMN_KIND = 'METRIC' AND oc.OBJECT_REF_ID = mt.METRIC_ID
            WHERE oc.OBJECT_ID = :object_id AND mt.STATUS = 'ACTIVE'
            ORDER BY mt.METRIC_NAME
        ]], {object_id = object_id_value}) or {}) do
            local name = tostring(row_value(row, "METRIC_NAME", 1))
            if not wanted_metrics[upper(name)] then metrics[#metrics + 1] = name end
        end
        for _, row in ipairs(query([[
            SELECT FACT_NAME FROM SYS_SEMANTIC.FACTS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS = 'ACTIVE'
              AND UPPER(FACT_NAME) LIKE UPPER(:prefix) ESCAPE '\'
            ORDER BY FACT_NAME
        ]], {model_id = model.model_id, version_id = model.version_id,
             prefix = prefix:gsub("_", "\\_") .. "\\_\\_%"}) or {}) do
            local name = tostring(row_value(row, "FACT_NAME", 1))
            if not wanted_facts[upper(name)] then facts[#facts + 1] = name end
        end
        return metrics, facts
    end

    local ADOPTION_TABLES = {"ENTITIES", "ENTITY_REPRESENTATIONS", "SEMANTIC_OBJECTS"}

    -- One adoption at a time. dbt adopts view models in parallel threads, and
    -- two adoptions that each read the catalog and then wrote it were both
    -- rolled back by Exasol as a transaction collision. A write before any
    -- catalog read makes the second wait for the first to commit instead:
    -- Exasol locks a table for writing whether or not a row changes.
    --
    -- Waiting is not quite enough. Rows read after the wait are current, but
    -- which schemas and views exist is fixed when the transaction starts, so
    -- an adoption that waited while the first adoption into a new model
    -- created its published schema cannot see that schema: it creates it
    -- again and fails at commit, or cannot create a view in it. It can tell,
    -- because the model reads PUBLISHED while its schema is not there; then it
    -- commits -- before writing anything, so only what the caller had pending
    -- goes with it, for dbt the view it just created -- and takes the lock in a
    -- fresh transaction.
    local function lock_catalog(model_name)
        for _ = 1, 3 do
            query("UPDATE SYS_SEMANTIC.MODELS SET UPDATED_AT = UPDATED_AT WHERE FALSE")
            local stale = scalar([[
                SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS m
                WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name) AND m.STATUS = 'PUBLISHED'
                  AND NOT EXISTS (SELECT 1 FROM SYS.EXA_SCHEMAS s
                                  WHERE s.SCHEMA_NAME = m.PUBLISHED_SCHEMA)
            ]], {model_name = model_name})
            if tonumber(stale or 0) == 0 then return end
            query("COMMIT")
        end
    end

    -- `definition` carries what the definition module owns: `interior_tables`,
    -- its rollback table list, and `clause_words`, the first word of each DDL
    -- clause.
    function M.adopt_view(model_name, view_schema, view_name, definition)
        for label, value in pairs({MODEL_NAME = model_name, VIEW_SCHEMA = view_schema,
                                   VIEW_NAME = view_name}) do
            if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required", 0) end
        end
        model_name, view_schema, view_name = trim(model_name), trim(view_schema), trim(view_name)
        lock_catalog(model_name)
        local statements = {}
        local function run_script(sql, params)
            local rendered = sql
            for name, value in pairs(params) do
                rendered = rendered:gsub(":" .. name .. "%f[^%w_]", function()
                    return missing(value) and "NULL" or sql_text.sql_string(value)
                end)
            end
            statements[#statements + 1] = rendered .. ";"
            return query(sql, params)
        end
        local function apply_ddl(ddl)
            statements[#statements + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
                .. sql_text.sql_string(ddl) .. ", FALSE);"
            local rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(:ddl, FALSE)",
                {ddl = ddl}) or {}
            local first = rows[1]
            if first ~= nil and row_value(first, "STATUS", 1) == "ERROR" then
                local code = tostring(row_value(first, "ERROR_CODE", 2) or "SEMANTIC_DDL_999")
                local message = tostring(row_value(first, "MESSAGE", 3))
                -- The message usually opens with its code already.
                if message:sub(1, #code) ~= code then message = code .. ": " .. message end
                error(message, 0)
            end
        end

        local view = read_view(view_schema, view_name)
        local object_name = upper(usable_name(view.object_name, "view name"))
        local select = parse_select(extract_query(view.text))
        local relation_schema, relation_object = source_columns.require_relation(query,
            select.relation.schema, select.relation.object)
        local relation = {schema = relation_schema, object = relation_object}
        local entity_name = usable_name(relation.object, "table name")

        local model = model_of(model_name)
        local created_model = model == nil
        local snapshot, tables = nil, nil
        local ok, result = pcall(function()
            if created_model then
                run_script("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(:model_name,"
                    .. " :published_schema, NULL, NULL)",
                    {model_name = model_name, published_schema = "SEMANTIC_" .. upper(model_name)})
                model = assert(model_of(model_name), "CREATE_MODEL left no model")
            else
                tables = {}
                for _, name in ipairs(ADOPTION_TABLES) do
                    tables[#tables + 1] = {name = name,
                        where = "MODEL_ID = :model_id AND VERSION_ID = :version_id"}
                end
                for _, spec in ipairs(definition.interior_tables) do tables[#tables + 1] = spec end
                snapshot = rollback.snapshot(query, tables,
                    {model_id = model.model_id, version_id = model.version_id},
                    "SEMANTIC_DDL_091")
            end

            local entity = entity_for(model, relation, entity_name)
            if entity == nil then
                local alias = free_alias(model, select.alias and not select.alias.quoted
                    and lower(select.alias.written) or nil, relation.object)
                local comment = scalar([[
                    SELECT OBJECT_COMMENT FROM SYS.EXA_ALL_OBJECTS
                    WHERE ROOT_NAME = :schema_name AND OBJECT_NAME = :object_name
                      AND OBJECT_TYPE IN ('TABLE', 'VIEW')
                ]], {schema_name = relation.schema, object_name = relation.object})
                run_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(:model_name, :entity_name,"
                    .. " :source_schema, :source_object, :source_alias, NULL, NULL, :description)",
                    {model_name = model_name, entity_name = entity_name,
                     source_schema = relation.schema, source_object = relation.object,
                     source_alias = alias, description = null_if_missing(comment_of(comment))})
                entity = {name = entity_name, alias = alias}
            end

            local object = object_of(model, object_name)
            if object ~= nil and (object.schema ~= relation.schema
                    or object.object ~= relation.object) then
                error("SEMANTIC_ADMIN_230: semantic view " .. object_name .. " is over "
                    .. object.schema .. "." .. object.object .. ", and the view now reads "
                    .. relation.schema .. "." .. relation.object .. ". Remove it first with"
                    .. " EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_OBJECT("
                    .. sql_text.sql_string(model_name) .. ", "
                    .. sql_text.sql_string(object_name) .. "), then adopt the view again.", 0)
            end
            if object == nil then
                run_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(:model_name,"
                    .. " :object_name, :root_entity_name, :description)",
                    {model_name = model_name, object_name = object_name,
                     root_entity_name = entity.name,
                     description = null_if_missing(view.comment)})
                object = object_of(model, object_name)
            end

            local scope = {alias = entity.alias, schema = relation.schema,
                           object = relation.object, columns = {},
                           qualifiers = {[upper(relation.object)] = true},
                           existing_descriptions = existing_descriptions(model)}
            if select.alias ~= nil then scope.qualifiers[select.alias.name] = true end
            for _, column in ipairs(columns_of(relation.schema, relation.object)) do
                scope.columns[column.name] = column
            end
            local plan = translate(view, select, scope, definition.clause_words)
            local alter = render_alter(model_name, object_name, entity.name, plan)
            local stale_metrics, stale_facts = stale_members(model, object.id,
                lower(object_name), plan)
            for _, name in ipairs(stale_metrics) do
                apply_ddl("ALTER SEMANTIC VIEW " .. model_name .. "." .. object_name
                    .. " DROP METRIC " .. name)
            end
            apply_ddl(alter)
            for _, name in ipairs(stale_facts) do
                apply_ddl("ALTER SEMANTIC VIEW " .. model_name .. "." .. object_name
                    .. " DROP FACT " .. name)
            end
            -- APPLY_SEMANTIC_DEFINITION refreshed a model that was published.
            if tostring(model.status or "") ~= "PUBLISHED" then
                run_script("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)",
                    {model_name = model_name})
            end
            return {{model_name, object_name, #plan.dimensions, #plan.metrics, "OK",
                     table.concat(statements, "\n\n")}}
        end)
        if ok then return result end
        -- Nothing the adoption did may outlive its refusal: an object left
        -- empty would stop the whole model publishing (SEMANTIC_SURFACE_014).
        if created_model then
            pcall(query, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS(:model_name)",
                {model_name = model_name})
        elseif snapshot ~= nil then
            rollback.restore(query, tables, snapshot,
                {model_id = model.model_id, version_id = model.version_id})
            pcall(query, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            if tostring(model.status or "") == "PUBLISHED" then
                pcall(query, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)",
                    {model_name = model_name})
            end
        end
        error(result, 0)
    end

    M.extract_query = extract_query
    M.parse_select = parse_select
    M.item_expression = item_expression
    M.aggregate_calls = aggregate_calls
    M.qualify = qualify
    M.translate = translate
    M.render_alter = render_alter
end

ESV_VIEW_ADOPTION = M
