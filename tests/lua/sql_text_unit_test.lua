local sql_text = ESV_SQL_TEXT

test("shared sql text quotes identifiers and literals for Exasol", function()
    -- Exasol resolves an unquoted identifier case-insensitively and a quoted one
    -- exactly, so an embedded quote has to double rather than terminate.
    assert_equal(sql_text.quote_ident("region"), '"region"')
    assert_equal(sql_text.quote_ident('we"ird'), '"we""ird"')
    assert_equal(sql_text.quote_ident(7), '"7"')
    assert_equal(sql_text.quote_qualified("MART", "ORDER LINES"),
        '"MART"."ORDER LINES"')

    assert_equal(sql_text.sql_string("plain"), "'plain'")
    assert_equal(sql_text.sql_string("it's"), "'it''s'")
end)

test("shared sql literal renders a filter value for its declared type", function()
    -- The declared type is load-bearing: Exasol will not coerce a string to a
    -- DATE in every position, and a quoted numeric compares differently from a
    -- bare one.
    assert_equal(sql_text.sql_literal("2020-01-31", "DATE"), "DATE '2020-01-31'")
    assert_equal(sql_text.sql_literal("2020-01-31 10:00:00", "TIMESTAMP"),
        "TIMESTAMP '2020-01-31 10:00:00'")
    assert_equal(sql_text.sql_literal("42", "DECIMAL(18,2)"), "42")
    assert_equal(sql_text.sql_literal("-1.5", "DOUBLE"), "-1.5")
    assert_equal(sql_text.sql_literal(12, "DECIMAL(18,0)"), "12")
    assert_equal(sql_text.sql_literal(true, "BOOLEAN"), "TRUE")
    assert_equal(sql_text.sql_literal(false, "BOOLEAN"), "FALSE")

    -- A value that does not match its declared type falls back to a quoted
    -- string rather than being emitted bare, which is the safe direction.
    assert_equal(sql_text.sql_literal("not-a-date", "DATE"), "'not-a-date'")
    assert_equal(sql_text.sql_literal("12x", "DECIMAL(18,0)"), "'12x'")
    assert_equal(sql_text.sql_literal("EMEA", "VARCHAR(100)"), "'EMEA'")

    -- An absent type is not an error; it is an unknown type.
    assert_equal(sql_text.sql_literal("2020-01-31"), "'2020-01-31'")

    -- Every spelling of absent renders as SQL NULL. json.NULL is in the list
    -- because a filter value arrives from a decoded request.
    assert_equal(sql_text.sql_literal(nil, "DATE"), "NULL")
    assert_equal(sql_text.sql_literal(null, "DATE"), "NULL")
    assert_equal(sql_text.sql_literal(ESV_JSON.NULL, "DATE"), "NULL")
end)

test("shared alias rewriting respects string literals", function()
    -- How an attribute bound to one representation is re-pointed at another, so
    -- it runs on every fusion path. This function was byte-identical in the
    -- validator and the compiler, which meant the validator proved an expression
    -- safe with one copy while the compiler emitted SQL with the other -- and a
    -- divergence there is not a crash, it is SQL that is wrong and validates.
    assert_equal(sql_text.replace_qualified_alias("o.amount + o.tax", "o", "crm"),
        "crm.amount + crm.tax")
    assert_equal(sql_text.replace_qualified_alias("O.amount", "o", "crm"),
        "crm.amount")

    -- A bare word that is not followed by a dot is a column, not an alias.
    assert_equal(sql_text.replace_qualified_alias("o + o.x", "o", "crm"),
        "o + crm.x")
    -- Whitespace between the alias and its dot still qualifies.
    assert_equal(sql_text.replace_qualified_alias("o .x", "o", "crm"), "crm .x")
    -- A longer word that merely starts with the alias is left alone.
    assert_equal(sql_text.replace_qualified_alias("orders.x", "o", "crm"),
        "orders.x")

    -- The part that has to be right: inside a literal, `o.` is data.
    assert_equal(sql_text.replace_qualified_alias("o.x = 'o.x'", "o", "crm"),
        "crm.x = 'o.x'")
    assert_equal(sql_text.replace_qualified_alias("'it''s o.x' || o.y", "o", "crm"),
        "'it''s o.x' || crm.y")
end)

test("shared literal stripping blanks contents and preserves offsets", function()
    -- Offsets survive so a caller can scan the stripped text for aliases or
    -- function calls and index back into the original.
    local original = "a = 'x.y' AND b = 'z'"
    local stripped = sql_text.strip_string_literals(original)
    assert_equal(#stripped, #original)
    assert_equal(stripped, "a =       AND b =    ")
    assert_true(string.find(stripped, "x.y", 1, true) == nil)

    local escaped = "'it''s' || c"
    assert_equal(#sql_text.strip_string_literals(escaped), #escaped)
    assert_contains(sql_text.strip_string_literals(escaped), "|| c")

    -- An unterminated literal blanks to the end rather than falling out of
    -- quote state and exposing its contents.
    assert_true(string.find(sql_text.strip_string_literals("a = 'oops"),
        "oops", 1, true) == nil)
end)

test("flattening keeps a spliced statement on the author's line numbers", function()
    -- The reason this exists: expansion splices compiled SQL into the middle of
    -- somebody else's statement, and eight lines of it moved every later line
    -- down by eight. Exasol then reported failures at "line 10" of a one-line
    -- query, pointing into text the author had never seen.
    assert_equal(sql_text.flatten_lines("SELECT a\nFROM t\nWHERE b = 1"),
        "SELECT a FROM t WHERE b = 1")
    assert_equal(sql_text.flatten_lines("a\r\nb"), "a  b")
    assert_equal(sql_text.flatten_lines("no newlines"), "no newlines")
    assert_equal(sql_text.flatten_lines(nil), nil)

    -- The part that has to be right: a newline inside a literal is data, and
    -- folding it would change the value rather than the layout.
    local with_literal = "SELECT 'two\nlines'\nFROM t"
    assert_equal(sql_text.flatten_lines(with_literal), "SELECT 'two\nlines' FROM t")

    -- A line comment cannot be folded at all: removing its newline would
    -- comment out the rest of the statement, so the text is left alone.
    local commented = "SELECT a -- why\nFROM t"
    assert_equal(sql_text.flatten_lines(commented), commented)
    local block = "SELECT a /* why */\nFROM t"
    assert_equal(sql_text.flatten_lines(block), block)

    -- A `--` that is only inside a literal is not a comment, so folding stands.
    assert_equal(sql_text.flatten_lines("SELECT '--'\nFROM t"), "SELECT '--' FROM t")
end)

test("shared lexer tokenizes the Exasol dialect once for both parsers", function()
    local tokens = sql_text.tokenize(
        "SELECT a, 'lit''x', \"Qu\"\"oted\", 12.5 FROM s.o -- trailing\n;")
    local kinds = {}
    for _, token in ipairs(tokens) do kinds[#kinds + 1] = token.kind end
    assert_equal(table.concat(kinds, " "),
        "word word symbol literal symbol identifier symbol number word word symbol word")

    -- Every token carries its byte span and its paren depth, which is what the
    -- DDL parser slices clauses with.
    assert_equal(tokens[1].start_pos, 1)
    assert_equal(tokens[1].end_pos, 6)
    assert_equal(tokens[1].upper, "SELECT")
    assert_equal(tokens[4].text, "'lit''x'")
    assert_equal(tokens[6].value, 'Qu"oted')

    -- The trailing semicolon is dropped; comments are skipped entirely.
    assert_equal(tokens[#tokens].text, "o")
    assert_equal(#sql_text.tokenize("/* only a comment */"), 0)
    assert_equal(#sql_text.tokenize("-- only a comment"), 0)
    -- A line comment ends at the newline rather than eating what follows it.
    assert_equal(#sql_text.tokenize("-- lead\nSELECT a"), 2)
    assert_equal(#sql_text.tokenize(""), 0)
    -- An unterminated comment or literal ends the input rather than looping.
    assert_equal(#sql_text.tokenize("/* never closed"), 0)
    assert_equal(sql_text.tokenize("'never closed")[1].kind, "literal")

    -- A closing paren carries the depth it returns to, which is the depth its
    -- matching opening paren was emitted at. So both parentheses of a top-level
    -- group sit at 0 and only what is between them is nested -- which is what
    -- lets the DDL parser find top-level commas by reading `depth == 0`.
    local nested = sql_text.tokenize("f( g( x ) )")
    local depths = {}
    for _, token in ipairs(nested) do depths[#depths + 1] = tostring(token.depth) end
    assert_equal(table.concat(depths, " "), "0 0 1 1 2 1 0")
end)

test("shared lexer's two modes differ in exactly the two documented ways", function()
    -- One lexer, two flags, because its two callers genuinely disagree. This is
    -- the whole remaining difference between what used to be two files, and
    -- naming it here is what stops it growing back into a third.
    local sql = 'a >= 1 AND b <> 2 AND c != 3 AND d <= 4 AND "AND" = 5'

    -- operators: the semantic-SQL parser compares whole operators; the DDL
    -- parser slices expressions by byte offset and has always seen two symbols.
    local fused = sql_text.tokenize(sql, {operators = true})
    local split = sql_text.tokenize(sql)
    assert_true(#fused < #split, "fusing operators must produce fewer tokens")
    local operators = {}
    for _, token in ipairs(fused) do
        if token.kind == "operator" then operators[#operators + 1] = token.text end
    end
    assert_equal(table.concat(operators, " "), ">= <> != <=")
    for _, token in ipairs(split) do
        assert_true(token.kind ~= "operator", "unfused mode emits no operator tokens")
    end
    assert_branch("sql_text.lexer.operators", #operators > 0, true)
    assert_branch("sql_text.lexer.operators", false, false)

    -- upper_identifiers: the DDL parser reads names out of quoted tokens, so it
    -- wants the folded form. The semantic-SQL parser must not have it, because
    -- token_upper is what its clause scanner compares against keywords -- a
    -- column quoted as "AND" would otherwise parse as a conjunction.
    local function last_identifier(tokens)
        for index = #tokens, 1, -1 do
            if tokens[index].kind == "identifier" then return tokens[index] end
        end
    end
    local plain = last_identifier(sql_text.tokenize(sql, {operators = true}))
    local folded = last_identifier(sql_text.tokenize(sql, {upper_identifiers = true}))
    assert_equal(plain.value, "AND")
    assert_equal(plain.upper, nil)
    assert_equal(sql_text.token_upper(plain), '"AND"')
    assert_equal(folded.upper, "AND")
    assert_equal(sql_text.token_upper(folded), "AND")
    assert_branch("sql_text.lexer.upper_identifiers", folded.upper ~= nil, true)
    assert_branch("sql_text.lexer.upper_identifiers", plain.upper ~= nil, false)

    -- Nothing else differs: same count, same spans, same kinds.
    local ddl = sql_text.tokenize(sql, {upper_identifiers = true})
    local compiler = sql_text.tokenize(sql, {operators = true})
    local ddl_words, compiler_words = {}, {}
    for _, token in ipairs(ddl) do
        if token.kind == "word" then
            ddl_words[#ddl_words + 1] = token.upper .. "@" .. token.start_pos
        end
    end
    for _, token in ipairs(compiler) do
        if token.kind == "word" then
            compiler_words[#compiler_words + 1] = token.upper .. "@" .. token.start_pos
        end
    end
    assert_equal(table.concat(ddl_words, " "), table.concat(compiler_words, " "))
end)

test("shared token_upper never mistakes a quoted identifier for a keyword", function()
    assert_equal(sql_text.token_upper(nil), nil)
    assert_equal(sql_text.token_upper({text = "select"}), "SELECT")
    assert_equal(sql_text.token_upper({text = "x", upper = "PRECOMPUTED"}),
        "PRECOMPUTED")
    assert_equal(sql_text.decode_quoted_identifier('"a""b"'), 'a"b')
end)

test("null literal recognition is narrow on purpose", function()
    -- A binding whose expression is a literal NULL is how a caller says "this
    -- representation has no such column". SEMANTIC_MODEL_063 refuses a model
    -- when one of those is preferred over real data, so a false positive costs
    -- someone a valid model. Under-matching only costs the diagnostic.
    for _, text in ipairs({"NULL", "null", "  NULL  ", "(NULL)", "((NULL))",
        "CAST(NULL AS VARCHAR(10))", "cast( null as decimal(18,2) )",
        "CAST(NULL AS DATE)", "CAST(NULL AS TIMESTAMP WITH LOCAL TIME ZONE)"}) do
        assert_true(ESV_SQL_TEXT.is_null_literal(text), "not matched: " .. text)
    end
    for _, text in ipairs({"c.churn_risk", "COALESCE(c.a, NULL)", "'NULL'",
        "CAST(c.x AS VARCHAR(10))", "NULLIF(c.a, 0)", "NULLABLE",
        "CAST(NULL AS VARCHAR(10)) || c.x"}) do
        assert_true(not ESV_SQL_TEXT.is_null_literal(text), "wrongly matched: " .. text)
    end
    assert_true(not ESV_SQL_TEXT.is_null_literal(nil))
    assert_branch("sql_text.null_literal", ESV_SQL_TEXT.is_null_literal("NULL"), true)
    assert_branch("sql_text.null_literal", ESV_SQL_TEXT.is_null_literal("c.x"), false)
end)

test("output projection returns the caller's select list, named and ordered", function()
    -- The planner emits its own order (dimensions, then metrics) under the
    -- semantic field name. A SQL client asked for something else: its own order,
    -- its own aliases, and -- unaliased -- the upper-case name the published view
    -- advertises. Binding by position against the planner's order silently puts
    -- the wrong data in each column, which is why this exists.
    local inner = 'SELECT c.region AS "customer_region", SUM(x) AS "total_revenue" FROM t'

    local reordered = sql_text.output_projection(inner, {
        {source = "total_revenue", output = "a0"},
        {source = "customer_region", output = "c11"},
    })
    assert_contains(reordered, '"total_revenue" AS "a0", "customer_region" AS "c11"')
    assert_contains(reordered, "FROM (\n" .. inner)

    -- Unaliased columns take the published SQL name.
    assert_contains(sql_text.output_projection(inner, {
        {source = "customer_region", output = "CUSTOMER_REGION"},
    }), '"customer_region" AS "CUSTOMER_REGION"')

    -- A name needing quotes survives it.
    assert_contains(sql_text.output_projection(inner, {
        {source = "customer_region", output = 'we"ird'},
    }), '"customer_region" AS "we""ird"')

    -- Nothing to project: the structured lane and any caller without a select
    -- list pay nothing.
    assert_equal(sql_text.output_projection(inner, {}), inner)
    assert_equal(sql_text.output_projection(inner, nil), inner)
    assert_equal(sql_text.output_projection(nil, {{source = "a", output = "b"}}), nil)
    -- A column with no source would rename a column that does not exist; leave
    -- the compiled SQL alone rather than emit SQL that cannot run.
    assert_equal(sql_text.output_projection(inner, {{source = "", output = "b"}}), inner)
    assert_branch("sql_text.output_projection",
        sql_text.output_projection(inner, {}) == inner, true)
    assert_branch("sql_text.output_projection",
        sql_text.output_projection(inner, {{source = "a", output = "b"}}) == inner, false)
end)
