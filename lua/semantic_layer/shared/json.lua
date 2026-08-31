-- One JSON implementation for the whole runtime.
--
-- There were four. `compiler/request_json.lua` and `admin/semantic_definition.lua`
-- carried a byte-identical 179-line block (encoder, decoder, `is_array`, escape);
-- `agent/runtime.lua` carried a third copy of the encoder half; and
-- `admin/validator.lua` carried a fourth parser of its own for well-formedness
-- checks. `admin/fusion_declaration.lua` avoided becoming a fifth only by taking
-- a dependency on the 4 600-line DDL parser to reach an encoder.
--
-- The copies had already drifted, and the drift was invisible because nothing
-- compared them. `compiler/query_spec.lua`'s `is_array` omitted the `JSON_NULL`
-- guard the other three had -- it had no sentinel in scope to compare against --
-- so `{"metrics": null}` reached the planner as an empty list on one code path
-- and as a refusal on another. `admin/fusion_declaration.lua` borrowed a decoder
-- whose sentinel its own `missing()` did not recognise, so a JSON `null` in a
-- declaration read as a *present* value that rendered as "table: 0x...".
--
-- Both defects are the same defect: a sentinel is only meaningful to code that
-- shares its identity, and identity cannot be shared across copies. Hence one
-- module, embedded by tools/package_lua_scripts.py into every runtime script
-- that needs it, the way shared/identity_join.lua already is.
--
-- Two entry points read text, and they are deliberately not the same function:
--
--   M.decode(text)    builds a value; lenient about scalar spelling
--   M.is_valid(text)  answers yes/no; strict RFC 8259 scalar grammar
--
-- The difference is real and load-bearing, so it is one parser with one `strict`
-- flag rather than two files. `M.decode` is applied to payloads this runtime
-- wrote and must keep accepting what it accepted before; `M.is_valid` backs
-- SEMANTIC_MODEL validation of user-supplied extension JSON, where "looks close
-- enough" is the wrong answer. tests/lua/json_unit_test.lua pins each input the
-- two disagree about.

local M = {}

-- The decoded spelling of JSON `null`.
--
-- A sentinel table, not Lua `nil`: in a Lua table an explicit null and an absent
-- key are the same thing, and the difference matters wherever a document's
-- omitted key means "leave alone" and an explicit null means "unset". Callers
-- test identity (`value == json.NULL`), never `type` or `tostring`, so this
-- stays a bare table with no metatable -- giving it a `__tostring` would make
-- the wrong test look like it worked.
M.NULL = {}

function M.is_array(value)
    if type(value) ~= "table" or value == M.NULL then
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

function M.escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
end

-- Object keys are emitted in sorted order, which is what makes an exported
-- document comparable to a re-exported one -- the round-trip contract behind
-- EXPORT_FUSION_DECLARATION and EXPORT_SEMANTIC_DEFINITION.
function M.encode(value)
    local value_type = type(value)
    if value == nil or value == null or value == M.NULL then
        return "null"
    elseif value_type == "string" then
        return '"' .. M.escape(value) .. '"'
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "table" then
        local parts = {}
        if M.is_array(value) then
            for i = 1, #value do
                parts[#parts + 1] = M.encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = M.encode(k) .. ":" .. M.encode(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return M.encode(tostring(value))
end

-- One recursive-descent parser. `strict` selects the scalar grammar:
--
--   strict = false  numbers are scanned loosely and handed to tonumber, a \u
--                   escape is accepted without checking its digits and decodes
--                   to "?", and a raw control character inside a string passes.
--   strict = true   numbers follow RFC 8259 exactly (no leading zero, a
--                   fraction and an exponent must have digits), \u must be four
--                   hex digits, and a byte below 0x20 inside a string is an
--                   error.
--
-- The structure -- whitespace, arrays, objects, keywords, the trailing-input
-- check -- is shared, because that half never differed between the two copies
-- this replaces. Values are built in both modes; is_valid discards them, which
-- costs less than a second traversal would cost to maintain.
local function parse(text, strict)
    if text == nil or text == null or text == M.NULL or tostring(text) == "" then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function is_digit(c)
        return string.match(c, "^%d$") ~= nil
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

    local function read_digits()
        local count = 0
        while is_digit(peek()) do
            count = count + 1
            pos = pos + 1
        end
        return count
    end

    local ESCAPES = {['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
        f = "\f", n = "\n", r = "\r", t = "\t"}

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
                if ESCAPES[e] ~= nil then
                    out[#out + 1] = ESCAPES[e]
                    pos = pos + 2
                elseif e == "u" then
                    if strict then
                        for offset = 2, 5 do
                            local digit = string.sub(text, pos + offset, pos + offset)
                            if string.match(digit, "^[0-9A-Fa-f]$") == nil then
                                error("invalid unicode escape at byte " .. tostring(pos))
                            end
                        end
                    end
                    -- Lossy and long-standing: the runtime stores model metadata
                    -- as ASCII, and a decoder that expanded escapes would have to
                    -- encode them again to keep a round-trip stable.
                    out[#out + 1] = "?"
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            elseif strict and (c == "" or string.byte(c) < 32) then
                error("invalid control character in string at byte " .. tostring(pos))
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
        if peek() == "-" then
            pos = pos + 1
        end
        if strict then
            if peek() == "0" then
                pos = pos + 1
            elseif string.match(peek(), "^[1-9]$") then
                read_digits()
            else
                error("invalid number at byte " .. tostring(start_pos))
            end
        else
            read_digits()
        end
        if peek() == "." then
            pos = pos + 1
            if read_digits() == 0 and strict then
                error("invalid number fraction at byte " .. tostring(pos))
            end
        end
        local c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            if read_digits() == 0 and strict then
                error("invalid number exponent at byte " .. tostring(pos))
            end
        end
        local value = tonumber(string.sub(text, start_pos, pos - 1))
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
        elseif c == "-" or is_digit(c) then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return M.NULL
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

-- Raises on malformed input; the message names the byte offset.
function M.decode(text)
    return parse(text, false)
end

-- Well-formedness only, under the strict scalar grammar. Never raises.
function M.is_valid(text)
    local ok = pcall(parse, text, true)
    return ok
end

ESV_JSON = M
