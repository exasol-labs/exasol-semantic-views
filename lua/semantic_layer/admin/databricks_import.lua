-- =====================================================================
-- Databricks Unity Catalog Metric View (UCMV) import
--
-- Translates a Databricks metric-view YAML definition into the native
-- semantic DDL of this project (positional ADD_* scaffolding + an ALTER SEMANTIC VIEW
-- block for facts and metrics) and, optionally, applies it. The translation
-- is database-native (pure Lua). Only file I/O lives host-side.
--
-- See docs/databricks-metric-views.md for the supported subset and the
-- DBX_IMPORT_* diagnostics emitted for anything outside it.
-- =====================================================================
--
-- Moved out of admin/semantic_definition.lua (2026-10-17), which it shared
-- nothing with but the helpers below: the importer only produces DDL and
-- calls the public admin scripts, so it is a client of that module, not part
-- of it. It is loaded first in SEMANTIC_DEFINITION_RUNTIME and kept inside a
-- `do` block, so its 28 helpers cost the chunk one local.

local M = {}

do
    local json = assert(ESV_JSON, "shared JSON runtime is required")
    assert(ESV_ROWS, "shared row runtime is required")
    local missing, row_value, null_if_missing, scalar, sql_bool =
        ESV_ROWS.missing, ESV_ROWS.row_value, ESV_ROWS.null_if_missing, ESV_ROWS.scalar,
        ESV_ROWS.sql_bool
    local sql_text = assert(ESV_SQL_TEXT, "shared SQL text runtime is required")
    -- The Semantic DDL lexer settings; see SEMANTIC_DDL_LEXER in
    -- admin/semantic_definition.lua for why identifiers fold and symbols do not fuse.
    local SEMANTIC_DDL_LEXER = {upper_identifiers = true}

    local function trim(value)
        return tostring(value):match("^%s*(.-)%s*$")
    end

    local function upper(value)
        return string.upper(tostring(value))
    end

    -- ---- Minimal YAML-subset parser (only the constructs UCMV emits) ----

    local function dbx_split_lines(text)
        local lines = {}
        for line in string.gmatch(tostring(text) .. "\n", "([^\n]*)\n") do
            local normalized_line = string.gsub(line, "\r$", "")
            lines[#lines + 1] = normalized_line
        end
        return lines
    end

    local function dbx_indent(line)
        local spaces = string.match(line, "^( *)%S")
        if spaces == nil then
            return nil
        end
        return #spaces
    end

    -- Strip a YAML line comment (hash preceded by whitespace or line start),
    -- honoring single and double quoted scalars so a hash inside a value survives.
    local function dbx_strip_comment(s)
        local out = {}
        local in_single = false
        local in_double = false
        local i = 1
        while i <= #s do
            local c = string.sub(s, i, i)
            if c == "'" and not in_double then
                in_single = not in_single
            elseif c == '"' and not in_single then
                in_double = not in_double
            elseif c == "#" and not in_single and not in_double then
                local prev = i > 1 and string.sub(s, i - 1, i - 1) or " "
                if prev == " " or prev == "\t" then
                    break
                end
            end
            out[#out + 1] = c
            i = i + 1
        end
        return table.concat(out)
    end

    local function dbx_unquote(s)
        s = trim(s)
        if #s >= 2 and string.sub(s, 1, 1) == '"' and string.sub(s, -1) == '"' then
            return (string.gsub(string.sub(s, 2, -2), '\\"', '"'))
        elseif #s >= 2 and string.sub(s, 1, 1) == "'" and string.sub(s, -1) == "'" then
            return (string.gsub(string.sub(s, 2, -2), "''", "'"))
        end
        return s
    end

    local function dbx_scalar(s)
        s = trim(s)
        if s == "" or s == "~" or s == "null" then
            return nil
        end
        if string.sub(s, 1, 1) == "[" and string.sub(s, -1) == "]" then
            local arr = {}
            for item in string.gmatch(string.sub(s, 2, -2), "[^,]+") do
                local v = dbx_unquote(trim(item))
                if v ~= "" then
                    arr[#arr + 1] = v
                end
            end
            return arr
        end
        return dbx_unquote(s)
    end

    local function dbx_next_meaningful(cur)
        while cur.pos <= #cur.lines do
            local stripped = dbx_strip_comment(cur.lines[cur.pos])
            if dbx_indent(stripped) ~= nil then
                return cur.pos, stripped
            end
            cur.pos = cur.pos + 1
        end
        return nil, nil
    end

    local dbx_parse_mapping
    local dbx_parse_sequence

    -- Literal/folded block scalar: consume lines more indented than the key.
    local function dbx_parse_block_scalar(cur, parent_indent, indicator)
        local collected = {}
        local base = nil
        while cur.pos <= #cur.lines do
            local raw = cur.lines[cur.pos]
            local ind = dbx_indent(raw)
            if ind == nil then
                collected[#collected + 1] = ""
                cur.pos = cur.pos + 1
            elseif ind > parent_indent then
                base = base or ind
                collected[#collected + 1] = string.sub(raw, base + 1)
                cur.pos = cur.pos + 1
            else
                break
            end
        end
        while #collected > 0 and collected[#collected] == "" do
            table.remove(collected, #collected)
        end
        if indicator == ">" or indicator == ">-" then
            return trim(table.concat(collected, " "))
        end
        return table.concat(collected, "\n")
    end

    local function dbx_parse_block_child(cur, parent_indent)
        local idx, line = dbx_next_meaningful(cur)
        if idx == nil then
            return nil
        end
        local li = dbx_indent(line)
        if li <= parent_indent then
            return nil
        end
        local content = trim(line)
        if string.sub(content, 1, 2) == "- " or content == "-" then
            return dbx_parse_sequence(cur, li)
        end
        return dbx_parse_mapping(cur, li)
    end

    local function dbx_assign(map, content, cur, item_indent)
        local k, rest = string.match(content, "^([^:]+):%s?(.*)$")
        if k == nil then
            error("DBX_IMPORT_004: invalid YAML mapping line: " .. content)
        end
        k = trim(k)
        rest = trim(rest)
        if rest == "" then
            map[k] = dbx_parse_block_child(cur, item_indent)
        elseif rest == "|" or rest == "|-" or rest == "|+" or rest == ">" or rest == ">-" then
            map[k] = dbx_parse_block_scalar(cur, item_indent, rest)
        else
            map[k] = dbx_scalar(rest)
        end
    end

    function dbx_parse_mapping(cur, indent)
        local map = {}
        while true do
            local idx, line = dbx_next_meaningful(cur)
            if idx == nil then
                break
            end
            local li = dbx_indent(line)
            if li < indent then
                break
            end
            if li > indent then
                error("DBX_IMPORT_002: unexpected indentation in YAML mapping")
            end
            local content = trim(line)
            if string.sub(content, 1, 2) == "- " or content == "-" then
                break
            end
            cur.pos = idx + 1
            dbx_assign(map, content, cur, indent)
        end
        return map
    end

    function dbx_parse_sequence(cur, indent)
        local arr = {}
        while true do
            local idx, line = dbx_next_meaningful(cur)
            if idx == nil then
                break
            end
            local li = dbx_indent(line)
            if li < indent then
                break
            end
            if li > indent then
                error("DBX_IMPORT_005: unexpected indentation in YAML sequence")
            end
            local content = trim(line)
            if string.sub(content, 1, 2) ~= "- " and content ~= "-" then
                break
            end
            local after = (content == "-") and "" or trim(string.sub(content, 3))
            cur.pos = idx + 1
            if after == "" then
                arr[#arr + 1] = dbx_parse_block_child(cur, li)
            elseif string.match(after, "^([^:]+):") then
                local item_indent = li + (#content - #after)
                local item = {}
                dbx_assign(item, after, cur, item_indent)
                local rest_map = dbx_parse_mapping(cur, item_indent)
                for mk, mv in pairs(rest_map) do
                    if item[mk] == nil then
                        item[mk] = mv
                    end
                end
                arr[#arr + 1] = item
            else
                arr[#arr + 1] = dbx_scalar(after)
            end
        end
        return arr
    end

    local function parse_databricks_yaml(yaml_text)
        if missing(yaml_text) then
            error("DBX_IMPORT_001: empty Databricks YAML payload")
        end
        local cur = {lines = dbx_split_lines(yaml_text), pos = 1}
        local idx, line = dbx_next_meaningful(cur)
        if idx == nil then
            error("DBX_IMPORT_001: empty Databricks YAML payload")
        end
        return dbx_parse_mapping(cur, dbx_indent(line))
    end

    -- ---- Identifier / alias helpers ----

    local function dbx_ident(name)
        local s = string.lower(trim(tostring(name or "")))
        s = string.gsub(s, "[^a-z0-9_]", "_")
        s = string.gsub(s, "_+", "_")
        s = string.gsub(s, "^_", "")
        s = string.gsub(s, "_$", "")
        if s == "" then
            s = "field"
        end
        if string.match(s, "^%d") then
            s = "f_" .. s
        end
        return s
    end

    local function dbx_unique(seen, base)
        local name = base
        local n = 2
        while seen[name] do
            name = base .. "_" .. n
            n = n + 1
        end
        seen[name] = true
        return name
    end

    local function dbx_alias(name, seen)
        local initials = {}
        for w in string.gmatch(dbx_ident(name), "[^_]+") do
            initials[#initials + 1] = string.sub(w, 1, 1)
        end
        local a = table.concat(initials)
        if a == "" then
            a = "t"
        end
        local base = a
        local n = 2
        while seen[a] do
            a = base .. n
            n = n + 1
        end
        seen[a] = true
        return a
    end

    local function dbx_table_ref(source)
        local s = trim(tostring(source or ""))
        if s == "" or string.match(upper(s), "^%s*SELECT") or string.find(s, "%s") then
            return nil, nil, false
        end
        local segs = {}
        for seg in string.gmatch(s, "[^.]+") do
            segs[#segs + 1] = trim(seg)
        end
        if #segs >= 2 then
            return upper(segs[#segs - 1]), upper(segs[#segs]), true
        elseif #segs == 1 then
            return nil, upper(segs[1]), true
        end
        return nil, nil, false
    end

    -- ---- Expression rewriter: qualify Databricks column refs with entity aliases ----

    local DBX_SQL_WORDS = {
        SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true, MEDIAN = true,
        STDDEV = true, VARIANCE = true, PERCENTILE = true, APPROX_COUNT_DISTINCT = true,
        NULLIF = true, COALESCE = true, CAST = true, CASE = true, WHEN = true,
        THEN = true, ELSE = true, END = true, DISTINCT = true, AS = true, AND = true,
        OR = true, NOT = true, IN = true, LIKE = true, BETWEEN = true, IS = true,
        NULL = true, TRUE = true, FALSE = true, DATE = true, TIMESTAMP = true,
        INTERVAL = true, EXTRACT = true, FROM = true, FILTER = true, WHERE = true,
        OVER = true, PARTITION = true, BY = true, ORDER = true, ASC = true, DESC = true,
        YEAR = true, MONTH = true, DAY = true, QUARTER = true, WEEK = true, HOUR = true,
        MINUTE = true, SECOND = true, MEASURE = true, AGG = true, ON = true, USING = true,
    }

    -- alias_paths: lowercased dotted path -> entity alias (e.g. "source"->"o",
    -- "customer"->"c", "customer.nation"->"n"). default_alias qualifies bare columns.
    -- dimension_lookup (optional): uppercased qualified-expr -> semantic dimension
    -- name. When present, a resolved column that matches is emitted as the
    -- dimension name (used for FILTER predicates).
    local function dbx_rewrite_expr(expr, alias_paths, default_alias, dimension_lookup, diags, path)
        local tokens = sql_text.tokenize(tostring(expr or ""), SEMANTIC_DDL_LEXER)
        local parts = {}
        local attach_next = false
        local function emit(text, tight)
            if #parts == 0 then
                parts[1] = text
            elseif tight then
                parts[#parts] = parts[#parts] .. text
            else
                parts[#parts + 1] = text
            end
        end
        local function emit_resolved(qualified, tight)
            if dimension_lookup ~= nil and dimension_lookup[upper(qualified)] ~= nil then
                emit(dimension_lookup[upper(qualified)], tight)
            else
                emit(qualified, tight)
            end
        end
        local i = 1
        while i <= #tokens do
            local tok = tokens[i]
            local is_word = tok.kind == "word" or tok.kind == "identifier"
            if is_word and tokens[i + 1] ~= nil and tokens[i + 1].text == "." then
                -- Dotted reference: gather the full a.b.c chain.
                local chain = {tok}
                local j = i + 1
                while tokens[j] ~= nil and tokens[j].text == "." and (tokens[j + 1] ~= nil)
                    and (tokens[j + 1].kind == "word" or tokens[j + 1].kind == "identifier") do
                    chain[#chain + 1] = tokens[j + 1]
                    j = j + 2
                end
                local segs = {}
                for _, c in ipairs(chain) do
                    segs[#segs + 1] = c.value or c.text
                end
                local alias = nil
                local column = nil
                for k = #segs - 1, 1, -1 do
                    local prefix = {}
                    for p = 1, k do
                        prefix[p] = string.lower(segs[p])
                    end
                    local mapped = alias_paths[table.concat(prefix, ".")]
                    if mapped ~= nil then
                        alias = mapped
                        local rest = {}
                        for p = k + 1, #segs do
                            rest[#rest + 1] = segs[p]
                        end
                        column = table.concat(rest, ".")
                        break
                    end
                end
                if alias == nil and string.lower(segs[1]) == "source" then
                    alias = default_alias
                    local rest = {}
                    for p = 2, #segs do
                        rest[#rest + 1] = segs[p]
                    end
                    column = table.concat(rest, ".")
                end
                if alias == nil then
                    if diags ~= nil then
                        diags[#diags + 1] = {code = "DBX_IMPORT_310", severity = "WARNING", path = path,
                            message = "Unresolved qualified reference '" .. table.concat(segs, ".") .. "'; emitted verbatim."}
                    end
                    emit(table.concat(segs, "."), attach_next)
                else
                    emit_resolved(alias .. "." .. column, attach_next)
                end
                attach_next = false
                i = j
            elseif is_word then
                local word = tok.value or tok.text
                local is_func = tokens[i + 1] ~= nil and tokens[i + 1].text == "("
                local prev = tokens[i - 1]
                local after_dot = prev ~= nil and prev.text == "."
                if is_func or after_dot or DBX_SQL_WORDS[upper(word)] then
                    emit(tok.text, attach_next)
                else
                    emit_resolved(default_alias .. "." .. word, attach_next)
                end
                attach_next = false
                i = i + 1
            elseif tok.text == "." then
                emit(".", true)
                attach_next = true
                i = i + 1
            elseif tok.text == "(" or tok.text == ")" or tok.text == "," then
                emit(tok.text, true)
                attach_next = (tok.text == "(")
                i = i + 1
            else
                emit(tok.text, attach_next)
                attach_next = false
                i = i + 1
            end
        end
        return trim(table.concat(parts, " "))
    end

    -- ---- Measure expression classification ----

    -- Split "<agg> FILTER (WHERE <pred>)" into the aggregate expression and the
    -- raw predicate (or nil). Returns agg_expr, filter_pred.
    local function dbx_split_filter(expr)
        local tokens = sql_text.tokenize(expr, SEMANTIC_DDL_LEXER)
        for i, tok in ipairs(tokens) do
            if (tok.upper == "FILTER") and tokens[i + 1] ~= nil and tokens[i + 1].text == "(" then
                local close = nil
                local depth = 0
                for j = i + 1, #tokens do
                    if tokens[j].text == "(" then
                        depth = depth + 1
                    elseif tokens[j].text == ")" then
                        depth = depth - 1
                        if depth == 0 then
                            close = j
                            break
                        end
                    end
                end
                if close ~= nil then
                    local agg_expr = trim(string.sub(expr, 1, tokens[i].start_pos - 1))
                    -- inside parens: WHERE <pred>
                    local inner = trim(string.sub(expr, tokens[i + 1].end_pos + 1, tokens[close].start_pos - 1))
                    inner = string.gsub(inner, "^[Ww][Hh][Ee][Rr][Ee]%s+", "")
                    return agg_expr, trim(inner)
                end
            end
        end
        return expr, nil
    end

    -- Detect a leading aggregate call: returns AGG_FUNC, inner_text, has_distinct.
    local function dbx_aggregate(expr)
        local tokens = sql_text.tokenize(expr, SEMANTIC_DDL_LEXER)
        if #tokens < 3 or tokens[1].kind ~= "word" or tokens[2].text ~= "(" then
            return nil, nil, false
        end
        local depth = 0
        for i = 2, #tokens do
            if tokens[i].text == "(" then
                depth = depth + 1
            elseif tokens[i].text == ")" then
                depth = depth - 1
                if depth == 0 then
                    -- The aggregate must wrap the whole expression.
                    if i ~= #tokens then
                        return nil, nil, false
                    end
                    local inner = trim(string.sub(expr, tokens[2].end_pos + 1, tokens[i].start_pos - 1))
                    local has_distinct = false
                    if string.match(upper(inner), "^DISTINCT%s") then
                        has_distinct = true
                        inner = trim(string.sub(inner, 9))
                    end
                    return upper(tokens[1].text), inner, has_distinct
                end
            end
        end
        return nil, nil, false
    end

    -- Replace MEASURE(x)/agg(x) wrappers with the bare referenced name.
    local function dbx_unwrap_measures(expr)
        local result = expr
        result = string.gsub(result, "[Mm][Ee][Aa][Ss][Uu][Rr][Ee]%s*%(%s*([%w_]+)%s*%)", "%1")
        result = string.gsub(result, "%f[%a][Aa][Gg][Gg]%s*%(%s*([%w_]+)%s*%)", "%1")
        return result
    end

    local function dbx_references_measure(expr)
        return string.match(expr, "[Mm][Ee][Aa][Ss][Uu][Rr][Ee]%s*%(") ~= nil
            or string.match(expr, "%f[%a][Aa][Gg][Gg]%s*%(") ~= nil
    end

    -- =====================================================================
    -- Translation: parsed UCMV document -> internal plan
    -- =====================================================================

    local function dbx_quote_ddl(value)
        if missing(value) then
            return "NULL"
        end
        return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
    end

    local function dbx_translate(doc, model_name, published_schema, diags)
        if type(doc) ~= "table" then
            error("DBX_IMPORT_006: Databricks metric view must be a YAML mapping")
        end
        if missing(doc.source) then
            error("DBX_IMPORT_010: metric view is missing the required 'source' key")
        end

        local model = dbx_ident(model_name)
        local object_name = upper(model)
        local plan = {
            model_name = model,
            object_name = object_name,
            published_schema = upper(published_schema),
            description = doc.comment,
            entities = {},
            relationships = {},
            dimensions = {},
            facts = {},
            metrics = {},
        }

        local entity_seen = {}
        local alias_seen = {}
        local rel_seen = {}
        local member_seen = {}
        local fact_seen = {}

        -- alias_paths maps a dotted YAML reference path to the entity alias.
        local alias_paths = {}
        -- entity_by_path maps a dotted path to the entity name (for member binding).
        local entity_by_path = {}
        -- entity_alias maps an entity name to its source alias.
        local entity_alias = {}

        -- Root entity from `source`.
        local src_schema, src_object, ref_ok = dbx_table_ref(doc.source)
        if not ref_ok then
            error("DBX_IMPORT_210: source '" .. tostring(doc.source)
                .. "' is an inline query or unsupported reference; wrap it in a view and import that instead")
        end
        local root_name = dbx_unique(entity_seen, dbx_ident(src_object))
        local root_alias = dbx_alias(src_object, alias_seen)
        plan.entities[#plan.entities + 1] = {
            name = root_name, source_schema = src_schema, source_object = src_object,
            alias = root_alias, primary_key_expr = nil,
            grain = "Imported from Databricks metric view source",
            description = doc.comment,
        }
        alias_paths["source"] = root_alias
        alias_paths[string.lower(root_name)] = root_alias
        entity_by_path["source"] = root_name
        entity_alias[root_name] = root_alias

        -- Joins (recursively) -> entities + relationships.
        local function add_join(join, parent_entity, parent_path)
            if type(join) ~= "table" or missing(join.name) then
                diags[#diags + 1] = {code = "DBX_IMPORT_230", severity = "WARNING", path = "joins",
                    message = "Skipped a join without a name."}
                return
            end
            local jschema, jobject, jok = dbx_table_ref(join.source)
            if not jok then
                diags[#diags + 1] = {code = "DBX_IMPORT_211", severity = "WARNING", path = "joins." .. tostring(join.name),
                    message = "Join source '" .. tostring(join.source) .. "' is not a plain table reference; join skipped."}
                return
            end
            local jname = dbx_unique(entity_seen, dbx_ident(join.name))
            local jalias = dbx_alias(join.name, alias_seen)
            local jpath = parent_path .. "." .. string.lower(join.name)
            local relative_jpath = string.gsub(jpath, "^source%.", "")
            alias_paths[string.lower(join.name)] = jalias
            alias_paths[jpath] = jalias
            alias_paths[relative_jpath] = jalias
            entity_by_path[string.lower(join.name)] = jname
            entity_by_path[jpath] = jname
            entity_by_path[relative_jpath] = jname
            entity_alias[jname] = jalias
            local cardinality = "MANY_TO_ONE"
            if not missing(join.cardinality) and upper(join.cardinality) == "ONE_TO_MANY" then
                cardinality = "ONE_TO_MANY"
            end
            plan.entities[#plan.entities + 1] = {
                name = jname, source_schema = jschema, source_object = jobject,
                alias = jalias, primary_key_expr = nil,
                grain = "Imported join: " .. tostring(join.name), description = join.comment,
            }
            local parent_alias = entity_alias[parent_entity] or root_alias
            local join_condition
            if not missing(join["on"]) then
                join_condition = dbx_rewrite_expr(join["on"], alias_paths, parent_alias, nil, diags, "joins." .. tostring(join.name))
            elseif not missing(join.using) then
                diags[#diags + 1] = {code = "DBX_IMPORT_240", severity = "WARNING", path = "joins." .. tostring(join.name),
                    message = "USING joins are not supported; provide an ON condition. Join skipped."}
                return
            else
                diags[#diags + 1] = {code = "DBX_IMPORT_241", severity = "WARNING", path = "joins." .. tostring(join.name),
                    message = "Join has no ON condition; skipped."}
                return
            end
            plan.relationships[#plan.relationships + 1] = {
                name = dbx_unique(rel_seen, dbx_ident(parent_entity .. "_to_" .. jname)),
                from_entity = parent_entity, to_entity = jname,
                join_condition = join_condition, cardinality = cardinality,
                join_type = "LEFT", fanout_policy = nil,
            }
            if cardinality == "ONE_TO_MANY" then
                diags[#diags + 1] = {code = "DBX_IMPORT_250", severity = "INFO", path = "joins." .. tostring(join.name),
                    message = "one_to_many join mapped to ONE_TO_MANY relationship; verify fan-out handling."}
            end
            for _, child in ipairs(join.joins or {}) do
                add_join(child, jname, jpath)
            end
        end
        for _, join in ipairs(doc.joins or {}) do
            add_join(join, root_name, "source")
        end

        -- Resolve which entity an expression primarily references (for member binding).
        local function entity_for_expr(expr)
            local tokens = sql_text.tokenize(tostring(expr or ""), SEMANTIC_DDL_LEXER)
            local best_entity = nil
            local best_depth = 0
            for i = 1, #tokens - 1 do
                local tok = tokens[i]
                if (tok.kind == "word" or tok.kind == "identifier") and tokens[i + 1].text == "." then
                    local segs = {string.lower(tok.value or tok.text)}
                    local j = i + 1
                    while tokens[j] ~= nil and tokens[j].text == "." and tokens[j + 1] ~= nil
                        and (tokens[j + 1].kind == "word" or tokens[j + 1].kind == "identifier") do
                        segs[#segs + 1] = string.lower(tokens[j + 1].value or tokens[j + 1].text)
                        j = j + 2
                    end
                    for depth = #segs - 1, 1, -1 do
                        local prefix = {}
                        for p = 1, depth do
                            prefix[p] = segs[p]
                        end
                        local path = table.concat(prefix, ".")
                        if path ~= "source" and entity_by_path[path] ~= nil and depth > best_depth then
                            best_entity = entity_by_path[path]
                            best_depth = depth
                            break
                        end
                    end
                end
            end
            return best_entity or root_name
        end

        -- Fields -> dimensions. Also build a lookup from qualified expr -> dim name
        -- so FILTER predicates can reference dimensions by name.
        local dimension_lookup = {}
        for _, field in ipairs(doc.fields or {}) do
            if type(field) == "table" and not missing(field.name) and not missing(field.expr) then
                local dim_name = dbx_unique(member_seen, dbx_ident(field.name))
                local entity = entity_for_expr(field.expr)
                local expr = dbx_rewrite_expr(field.expr, alias_paths, root_alias, nil, diags, "fields." .. tostring(field.name))
                local data_type = "VARCHAR(2000000)"
                if string.match(upper(expr), "DATE_TRUNC") or string.match(upper(expr), "TRUNC%s*%(") then
                    data_type = "DATE"
                end
                plan.dimensions[#plan.dimensions + 1] = {
                    object = object_name, entity = entity, name = dim_name, expression = expr,
                    data_type = data_type, display_name = field.display_name,
                    description = field.comment, format_hint = nil, is_certified = false,
                }
                dimension_lookup[upper(expr)] = dim_name
            elseif type(field) == "table" and not missing(field.name) then
                diags[#diags + 1] = {code = "DBX_IMPORT_320", severity = "WARNING", path = "fields." .. tostring(field.name),
                    message = "Field has no expr; skipped."}
            end
        end

        -- Measures -> facts + metrics.
        local base_metrics = {}
        local derived_metrics = {}
        for _, measure in ipairs(doc.measures or {}) do
            if type(measure) ~= "table" or missing(measure.name) or missing(measure.expr) then
                diags[#diags + 1] = {code = "DBX_IMPORT_400", severity = "WARNING", path = "measures",
                    message = "Skipped a measure without name/expr."}
            elseif not missing(measure.window) then
                diags[#diags + 1] = {code = "DBX_IMPORT_410", severity = "WARNING", path = "measures." .. tostring(measure.name),
                    message = "Window measures are not supported and were skipped."}
            else
                local metric_name = dbx_unique(member_seen, dbx_ident(measure.name))
                local agg_expr, filter_pred = dbx_split_filter(measure.expr)
                local format_hint = nil
                if type(measure.format) == "table" and not missing(measure.format.type) then
                    local ft = string.lower(tostring(measure.format.type))
                    if ft == "currency" then
                        format_hint = "currency"
                    elseif ft == "percent" or ft == "percentage" then
                        format_hint = "percentage"
                    elseif ft == "number" then
                        format_hint = "number"
                    end
                end
                local common = {
                    name = metric_name, entity = root_name, display_name = measure.display_name,
                    description = measure.comment, format_hint = format_hint,
                    synonyms = type(measure.synonyms) == "table" and measure.synonyms or nil,
                    data_type = "DECIMAL(36,6)", filter_pred = nil, kind = "ADDITIVE",
                }
                if dbx_references_measure(agg_expr) then
                    -- Derived / ratio metric over other measures.
                    local unwrapped = dbx_unwrap_measures(agg_expr)
                    local lhs, rhs = string.match(trim(unwrapped), "^([%w_]+)%s*/%s*([%w_]+)$")
                    if lhs ~= nil then
                        common.expression = lhs .. " / NULLIF(" .. rhs .. ", 0)"
                        common.kind = "RATIO"
                    else
                        common.expression = unwrapped
                        common.kind = "DERIVED"
                    end
                    if filter_pred ~= nil then
                        diags[#diags + 1] = {code = "DBX_IMPORT_430", severity = "WARNING", path = "measures." .. tostring(measure.name),
                            message = "FILTER on a composed measure is not supported and was dropped."}
                    end
                    derived_metrics[#derived_metrics + 1] = common
                else
                    local agg_func, inner, has_distinct = dbx_aggregate(agg_expr)
                    if agg_func == nil then
                        diags[#diags + 1] = {code = "DBX_IMPORT_420", severity = "WARNING", path = "measures." .. tostring(measure.name),
                            message = "Measure expression '" .. tostring(measure.expr) .. "' is not a recognized aggregate; skipped."}
                    else
                        -- Build a private fact for the aggregate input.
                        local fact_inner
                        if inner == "*" or inner == "1" or inner == "" then
                            fact_inner = "1"
                            common.data_type = "DECIMAL(18,0)"
                        else
                            fact_inner = dbx_rewrite_expr(inner, alias_paths, root_alias, nil, diags, "measures." .. tostring(measure.name))
                        end
                        local fact_name = dbx_unique(fact_seen, dbx_ident(measure.name) .. "_base")
                        member_seen[fact_name] = true
                        local fact_type = (common.data_type == "DECIMAL(18,0)") and "DECIMAL(18,0)" or "DECIMAL(36,6)"
                        plan.facts[#plan.facts + 1] = {
                            name = fact_name, entity = root_name, expression = fact_inner,
                            data_type = fact_type, additive = "ADDITIVE",
                            display_name = nil, description = "Imported base for measure " .. tostring(measure.name),
                            is_private = true, is_certified = false,
                        }
                        if agg_func == "COUNT" then
                            common.data_type = "DECIMAL(18,0)"
                        end
                        if has_distinct then
                            common.expression = agg_func .. "(DISTINCT " .. fact_name .. ")"
                        else
                            common.expression = agg_func .. "(" .. fact_name .. ")"
                        end
                        if filter_pred ~= nil then
                            common.filter_pred = dbx_rewrite_expr(filter_pred, alias_paths, root_alias, dimension_lookup, diags, "measures." .. tostring(measure.name))
                        end
                        base_metrics[#base_metrics + 1] = common
                    end
                end
            end
        end
        for _, m in ipairs(base_metrics) do
            plan.metrics[#plan.metrics + 1] = m
        end
        for _, m in ipairs(derived_metrics) do
            plan.metrics[#plan.metrics + 1] = m
        end

        if not missing(doc.filter) then
            diags[#diags + 1] = {code = "DBX_IMPORT_500", severity = "WARNING", path = "filter",
                message = "View-level filter is not applied automatically; add it to individual metrics if needed."}
        end
        if not missing(doc.materialization) then
            diags[#diags + 1] = {code = "DBX_IMPORT_510", severity = "INFO", path = "materialization",
                message = "Databricks materialization config ignored; use this project's materialization selection."}
        end
        if #plan.metrics == 0 then
            diags[#diags + 1] = {code = "DBX_IMPORT_420", severity = "WARNING", path = "measures",
                message = "No metrics were produced from the metric view measures."}
        end

        return plan
    end

    -- ---- Render native DDL text for the plan (reviewable / re-runnable) ----

    local function dbx_render_member_clauses(buf, m, is_fact)
        if is_fact then
            buf[#buf + 1] = "    ON ENTITY " .. m.entity
            buf[#buf + 1] = "    AS " .. m.expression
            buf[#buf + 1] = "    RETURNS " .. m.data_type
            buf[#buf + 1] = "    " .. m.additive
        else
            buf[#buf + 1] = "    AS " .. m.expression
            buf[#buf + 1] = "    ON ENTITY " .. m.entity
            if m.filter_pred ~= nil then
                buf[#buf + 1] = "    FILTER (WHERE " .. m.filter_pred .. ")"
            end
            buf[#buf + 1] = "    RETURNS " .. m.data_type
            if not missing(m.format_hint) then
                buf[#buf + 1] = "    FORMAT " .. dbx_quote_ddl(m.format_hint)
            end
        end
        if not missing(m.display_name) then
            buf[#buf + 1] = "    DISPLAY " .. dbx_quote_ddl(m.display_name)
        end
        if not missing(m.description) then
            buf[#buf + 1] = "    COMMENT " .. dbx_quote_ddl(m.description)
        end
        if not is_fact and type(m.synonyms) == "table" and #m.synonyms > 0 then
            local quoted = {}
            for _, s in ipairs(m.synonyms) do
                quoted[#quoted + 1] = dbx_quote_ddl(s)
            end
            buf[#buf + 1] = "    SYNONYMS (" .. table.concat(quoted, ", ") .. ")"
        end
        if not is_fact then
            buf[#buf + 1] = "    " .. m.kind
        end
        if is_fact then
            buf[#buf + 1] = "    PRIVATE"
        else
            buf[#buf + 1] = "    PUBLIC"
        end
    end

    local function dbx_alter_semantic_view(plan)
        if #plan.facts == 0 and #plan.metrics == 0 then
            return nil
        end
        local buf = {}
        buf[#buf + 1] = "ALTER SEMANTIC VIEW " .. plan.model_name .. "." .. plan.object_name
        if #plan.facts > 0 then
            buf[#buf + 1] = "REPLACE FACTS ("
            local entries = {}
            for _, f in ipairs(plan.facts) do
                local e = {"  FACT " .. f.name}
                dbx_render_member_clauses(e, f, true)
                entries[#entries + 1] = table.concat(e, "\n")
            end
            buf[#buf + 1] = table.concat(entries, ",\n\n")
            buf[#buf + 1] = ")"
        end
        if #plan.metrics > 0 then
            buf[#buf + 1] = "REPLACE METRICS ("
            local entries = {}
            for _, m in ipairs(plan.metrics) do
                local e = {"  METRIC " .. m.name}
                dbx_render_member_clauses(e, m, false)
                entries[#entries + 1] = table.concat(e, "\n")
            end
            buf[#buf + 1] = table.concat(entries, ",\n\n")
            buf[#buf + 1] = ")"
        end
        return table.concat(buf, "\n")
    end

    local function dbx_render_ddl(plan)
        local out = {}
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(" .. dbx_quote_ddl(plan.model_name)
            .. ", " .. dbx_quote_ddl(plan.published_schema) .. ", " .. dbx_quote_ddl(plan.description) .. ", NULL);"
        for _, e in ipairs(plan.entities) do
            out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(" .. dbx_quote_ddl(plan.model_name)
                .. ", " .. dbx_quote_ddl(e.name) .. ", " .. dbx_quote_ddl(e.source_schema)
                .. ", " .. dbx_quote_ddl(e.source_object) .. ", " .. dbx_quote_ddl(e.alias)
                .. ", " .. dbx_quote_ddl(e.primary_key_expr) .. ", " .. dbx_quote_ddl(e.grain)
                .. ", " .. dbx_quote_ddl(e.description) .. ");"
        end
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(" .. dbx_quote_ddl(plan.model_name)
            .. ", " .. dbx_quote_ddl(plan.object_name) .. ", " .. dbx_quote_ddl(plan.entities[1].name)
            .. ", " .. dbx_quote_ddl(plan.description) .. ");"
        for _, r in ipairs(plan.relationships) do
            out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(" .. dbx_quote_ddl(plan.model_name)
                .. ", " .. dbx_quote_ddl(r.name) .. ", " .. dbx_quote_ddl(r.from_entity)
                .. ", " .. dbx_quote_ddl(r.to_entity) .. ", " .. dbx_quote_ddl(r.join_condition)
                .. ", " .. dbx_quote_ddl(r.cardinality) .. ", " .. dbx_quote_ddl(r.join_type)
                .. ", " .. dbx_quote_ddl(r.fanout_policy) .. ");"
        end
        for _, d in ipairs(plan.dimensions) do
            out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(" .. dbx_quote_ddl(plan.model_name)
                .. ", " .. dbx_quote_ddl(d.object) .. ", " .. dbx_quote_ddl(d.entity)
                .. ", " .. dbx_quote_ddl(d.name) .. ", " .. dbx_quote_ddl(d.expression)
                .. ", " .. dbx_quote_ddl(d.data_type) .. ", " .. dbx_quote_ddl(d.display_name)
                .. ", " .. dbx_quote_ddl(d.description) .. ", " .. dbx_quote_ddl(d.format_hint)
                .. ", " .. (d.is_certified and "TRUE" or "FALSE") .. ");"
        end
        local alter = dbx_alter_semantic_view(plan)
        if alter ~= nil then
            out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(\n"
                .. dbx_quote_ddl(alter) .. ",\n  FALSE);"
        end
        return table.concat(out, "\n\n")
    end

    -- ---- Apply the plan against the catalog ----

    local function dbx_apply_plan(plan)
        if not missing(scalar("SELECT MAX(MODEL_ID) FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER(:name)",
            {name = plan.model_name})) then
            error("DBX_IMPORT_200: model '" .. plan.model_name .. "' already exists; choose a different model name or reset it first")
        end
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(:model_name, :published_schema, :description, NULL)",
            {model_name = plan.model_name, published_schema = plan.published_schema, description = null_if_missing(plan.description)})
        for _, e in ipairs(plan.entities) do
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(:model_name, :entity_name, :source_schema, :source_object, :source_alias, :primary_key_expr, :grain_description, :description)",
                {model_name = plan.model_name, entity_name = e.name, source_schema = e.source_schema,
                 source_object = e.source_object, source_alias = e.alias,
                 primary_key_expr = null_if_missing(e.primary_key_expr),
                 grain_description = null_if_missing(e.grain), description = null_if_missing(e.description)})
        end
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(:model_name, :object_name, :root_entity_name, :description)",
            {model_name = plan.model_name, object_name = plan.object_name, root_entity_name = plan.entities[1].name,
             description = null_if_missing(plan.description)})
        for _, r in ipairs(plan.relationships) do
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(:model_name, :relationship_name, :from_entity_name, :to_entity_name, :join_condition, :cardinality, :join_type, :fanout_policy)",
                {model_name = plan.model_name, relationship_name = r.name, from_entity_name = r.from_entity,
                 to_entity_name = r.to_entity, join_condition = r.join_condition, cardinality = r.cardinality,
                 join_type = r.join_type, fanout_policy = null_if_missing(r.fanout_policy)})
        end
        for _, d in ipairs(plan.dimensions) do
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(:model_name, :object_name, :entity_name, :dimension_name, :expression, :data_type, :display_name, :description, :format_hint, :is_certified)",
                {model_name = plan.model_name, object_name = d.object, entity_name = d.entity, dimension_name = d.name,
                 expression = d.expression, data_type = d.data_type, display_name = null_if_missing(d.display_name),
                 description = null_if_missing(d.description), format_hint = null_if_missing(d.format_hint),
                 is_certified = d.is_certified})
        end
        local validation_run_id
        local alter = dbx_alter_semantic_view(plan)
        if alter ~= nil then
            local rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(:ddl, FALSE)", {ddl = alter})
            local first = rows and rows[1] or nil
            local status = first and row_value(first, "STATUS", 1) or "OK"
            validation_run_id = first and row_value(first, "VALIDATION_RUN_ID", 6) or nil
            if status == "ERROR" then
                error((first and row_value(first, "ERROR_CODE", 2) or "DBX_IMPORT_600") .. ": "
                    .. tostring(first and row_value(first, "MESSAGE", 3) or "fact/metric definition rejected"))
            end
        else
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = plan.model_name})
            validation_run_id = scalar([[
                SELECT MAX(vr.VALIDATION_RUN_ID)
                FROM SYS_SEMANTIC.VALIDATION_RUNS vr
                JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = vr.MODEL_ID
                WHERE UPPER(m.MODEL_NAME) = UPPER(:name)
            ]], {name = plan.model_name})
        end
        -- Validation passed (APPLY_SEMANTIC_DEFINITION raises on validation errors),
        -- so publish the model immediately, matching Databricks where a metric view
        -- is queryable as soon as it is created.
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)", {model_name = plan.model_name})
        return validation_run_id
    end

    function M.import_metric_view(yaml_text, model_name, published_schema, apply_flag)
        local diags = {}
        local ok, result = pcall(function()
            if missing(model_name) then
                error("DBX_IMPORT_020: a target model name is required")
            end
            local doc = parse_databricks_yaml(yaml_text)
            local schema = missing(published_schema) and ("SEMANTIC_" .. upper(dbx_ident(model_name))) or published_schema
            local plan = dbx_translate(doc, model_name, schema, diags)
            local ddl = dbx_render_ddl(plan)
            local validation_run_id = null
            if sql_bool(apply_flag) then
                validation_run_id = dbx_apply_plan(plan) or null
            end
            return {plan = plan, ddl = ddl, validation_run_id = validation_run_id}
        end)
        if ok then
            return {{
                "OK", null, "Databricks metric view translated" .. (sql_bool(apply_flag) and " and applied." or "."),
                result.plan.model_name, result.ddl, json.encode(diags), result.validation_run_id,
            }}
        end
        local message = tostring(result)
        local error_code = string.match(message, "(DBX_IMPORT_%d+)") or string.match(message, "(SEMANTIC_%w+_%d+)") or "DBX_IMPORT_999"
        return {{
            "ERROR", error_code, message, missing(model_name) and null or dbx_ident(model_name),
            null, json.encode(diags), null,
        }}
    end

    M.parse_databricks_yaml = parse_databricks_yaml
    M.dbx_table_ref = dbx_table_ref
    M.dbx_rewrite_expr = dbx_rewrite_expr
    M.dbx_split_filter = dbx_split_filter
    M.dbx_aggregate = dbx_aggregate
    M.dbx_unwrap_measures = dbx_unwrap_measures
    M.dbx_translate = dbx_translate
    M.dbx_render_ddl = dbx_render_ddl
end

ESV_DATABRICKS_IMPORT = M
