-- Canonical relationship graph and path-proof implementation shared by the
-- validator and compiler runtimes. The packaging step embeds this source into
-- both Exasol scripts so the installed runtime has no external dependency.

local M = {}

local function key(value)
    return tostring(value)
end

local function upper(value)
    return string.upper(tostring(value or ""))
end

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function copy_list(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    return out
end

local function edge_order(left, right)
    local left_priority = tonumber(left.path_priority) or 100
    local right_priority = tonumber(right.path_priority) or 100
    if left_priority ~= right_priority then
        return left_priority < right_priority
    end
    local left_id = tonumber(left.relationship and left.relationship.id) or math.huge
    local right_id = tonumber(right.relationship and right.relationship.id) or math.huge
    if left_id ~= right_id then
        return left_id < right_id
    end
    if tostring(left.name) ~= tostring(right.name) then
        return tostring(left.name) < tostring(right.name)
    end
    return key(left.to_id) < key(right.to_id)
end

local function add_edge(target, from_id, to_id, relationship, safe, reason)
    local from_key = key(from_id)
    target[from_key] = target[from_key] or {}
    target[from_key][#target[from_key] + 1] = {
        from_id = from_id,
        to_id = to_id,
        name = relationship.name,
        relationship = relationship,
        safe = safe,
        reason = reason,
        path_priority = relationship.path_priority,
    }
end

-- Build both the cardinality-preserving graph and the complete relationship
-- graph. A declared fanout policy remains compatible with the legacy planner.
-- Phase C can pass allow_many_to_many=false for the stricter multi-fact proof.
function M.build_edges(relationships, options)
    options = options or {}
    local allow_many_to_many = options.allow_many_to_many
    if allow_many_to_many == nil then
        allow_many_to_many = true
    end
    local safe_edges = {}
    local all_edges = {}

    for _, relationship in ipairs(relationships or {}) do
        local cardinality = upper(relationship.cardinality)
        local function add(from_id, to_id, safe, reason)
            add_edge(all_edges, from_id, to_id, relationship, safe, reason)
            if safe then
                add_edge(safe_edges, from_id, to_id, relationship, true, "OK")
            end
        end

        if cardinality == "ONE_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
        elseif cardinality == "MANY_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "ONE_TO_MANY" then
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
            add(relationship.from_entity_id, relationship.to_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "MANY_TO_MANY" then
            local safe = allow_many_to_many and not missing(relationship.fanout_policy)
            local reason = safe and "OK" or "MANY_TO_MANY_REQUIRES_FANOUT"
            add(relationship.from_entity_id, relationship.to_entity_id, safe, reason)
            add(relationship.to_entity_id, relationship.from_entity_id, safe, reason)
        end
    end

    for _, edge_map in ipairs({safe_edges, all_edges}) do
        for _, edges in pairs(edge_map) do
            table.sort(edges, edge_order)
        end
    end
    return safe_edges, all_edges
end

local function path_signature(path)
    local parts = {}
    for _, edge in ipairs(path) do
        parts[#parts + 1] = tostring(edge.name) .. ":" .. key(edge.to_id)
    end
    return table.concat(parts, ">")
end

local function path_text(path)
    local names = {}
    for _, edge in ipairs(path or {}) do
        names[#names + 1] = edge.name
    end
    return #names == 0 and "SELF" or table.concat(names, " > ")
end

-- Return a proof object instead of only a path. All shortest safe paths are
-- retained so semantic ambiguity cannot be hidden by relationship ordering or
-- PATH_PRIORITY.
function M.prove_path(edge_map, from_id, to_id, options)
    options = options or {}
    if missing(from_id) or missing(to_id) then
        return {ok = false, reason = "MISSING_ENTITY", candidates = {}}
    end
    if key(from_id) == key(to_id) then
        return {
            ok = true,
            reason = "OK",
            edges = {},
            path = "SELF",
            candidates = {{}},
            ambiguous = false,
        }
    end

    local queue = {{id = from_id, path = {}, visited = {[key(from_id)] = true}}}
    local best_depth_by_node = {[key(from_id)] = 0}
    local candidates = {}
    local candidate_seen = {}
    local shortest = nil
    local first_blocked_reason = nil
    local index = 1

    local max_depth = tonumber(options.max_depth) or 64
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        local depth = #current.path
        if depth < max_depth
            and (shortest == nil or depth < shortest or options.reject_any_ambiguity) then
            for _, edge in ipairs(edge_map[key(current.id)] or {}) do
                if options.require_safe and not edge.safe then
                    first_blocked_reason = first_blocked_reason or edge.reason
                else
                    local next_key = key(edge.to_id)
                    if not current.visited[next_key] then
                        local next_path = copy_list(current.path)
                        next_path[#next_path + 1] = edge
                        local next_depth = #next_path
                        if next_key == key(to_id) then
                            shortest = shortest or next_depth
                            if next_depth == shortest or options.reject_any_ambiguity then
                                local signature = path_signature(next_path)
                                if not candidate_seen[signature] then
                                    candidate_seen[signature] = true
                                    candidates[#candidates + 1] = next_path
                                end
                            end
                        elseif (shortest == nil or options.reject_any_ambiguity)
                            and (options.reject_any_ambiguity
                                or best_depth_by_node[next_key] == nil
                                or next_depth <= best_depth_by_node[next_key]) then
                            best_depth_by_node[next_key] = next_depth
                            local visited = {}
                            for entity_key, seen in pairs(current.visited) do
                                visited[entity_key] = seen
                            end
                            visited[next_key] = true
                            queue[#queue + 1] = {
                                id = edge.to_id,
                                path = next_path,
                                visited = visited,
                            }
                        end
                    end
                end
            end
        end
    end

    if #candidates == 0 then
        return {
            ok = false,
            reason = first_blocked_reason or "NO_RELATIONSHIP_PATH",
            candidates = {},
            ambiguous = false,
        }
    end

    table.sort(candidates, function(left, right)
        if #left ~= #right then return #left < #right end
        return path_signature(left) < path_signature(right)
    end)
    local ambiguous = #candidates > 1
    if ambiguous and options.reject_ambiguous then
        local descriptions = {}
        for _, candidate in ipairs(candidates) do
            descriptions[#descriptions + 1] = path_text(candidate)
        end
        return {
            ok = false,
            reason = "AMBIGUOUS_RELATIONSHIP_PATH",
            candidates = candidates,
            candidate_paths = descriptions,
            ambiguous = true,
        }
    end

    return {
        ok = true,
        reason = "OK",
        edges = candidates[1],
        path = path_text(candidates[1]),
        candidates = candidates,
        ambiguous = ambiguous,
    }
end

function M.path_text(path)
    return path_text(path)
end

function M.canonical_key(unique_key)
    local columns = {}
    for _, column in ipairs((unique_key or {}).columns or {}) do
        local column_name = nil
        local expression = nil
        if not missing(column.column_name) then
            column_name = tostring(column.column_name)
        end
        if not missing(column.expression) then
            expression = tostring(column.expression)
        end
        columns[#columns + 1] = {
            ordinal_position = tonumber(column.ordinal_position),
            column_name = column_name,
            expression = expression,
        }
    end
    table.sort(columns, function(left, right)
        return (left.ordinal_position or math.huge) < (right.ordinal_position or math.huge)
    end)
    return {
        id = unique_key and unique_key.id or nil,
        entity_id = unique_key and unique_key.entity_id or nil,
        name = unique_key and unique_key.name or nil,
        kind = upper(unique_key and unique_key.kind or "UNIQUE"),
        columns = columns,
    }
end

function M.mapping_matches_key(mappings, side, unique_key)
    local columns = (unique_key or {}).columns or {}
    if #mappings == 0 or #mappings ~= #columns then
        return false
    end
    for index, mapping in ipairs(mappings) do
        local mapped_column = mapping[side .. "_column_name"]
        local mapped_expression = mapping[side .. "_expression"]
        local key_column = columns[index]
        if not missing(key_column.column_name) then
            if upper(mapped_column) ~= upper(key_column.column_name) then
                return false
            end
        elseif tostring(mapped_expression or "") ~= tostring(key_column.expression or "") then
            return false
        end
    end
    return true
end

ESV_GRAIN_GRAPH = M
