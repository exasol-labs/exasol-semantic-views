-- Canonical request boundary shared by JSON and Semantic SQL lowering.

local M = {VERSION = 1}

local ARRAY_FIELDS = {"metrics", "dimensions", "filters", "having", "order_by"}
local ARRAY_FIELD_SET = {}
for _, name in ipairs(ARRAY_FIELDS) do ARRAY_FIELD_SET[name] = true end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("QuerySpec cannot contain cycles") end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child, seen) end
    seen[value] = nil
    return out
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_name(value)
    if value == nil then return nil end
    local normalized = trim(value)
    if normalized == "" then return nil end
    return normalized
end

local function is_array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    local largest = 0
    for item_key, _ in pairs(value) do
        if type(item_key) ~= "number" or item_key < 1 or item_key % 1 ~= 0 then
            return false
        end
        count = count + 1
        if item_key > largest then largest = item_key end
    end
    return count == largest
end

function M.new(request, source)
    if type(request) ~= "table" then
        return nil, "QUERY_SPEC_INVALID"
    end
    local spec = {
        query_spec_version = M.VERSION,
        source = source or request.source or "JSON",
        model = normalize_name(request.model),
        object = normalize_name(request.object),
        metrics = {},
        dimensions = {},
        filters = {},
        having = {},
        order_by = {},
    }
    for _, name in ipairs(ARRAY_FIELDS) do
        local value = request[name]
        if value ~= nil then
            if not is_array(value) then
                return nil, "QUERY_SPEC_" .. string.upper(name) .. "_NOT_ARRAY"
            end
            spec[name] = copy(value)
        end
    end
    if request.limit ~= nil then spec.limit = request.limit end
    if request.client ~= nil then spec.client = request.client end
    if request.purpose ~= nil then spec.purpose = request.purpose end
    if request.natural_language_text ~= nil then
        spec.natural_language_text = request.natural_language_text
    end
    if request.proof_mode ~= nil then
        spec.proof_mode = string.upper(trim(request.proof_mode))
    else
        spec.proof_mode = "LEGACY_JOIN"
    end
    return spec
end

function M.equivalent(left, right)
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for key, value in pairs(a) do
            if key ~= "source" and not same(value, b[key]) then return false end
        end
        for key, value in pairs(b) do
            if key ~= "source" and a[key] == nil and value ~= nil then return false end
        end
        return true
    end
    return same(left, right)
end

ESV_QUERY_SPEC = M
