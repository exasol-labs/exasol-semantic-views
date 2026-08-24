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
-- graph. Fanning edges are present in the complete graph for diagnostics but
-- are never safe, and no declaration changes that: traversing one is what
-- attributes one fact row to several dimension rows. FANOUT_POLICY records
-- modeler intent for a many-to-many relationship; it is not an allocation
-- proof. Reason codes therefore name the cardinality that blocks the walk, not
-- a remedy. See
-- plans/architecture-decisions/001-grain-aware-result-semantics.md.
function M.build_edges(relationships)
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
            -- Walking back to the many-side attributes one row to several. No
            -- declaration makes that safe, so the reason must not name one: the
            -- strict lane already reports this direction the same way.
            add(relationship.to_entity_id, relationship.from_entity_id, false,
                "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
        elseif cardinality == "ONE_TO_MANY" then
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
            add(relationship.from_entity_id, relationship.to_entity_id, false,
                "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
        elseif cardinality == "MANY_TO_MANY" then
            add(relationship.from_entity_id, relationship.to_entity_id, false,
                "MANY_TO_MANY_UNSUPPORTED")
            add(relationship.to_entity_id, relationship.from_entity_id, false,
                "MANY_TO_MANY_UNSUPPORTED")
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
    -- Enumerating paths of every length (reject_any_ambiguity) is unbounded in a
    -- densely connected graph. These caps bound that walk, and a walk that hit
    -- one reports truncated = true so no caller can read "there is no
    -- alternative path" out of a search that stopped early.
    local max_candidates = tonumber(options.max_candidates)
    local max_visits = tonumber(options.max_visits)
    local truncated = false
    while index <= #queue do
        if max_visits ~= nil and index > max_visits then
            truncated = true
            break
        end
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
                                    if max_candidates ~= nil
                                        and #candidates >= max_candidates then
                                        truncated = true
                                    else
                                        candidate_seen[signature] = true
                                        candidates[#candidates + 1] = next_path
                                    end
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
            truncated = truncated,
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
            truncated = truncated,
        }
    end

    return {
        ok = true,
        reason = "OK",
        edges = candidates[1],
        path = path_text(candidates[1]),
        candidates = candidates,
        ambiguous = ambiguous,
        truncated = truncated,
    }
end

-- Every distinct safe path between two entities, shortest first, not only the
-- shortest ones.
--
-- prove_path measures ambiguity as "more than one shortest path" and refuses
-- that. An alternative of a different length is invisible to it: the shortest
-- path simply wins. But path length is not a semantic authority — a longer
-- path can attribute a fact row to a different dimension row and so change the
-- number. Callers use this to report the choice instead of making it silently.
-- STRICT_GRAIN refuses any such alternative outright (reject_any_ambiguity).
function M.safe_path_alternatives(edge_map, from_id, to_id, options)
    options = options or {}
    local proof = M.prove_path(edge_map, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = false,
        reject_any_ambiguity = true,
        max_depth = tonumber(options.max_depth) or 64,
        max_candidates = tonumber(options.max_candidates) or 8,
        max_visits = tonumber(options.max_visits) or 50000,
    })
    local paths = {}
    for _, candidate in ipairs(proof.candidates or {}) do
        paths[#paths + 1] = {
            path = path_text(candidate),
            length = #candidate,
        }
    end
    local alternates = {}
    for index = 2, #paths do
        alternates[#alternates + 1] = paths[index]
    end
    return {
        selected = paths[1],
        alternates = alternates,
        paths = paths,
        truncated = proof.truncated == true,
    }
end

function M.path_text(path)
    return path_text(path)
end

-- Render the path a walk would take if unsafe edges were allowed, annotating
-- each unsafe edge with the reason it was rejected. Validator provenance and
-- compiler refusal messages both go through this so a rejected traversal names
-- the same blocking edge in both runtimes.
function M.rejected_path_text(edges)
    local parts = {}
    local first_reason = nil
    for _, edge in ipairs(edges or {}) do
        local name = tostring(edge.name)
        if edge.safe == false then
            local reason = tostring(edge.reason or "UNSAFE_RELATIONSHIP_EDGE")
            first_reason = first_reason or reason
            name = name .. " (rejected: " .. reason .. ")"
        end
        parts[#parts + 1] = name
    end
    if #parts == 0 then
        return nil, first_reason
    end
    return table.concat(parts, " > "), first_reason
end

-- Diagnostic for a failed safe walk: the annotated path over the complete
-- graph, plus the reason of the first edge that made it unsafe.
function M.attempted_path(all_edges, from_id, to_id)
    local proof = M.prove_path(all_edges, from_id, to_id, {
        require_safe = false,
        reject_ambiguous = true,
    })
    if proof.ok then
        return M.rejected_path_text(proof.edges)
    end
    if proof.ambiguous then
        local paths = {}
        for _, candidate in ipairs(proof.candidates or {}) do
            paths[#paths + 1] = M.rejected_path_text(candidate)
        end
        return table.concat(paths, " | "), proof.reason
    end
    return nil, proof.reason
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

local function direct_column_expression(expression, source_alias)
    local text = tostring(expression or ""):match("^%s*(.-)%s*$")
    local alias, column = string.match(text,
        "^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)$")
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return upper(column)
    end
    alias, column = string.match(text,
        '^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*"([^"]+)"$')
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return column
    end
    return nil
end

function M.scalar_mapping_key(unique_keys, mappings, side)
    if #(mappings or {}) ~= 1 then
        return nil, "COMPOSITE_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    local mapping = mappings[1]
    if missing(mapping[side .. "_column_name"])
        or not missing(mapping[side .. "_expression"]) then
        return nil, "EXPRESSION_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    for _, unique_key in ipairs(unique_keys or {}) do
        local columns = unique_key.columns or {}
        if #columns == 1 and not missing(columns[1].column_name)
            and missing(columns[1].expression)
            and M.mapping_matches_key(mappings, side, unique_key) then
            return unique_key, nil
        end
    end
    return nil, "RELATIONSHIP_ENDPOINT_IS_NOT_SCALAR_UNIQUE_KEY"
end

function M.direct_identity_remap(identity, primary_representation,
        target_representation, unique_key)
    if identity == nil or primary_representation == nil
        or target_representation == nil or unique_key == nil then
        return nil, "SEMANTIC_IDENTITY_REMAP_METADATA_MISSING"
    end
    local primary_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(primary_representation.id)] or nil
    local target_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(target_representation.id)] or nil
    if primary_binding == nil or upper(primary_binding.kind) ~= "DIRECT" then
        return nil, "PRIMARY_IDENTITY_BINDING_NOT_DIRECT"
    end
    if target_binding == nil or upper(target_binding.kind) ~= "DIRECT" then
        return nil, "REPRESENTATION_IDENTITY_BINDING_NOT_DIRECT"
    end
    local key_column = unique_key.columns and unique_key.columns[1]
        and unique_key.columns[1].column_name or nil
    local anchor_column = direct_column_expression(primary_binding.expression,
        primary_representation.alias)
    if missing(key_column) or anchor_column == nil
        or upper(anchor_column) ~= upper(key_column) then
        return nil, "SEMANTIC_IDENTITY_NOT_ANCHORED_TO_RELATIONSHIP_KEY"
    end
    return {
        identity = identity,
        unique_key = unique_key,
        primary_binding = primary_binding,
        binding = target_binding,
    }, nil
end

ESV_GRAIN_GRAPH = M
