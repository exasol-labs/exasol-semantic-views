local M = {}

local JSON_NULL = {}

local function missing(value)
    return value == nil or value == null or value == JSON_NULL or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or row_value(rows[1], "COUNT", 1) or row_value(rows[1], "MAX", 1) or rows[1][1]
end

local function sql_string(value)
    if missing(value) then
        return "NULL"
    end
    local text = tostring(value)
    text = string.gsub(text, "'", "''")
    return "'" .. text .. "'"
end

local function sql_boolean(value)
    return value and "TRUE" or "FALSE"
end

local function sql_bool(value)
    if value == true or tostring(value) == "true" or tostring(value) == "TRUE" or tostring(value) == "1" then
        return true
    end
    return false
end

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function is_array(value)
    if type(value) ~= "table" or value == JSON_NULL then
        return false
    end
    local max_index = 0
    local count = 0
    for k, _ in pairs(value) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max_index then
            max_index = k
        end
        count = count + 1
    end
    return max_index == count
end

local function json_escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
end

local function json_encode(value)
    local value_type = type(value)
    if value == nil or value == null or value == JSON_NULL then
        return "null"
    elseif value_type == "string" then
        return '"' .. json_escape(value) .. '"'
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "table" then
        local parts = {}
        if is_array(value) then
            for i = 1, #value do
                parts[#parts + 1] = json_encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_encode(tostring(value))
end

local function json_decode(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" then
                    out[#out + 1] = e
                    pos = pos + 2
                elseif e == "b" then
                    out[#out + 1] = "\b"
                    pos = pos + 2
                elseif e == "f" then
                    out[#out + 1] = "\f"
                    pos = pos + 2
                elseif e == "n" then
                    out[#out + 1] = "\n"
                    pos = pos + 2
                elseif e == "r" then
                    out[#out + 1] = "\r"
                    pos = pos + 2
                elseif e == "t" then
                    out[#out + 1] = "\t"
                    pos = pos + 2
                elseif e == "u" then
                    out[#out + 1] = "?"
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        local c = peek()
        if c == "-" then
            pos = pos + 1
        end
        while string.match(peek(), "%d") do
            pos = pos + 1
        end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        local raw = string.sub(text, start_pos, pos - 1)
        local value = tonumber(raw)
        if value == nil then
            error("invalid number at byte " .. tostring(start_pos))
        end
        return value
    end

    local function parse_array()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return out
        end
        while true do
            out[#out + 1] = parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return out
        end
        while true do
            skip_ws()
            local name = parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            out[name] = parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or string.match(c, "%d") then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    local value = parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_DDL_001: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_DDL_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function decode_quoted_identifier(token_text)
    local raw = string.sub(token_text, 2, -2)
    return string.gsub(raw, '""', '"')
end

local function tokenize(text)
    local tokens = {}
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
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "literal", start_pos = start_pos, end_pos = i - 1, depth = depth}
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
            tokens[#tokens + 1] = {text = token_text, kind = "identifier", value = decode_quoted_identifier(token_text), upper = upper(decode_quoted_identifier(token_text)), start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "[A-Za-z_]") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[A-Za-z0-9_]") do
                i = i + 1
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "word", value = token_text, upper = upper(token_text), start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "%d") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[0-9.]") do
                i = i + 1
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "number", start_pos = start_pos, end_pos = i - 1, depth = depth}
        else
            local token_depth = depth
            if c == ")" then
                depth = math.max(depth - 1, 0)
                token_depth = depth
            end
            tokens[#tokens + 1] = {text = c, kind = "symbol", upper = c, start_pos = i, end_pos = i, depth = token_depth}
            if c == "(" then
                depth = depth + 1
            end
            i = i + 1
        end
    end
    if #tokens > 0 and tokens[#tokens].text == ";" then
        table.remove(tokens, #tokens)
    end
    return tokens
end

local function token_upper(token)
    if token == nil then
        return nil
    end
    return token.upper or upper(token.text)
end

local function token_identifier(token)
    if token == nil then
        return nil
    end
    if token.kind == "word" or token.kind == "identifier" then
        return token.value or token.text
    end
    return nil
end

local function text_from_tokens(source, tokens, first, last)
    if first == nil or last == nil or first > last then
        return nil
    end
    return trim(string.sub(source, tokens[first].start_pos, tokens[last].end_pos))
end

local function find_sequence(tokens, words, start_index, depth)
    start_index = start_index or 1
    for i = start_index, #tokens - #words + 1 do
        local ok = true
        if depth ~= nil and tokens[i].depth ~= depth then
            ok = false
        end
        if ok then
            for j, word in ipairs(words) do
                if token_upper(tokens[i + j - 1]) ~= word then
                    ok = false
                    break
                end
            end
        end
        if ok then
            return i
        end
    end
    return nil
end

local function split_top_level_text(text)
    local parts = {}
    local depth = 0
    local in_quote = false
    local start_pos = 1
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif not in_quote then
            if c == "(" then
                depth = depth + 1
            elseif c == ")" then
                depth = depth - 1
            elseif c == "," and depth == 0 then
                parts[#parts + 1] = trim(string.sub(text, start_pos, i - 1))
                start_pos = i + 1
            end
            i = i + 1
        else
            i = i + 1
        end
    end
    local tail = trim(string.sub(text, start_pos))
    if tail ~= "" then
        parts[#parts + 1] = tail
    end
    return parts
end

local CLAUSES = {
    {"ON", "ENTITY"},
    {"AS"},
    {"FILTER"},
    {"RETURNS"},
    {"FORMAT"},
    {"DISPLAY"},
    {"COMMENT"},
    {"SYNONYMS"},
    {"DISTINCT_KEY"},
    {"NON", "ADDITIVE", "BY"},
    {"WINDOW"},
    {"ADDITIVE"},
    {"DERIVED"},
    {"RATIO"},
    {"DISTINCT"},
    {"SEMI_ADDITIVE"},
    {"PUBLIC"},
    {"PRIVATE"},
    {"CERTIFIED"},
}

local function clause_key(words)
    return table.concat(words, "_")
end

local function clause_positions(tokens, start_index)
    local positions = {}
    local ordered = {}
    for i = start_index, #tokens do
        if tokens[i].depth == 0 then
            for _, words in ipairs(CLAUSES) do
                local ok = true
                for j, word in ipairs(words) do
                    if token_upper(tokens[i + j - 1]) ~= word then
                        ok = false
                        break
                    end
                end
                if ok then
                    local key_name = clause_key(words)
                    if positions[key_name] == nil then
                        positions[key_name] = {index = i, words = words}
                        ordered[#ordered + 1] = {index = i, words = words, key = key_name}
                    end
                end
            end
        end
    end
    table.sort(ordered, function(a, b) return a.index < b.index end)
    return positions, ordered
end

local function clause_text(source, tokens, positions, ordered, key_name)
    local entry = positions[key_name]
    if entry == nil then
        return nil
    end
    local value_first = entry.index + #entry.words
    local next_index = #tokens + 1
    for _, candidate in ipairs(ordered) do
        if candidate.index > entry.index and candidate.index < next_index then
            next_index = candidate.index
        end
    end
    return text_from_tokens(source, tokens, value_first, next_index - 1)
end

local function parse_literal_list(text)
    if missing(text) then
        return {}
    end
    local inside = trim(text)
    if string.sub(inside, 1, 1) == "(" and string.sub(inside, -1) == ")" then
        inside = string.sub(inside, 2, -2)
    end
    local values = {}
    for _, part in ipairs(split_top_level_text(inside)) do
        local p = trim(part)
        if string.sub(p, 1, 1) == "'" and string.sub(p, -1) == "'" then
            p = string.sub(p, 2, -2)
            p = string.gsub(p, "''", "'")
        end
        values[#values + 1] = p
    end
    return values
end

local function parse_filter(text)
    if missing(text) then
        return nil
    end
    local value = trim(text)
    if string.sub(value, 1, 1) == "(" and string.sub(value, -1) == ")" then
        value = trim(string.sub(value, 2, -2))
    end
    if string.sub(upper(value), 1, 5) == "WHERE" then
        value = trim(string.sub(value, 6))
    end
    return value
end

local function parse_clause_scalar(text)
    if missing(text) then
        return nil
    end
    local value = trim(text)
    if string.sub(value, 1, 1) == "'" and string.sub(value, -1) == "'" then
        value = string.sub(value, 2, -2)
        value = string.gsub(value, "''", "'")
    end
    return value
end

local function parse_fact(text)
    local tokens = tokenize(text)
    if token_upper(tokens[1]) ~= "FACT" then
        error("SEMANTIC_DDL_020: expected FACT entry")
    end
    local name = normalize_name(token_identifier(tokens[2]), "FACT_NAME")
    local positions, ordered = clause_positions(tokens, 3)
    local entity = normalize_name(clause_text(text, tokens, positions, ordered, "ON_ENTITY"), "ENTITY_NAME")
    local expression = clause_text(text, tokens, positions, ordered, "AS")
    local data_type = clause_text(text, tokens, positions, ordered, "RETURNS")
    if missing(expression) then
        error("SEMANTIC_DDL_021: FACT " .. name .. " requires AS")
    end
    if missing(data_type) then
        error("SEMANTIC_DDL_022: FACT " .. name .. " requires RETURNS")
    end
    local policy = "ADDITIVE"
    if positions.SEMI_ADDITIVE ~= nil then
        policy = "SEMI_ADDITIVE"
    elseif positions.NON_ADDITIVE_BY ~= nil then
        policy = "NON_ADDITIVE"
    end
    return {
        kind = "FACT",
        name = name,
        entity = entity,
        expression = expression,
        data_type = data_type,
        additive_policy = policy,
        display_name = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "DISPLAY")),
        description = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "COMMENT")),
        is_private = positions.PRIVATE ~= nil,
        is_certified = positions.CERTIFIED ~= nil,
    }
end

local function aggregate_parts(expression)
    local text = trim(expression)
    local tokens = tokenize(text)
    if #tokens < 3 or tokens[1].kind ~= "word" or tokens[2].text ~= "(" then
        return nil, nil
    end
    local depth = 0
    for i = 2, #tokens do
        if tokens[i].text == "(" then
            depth = depth + 1
        elseif tokens[i].text == ")" then
            depth = depth - 1
            if depth == 0 then
                local inner = string.sub(text, tokens[2].end_pos + 1, tokens[i].start_pos - 1)
                return upper(tokens[1].text), trim(inner)
            end
        end
    end
    return nil, nil
end

local function parse_metric(text, leading_metric_seen)
    local tokens = tokenize(text)
    local name_index = 2
    if not leading_metric_seen then
        local metric_index = find_sequence(tokens, {"METRIC"}, 1, 0)
        if metric_index == nil then
            error("SEMANTIC_DDL_030: expected METRIC entry")
        end
        name_index = metric_index + 1
    elseif token_upper(tokens[1]) ~= "METRIC" then
        error("SEMANTIC_DDL_030: expected METRIC entry")
    end
    local name = normalize_name(token_identifier(tokens[name_index]), "METRIC_NAME")
    local positions, ordered = clause_positions(tokens, name_index + 1)
    local expression = clause_text(text, tokens, positions, ordered, "AS")
    if missing(expression) then
        error("SEMANTIC_DDL_031: METRIC " .. name .. " requires AS")
    end
    local metric_kind = "SIMPLE"
    local metric_type = "ADDITIVE"
    if positions.RATIO ~= nil then
        metric_kind = "RATIO"
        metric_type = "RATIO"
    elseif positions.DERIVED ~= nil then
        metric_kind = "DERIVED"
        metric_type = "DERIVED"
    elseif positions.DISTINCT ~= nil then
        metric_kind = "DISTINCT"
        metric_type = "DISTINCT"
    elseif positions.SEMI_ADDITIVE ~= nil or positions.NON_ADDITIVE_BY ~= nil then
        metric_kind = "SEMI_ADDITIVE"
        metric_type = "SEMI_ADDITIVE"
    elseif positions.WINDOW ~= nil then
        metric_kind = "WINDOW"
        metric_type = "WINDOW"
    end
    local agg_func, measure_expr = aggregate_parts(expression)
    local semantic_filter = parse_filter(clause_text(text, tokens, positions, ordered, "FILTER"))
    if metric_kind == "SIMPLE" and not missing(semantic_filter) then
        metric_kind = "FILTERED"
    end
    local data_type = clause_text(text, tokens, positions, ordered, "RETURNS")
    if missing(data_type) then
        error("SEMANTIC_DDL_032: METRIC " .. name .. " requires RETURNS")
    end
    return {
        kind = "METRIC",
        name = name,
        expression = expression,
        semantic_filter_expr = semantic_filter,
        metric_type = metric_type,
        metric_kind = metric_kind,
        aggregation_function = agg_func,
        measure_expr = measure_expr,
        base_entity = normalize_name(clause_text(text, tokens, positions, ordered, "ON_ENTITY"), "BASE_ENTITY_NAME"),
        data_type = data_type,
        display_name = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "DISPLAY")),
        description = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "COMMENT")),
        format_hint = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "FORMAT")),
        synonyms = parse_literal_list(clause_text(text, tokens, positions, ordered, "SYNONYMS")),
        is_private = positions.PRIVATE ~= nil,
        is_certified = positions.CERTIFIED ~= nil,
        distinct_key_expr = clause_text(text, tokens, positions, ordered, "DISTINCT_KEY"),
        non_additive_dimension = clause_text(text, tokens, positions, ordered, "NON_ADDITIVE_BY"),
        window_spec_json = clause_text(text, tokens, positions, ordered, "WINDOW"),
    }
end

local function matching_close(tokens, open_index)
    local depth = 0
    for i = open_index, #tokens do
        if tokens[i].text == "(" then
            depth = depth + 1
        elseif tokens[i].text == ")" then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
    end
    return nil
end

local function parse_qualified(tokens, start_index)
    local model_name = token_identifier(tokens[start_index])
    local object_name = nil
    local metric_name = nil
    local index = start_index + 1
    if tokens[index] ~= nil and tokens[index].text == "." then
        object_name = token_identifier(tokens[index + 1])
        index = index + 2
    end
    if tokens[index] ~= nil and tokens[index].text == "." then
        metric_name = token_identifier(tokens[index + 1])
        index = index + 2
    end
    return normalize_name(model_name, "MODEL_NAME"), object_name and normalize_name(object_name, "OBJECT_NAME") or nil, metric_name and normalize_name(metric_name, "METRIC_NAME") or nil, index
end

local function parse_definition(definition_sql)
    local source = tostring(definition_sql or "")
    local tokens = tokenize(source)
    if #tokens == 0 then
        error("SEMANTIC_DDL_001: definition SQL is required")
    end
    if token_upper(tokens[1]) ~= "ALTER" or token_upper(tokens[2]) ~= "SEMANTIC" or token_upper(tokens[3]) ~= "VIEW" then
        error("SEMANTIC_DDL_010: expected ALTER SEMANTIC VIEW")
    end
    local model_name, object_name, _, next_index = parse_qualified(tokens, 4)
    if object_name == nil then
        error("SEMANTIC_DDL_011: semantic view name must be model.object")
    end
    local definition = {
        statement_kind = "ALTER_SEMANTIC_VIEW",
        model_name = model_name,
        object_name = object_name,
        facts = {},
        metrics = {},
        replace_facts = false,
        replace_metrics = false,
    }

    local replace_facts = find_sequence(tokens, {"REPLACE", "FACTS"}, next_index, 0)
    local replace_metrics = find_sequence(tokens, {"REPLACE", "METRICS"}, next_index, 0)
    local add_metric = find_sequence(tokens, {"ADD", "OR", "REPLACE", "METRIC"}, next_index, 0)

    if replace_facts ~= nil then
        definition.replace_facts = true
        local open = replace_facts + 2
        if tokens[open] == nil or tokens[open].text ~= "(" then
            error("SEMANTIC_DDL_023: REPLACE FACTS requires a parenthesized block")
        end
        local close = matching_close(tokens, open)
        if close == nil then
            error("SEMANTIC_DDL_024: unterminated FACTS block")
        end
        local block = string.sub(source, tokens[open].end_pos + 1, tokens[close].start_pos - 1)
        for _, part in ipairs(split_top_level_text(block)) do
            definition.facts[#definition.facts + 1] = parse_fact(part)
        end
    end

    if replace_metrics ~= nil then
        definition.replace_metrics = true
        local open = replace_metrics + 2
        if tokens[open] == nil or tokens[open].text ~= "(" then
            error("SEMANTIC_DDL_033: REPLACE METRICS requires a parenthesized block")
        end
        local close = matching_close(tokens, open)
        if close == nil then
            error("SEMANTIC_DDL_034: unterminated METRICS block")
        end
        local block = string.sub(source, tokens[open].end_pos + 1, tokens[close].start_pos - 1)
        for _, part in ipairs(split_top_level_text(block)) do
            definition.metrics[#definition.metrics + 1] = parse_metric(part, true)
        end
    elseif add_metric ~= nil then
        local metric_text = string.sub(source, tokens[add_metric + 3].start_pos)
        definition.metrics[#definition.metrics + 1] = parse_metric(metric_text, false)
    else
        error("SEMANTIC_DDL_012: expected REPLACE FACTS, REPLACE METRICS, or ADD OR REPLACE METRIC")
    end

    return definition
end

local function load_model(model_name)
    local rows = query([[
        SELECT MODEL_ID, ACTIVE_VERSION_ID
        FROM SYS_SEMANTIC.MODELS
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_DDL_040: model not found: " .. tostring(model_name))
    end
    return {model_id = row_value(rows[1], "MODEL_ID", 1), version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2), model_name = model_name}
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_DDL_041: semantic view not found: " .. tostring(object_name))
    end
    return id
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_DDL_042: entity not found: " .. tostring(entity_name))
    end
    return id
end

local function dimension_by_name(model, name)
    if missing(name) then
        return nil
    end
    local rows = query([[
        SELECT DIMENSION_ID, ENTITY_ID, EXPRESSION
        FROM SYS_SEMANTIC.DIMENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(DIMENSION_NAME) = UPPER(:name)
    ]], {model_id = model.model_id, version_id = model.version_id, name = name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {id = row_value(rows[1], "DIMENSION_ID", 1), entity_id = row_value(rows[1], "ENTITY_ID", 2), expression = row_value(rows[1], "EXPRESSION", 3)}
end

local function replace_semantic_identifiers(model, expression)
    if missing(expression) then
        return nil
    end
    local tokens = tokenize(expression)
    local out = {}
    local last = 1
    for _, token in ipairs(tokens) do
        if token.kind == "word" or token.kind == "identifier" then
            local dim = dimension_by_name(model, token.value or token.text)
            if dim ~= nil then
                out[#out + 1] = string.sub(expression, last, token.start_pos - 1)
                out[#out + 1] = tostring(dim.expression)
                last = token.end_pos + 1
            end
        end
    end
    out[#out + 1] = string.sub(expression, last)
    return trim(table.concat(out))
end

local function source_hash(text)
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + string.byte(text, i)) % 4294967296
    end
    return tostring(hash)
end

local function insert_source(model, definition, definition_sql, normalized_json, status)
    query([[
        INSERT INTO SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES (
          MODEL_ID, VERSION_ID, SOURCE_KIND, SOURCE_NAME, DEFINITION_SQL,
          NORMALIZED_JSON, DEFINITION_HASH, APPLY_STATUS
        ) VALUES (
          :model_id, :version_id, :source_kind, :source_name, :definition_sql,
          :normalized_json, :definition_hash, :apply_status
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        source_kind = definition.statement_kind,
        source_name = definition.model_name .. "." .. definition.object_name,
        definition_sql = definition_sql,
        normalized_json = normalized_json,
        definition_hash = source_hash(definition_sql),
        apply_status = status,
    })
    return scalar([[
        SELECT MAX(DEFINITION_SOURCE_ID)
        FROM SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND DEFINITION_HASH = :definition_hash
    ]], {model_id = model.model_id, version_id = model.version_id, definition_hash = source_hash(definition_sql)})
end

local function add_object_column(object_id_value, kind, ref_id, column_name, is_visible)
    local visible = true
    if is_visible == false then
        visible = false
    end
    local existing = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = :kind
          AND OBJECT_REF_ID = :ref_id
    ]], {object_id = object_id_value, kind = kind, ref_id = ref_id})
    if tonumber(existing or 0) > 0 then
        return
    end
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id_value})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :kind, :ref_id, :column_name, :ordinal, :is_visible
        )
    ]], {object_id = object_id_value, kind = kind, ref_id = ref_id, column_name = column_name, ordinal = ordinal, is_visible = visible})
end

local function upsert_fact(model, object_id_value, fact)
    local entity = entity_id(model, fact.entity)
    local existing_id = scalar([[
        SELECT FACT_ID
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(FACT_NAME) = UPPER(:fact_name)
    ]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact.name})
    if existing_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.FACTS
            SET ENTITY_ID = :entity_id,
                EXPRESSION = :expression,
                DATA_TYPE = :data_type,
                ADDITIVE_POLICY = :additive_policy,
                DISPLAY_NAME = :display_name,
                DESCRIPTION = :description,
                IS_PRIVATE = :is_private,
                IS_CERTIFIED = :is_certified,
                STATUS = 'ACTIVE'
            WHERE FACT_ID = :fact_id
        ]], {
            fact_id = existing_id,
            entity_id = entity,
            expression = fact.expression,
            data_type = fact.data_type,
            additive_policy = fact.additive_policy,
            display_name = null_if_missing(fact.display_name),
            description = null_if_missing(fact.description),
            is_private = fact.is_private,
            is_certified = fact.is_certified,
        })
    else
        query([[
            INSERT INTO SYS_SEMANTIC.FACTS (
              MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
              ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, IS_PRIVATE, IS_CERTIFIED, STATUS
            ) VALUES (
              :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
              :additive_policy, :display_name, :description, :is_private, :is_certified, 'ACTIVE'
            )
        ]], {
            model_id = model.model_id,
            version_id = model.version_id,
            entity_id = entity,
            fact_name = fact.name,
            expression = fact.expression,
            data_type = fact.data_type,
            additive_policy = fact.additive_policy,
            display_name = null_if_missing(fact.display_name),
            description = null_if_missing(fact.description),
            is_private = fact.is_private,
            is_certified = fact.is_certified,
        })
        existing_id = scalar([[
            SELECT FACT_ID FROM SYS_SEMANTIC.FACTS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(FACT_NAME) = UPPER(:fact_name)
        ]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact.name})
    end
    add_object_column(object_id_value, "FACT", existing_id, fact.name, false)
    return existing_id
end

local function object_id_by_name(model, object_type, name)
    if object_type == "FACT" then
        return scalar("SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(FACT_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    elseif object_type == "METRIC" then
        return scalar("SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(METRIC_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    elseif object_type == "DIMENSION" then
        return scalar("SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(DIMENSION_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    end
    return nil
end

local SQL_WORDS = {
    SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true, NULLIF = true,
    CASE = true, WHEN = true, THEN = true, ELSE = true, END = true, DISTINCT = true,
    DATE = true, TIMESTAMP = true, TRUE = true, FALSE = true, NULL = true,
}

local function identifiers_in_expression(expression)
    local identifiers = {}
    local seen = {}
    for _, token in ipairs(tokenize(expression or "")) do
        if token.kind == "word" or token.kind == "identifier" then
            local name = token.value or token.text
            local normalized = upper(name)
            if not SQL_WORDS[normalized] and not seen[normalized] then
                identifiers[#identifiers + 1] = name
                seen[normalized] = true
            end
        end
    end
    return identifiers
end

local function validate_metric_shape(model, metric)
    if metric.metric_type == "RATIO" then
        local metric_input_count = 0
        for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
            if object_id_by_name(model, "METRIC", identifier) ~= nil then
                metric_input_count = metric_input_count + 1
            end
        end
        if metric_input_count < 2 then
            error("SEMANTIC_DDL_070: RATIO metric " .. metric.name .. " must reference at least two aggregate metrics")
        end
    elseif metric.metric_kind == "DISTINCT" then
        if missing(metric.distinct_key_expr) then
            error("SEMANTIC_DDL_071: DISTINCT metric " .. metric.name .. " requires DISTINCT KEY")
        end
    elseif metric.metric_type == "SEMI_ADDITIVE" then
        if missing(metric.non_additive_dimension) then
            error("SEMANTIC_DDL_072: SEMI ADDITIVE metric " .. metric.name .. " requires NON ADDITIVE BY")
        end
        local dim_name = tostring(metric.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
        if dimension_by_name(model, dim_name) == nil then
            error("SEMANTIC_DDL_073: SEMI ADDITIVE metric " .. metric.name .. " references unknown non-additive dimension")
        end
    elseif metric.metric_kind == "WINDOW" then
        if missing(metric.window_spec_json) then
            error("SEMANTIC_DDL_074: WINDOW metric " .. metric.name .. " requires WINDOW metadata")
        end
    end
end

local function refresh_metric_inputs(model, metric_id, metric)
    query("DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID = :metric_id", {metric_id = metric_id})
    query("DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID = :metric_id", {metric_id = metric_id})
    local ordinal = 1
    for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
        local object_type = nil
        local object_id_value = object_id_by_name(model, "FACT", identifier)
        local input_role = "MEASURE"
        if object_id_value ~= nil then
            object_type = "FACT"
        else
            object_id_value = object_id_by_name(model, "METRIC", identifier)
            if object_id_value ~= nil then
                object_type = "METRIC"
                input_role = metric.metric_type == "RATIO" and (ordinal == 1 and "NUMERATOR" or "DENOMINATOR") or "INPUT_METRIC"
            end
        end
        if object_type ~= nil then
            query([[
                INSERT INTO SYS_SEMANTIC.METRIC_INPUTS (
                  METRIC_ID, INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_ID,
                  EXPRESSION_ALIAS, ORDINAL_POSITION
                ) VALUES (
                  :metric_id, :input_role, :object_type, :object_id, :alias, :ordinal
                )
            ]], {metric_id = metric_id, input_role = input_role, object_type = object_type, object_id = object_id_value, alias = identifier, ordinal = ordinal})
            ordinal = ordinal + 1
        end
    end
    if not missing(metric.semantic_filter_expr) then
        local resolved = replace_semantic_identifiers(model, metric.semantic_filter_expr)
        local required_dimension_id = nil
        local required_entity_id = nil
        for _, identifier in ipairs(identifiers_in_expression(metric.semantic_filter_expr)) do
            local dim = dimension_by_name(model, identifier)
            if dim ~= nil then
                required_dimension_id = dim.id
                required_entity_id = dim.entity_id
                break
            end
        end
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_FILTERS (
              METRIC_ID, FILTER_KIND, FILTER_EXPR, RESOLVED_SQL_EXPR,
              REQUIRED_DIMENSION_ID, REQUIRED_ENTITY_ID, ORDINAL_POSITION
            ) VALUES (
              :metric_id, 'SEMANTIC_SQL', :filter_expr, :resolved_sql,
              :required_dimension_id, :required_entity_id, 1
            )
        ]], {
            metric_id = metric_id,
            filter_expr = metric.semantic_filter_expr,
            resolved_sql = resolved,
            required_dimension_id = null_if_missing(required_dimension_id),
            required_entity_id = null_if_missing(required_entity_id),
        })
        metric.sql_filter_expr = resolved
    end
end

local function upsert_synonyms(model, metric_id, synonyms)
    query([[
        DELETE FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE = 'METRIC'
          AND OBJECT_ID = :metric_id
    ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id})
    for _, synonym in ipairs(synonyms or {}) do
        if not missing(synonym) then
            query([[
                INSERT INTO SYS_SEMANTIC.SYNONYMS (
                  MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
                ) VALUES (
                  :model_id, :version_id, 'METRIC', :metric_id, :synonym, 'SEMANTIC_SQL'
                )
            ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id, synonym = synonym})
        end
    end
end

local function upsert_metric(model, object_id_value, metric, definition_source_id)
    local base_entity = entity_id(model, metric.base_entity)
    validate_metric_shape(model, metric)
    local existing_id = scalar([[
        SELECT METRIC_ID
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(METRIC_NAME) = UPPER(:metric_name)
    ]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric.name})
    local filter_expr = metric.sql_filter_expr or (not missing(metric.semantic_filter_expr) and replace_semantic_identifiers(model, metric.semantic_filter_expr) or nil)
    local non_additive_dimension_id = nil
    if not missing(metric.non_additive_dimension) then
        local dim_name = tostring(metric.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
        local dim = dimension_by_name(model, dim_name)
        if dim ~= nil then
            non_additive_dimension_id = dim.id
        end
    end
    if existing_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.METRICS
            SET EXPRESSION = :expression,
                FILTER_EXPR = :filter_expr,
                METRIC_TYPE = :metric_type,
                BASE_ENTITY_ID = :base_entity_id,
                DATA_TYPE = :data_type,
                DISPLAY_NAME = :display_name,
                DESCRIPTION = :description,
                FORMAT_HINT = :format_hint,
                IS_PRIVATE = :is_private,
                IS_CERTIFIED = :is_certified,
                METRIC_KIND = :metric_kind,
                AGGREGATION_FUNCTION = :aggregation_function,
                MEASURE_EXPR = :measure_expr,
                SEMANTIC_FILTER_EXPR = :semantic_filter_expr,
                SQL_FILTER_EXPR = :sql_filter_expr,
                DISTINCT_KEY_EXPR = :distinct_key_expr,
                NON_ADDITIVE_DIMENSION_ID = :non_additive_dimension_id,
                WINDOW_SPEC_JSON = :window_spec_json,
                TYPE_PARAMS_JSON = :type_params_json,
                DEFINITION_SOURCE_ID = :definition_source_id,
                STATUS = 'ACTIVE'
            WHERE METRIC_ID = :metric_id
        ]], {
            metric_id = existing_id,
            expression = metric.expression,
            filter_expr = null_if_missing(filter_expr),
            metric_type = metric.metric_type,
            base_entity_id = base_entity,
            data_type = metric.data_type,
            display_name = null_if_missing(metric.display_name),
            description = null_if_missing(metric.description),
            format_hint = null_if_missing(metric.format_hint),
            is_private = metric.is_private,
            is_certified = metric.is_certified,
            metric_kind = metric.metric_kind,
            aggregation_function = null_if_missing(metric.aggregation_function),
            measure_expr = null_if_missing(metric.measure_expr),
            semantic_filter_expr = null_if_missing(metric.semantic_filter_expr),
            sql_filter_expr = null_if_missing(filter_expr),
            distinct_key_expr = null_if_missing(metric.distinct_key_expr),
            non_additive_dimension_id = null_if_missing(non_additive_dimension_id),
            window_spec_json = null_if_missing(metric.window_spec_json),
            type_params_json = json_encode({metric_type = metric.metric_type}),
            definition_source_id = definition_source_id,
        })
    else
        query([[
            INSERT INTO SYS_SEMANTIC.METRICS (
              MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
              METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
              FORMAT_HINT, IS_PRIVATE, IS_CERTIFIED, METRIC_KIND,
              AGGREGATION_FUNCTION, MEASURE_EXPR, SEMANTIC_FILTER_EXPR,
              SQL_FILTER_EXPR, DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_ID,
              WINDOW_SPEC_JSON, TYPE_PARAMS_JSON, DEFINITION_SOURCE_ID, STATUS
            ) VALUES (
              :model_id, :version_id, :metric_name, :expression, :filter_expr,
              :metric_type, :base_entity_id, :data_type, :display_name, :description,
              :format_hint, :is_private, :is_certified, :metric_kind,
              :aggregation_function, :measure_expr, :semantic_filter_expr,
              :sql_filter_expr, :distinct_key_expr, :non_additive_dimension_id,
              :window_spec_json, :type_params_json, :definition_source_id, 'ACTIVE'
            )
        ]], {
            model_id = model.model_id,
            version_id = model.version_id,
            metric_name = metric.name,
            expression = metric.expression,
            filter_expr = null_if_missing(filter_expr),
            metric_type = metric.metric_type,
            base_entity_id = base_entity,
            data_type = metric.data_type,
            display_name = null_if_missing(metric.display_name),
            description = null_if_missing(metric.description),
            format_hint = null_if_missing(metric.format_hint),
            is_private = metric.is_private,
            is_certified = metric.is_certified,
            metric_kind = metric.metric_kind,
            aggregation_function = null_if_missing(metric.aggregation_function),
            measure_expr = null_if_missing(metric.measure_expr),
            semantic_filter_expr = null_if_missing(metric.semantic_filter_expr),
            sql_filter_expr = null_if_missing(filter_expr),
            distinct_key_expr = null_if_missing(metric.distinct_key_expr),
            non_additive_dimension_id = null_if_missing(non_additive_dimension_id),
            window_spec_json = null_if_missing(metric.window_spec_json),
            type_params_json = json_encode({metric_type = metric.metric_type}),
            definition_source_id = definition_source_id,
        })
        existing_id = scalar([[
            SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(METRIC_NAME) = UPPER(:metric_name)
        ]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric.name})
    end
    add_object_column(object_id_value, "METRIC", existing_id, metric.name, true)
    refresh_metric_inputs(model, existing_id, metric)
    upsert_synonyms(model, existing_id, metric.synonyms)
    return existing_id
end

local function replace_object_columns(object_id_value, column_kind)
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = :column_kind
    ]], {object_id = object_id_value, column_kind = column_kind})
end

local function snapshot_model_state(model)
    return {
        facts = query([[
            SELECT FACT_ID, MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
                   ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT,
                   SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, IS_CERTIFIED, STATUS
            FROM SYS_SEMANTIC.FACTS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metrics = query([[
            SELECT METRIC_ID, MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
                   METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
                   FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE,
                   IS_CERTIFIED, OWNER_ROLE, METRIC_KIND, AGGREGATION_FUNCTION, MEASURE_EXPR,
                   SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR, DISTINCT_KEY_EXPR,
                   NON_ADDITIVE_DIMENSION_ID, WINDOW_SPEC_JSON, TYPE_PARAMS_JSON,
                   DEFINITION_SOURCE_ID, STATUS
            FROM SYS_SEMANTIC.METRICS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        object_columns = query([[
            SELECT oc.OBJECT_ID, oc.COLUMN_KIND, oc.OBJECT_REF_ID, oc.COLUMN_NAME,
                   oc.ORDINAL_POSITION, oc.IS_VISIBLE
            FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
            JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON so.OBJECT_ID = oc.OBJECT_ID
            WHERE so.MODEL_ID = :model_id
              AND so.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metric_inputs = query([[
            SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE, mi.INPUT_OBJECT_ID,
                   mi.EXPRESSION_ALIAS, mi.OFFSET_WINDOW, mi.FILTER_EXPR, mi.ORDINAL_POSITION
            FROM SYS_SEMANTIC.METRIC_INPUTS mi
            JOIN SYS_SEMANTIC.METRICS mt
              ON mt.METRIC_ID = mi.METRIC_ID
            WHERE mt.MODEL_ID = :model_id
              AND mt.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metric_filters = query([[
            SELECT mf.METRIC_ID, mf.FILTER_KIND, mf.FILTER_EXPR, mf.RESOLVED_SQL_EXPR,
                   mf.REQUIRED_DIMENSION_ID, mf.REQUIRED_ENTITY_ID, mf.ORDINAL_POSITION
            FROM SYS_SEMANTIC.METRIC_FILTERS mf
            JOIN SYS_SEMANTIC.METRICS mt
              ON mt.METRIC_ID = mf.METRIC_ID
            WHERE mt.MODEL_ID = :model_id
              AND mt.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        synonyms = query([[
            SELECT SYNONYM_ID, MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
            FROM SYS_SEMANTIC.SYNONYMS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
    }
end

local function clear_model_state(model)
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_INPUTS
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_FILTERS
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID IN (
          SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
end

local function restore_model_state(model, snapshot)
    clear_model_state(model)
    for _, row in ipairs(snapshot.facts or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.FACTS (
              FACT_ID, MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
              ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT,
              SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, IS_CERTIFIED, STATUS
            ) VALUES (
              :fact_id, :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
              :additive_policy, :display_name, :description, :format_hint, :unit_hint,
              :sensitivity_label, :display_policy, :is_private, :is_certified, :status
            )
        ]], {
            fact_id = row_value(row, "FACT_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            entity_id = row_value(row, "ENTITY_ID", 4),
            fact_name = row_value(row, "FACT_NAME", 5),
            expression = row_value(row, "EXPRESSION", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            additive_policy = row_value(row, "ADDITIVE_POLICY", 8),
            display_name = null_if_missing(row_value(row, "DISPLAY_NAME", 9)),
            description = null_if_missing(row_value(row, "DESCRIPTION", 10)),
            format_hint = null_if_missing(row_value(row, "FORMAT_HINT", 11)),
            unit_hint = null_if_missing(row_value(row, "UNIT_HINT", 12)),
            sensitivity_label = null_if_missing(row_value(row, "SENSITIVITY_LABEL", 13)),
            display_policy = null_if_missing(row_value(row, "DISPLAY_POLICY", 14)),
            is_private = row_value(row, "IS_PRIVATE", 15),
            is_certified = row_value(row, "IS_CERTIFIED", 16),
            status = row_value(row, "STATUS", 17),
        })
    end
    for _, row in ipairs(snapshot.metrics or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRICS (
              METRIC_ID, MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
              METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
              FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE,
              IS_CERTIFIED, OWNER_ROLE, METRIC_KIND, AGGREGATION_FUNCTION, MEASURE_EXPR,
              SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR, DISTINCT_KEY_EXPR,
              NON_ADDITIVE_DIMENSION_ID, WINDOW_SPEC_JSON, TYPE_PARAMS_JSON,
              DEFINITION_SOURCE_ID, STATUS
            ) VALUES (
              :metric_id, :model_id, :version_id, :metric_name, :expression, :filter_expr,
              :metric_type, :base_entity_id, :data_type, :display_name, :description,
              :format_hint, :unit_hint, :sensitivity_label, :display_policy, :is_private,
              :is_certified, :owner_role, :metric_kind, :aggregation_function, :measure_expr,
              :semantic_filter_expr, :sql_filter_expr, :distinct_key_expr,
              :non_additive_dimension_id, :window_spec_json, :type_params_json,
              :definition_source_id, :status
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            metric_name = row_value(row, "METRIC_NAME", 4),
            expression = row_value(row, "EXPRESSION", 5),
            filter_expr = null_if_missing(row_value(row, "FILTER_EXPR", 6)),
            metric_type = row_value(row, "METRIC_TYPE", 7),
            base_entity_id = null_if_missing(row_value(row, "BASE_ENTITY_ID", 8)),
            data_type = row_value(row, "DATA_TYPE", 9),
            display_name = null_if_missing(row_value(row, "DISPLAY_NAME", 10)),
            description = null_if_missing(row_value(row, "DESCRIPTION", 11)),
            format_hint = null_if_missing(row_value(row, "FORMAT_HINT", 12)),
            unit_hint = null_if_missing(row_value(row, "UNIT_HINT", 13)),
            sensitivity_label = null_if_missing(row_value(row, "SENSITIVITY_LABEL", 14)),
            display_policy = null_if_missing(row_value(row, "DISPLAY_POLICY", 15)),
            is_private = row_value(row, "IS_PRIVATE", 16),
            is_certified = row_value(row, "IS_CERTIFIED", 17),
            owner_role = null_if_missing(row_value(row, "OWNER_ROLE", 18)),
            metric_kind = null_if_missing(row_value(row, "METRIC_KIND", 19)),
            aggregation_function = null_if_missing(row_value(row, "AGGREGATION_FUNCTION", 20)),
            measure_expr = null_if_missing(row_value(row, "MEASURE_EXPR", 21)),
            semantic_filter_expr = null_if_missing(row_value(row, "SEMANTIC_FILTER_EXPR", 22)),
            sql_filter_expr = null_if_missing(row_value(row, "SQL_FILTER_EXPR", 23)),
            distinct_key_expr = null_if_missing(row_value(row, "DISTINCT_KEY_EXPR", 24)),
            non_additive_dimension_id = null_if_missing(row_value(row, "NON_ADDITIVE_DIMENSION_ID", 25)),
            window_spec_json = null_if_missing(row_value(row, "WINDOW_SPEC_JSON", 26)),
            type_params_json = null_if_missing(row_value(row, "TYPE_PARAMS_JSON", 27)),
            definition_source_id = null_if_missing(row_value(row, "DEFINITION_SOURCE_ID", 28)),
            status = row_value(row, "STATUS", 29),
        })
    end
    for _, row in ipairs(snapshot.object_columns or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
              OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
            ) VALUES (
              :object_id, :column_kind, :object_ref_id, :column_name, :ordinal_position, :is_visible
            )
        ]], {
            object_id = row_value(row, "OBJECT_ID", 1),
            column_kind = row_value(row, "COLUMN_KIND", 2),
            object_ref_id = row_value(row, "OBJECT_REF_ID", 3),
            column_name = row_value(row, "COLUMN_NAME", 4),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 5),
            is_visible = row_value(row, "IS_VISIBLE", 6),
        })
    end
    for _, row in ipairs(snapshot.metric_inputs or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_INPUTS (
              METRIC_ID, INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_ID,
              EXPRESSION_ALIAS, OFFSET_WINDOW, FILTER_EXPR, ORDINAL_POSITION
            ) VALUES (
              :metric_id, :input_role, :input_object_type, :input_object_id,
              :expression_alias, :offset_window, :filter_expr, :ordinal_position
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            input_role = row_value(row, "INPUT_ROLE", 2),
            input_object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
            input_object_id = null_if_missing(row_value(row, "INPUT_OBJECT_ID", 4)),
            expression_alias = null_if_missing(row_value(row, "EXPRESSION_ALIAS", 5)),
            offset_window = null_if_missing(row_value(row, "OFFSET_WINDOW", 6)),
            filter_expr = null_if_missing(row_value(row, "FILTER_EXPR", 7)),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 8),
        })
    end
    for _, row in ipairs(snapshot.metric_filters or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_FILTERS (
              METRIC_ID, FILTER_KIND, FILTER_EXPR, RESOLVED_SQL_EXPR,
              REQUIRED_DIMENSION_ID, REQUIRED_ENTITY_ID, ORDINAL_POSITION
            ) VALUES (
              :metric_id, :filter_kind, :filter_expr, :resolved_sql_expr,
              :required_dimension_id, :required_entity_id, :ordinal_position
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            filter_kind = row_value(row, "FILTER_KIND", 2),
            filter_expr = row_value(row, "FILTER_EXPR", 3),
            resolved_sql_expr = null_if_missing(row_value(row, "RESOLVED_SQL_EXPR", 4)),
            required_dimension_id = null_if_missing(row_value(row, "REQUIRED_DIMENSION_ID", 5)),
            required_entity_id = null_if_missing(row_value(row, "REQUIRED_ENTITY_ID", 6)),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
        })
    end
    for _, row in ipairs(snapshot.synonyms or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.SYNONYMS (
              SYNONYM_ID, MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
            ) VALUES (
              :synonym_id, :model_id, :version_id, :object_type, :object_id, :synonym, :synonym_source
            )
        ]], {
            synonym_id = row_value(row, "SYNONYM_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            object_type = row_value(row, "OBJECT_TYPE", 4),
            object_id = row_value(row, "OBJECT_ID", 5),
            synonym = row_value(row, "SYNONYM", 6),
            synonym_source = null_if_missing(row_value(row, "SYNONYM_SOURCE", 7)),
        })
    end
end

local function batch_arg(args, name)
    if type(args) ~= "table" then
        return null
    end
    return null_if_missing(args[name])
end

local function batch_call(target, args)
    if target == "SEMANTIC_ADMIN.CREATE_MODEL" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(:model_name, :published_schema, :description, :owner_role)",
            {
                model_name = batch_arg(args, "model_name"),
                published_schema = batch_arg(args, "published_schema"),
                description = batch_arg(args, "description"),
                owner_role = batch_arg(args, "owner_role"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_ENTITY" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(:model_name, :entity_name, :source_schema, :source_object, :source_alias, :primary_key_expr, :grain_description, :description)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                source_schema = batch_arg(args, "source_schema"),
                source_object = batch_arg(args, "source_object"),
                source_alias = batch_arg(args, "source_alias"),
                primary_key_expr = batch_arg(args, "primary_key_expr"),
                grain_description = batch_arg(args, "grain_description"),
                description = batch_arg(args, "description"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(:model_name, :object_name, :root_entity_name, :description)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                root_entity_name = batch_arg(args, "root_entity_name"),
                description = batch_arg(args, "description"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_RELATIONSHIP" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(:model_name, :relationship_name, :from_entity_name, :to_entity_name, :join_condition, :cardinality, :join_type, :fanout_policy)",
            {
                model_name = batch_arg(args, "model_name"),
                relationship_name = batch_arg(args, "relationship_name"),
                from_entity_name = batch_arg(args, "from_entity_name"),
                to_entity_name = batch_arg(args, "to_entity_name"),
                join_condition = batch_arg(args, "join_condition"),
                cardinality = batch_arg(args, "cardinality"),
                join_type = batch_arg(args, "join_type"),
                fanout_policy = batch_arg(args, "fanout_policy"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_DIMENSION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(:model_name, :object_name, :entity_name, :dimension_name, :expression, :data_type, :display_name, :description, :format_hint, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                entity_name = batch_arg(args, "entity_name"),
                dimension_name = batch_arg(args, "dimension_name"),
                expression = batch_arg(args, "expression"),
                data_type = batch_arg(args, "data_type"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                format_hint = batch_arg(args, "format_hint"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_FACT" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(:model_name, :entity_name, :fact_name, :expression, :data_type, :additive_policy, :display_name, :description, :is_private, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                fact_name = batch_arg(args, "fact_name"),
                expression = batch_arg(args, "expression"),
                data_type = batch_arg(args, "data_type"),
                additive_policy = batch_arg(args, "additive_policy"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                is_private = batch_arg(args, "is_private"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_METRIC" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(:model_name, :object_name, :metric_name, :expression, :filter_expr, :metric_type, :base_entity_name, :data_type, :display_name, :description, :format_hint, :is_private, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                metric_name = batch_arg(args, "metric_name"),
                expression = batch_arg(args, "expression"),
                filter_expr = batch_arg(args, "filter_expr"),
                metric_type = batch_arg(args, "metric_type"),
                base_entity_name = batch_arg(args, "base_entity_name"),
                data_type = batch_arg(args, "data_type"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                format_hint = batch_arg(args, "format_hint"),
                is_private = batch_arg(args, "is_private"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION(:model_name, :scope_type, :scope_name, :vendor_name, :data_json, :source_format, :extension_name)",
            {
                model_name = batch_arg(args, "model_name"),
                scope_type = batch_arg(args, "scope_type"),
                scope_name = batch_arg(args, "scope_name"),
                vendor_name = batch_arg(args, "vendor_name"),
                data_json = batch_arg(args, "data_json"),
                source_format = batch_arg(args, "source_format"),
                extension_name = batch_arg(args, "extension_name"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_UNIQUE_KEY" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(:model_name, :entity_name, :key_name, :key_kind, :description, :source_format)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                key_name = batch_arg(args, "key_name"),
                key_kind = batch_arg(args, "key_kind"),
                description = batch_arg(args, "description"),
                source_format = batch_arg(args, "source_format"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(:model_name, :entity_name, :key_name, :column_name, :expression, :ordinal_position)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                key_name = batch_arg(args, "key_name"),
                column_name = batch_arg(args, "column_name"),
                expression = batch_arg(args, "expression"),
                ordinal_position = batch_arg(args, "ordinal_position"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_SYNONYM" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(:model_name, :object_type, :object_name, :synonym, :source)",
            {
                model_name = batch_arg(args, "model_name"),
                object_type = batch_arg(args, "object_type"),
                object_name = batch_arg(args, "object_name"),
                synonym = batch_arg(args, "synonym"),
                source = batch_arg(args, "source"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(:model_name, :scope_type, :scope_name, :instruction_kind, :instruction_text, :applies_to_role, :priority)",
            {
                model_name = batch_arg(args, "model_name"),
                scope_type = batch_arg(args, "scope_type"),
                scope_name = batch_arg(args, "scope_name"),
                instruction_kind = batch_arg(args, "instruction_kind"),
                instruction_text = batch_arg(args, "instruction_text"),
                applies_to_role = batch_arg(args, "applies_to_role"),
                priority = batch_arg(args, "priority"),
            }
        )
    end
    error("SEMANTIC_OSI_010: unsupported normalized import target: " .. tostring(target))
end

local function metadata_of(operation)
    if type(operation) ~= "table" or type(operation.metadata) ~= "table" then
        return {}
    end
    return operation.metadata
end

local function ref_id_for_object_column(model, kind_value, name)
    local kind_name = upper(kind_value)
    local ref_id = object_id_by_name(model, kind_name, name)
    if ref_id == nil then
        error("SEMANTIC_OSI_020: object-column reference not found: " .. tostring(kind_value) .. " " .. tostring(name))
    end
    return kind_name, ref_id
end

local function visible_value(column, kind_name)
    if column.is_visible == false then
        return false
    end
    if column.is_visible == true then
        return true
    end
    return kind_name ~= "FACT"
end

local function insert_object_column(object_id_value, kind_name, ref_id, column_name, ordinal, is_visible)
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :column_kind, :object_ref_id, :column_name, :ordinal_position, :is_visible
        )
    ]], {
        object_id = object_id_value,
        column_kind = kind_name,
        object_ref_id = ref_id,
        column_name = column_name,
        ordinal_position = ordinal,
        is_visible = is_visible,
    })
end

local function replace_semantic_object_columns(args, metadata)
    local columns = metadata.columns
    if type(columns) ~= "table" or #columns == 0 then
        return
    end
    local model = load_model(args.model_name)
    local object_id_value = object_id(model, args.object_name)
    query("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id", {object_id = object_id_value})
    for index, column in ipairs(columns) do
        local kind_name, ref_id = ref_id_for_object_column(model, column.kind, column.name)
        insert_object_column(
            object_id_value,
            kind_name,
            ref_id,
            column.name,
            column.ordinal or index,
            visible_value(column, kind_name)
        )
    end
end

local function patch_operation_object_columns(operation)
    local metadata = metadata_of(operation)
    local columns = metadata.object_columns
    if type(columns) ~= "table" or #columns == 0 then
        return
    end
    local args = operation.arguments or {}
    local kind_name = nil
    local ref_name = nil
    if operation.operation == "add_dimension" then
        kind_name = "DIMENSION"
        ref_name = args.dimension_name
    elseif operation.operation == "add_fact" then
        kind_name = "FACT"
        ref_name = args.fact_name
    elseif operation.operation == "add_metric" then
        kind_name = "METRIC"
        ref_name = args.metric_name
    else
        return
    end
    local model = load_model(args.model_name)
    local _, ref_id = ref_id_for_object_column(model, kind_name, ref_name)
    for index, column in ipairs(columns) do
        local object_id_value = object_id(model, column.object_name)
        query([[
            DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
            WHERE OBJECT_ID = :object_id
              AND COLUMN_KIND = :column_kind
              AND OBJECT_REF_ID = :object_ref_id
        ]], {object_id = object_id_value, column_kind = kind_name, object_ref_id = ref_id})
        insert_object_column(
            object_id_value,
            kind_name,
            ref_id,
            column.column_name or ref_name,
            column.ordinal or index,
            visible_value(column, kind_name)
        )
    end
end

local function patch_relationship_metadata(operation)
    local metadata = metadata_of(operation)
    local native = metadata.native
    if operation.operation ~= "add_relationship" or type(native) ~= "table" then
        return
    end
    if missing(native.description) and missing(native.path_priority) then
        return
    end
    local args = operation.arguments or {}
    local model = load_model(args.model_name)
    query([[
        UPDATE SYS_SEMANTIC.RELATIONSHIPS
        SET DESCRIPTION = COALESCE(:description, DESCRIPTION),
            PATH_PRIORITY = COALESCE(:path_priority, PATH_PRIORITY)
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(RELATIONSHIP_NAME) = UPPER(:relationship_name)
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        relationship_name = args.relationship_name,
        description = null_if_missing(native.description),
        path_priority = null_if_missing(native.path_priority),
    })
end

local function non_additive_dimension_id(model, native)
    if missing(native.non_additive_dimension) then
        return null
    end
    local dim_name = tostring(native.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
    local dim = dimension_by_name(model, dim_name)
    if dim == nil then
        return null
    end
    return dim.id
end

local function patch_metric_metadata(operation)
    local metadata = metadata_of(operation)
    local native = metadata.native
    if operation.operation ~= "add_metric" or type(native) ~= "table" then
        return
    end
    local args = operation.arguments or {}
    local model = load_model(args.model_name)
    local metric_id = object_id_by_name(model, "METRIC", args.metric_name)
    if metric_id == nil then
        error("SEMANTIC_OSI_030: metric not found for metadata patch: " .. tostring(args.metric_name))
    end
    local metric_for_inputs = {
        name = args.metric_name,
        expression = args.expression,
        metric_type = native.metric_type or args.metric_type,
        semantic_filter_expr = native.semantic_filter_expr,
    }
    refresh_metric_inputs(model, metric_id, metric_for_inputs)
    local sql_filter_expr = native.sql_filter_expr or metric_for_inputs.sql_filter_expr
    query([[
        UPDATE SYS_SEMANTIC.METRICS
        SET METRIC_KIND = COALESCE(:metric_kind, METRIC_KIND),
            AGGREGATION_FUNCTION = COALESCE(:aggregation_function, AGGREGATION_FUNCTION),
            MEASURE_EXPR = COALESCE(:measure_expr, MEASURE_EXPR),
            SEMANTIC_FILTER_EXPR = COALESCE(:semantic_filter_expr, SEMANTIC_FILTER_EXPR),
            SQL_FILTER_EXPR = COALESCE(:sql_filter_expr, SQL_FILTER_EXPR),
            FILTER_EXPR = COALESCE(:sql_filter_expr, FILTER_EXPR),
            DISTINCT_KEY_EXPR = COALESCE(:distinct_key_expr, DISTINCT_KEY_EXPR),
            NON_ADDITIVE_DIMENSION_ID = COALESCE(:non_additive_dimension_id, NON_ADDITIVE_DIMENSION_ID),
            WINDOW_SPEC_JSON = COALESCE(:window_spec_json, WINDOW_SPEC_JSON),
            TYPE_PARAMS_JSON = COALESCE(:type_params_json, TYPE_PARAMS_JSON),
            UNIT_HINT = COALESCE(:unit_hint, UNIT_HINT),
            SENSITIVITY_LABEL = COALESCE(:sensitivity_label, SENSITIVITY_LABEL),
            DISPLAY_POLICY = COALESCE(:display_policy, DISPLAY_POLICY),
            OWNER_ROLE = COALESCE(:owner_role, OWNER_ROLE)
        WHERE METRIC_ID = :metric_id
    ]], {
        metric_id = metric_id,
        metric_kind = null_if_missing(native.metric_kind),
        aggregation_function = null_if_missing(native.aggregation_function),
        measure_expr = null_if_missing(native.measure_expr),
        semantic_filter_expr = null_if_missing(native.semantic_filter_expr),
        sql_filter_expr = null_if_missing(sql_filter_expr),
        distinct_key_expr = null_if_missing(native.distinct_key_expr),
        non_additive_dimension_id = non_additive_dimension_id(model, native),
        window_spec_json = null_if_missing(native.window_spec_json),
        type_params_json = null_if_missing(native.type_params_json),
        unit_hint = null_if_missing(native.unit_hint),
        sensitivity_label = null_if_missing(native.sensitivity_label),
        display_policy = null_if_missing(native.display_policy),
        owner_role = null_if_missing(native.owner_role),
    })
end

local function model_names_from_plan(plan)
    local names = {}
    local seen = {}
    for _, model in ipairs(plan.models or {}) do
        if type(model) == "table" and not missing(model.model_name) and not seen[model.model_name] then
            names[#names + 1] = model.model_name
            seen[model.model_name] = true
        end
    end
    for _, operation in ipairs(plan.operations or {}) do
        local args = operation.arguments or {}
        if operation.operation == "create_model" and not missing(args.model_name) and not seen[args.model_name] then
            names[#names + 1] = args.model_name
            seen[args.model_name] = true
        end
    end
    return names
end

local function validation_summary(plan, warnings, warnings_as_errors)
    local error_count = 0
    local warning_count = 0
    local validation_run_id = nil
    for _, model_name in ipairs(model_names_from_plan(plan)) do
        local rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name}) or {}
        local model = load_model(model_name)
        validation_run_id = scalar([[
            SELECT MAX(VALIDATION_RUN_ID)
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or validation_run_id
        for _, row in ipairs(rows) do
            local severity = row_value(row, "SEVERITY", 1)
            if severity == "ERROR" or severity == "WARNING" then
                warnings[#warnings + 1] = {
                    code = "OSI_APPLY_030",
                    severity = severity,
                    path = tostring(row_value(row, "OBJECT_NAME", 3) or row_value(row, "OBJECT_TYPE", 2) or "$"),
                    message = tostring(row_value(row, "RULE_CODE", 4) or "") .. ": " .. tostring(row_value(row, "MESSAGE", 5) or ""),
                }
            end
            if severity == "ERROR" then
                error_count = error_count + 1
            elseif severity == "WARNING" then
                warning_count = warning_count + 1
            end
        end
    end
    if error_count > 0 then
        return "ERROR", validation_run_id, tostring(error_count) .. " validation error(s)."
    end
    if sql_bool(warnings_as_errors) and warning_count > 0 then
        return "ERROR", validation_run_id, tostring(warning_count) .. " validation warning(s) promoted to errors."
    end
    return "OK", validation_run_id, "Normalized OSI import applied."
end

local function apply_metadata_patches(plan)
    for _, operation in ipairs(plan.operations or {}) do
        patch_relationship_metadata(operation)
        patch_metric_metadata(operation)
        patch_operation_object_columns(operation)
    end
    for _, operation in ipairs(plan.operations or {}) do
        if operation.operation == "add_semantic_object" then
            replace_semantic_object_columns(operation.arguments or {}, metadata_of(operation))
        end
    end
end

function M.apply_normalized_osi_import(plan_json, validate_after_apply, warnings_as_errors)
    local rows = {}
    local warnings = {}
    local current_operation = nil
    local ok, result = pcall(function()
        local plan = json_decode(plan_json)
        if type(plan) ~= "table" or type(plan.operations) ~= "table" then
            error("SEMANTIC_OSI_001: normalized import plan must contain operations")
        end
        for index, operation in ipairs(plan.operations) do
            if type(operation) ~= "table" then
                error("SEMANTIC_OSI_002: normalized operation must be an object")
            end
            current_operation = operation
            current_operation.index = index - 1
            local target = operation.target
            local result_rows = batch_call(target, operation.arguments or {}) or {}
            rows[#rows + 1] = {
                "OK",
                index - 1,
                operation.operation or null,
                target or null,
                operation.source_path or null,
                #result_rows,
                nil,
                nil,
                "Applied normalized operation.",
            }
        end
        apply_metadata_patches(plan)
        local status = "OK"
        local validation_run_id = nil
        local message = "Normalized OSI import applied."
        if sql_bool(validate_after_apply) then
            status, validation_run_id, message = validation_summary(plan, warnings, warnings_as_errors)
        end
        rows[#rows + 1] = {
            status,
            nil,
            "validate_model",
            "SEMANTIC_ADMIN.VALIDATE_MODEL",
            "$.models",
            nil,
            json_encode(warnings),
            validation_run_id or null,
            message,
        }
        return rows
    end)
    if ok then
        return result
    end
    rows[#rows + 1] = {
        "ERROR",
        current_operation and current_operation.index or nil,
        current_operation and current_operation.operation or "apply_normalized_osi_import",
        current_operation and current_operation.target or "SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT",
        current_operation and current_operation.source_path or "$",
        nil,
        json_encode(warnings),
        nil,
        tostring(result),
    }
    return rows
end

function M.apply_semantic_definition(definition_sql, dry_run)
    local source_id = nil
    local snapshot = nil
    local restore_model = nil
    local ok, result = pcall(function()
        local definition = parse_definition(definition_sql)
        local normalized_json = json_encode(definition)
        if sql_bool(dry_run) then
            return {{"DRY_RUN", nil, "Parsed Semantic SQL definition.", normalized_json, #definition.facts + #definition.metrics, nil}}
        end
        local model = load_model(definition.model_name)
        restore_model = model
        local object_id_value = object_id(model, definition.object_name)
        snapshot = snapshot_model_state(model)
        source_id = insert_source(model, definition, definition_sql, normalized_json, "APPLYING")
        if definition.replace_facts then
            replace_object_columns(object_id_value, "FACT")
        end
        if definition.replace_metrics then
            replace_object_columns(object_id_value, "METRIC")
        end
        for _, fact in ipairs(definition.facts) do
            upsert_fact(model, object_id_value, fact)
        end
        for _, metric in ipairs(definition.metrics) do
            upsert_metric(model, object_id_value, metric, source_id)
        end
        local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
        local error_count = 0
        for _, row in ipairs(validation_rows or {}) do
            if row_value(row, "SEVERITY", 1) == "ERROR" then
                error_count = error_count + 1
            end
        end
        local validation_run_id = scalar([[
            SELECT MAX(VALIDATION_RUN_ID)
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id})
        query([[
            UPDATE SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
            SET APPLY_STATUS = :status,
                VALIDATION_RUN_ID = :validation_run_id
            WHERE DEFINITION_SOURCE_ID = :source_id
        ]], {status = error_count > 0 and "VALIDATION_FAILED" or "APPLIED", validation_run_id = validation_run_id, source_id = source_id})
        if error_count > 0 then
            restore_model_state(model, snapshot)
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
            return {{"ERROR", "SEMANTIC_DDL_090", "Definition rejected; validation failed and catalog state was restored.", normalized_json, #definition.facts + #definition.metrics, validation_run_id}}
        end
        return {{"OK", nil, "Semantic definition applied.", normalized_json, #definition.facts + #definition.metrics, validation_run_id}}
    end)
    if ok then
        return result
    end
    if source_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
            SET APPLY_STATUS = 'ERROR'
            WHERE DEFINITION_SOURCE_ID = :source_id
        ]], {source_id = source_id})
    end
    if restore_model ~= nil and snapshot ~= nil then
        restore_model_state(restore_model, snapshot)
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = restore_model.model_name})
    end
    local message = tostring(result)
    local error_code = string.match(message, "(SEMANTIC_DDL_%d+)")
    return {{"ERROR", error_code or "SEMANTIC_DDL_999", message, nil, nil, nil}}
end

local function parse_metric_ref(ref)
    local parts = {}
    for part in string.gmatch(tostring(ref or ""), "[^.]+") do
        parts[#parts + 1] = part
    end
    if #parts ~= 3 then
        error("SEMANTIC_DDL_050: metric reference must be model.object.metric")
    end
    return normalize_name(parts[1], "MODEL_NAME"), normalize_name(parts[2], "OBJECT_NAME"), normalize_name(parts[3], "METRIC_NAME")
end

local function load_metric(model_name, object_name, metric_name)
    local rows = query([[
        SELECT mo.MODEL_NAME, mo.OBJECT_NAME, mo.METRIC_ID, mo.METRIC_NAME,
               mo.DISPLAY_NAME, mo.METRIC_KIND, mo.METRIC_TYPE, mo.BASE_ENTITY_NAME,
               mo.FORMAT_HINT, mo.IS_CERTIFIED, mo.IS_PRIVATE, mo.OWNER_ROLE,
               mo.DESCRIPTION, mo.SYNONYMS, mt.EXPRESSION, mt.SEMANTIC_FILTER_EXPR,
               mt.FILTER_EXPR, mt.DATA_TYPE, mt.DEFINITION_SOURCE_ID
        FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mo.METRIC_ID
        WHERE UPPER(mo.MODEL_NAME) = UPPER(:model_name)
          AND UPPER(mo.OBJECT_NAME) = UPPER(:object_name)
          AND UPPER(mo.METRIC_NAME) = UPPER(:metric_name)
          AND mo.STATUS = 'ACTIVE'
          AND mo.IS_PRIVATE = FALSE
          AND EXISTS (
            SELECT 1
            FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
            WHERE af.FIELD_KIND = 'METRIC'
              AND af.MODEL_NAME = mo.MODEL_NAME
              AND af.OBJECT_NAME = mo.OBJECT_NAME
              AND af.FIELD_ID = mo.METRIC_ID
          )
    ]], {model_name = model_name, object_name = object_name, metric_name = metric_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_DDL_051: metric not found: " .. model_name .. "." .. object_name .. "." .. metric_name)
    end
    return rows[1]
end

function M.describe_semantic_metric(model_name, object_name, metric_name)
    local row = load_metric(model_name, object_name, metric_name)
    local rows = {}
    local function add(section, name, value)
        rows[#rows + 1] = {section, name, missing(value) and null or tostring(value)}
    end
    add("Identity", "model_name", row_value(row, "MODEL_NAME", 1))
    add("Identity", "object_name", row_value(row, "OBJECT_NAME", 2))
    add("Identity", "metric_name", row_value(row, "METRIC_NAME", 4))
    add("Identity", "display_name", row_value(row, "DISPLAY_NAME", 5))
    add("Meaning", "description", row_value(row, "DESCRIPTION", 13))
    add("Meaning", "synonyms", row_value(row, "SYNONYMS", 14))
    add("Computation", "metric_kind", row_value(row, "METRIC_KIND", 6))
    add("Computation", "metric_type", row_value(row, "METRIC_TYPE", 7))
    add("Computation", "expression", row_value(row, "EXPRESSION", 15))
    add("Computation", "semantic_filter", row_value(row, "SEMANTIC_FILTER_EXPR", 16))
    add("Computation", "sql_filter", row_value(row, "FILTER_EXPR", 17))
    add("Computation", "base_entity", row_value(row, "BASE_ENTITY_NAME", 8))
    add("Governance", "visibility", row_value(row, "IS_PRIVATE", 11) and "PRIVATE" or "PUBLIC")
    add("Governance", "certified", row_value(row, "IS_CERTIFIED", 10))
    add("Governance", "owner_role", row_value(row, "OWNER_ROLE", 12))
    add("Presentation", "format", row_value(row, "FORMAT_HINT", 9))
    add("Presentation", "data_type", row_value(row, "DATA_TYPE", 18))
    return rows
end

function M.explain_semantic_metric(model_name, object_name, metric_name)
    local metric = load_metric(model_name, object_name, metric_name)
    local metric_id = row_value(metric, "METRIC_ID", 3)
    local rows = {}
    local function add(section, item, detail)
        rows[#rows + 1] = {section, item, missing(detail) and null or tostring(detail)}
    end
    add("Definition", "expression", row_value(metric, "EXPRESSION", 15))
    add("Definition", "semantic_filter", row_value(metric, "SEMANTIC_FILTER_EXPR", 16))
    add("Aggregation", "base_entity", row_value(metric, "BASE_ENTITY_NAME", 8))
    for _, dep in ipairs(query([[
        SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_NAME
        FROM SEMANTIC_CATALOG.METRIC_LINEAGE
        WHERE METRIC_ID = :metric_id
        ORDER BY ORDINAL_POSITION
    ]], {metric_id = metric_id}) or {}) do
        add("Lineage", tostring(row_value(dep, "INPUT_ROLE", 1)) .. ":" .. tostring(row_value(dep, "INPUT_OBJECT_TYPE", 2)), row_value(dep, "INPUT_OBJECT_NAME", 3))
    end
    for _, dim in ipairs(query([[
        SELECT DIMENSION_NAME
        FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS
        WHERE METRIC_ID = :metric_id
          AND IS_VALID = TRUE
        ORDER BY DIMENSION_NAME
    ]], {metric_id = metric_id}) or {}) do
        add("Compatibility", "valid_dimension", row_value(dim, "DIMENSION_NAME", 1))
    end
    local validation_status = scalar([[
        SELECT STATUS
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE VALIDATION_RUN_ID = (
          SELECT MAX(VALIDATION_RUN_ID)
          FROM SYS_SEMANTIC.VALIDATION_RUNS
          WHERE MODEL_NAME = :model_name
        )
    ]], {model_name = model_name})
    add("Validation", "latest_status", validation_status)
    return rows
end

local function canonical_metric_sql(model_name, object_name, metric_name)
    local row = load_metric(model_name, object_name, metric_name)
    local lines = {}
    lines[#lines + 1] = "ALTER SEMANTIC VIEW " .. model_name .. "." .. object_name
    lines[#lines + 1] = "  ADD OR REPLACE METRIC " .. tostring(row_value(row, "METRIC_NAME", 4))
    lines[#lines + 1] = "  AS " .. tostring(row_value(row, "EXPRESSION", 15))
    lines[#lines + 1] = "  ON ENTITY " .. tostring(row_value(row, "BASE_ENTITY_NAME", 8))
    lines[#lines + 1] = "  RETURNS " .. tostring(row_value(row, "DATA_TYPE", 18))
    if not missing(row_value(row, "SEMANTIC_FILTER_EXPR", 16)) then
        lines[#lines + 1] = "  FILTER (WHERE " .. tostring(row_value(row, "SEMANTIC_FILTER_EXPR", 16)) .. ")"
    end
    if not missing(row_value(row, "FORMAT_HINT", 9)) then
        lines[#lines + 1] = "  FORMAT " .. sql_string(row_value(row, "FORMAT_HINT", 9))
    end
    if not missing(row_value(row, "DISPLAY_NAME", 5)) then
        lines[#lines + 1] = "  DISPLAY " .. sql_string(row_value(row, "DISPLAY_NAME", 5))
    end
    if not missing(row_value(row, "DESCRIPTION", 13)) then
        lines[#lines + 1] = "  COMMENT " .. sql_string(row_value(row, "DESCRIPTION", 13))
    end
    if not missing(row_value(row, "SYNONYMS", 14)) then
        local syn_literals = {}
        for synonym in string.gmatch(tostring(row_value(row, "SYNONYMS", 14)), "([^,]+)") do
            syn_literals[#syn_literals + 1] = sql_string(trim(synonym))
        end
        lines[#lines + 1] = "  SYNONYMS (" .. table.concat(syn_literals, ", ") .. ")"
    end
    lines[#lines + 1] = "  " .. tostring(row_value(row, "METRIC_TYPE", 7))
        .. (row_value(row, "IS_PRIVATE", 11) and " PRIVATE" or " PUBLIC")
        .. (row_value(row, "IS_CERTIFIED", 10) and " CERTIFIED" or "")
        .. ";"
    return table.concat(lines, "\n")
end

local function canonical_entity_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "ENTITY_NAME", 1)),
            sql_string(row_value(row, "SOURCE_SCHEMA", 2)),
            sql_string(row_value(row, "SOURCE_OBJECT", 3)),
            sql_string(row_value(row, "SOURCE_ALIAS", 4)),
            sql_string(row_value(row, "PRIMARY_KEY_EXPR", 5)),
            sql_string(row_value(row, "GRAIN_DESCRIPTION", 6)),
            sql_string(row_value(row, "DESCRIPTION", 7)),
        }, ", ") .. ");"
end

local function canonical_relationship_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "RELATIONSHIP_NAME", 1)),
            sql_string(row_value(row, "FROM_ENTITY_NAME", 2)),
            sql_string(row_value(row, "TO_ENTITY_NAME", 3)),
            sql_string(row_value(row, "JOIN_CONDITION", 4)),
            sql_string(row_value(row, "RELATIONSHIP_CARDINALITY", 5)),
            sql_string(row_value(row, "JOIN_TYPE", 6)),
            sql_string(row_value(row, "FANOUT_POLICY", 7)),
        }, ", ") .. ");"
end

local function canonical_fact_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "ENTITY_NAME", 2)),
            sql_string(row_value(row, "FACT_NAME", 1)),
            sql_string(row_value(row, "EXPRESSION", 3)),
            sql_string(row_value(row, "DATA_TYPE", 4)),
            sql_string(row_value(row, "ADDITIVE_POLICY", 5)),
            sql_string(row_value(row, "DISPLAY_NAME", 6)),
            sql_string(row_value(row, "DESCRIPTION", 7)),
            sql_boolean(row_value(row, "IS_PRIVATE", 8)),
            sql_boolean(row_value(row, "IS_CERTIFIED", 9)),
        }, ", ") .. ");"
end

local function canonical_dimension_sql(model_name, object_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        .. table.concat({
            sql_string(model_name),
            sql_string(object_name),
            sql_string(row_value(row, "ENTITY_NAME", 2)),
            sql_string(row_value(row, "DIMENSION_NAME", 1)),
            sql_string(row_value(row, "EXPRESSION", 3)),
            sql_string(row_value(row, "DATA_TYPE", 4)),
            sql_string(row_value(row, "DISPLAY_NAME", 5)),
            sql_string(row_value(row, "DESCRIPTION", 6)),
            sql_string(row_value(row, "FORMAT_HINT", 7)),
            sql_boolean(row_value(row, "IS_CERTIFIED", 8)),
        }, ", ") .. ");"
end

function M.export_semantic_definition(model_name, object_name, metric_name)
    local filter_kind = nil
    if not missing(metric_name) then
        local maybe_kind = upper(trim(metric_name))
        if maybe_kind == "ENTITY" or maybe_kind == "RELATIONSHIP" or maybe_kind == "FACT" or maybe_kind == "DIMENSION" or maybe_kind == "METRIC" then
            filter_kind = maybe_kind
        end
    end
    if not missing(metric_name) and filter_kind == nil then
        return {{"METRIC", model_name .. "." .. object_name .. "." .. metric_name, canonical_metric_sql(model_name, object_name, metric_name)}}
    end
    local rows = {}
    local function add_export(kind, ref, definition_sql)
        if filter_kind == nil or filter_kind == kind then
            rows[#rows + 1] = {kind, ref, definition_sql}
        end
    end
    if missing(object_name) then
        for _, row in ipairs(query([[
            SELECT e.ENTITY_NAME, e.SOURCE_SCHEMA, e.SOURCE_OBJECT, e.SOURCE_ALIAS,
                   e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION, e.DESCRIPTION
            FROM SYS_SEMANTIC.ENTITIES e
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = e.MODEL_ID
             AND m.ACTIVE_VERSION_ID = e.VERSION_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND e.STATUS = 'ACTIVE'
            ORDER BY ENTITY_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "ENTITY_NAME", 1)
            add_export("ENTITY", model_name .. "." .. name, canonical_entity_sql(model_name, row))
        end
        for _, row in ipairs(query([[
            SELECT r.RELATIONSHIP_NAME, fe.ENTITY_NAME AS FROM_ENTITY_NAME,
                   te.ENTITY_NAME AS TO_ENTITY_NAME, r.JOIN_CONDITION,
                   r.RELATIONSHIP_CARDINALITY, r.JOIN_TYPE, r.FANOUT_POLICY
            FROM SYS_SEMANTIC.RELATIONSHIPS r
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = r.MODEL_ID
             AND m.ACTIVE_VERSION_ID = r.VERSION_ID
            JOIN SYS_SEMANTIC.ENTITIES fe
              ON fe.ENTITY_ID = r.FROM_ENTITY_ID
            JOIN SYS_SEMANTIC.ENTITIES te
              ON te.ENTITY_ID = r.TO_ENTITY_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND r.STATUS = 'ACTIVE'
            ORDER BY r.RELATIONSHIP_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "RELATIONSHIP_NAME", 1)
            add_export("RELATIONSHIP", model_name .. "." .. name, canonical_relationship_sql(model_name, row))
        end
        for _, row in ipairs(query([[
            SELECT f.FACT_NAME, e.ENTITY_NAME, f.EXPRESSION, f.DATA_TYPE,
                   f.ADDITIVE_POLICY, f.DISPLAY_NAME, f.DESCRIPTION,
                   f.IS_PRIVATE, f.IS_CERTIFIED
            FROM SYS_SEMANTIC.FACTS f
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = f.MODEL_ID
             AND m.ACTIVE_VERSION_ID = f.VERSION_ID
            JOIN SYS_SEMANTIC.ENTITIES e
              ON e.ENTITY_ID = f.ENTITY_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND f.STATUS = 'ACTIVE'
            ORDER BY f.FACT_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "FACT_NAME", 1)
            add_export("FACT", model_name .. "." .. name, canonical_fact_sql(model_name, row))
        end
        for _, row in ipairs(query([[
            SELECT so.OBJECT_NAME, d.DIMENSION_NAME, e.ENTITY_NAME,
                   d.EXPRESSION, d.DATA_TYPE, d.DISPLAY_NAME,
                   d.DESCRIPTION, d.FORMAT_HINT, d.IS_CERTIFIED
            FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
            JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON so.OBJECT_ID = oc.OBJECT_ID
            JOIN SYS_SEMANTIC.DIMENSIONS d
              ON d.DIMENSION_ID = oc.OBJECT_REF_ID
            JOIN SYS_SEMANTIC.ENTITIES e
              ON e.ENTITY_ID = d.ENTITY_ID
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = so.MODEL_ID
             AND m.ACTIVE_VERSION_ID = so.VERSION_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND oc.COLUMN_KIND = 'DIMENSION'
              AND oc.IS_VISIBLE = TRUE
              AND d.STATUS = 'ACTIVE'
              AND d.IS_HIDDEN = FALSE
            ORDER BY so.OBJECT_NAME, oc.ORDINAL_POSITION
        ]], {model_name = model_name}) or {}) do
            local current_object_name = row_value(row, "OBJECT_NAME", 1)
            local name = row_value(row, "DIMENSION_NAME", 2)
            add_export("DIMENSION", model_name .. "." .. current_object_name .. "." .. name, canonical_dimension_sql(model_name, current_object_name, row))
        end
        for _, row in ipairs(query([[
            SELECT OBJECT_NAME, METRIC_NAME
            FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
            WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
              AND STATUS = 'ACTIVE'
              AND IS_PRIVATE = FALSE
              AND EXISTS (
                SELECT 1
                FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
                WHERE af.FIELD_KIND = 'METRIC'
                  AND af.MODEL_NAME = mo.MODEL_NAME
                  AND af.OBJECT_NAME = mo.OBJECT_NAME
                  AND af.FIELD_ID = mo.METRIC_ID
              )
            ORDER BY OBJECT_NAME, METRIC_NAME
        ]], {model_name = model_name}) or {}) do
            local current_object_name = row_value(row, "OBJECT_NAME", 1)
            local name = row_value(row, "METRIC_NAME", 2)
            add_export("METRIC", model_name .. "." .. current_object_name .. "." .. name, canonical_metric_sql(model_name, current_object_name, name))
        end
        return rows
    end
    for _, row in ipairs(query([[
        SELECT d.DIMENSION_NAME, e.ENTITY_NAME, d.EXPRESSION, d.DATA_TYPE,
               d.DISPLAY_NAME, d.DESCRIPTION, d.FORMAT_HINT, d.IS_CERTIFIED
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = oc.OBJECT_REF_ID
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = d.ENTITY_ID
        JOIN SYS_SEMANTIC.MODELS m
          ON m.MODEL_ID = so.MODEL_ID
         AND m.ACTIVE_VERSION_ID = so.VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
          AND UPPER(so.OBJECT_NAME) = UPPER(:object_name)
          AND oc.COLUMN_KIND = 'DIMENSION'
          AND oc.IS_VISIBLE = TRUE
          AND d.STATUS = 'ACTIVE'
          AND d.IS_HIDDEN = FALSE
        ORDER BY oc.ORDINAL_POSITION
    ]], {model_name = model_name, object_name = object_name}) or {}) do
        local name = row_value(row, "DIMENSION_NAME", 1)
        add_export("DIMENSION", model_name .. "." .. object_name .. "." .. name, canonical_dimension_sql(model_name, object_name, row))
    end
    for _, row in ipairs(query([[
        SELECT METRIC_NAME
        FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
          AND IS_PRIVATE = FALSE
          AND EXISTS (
            SELECT 1
            FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
            WHERE af.FIELD_KIND = 'METRIC'
              AND af.MODEL_NAME = mo.MODEL_NAME
              AND af.OBJECT_NAME = mo.OBJECT_NAME
              AND af.FIELD_ID = mo.METRIC_ID
          )
        ORDER BY METRIC_NAME
    ]], {model_name = model_name, object_name = object_name}) or {}) do
        local name = row_value(row, "METRIC_NAME", 1)
        add_export("METRIC", model_name .. "." .. object_name .. "." .. name, canonical_metric_sql(model_name, object_name, name))
    end
    return rows
end

local function parse_show_metrics(sql_text)
    local certified = string.match(upper(sql_text), "^%s*SHOW%s+CERTIFIED%s+SEMANTIC%s+METRICS")
    local private = string.match(upper(sql_text), "^%s*SHOW%s+PRIVATE%s+SEMANTIC%s+METRICS")
    local ref = string.match(sql_text, "[Ii][Nn]%s+([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name = string.match(ref, "^([^.]+)%.([^.]+)$")
    local like_value = string.match(sql_text, "[Ll][Ii][Kk][Ee]%s+'([^']*)'")
    local where_parts = {
        "UPPER(mo.MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ")",
        "UPPER(mo.OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ")",
        "mo.STATUS = 'ACTIVE'",
        [[EXISTS (
    SELECT 1
    FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
    WHERE af.FIELD_KIND = 'METRIC'
      AND af.MODEL_NAME = mo.MODEL_NAME
      AND af.OBJECT_NAME = mo.OBJECT_NAME
      AND af.FIELD_ID = mo.METRIC_ID
  )]],
    }
    if certified then
        where_parts[#where_parts + 1] = "mo.IS_CERTIFIED = TRUE"
    end
    if private then
        where_parts[#where_parts + 1] = "mo.IS_PRIVATE = TRUE"
    else
        where_parts[#where_parts + 1] = "mo.IS_PRIVATE = FALSE"
    end
    if like_value ~= nil then
        where_parts[#where_parts + 1] = "(UPPER(mo.METRIC_NAME) LIKE UPPER(" .. sql_string("%" .. like_value .. "%") .. ") OR UPPER(mo.DISPLAY_NAME) LIKE UPPER(" .. sql_string("%" .. like_value .. "%") .. "))"
    end
    return [[
SELECT mo.METRIC_NAME, mo.DISPLAY_NAME, mo.METRIC_KIND, mo.BASE_ENTITY_NAME, mo.FORMAT_HINT,
       mo.IS_CERTIFIED, mo.IS_PRIVATE, mo.OWNER_ROLE, mo.DESCRIPTION, mo.SYNONYMS
FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
WHERE ]] .. table.concat(where_parts, "\n  AND ") .. "\nORDER BY METRIC_NAME"
end

local function parse_metric_ref_from_command(sql_text)
    local ref = string.match(sql_text, "([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name, metric_name = string.match(ref, "^([^.]+)%.([^.]+)%.([^.]+)$")
    return model_name, object_name, metric_name
end

local function parse_object_ref_from_command(sql_text)
    local ref = string.match(sql_text, "([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name = string.match(ref, "^([^.]+)%.([^.]+)$")
    return model_name, object_name
end

local function parse_model_ref_from_command(sql_text)
    return string.match(sql_text, "[Mm][Oo][Dd][Ee][Ll]%s+([A-Za-z_][A-Za-z0-9_]*)")
end

function M.preprocess_sql(sql_text)
    local text = tostring(sql_text or "")
    local u = upper(trim(text))
    if string.match(u, "^ALTER%s+SEMANTIC%s+VIEW") then
        local ok, parse_result = pcall(function()
            return parse_definition(text)
        end)
        if not ok then
            local message = tostring(parse_result)
            return {
                status = "ERROR",
                error_code = string.match(message, "(SEMANTIC_DDL_%d+)") or "SEMANTIC_DDL_999",
                error_message = message,
            }
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(" .. sql_string(text) .. ", FALSE)"}
    elseif string.match(u, "^SHOW%s+SEMANTIC%s+VIEW%s+") then
        local model_name, object_name = parse_object_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_067", error_message = "SHOW SEMANTIC VIEW requires model.object."}
        end
        return {status = "OK", generated_sql = "SELECT FIELD_KIND, FIELD_NAME, SQL_COLUMN_NAME, DATA_TYPE, DISPLAY_NAME, DESCRIPTION, IS_CERTIFIED, AGENT_READINESS FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE UPPER(MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ") AND UPPER(OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ") ORDER BY FIELD_KIND, ORDINAL_POSITION, FIELD_NAME"}
    elseif string.match(u, "^SHOW%s+SEMANTIC%s+VIEWS") then
        return {status = "OK", generated_sql = "SELECT MODEL_NAME, OBJECT_NAME, ROOT_ENTITY_NAME, DESCRIPTION, STATUS FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS WHERE STATUS = 'ACTIVE' ORDER BY MODEL_NAME, OBJECT_NAME"}
    elseif string.match(u, "^SHOW%s+.*SEMANTIC%s+METRICS") then
        local generated = parse_show_metrics(text)
        if generated == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_060", error_message = "SHOW SEMANTIC METRICS requires IN model.object."}
        end
        return {status = "OK", generated_sql = generated}
    elseif string.match(u, "^SHOW%s+ALL%s+SEMANTIC%s+DIMENSIONS%s+FOR%s+METRIC") or string.match(u, "^SHOW%s+SEMANTIC%s+DIMENSIONS%s+FOR%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_061", error_message = "SHOW SEMANTIC DIMENSIONS FOR METRIC requires model.object.metric."}
        end
        local only_valid = not string.match(u, "^SHOW%s+ALL%s+")
        local valid_filter = only_valid and " AND IS_VALID = TRUE" or ""
        return {status = "OK", generated_sql = "SELECT mcd.DIMENSION_NAME, mcd.DISPLAY_NAME, mcd.ENTITY_NAME, mcd.IS_VALID, mcd.REASON_CODE, mcd.REASON_MESSAGE, mcd.JOIN_PATH_NAME FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS mcd WHERE UPPER(mcd.MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ") AND UPPER(mcd.OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ") AND UPPER(mcd.METRIC_NAME) = UPPER(" .. sql_string(metric_name) .. ")" .. valid_filter .. " AND EXISTS (SELECT 1 FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af WHERE af.FIELD_KIND = 'METRIC' AND af.MODEL_NAME = mcd.MODEL_NAME AND af.OBJECT_NAME = mcd.OBJECT_NAME AND af.FIELD_ID = mcd.METRIC_ID) AND EXISTS (SELECT 1 FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT df WHERE df.FIELD_KIND = 'DIMENSION' AND df.MODEL_NAME = mcd.MODEL_NAME AND df.OBJECT_NAME = mcd.OBJECT_NAME AND df.FIELD_ID = mcd.DIMENSION_ID) ORDER BY mcd.IS_VALID DESC, mcd.DIMENSION_NAME"}
    elseif string.match(u, "^DESCRIBE%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_062", error_message = "DESCRIBE SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPLAIN%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_063", error_message = "EXPLAIN SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_SEMANTIC_METRIC(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_064", error_message = "EXPORT SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+VIEW") then
        local model_name, object_name = parse_object_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_065", error_message = "EXPORT SEMANTIC VIEW requires model.object."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", NULL)"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+MODEL") then
        local model_name = parse_model_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_066", error_message = "EXPORT SEMANTIC MODEL requires a model name."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", NULL, NULL)"}
    elseif string.match(u, "^EXPLAIN%s+SEMANTIC%s+QUERY") then
        local query_text = trim(string.sub(text, string.find(u, "QUERY") + 5))
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG(" .. sql_string(query_text) .. ", 'EXPLAIN_SEMANTIC_QUERY')"}
    end
    return {status = "UNCHANGED", generated_sql = sql_text}
end

apply_semantic_definition = M.apply_semantic_definition
apply_normalized_osi_import = M.apply_normalized_osi_import
describe_semantic_metric = M.describe_semantic_metric
explain_semantic_metric = M.explain_semantic_metric
export_semantic_definition = M.export_semantic_definition
preprocess_sql = M.preprocess_sql
