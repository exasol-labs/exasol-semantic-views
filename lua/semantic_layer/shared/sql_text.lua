-- Reading and writing SQL text, shared by every runtime that does either.
--
-- `shared/grain_graph.lua` exists because relationship proofs must not drift
-- between the validator and the compiler, and CLAUDE.md states that invariant.
-- Nothing stated it for *SQL rendering*, and the rendering drifted the same way:
-- BUG-G03 was one defect -- a declared column name quoted verbatim -- living
-- independently in five copies of the F5 mapping join, and fixing it meant
-- finding all five.
--
-- `shared/identity_join.lua` closed that instance and, in its own header,
-- named this module as the thing it could not yet call:
--
--   > Quoting is duplicated from the caller runtimes deliberately: three lines
--   > each, against a module that would otherwise have to receive them as
--   > arguments at every call. The alternative -- a shared SQL module -- is a
--   > bigger change than this one earns.
--
-- This is that module, so identity_join now calls it instead.
--
-- Two of the routines here are the ones worth the move. `replace_qualified_alias`
-- rewrites a table alias inside an expression while respecting string literals --
-- it is how a representation's expression gets re-pointed at a different source --
-- and `strip_string_literals` backs the alias and column analysis the validator
-- proves expressions with. They were byte-identical in admin/validator.lua and
-- compiler/request_json.lua, which means the validator proved an expression safe
-- with one copy while the compiler emitted SQL with the other. A divergence
-- there is not a crash; it is SQL that is wrong and validates.

local json = assert(ESV_JSON, "shared JSON runtime is required")

local M = {}

local function upper(value)
    return string.upper(tostring(value))
end

-- ---------------------------------------------------------------------------
-- Quoting
-- ---------------------------------------------------------------------------

-- Exasol resolves an unquoted identifier case-insensitively and a quoted one
-- exactly, so everything the compiler emits is quoted and everything it quotes
-- has to be the physical spelling (see shared/source_columns.lua).
function M.quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

function M.quote_qualified(schema_name, object_name)
    return M.quote_ident(schema_name) .. "." .. M.quote_ident(object_name)
end

function M.sql_string(value)
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

-- A filter value rendered for its declared column type.
--
-- The type matters because Exasol will not silently coerce a string to a DATE in
-- every position, and an unadorned numeric literal compares differently from a
-- quoted one. `data_type` may be absent; an unknown type falls through to a
-- quoted string, which is the safe default.
function M.sql_literal(value, data_type)
    if value == nil or value == null or value == json.NULL then
        return "NULL"
    end
    local value_type = type(value)
    if value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "TRUE" or "FALSE"
    end
    local text = tostring(value)
    local dtype = upper(data_type or "")
    if string.sub(dtype, 1, 4) == "DATE"
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
        return "DATE " .. M.sql_string(text)
    end
    if string.find(dtype, "TIMESTAMP", 1, true) == 1
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d") then
        return "TIMESTAMP " .. M.sql_string(text)
    end
    if string.find(dtype, "DECIMAL", 1, true)
        or string.find(dtype, "INT", 1, true)
        or string.find(dtype, "NUMBER", 1, true)
        or string.find(dtype, "DOUBLE", 1, true) then
        if string.match(text, "^%-?%d+%.?%d*$") then
            return text
        end
    end
    return M.sql_string(text)
end

-- ---------------------------------------------------------------------------
-- Expression rewriting
-- ---------------------------------------------------------------------------

-- Replace `source_alias.` with `target_alias.` throughout an expression, without
-- touching anything inside a string literal.
--
-- This is how an attribute bound to one representation is re-pointed at another,
-- so it runs on every fusion path. The literal handling is the part that has to
-- be right: `'o.name'` is data, `o.name` is a column reference, and a naive
-- gsub cannot tell them apart.
function M.replace_qualified_alias(expression, source_alias, target_alias)
    local source = upper(source_alias)
    local text = tostring(expression)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif not in_quote and string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local cursor = j
            while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
            local token = string.sub(text, i, j - 1)
            if upper(token) == source and string.sub(text, cursor, cursor) == "." then
                out[#out + 1] = target_alias
            else
                out[#out + 1] = token
            end
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Blank out the contents of every string literal, preserving byte offsets.
--
-- Offsets are preserved so a caller can scan the result for aliases, column
-- references or function calls and still index back into the original text.
function M.strip_string_literals(text)
    local out = {}
    local in_quote = false
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                out[#out + 1] = " "
                out[#out + 1] = " "
                i = i + 2
            else
                in_quote = not in_quote
                out[#out + 1] = " "
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = " "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Is this expression a bare SQL NULL constant?
--
-- A binding whose expression is a literal NULL means one thing: "this
-- representation does not carry this attribute." That is a legitimate and
-- necessary declaration -- it is how a caller says the primary has no such
-- column -- but it is only ever correct as the *least* preferred binding, and
-- the catalog cannot tell a placeholder from real data without asking.
--
-- Deliberately narrow. It matches NULL and CAST(NULL AS <type>), with optional
-- wrapping parentheses, and nothing else. An exotic spelling that is also
-- constant-NULL -- COALESCE(NULL, NULL), a UDF that returns NULL -- is not
-- matched, and that is the safe direction to be wrong in: the rules built on
-- this refuse a model, so a false positive costs a user a valid model while a
-- false negative only costs the diagnostic that was missing anyway.
function M.is_null_literal(expression)
    if expression == nil then return false end
    local text = tostring(expression):match("^%s*(.-)%s*$")
    -- Peel wrapping parens: ((NULL)) is the same constant as NULL.
    while true do
        local inner = text:match("^%(%s*(.-)%s*%)$")
        if inner == nil or inner == text then break end
        text = inner
    end
    local upper_text = string.upper(text)
    if upper_text == "NULL" then return true end
    local cast_target = upper_text:match("^CAST%s*%(%s*NULL%s+AS%s+(.+)%)$")
    if cast_target == nil then return false end
    -- The target has to look like a type name, not another expression that
    -- happens to close a paren early: VARCHAR(10), DECIMAL(18,2), DATE.
    return cast_target:match("^[A-Z][A-Z0-9_ ]*%s*%(?[%d%s,%)]*$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Lexing
-- ---------------------------------------------------------------------------

function M.decode_quoted_identifier(token_text)
    return string.gsub(string.sub(tostring(token_text), 2, -2), '""', '"')
end

-- The uppercase form of a token for keyword comparison.
--
-- Falls back to the token's raw `text`, which for a quoted identifier still
-- carries its quotes -- so `"AND"` never compares equal to the keyword AND
-- unless the lexer was asked to fold identifiers (see `upper_identifiers`).
function M.token_upper(token)
    if token == nil then
        return nil
    end
    return token.upper or upper(token.text)
end

-- One lexer for the Exasol dialect, with two options where its two callers
-- genuinely disagree.
--
-- Everything else -- whitespace, `--` and `/* */` comments, single-quoted
-- literals with `''` escapes, double-quoted identifiers with `""` escapes,
-- words, numbers, symbols, the trailing semicolon -- was character-for-character
-- identical in compiler/request_json.lua's `sql_tokens` and
-- admin/semantic_definition.lua's `tokenize`. A new literal form or comment
-- syntax had to be taught twice.
--
--   options.operators          fuse `>=`, `<=`, `<>`, `!=` into one token. The
--                              semantic-SQL parser compares whole operators; the
--                              DDL parser slices expressions by byte offset and
--                              never looks at them, and has always seen two
--                              symbols. Changing that for the DDL would alter a
--                              4 600-line parser for no gain.
--
--   options.upper_identifiers  set `upper` on a quoted identifier from its
--                              *decoded* value. The DDL parser wants it, because
--                              it reads names out of quoted tokens. The
--                              semantic-SQL parser must not have it: `token_upper`
--                              is what its clause scanner compares against
--                              keywords, so folding `"AND"` to `AND` would make a
--                              quoted column named "and" parse as a conjunction.
--
-- Every token carries `start_pos`, `end_pos` and `depth` regardless. The
-- semantic-SQL parser ignores them; that costs three assignments and removes the
-- reason to keep a second lexer.
function M.tokenize(text, options)
    options = options or {}
    local fuse_operators = options.operators == true
    local fold_identifiers = options.upper_identifiers == true
    local tokens = {}
    text = tostring(text)
    local i = 1
    local depth = 0
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if string.match(c, "%s") then
            i = i + 1
        elseif c == "-" and n == "-" then
            i = i + 2
            while i <= #text and string.sub(text, i, i) ~= "\n" do
                i = i + 1
            end
        elseif c == "/" and n == "*" then
            i = i + 2
            while i <= #text - 1 and string.sub(text, i, i + 1) ~= "*/" do
                i = i + 1
            end
            i = math.min(i + 2, #text + 1)
        elseif c == "'" then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == "'" and n == "'" then
                    i = i + 2
                elseif c == "'" then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1),
                kind = "literal", start_pos = start_pos, end_pos = i - 1,
                depth = depth}
        elseif c == '"' then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == '"' and n == '"' then
                    i = i + 2
                elseif c == '"' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            local token_text = string.sub(text, start_pos, i - 1)
            local decoded = M.decode_quoted_identifier(token_text)
            tokens[#tokens + 1] = {text = token_text, kind = "identifier",
                value = decoded,
                upper = fold_identifiers and upper(decoded) or nil,
                start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "[A-Za-z_]") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[A-Za-z0-9_]") do
                i = i + 1
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "word",
                value = token_text, upper = upper(token_text),
                start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "%d") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[0-9.]") do
                i = i + 1
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1),
                kind = "number", start_pos = start_pos, end_pos = i - 1,
                depth = depth}
        else
            local two = string.sub(text, i, i + 1)
            if fuse_operators and (two == ">=" or two == "<=" or two == "<>"
                or two == "!=") then
                tokens[#tokens + 1] = {text = two, kind = "operator", upper = two,
                    start_pos = i, end_pos = i + 1, depth = depth}
                i = i + 2
            else
                -- A closing paren carries the depth it returns to, which is the
                -- depth its matching opening paren was emitted at. Both
                -- parentheses of a top-level group therefore sit at 0 and only
                -- their contents are nested, which is what lets a clause scanner
                -- find top-level commas by reading `depth == 0`.
                local token_depth = depth
                if c == ")" then
                    depth = math.max(depth - 1, 0)
                    token_depth = depth
                end
                tokens[#tokens + 1] = {text = c, kind = "symbol", upper = c,
                    start_pos = i, end_pos = i, depth = token_depth}
                if c == "(" then
                    depth = depth + 1
                end
                i = i + 1
            end
        end
    end
    if #tokens > 0 and tokens[#tokens].text == ";" then
        table.remove(tokens, #tokens)
    end
    return tokens
end

ESV_SQL_TEXT = M
