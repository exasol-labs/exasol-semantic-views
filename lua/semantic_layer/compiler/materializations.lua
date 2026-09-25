assert(ESV_ROWS, "shared row runtime is required")
local missing, row_value = ESV_ROWS.missing, ESV_ROWS.row_value

local M = {}

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function field_key(field)
    return tostring(field.kind) .. ":" .. key(field.id)
end

local function add_rejection(rejections, candidate, reason_code, reason_message)
    rejections[#rejections + 1] = {
        materialization_id = candidate.materialization_id,
        materialization_name = candidate.materialization_name,
        reason_code = reason_code,
        reason_message = reason_message,
    }
end

-- What a FRESHNESS_POLICY says, in terms the selector can act on.
--
-- ALWAYS, MANUAL and SNAPSHOT are declarations the selector trusts: the
-- registrant vouches that the object is current, is refreshed by hand, or is a
-- deliberate point-in-time copy. MAX_AGE is the one that is *checked*: the
-- materialization is used only while LAST_REFRESHED_AT -- written by
-- MARK_MATERIALIZATION_REFRESHED, which the refresh job calls -- is younger
-- than the bound. Otherwise the query reads the live sources instead, which is
-- always correct because a materialization is only ever an accelerator.
--
-- Anything else used to be stored verbatim and then rejected on every compile,
-- so `'dbt run --select gold (hourly)'` registered cleanly and could never be
-- selected (BUG-27). REGISTER_MATERIALIZATION calls this and refuses it.
local FRESHNESS_UNITS = {MINUTE = 60, MINUTES = 60, HOUR = 3600, HOURS = 3600,
    DAY = 86400, DAYS = 86400}

function M.freshness_policy(policy)
    if missing(policy) then
        return {kind = "UNDECLARED"}
    end
    local normalized = upper(policy):match("^%s*(.-)%s*$")
    if normalized == "ALWAYS" or normalized == "MANUAL" or normalized == "SNAPSHOT" then
        return {kind = normalized}
    end
    local amount, unit = normalized:match("^MAX_AGE%s+(%d+)%s+(%a+)$")
    if amount ~= nil and FRESHNESS_UNITS[unit] ~= nil and tonumber(amount) > 0 then
        return {kind = "MAX_AGE", seconds = tonumber(amount) * FRESHNESS_UNITS[unit],
            text = "MAX_AGE " .. amount .. " " .. unit}
    end
    return nil, "FRESHNESS_POLICY must be ALWAYS, MANUAL, SNAPSHOT, or"
        .. " MAX_AGE <n> MINUTES|HOURS|DAYS, not: " .. tostring(policy)
end

local function supported_freshness(policy)
    return M.freshness_policy(policy) ~= nil
end

-- Why this candidate cannot be used on freshness grounds, or nil.
local function freshness_rejection(candidate)
    local policy = M.freshness_policy(candidate.freshness_policy)
    if policy == nil then
        return "UNSUPPORTED_FRESHNESS_POLICY",
            "Freshness policy is not supported by the deterministic selector."
    end
    if policy.kind ~= "MAX_AGE" then
        return nil
    end
    local age = tonumber(candidate.age_seconds)
    if age == nil then
        return "NEVER_REFRESHED", "Policy " .. policy.text .. " needs LAST_REFRESHED_AT,"
            .. " and no refresh has been recorded; the refresh job records one with"
            .. " MARK_MATERIALIZATION_REFRESHED."
    end
    if age > policy.seconds then
        return "STALE", "Last refreshed " .. tostring(math.floor(age)) .. " s ago, beyond "
            .. policy.text .. " (" .. tostring(policy.seconds) .. " s); the live sources"
            .. " answer instead."
    end
    return nil
end

-- Freshness facts the plan records for the materialization it used.
local function freshness_provenance(candidate)
    local policy = M.freshness_policy(candidate.freshness_policy) or {}
    return {
        freshness_policy = missing(candidate.freshness_policy) and null
            or tostring(candidate.freshness_policy),
        last_refreshed_at = missing(candidate.last_refreshed_at) and null
            or tostring(candidate.last_refreshed_at),
        age_seconds = tonumber(candidate.age_seconds) or null,
        refreshed_row_count = tonumber(candidate.refreshed_row_count) or null,
        source_snapshot = missing(candidate.source_snapshot) and null
            or tostring(candidate.source_snapshot),
        -- A compile that chose it must not outlive the bound in the cache.
        time_bounded = policy.kind == "MAX_AGE",
    }
end

local function allowed_rollup_policy(policy)
    if missing(policy) then
        return true
    end
    local normalized = upper(policy)
    return normalized == "DIRECT"
        or normalized == "NONE"
        or normalized == "SUM"
        or normalized == "MIN"
        or normalized == "MAX"
        or normalized == "COUNT"
end

local function load_candidates(ctx)
    local rows = query([[
        SELECT MATERIALIZATION_ID, MATERIALIZATION_NAME, PHYSICAL_SCHEMA,
               PHYSICAL_OBJECT, MATERIALIZATION_TYPE, FRESHNESS_POLICY, STATUS,
               LAST_REFRESHED_AT,
               SECONDS_BETWEEN(CURRENT_TIMESTAMP, LAST_REFRESHED_AT) AS AGE_SECONDS,
               REFRESHED_ROW_COUNT, SOURCE_SNAPSHOT
        FROM SEMANTIC_SOURCE.MATERIALIZATIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
        ORDER BY MATERIALIZATION_ID
    ]], {
        model_id = ctx.model.model_id,
        version_id = ctx.model.version_id,
    })

    local candidates = {}
    local by_id = {}
    local ids = {}
    for _, row in ipairs(rows or {}) do
        local candidate = {
            materialization_id = row_value(row, "MATERIALIZATION_ID", 1),
            materialization_name = row_value(row, "MATERIALIZATION_NAME", 2),
            physical_schema = row_value(row, "PHYSICAL_SCHEMA", 3),
            physical_object = row_value(row, "PHYSICAL_OBJECT", 4),
            materialization_type = row_value(row, "MATERIALIZATION_TYPE", 5),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 6),
            status = row_value(row, "STATUS", 7),
            last_refreshed_at = row_value(row, "LAST_REFRESHED_AT", 8),
            age_seconds = row_value(row, "AGE_SECONDS", 9),
            refreshed_row_count = row_value(row, "REFRESHED_ROW_COUNT", 10),
            source_snapshot = row_value(row, "SOURCE_SNAPSHOT", 11),
            columns = {},
            dimension_keys = {},
            metric_keys = {},
        }
        candidates[#candidates + 1] = candidate
        by_id[key(candidate.materialization_id)] = candidate
        ids[#ids + 1] = candidate.materialization_id
    end

    if #ids == 0 then
        return candidates
    end

    local column_rows = query([[
        SELECT MATERIALIZATION_ID, OBJECT_TYPE, OBJECT_ID, PHYSICAL_COLUMN, ROLLUP_POLICY
        FROM SEMANTIC_SOURCE.MATERIALIZATION_COLUMNS
        WHERE MATERIALIZATION_ID IN (
          SELECT MATERIALIZATION_ID
          FROM SEMANTIC_SOURCE.MATERIALIZATIONS
          WHERE MODEL_ID = :model_id
            AND VERSION_ID = :version_id
        )
        ORDER BY MATERIALIZATION_ID, OBJECT_TYPE, OBJECT_ID
    ]], {
        model_id = ctx.model.model_id,
        version_id = ctx.model.version_id,
    })

    for _, row in ipairs(column_rows or {}) do
        local materialization_id = row_value(row, "MATERIALIZATION_ID", 1)
        local candidate = by_id[key(materialization_id)]
        if candidate ~= nil then
            local object_type = upper(row_value(row, "OBJECT_TYPE", 2))
            local object_id = row_value(row, "OBJECT_ID", 3)
            local col_key = object_type .. ":" .. key(object_id)
            local column = {
                object_type = object_type,
                object_id = object_id,
                physical_column = row_value(row, "PHYSICAL_COLUMN", 4),
                rollup_policy = row_value(row, "ROLLUP_POLICY", 5),
            }
            candidate.columns[col_key] = column
            if object_type == "DIMENSION" then
                candidate.dimension_keys[col_key] = true
            elseif object_type == "METRIC" then
                candidate.metric_keys[col_key] = true
            end
        end
    end

    return candidates
end

local function count_extra_dimensions(candidate, selected_dimension_keys)
    local count = 0
    for dimension_key, _ in pairs(candidate.dimension_keys) do
        if not selected_dimension_keys[dimension_key] then
            count = count + 1
        end
    end
    return count
end

local function sorted_states_for_branch(physical_plan, branch)
    local result = {}
    for _, state in ipairs(physical_plan.states or {}) do
        if key(state.leaf_entity_id) == key(branch.leaf_entity_id) then
            result[#result + 1] = state
        end
    end
    table.sort(result, function(left, right)
        return key(left.state_id) < key(right.state_id)
    end)
    return result
end

local function required_branch_dimensions(physical_plan)
    local result = {}
    for _, dimension in ipairs(physical_plan.dimensions or {}) do
        result["DIMENSION:" .. key(dimension.dimension_id)] = true
    end
    for _, predicate in ipairs(physical_plan.global_filters or {}) do
        result["DIMENSION:" .. key(predicate.dimension_id)] = true
    end
    return result
end

local function branch_candidate(candidate, physical_plan, branch,
    required_dimensions, states)
    if upper(candidate.status) ~= "ACTIVE" then
        return nil, "INACTIVE", "Materialization status is not ACTIVE."
    end
    if upper(candidate.materialization_type) ~= "AGGREGATE" then
        return nil, "UNSUPPORTED_TYPE",
            "Only AGGREGATE materializations can provide branch states."
    end
    local stale_code, stale_message = freshness_rejection(candidate)
    if stale_code ~= nil then
        return nil, stale_code, stale_message
    end
    local dimension_columns = {}
    local dimension_keys = {}
    for dimension_key, _ in pairs(required_dimensions) do
        dimension_keys[#dimension_keys + 1] = dimension_key
    end
    table.sort(dimension_keys)
    for _, dimension_key in ipairs(dimension_keys) do
        local column = candidate.columns[dimension_key]
        if column == nil then
            return nil, "MISSING_DIMENSION",
                "A selected or globally filtered dimension is not present."
        end
        dimension_columns[dimension_key] = column
    end

    local state_columns = {}
    for _, state in ipairs(states) do
        if not missing(state.filter_expression) then
            return nil, "FILTERED_STATE_UNSUPPORTED",
                "Metric-local filters do not yet have a materialized-state identity contract."
        end
        if upper(state.merge_operator) ~= "SUM" then
            return nil, "STATE_MERGE_UNSUPPORTED",
                "The materialized state requires an unsupported merge operator."
        end
        local column = candidate.columns["METRIC:" .. key(state.metric_id)]
        if column == nil then
            return nil, "MISSING_STATE",
                "A complete aggregate-state producer metric is not present."
        end
        local policy = missing(column.rollup_policy)
            and "DIRECT" or upper(column.rollup_policy)
        if policy ~= upper(state.merge_operator) then
            return nil, "ROLLUP_POLICY_UNSAFE",
                "The state column rollup policy does not match its merge operator."
        end
        state_columns[key(state.state_id)] = column
    end

    return {
        candidate = candidate,
        dimension_columns = dimension_columns,
        state_columns = state_columns,
        extra_dimension_count = count_extra_dimensions(candidate,
            required_dimensions),
    }
end

local function materialization_column(candidate, field)
    return candidate.columns[field_key(field)]
end

function M.select_materialization(ctx, selected_dimensions, selected_metrics, filter_dimensions)
    local diagnostics = {
        candidate_count = 0,
        rejected_materializations = {},
    }

    local candidates = load_candidates(ctx)
    diagnostics.candidate_count = #candidates
    if #candidates == 0 then
        diagnostics.selected_materialization = null
        return nil, diagnostics
    end

    local selected_dimension_keys = {}
    local required_dimension_keys = {}
    for _, dimension in ipairs(selected_dimensions or {}) do
        selected_dimension_keys[field_key(dimension)] = true
        required_dimension_keys[field_key(dimension)] = true
    end
    for _, dimension in ipairs(filter_dimensions or {}) do
        required_dimension_keys[field_key(dimension)] = true
    end

    local eligible = {}
    for _, candidate in ipairs(candidates) do
        local rejected = false
        local function reject(reason_code, reason_message)
            if not rejected then
                add_rejection(diagnostics.rejected_materializations, candidate, reason_code, reason_message)
                rejected = true
            end
        end

        if upper(candidate.status) ~= "ACTIVE" then
            reject("INACTIVE", "Materialization status is not ACTIVE.")
        elseif upper(candidate.materialization_type) ~= "AGGREGATE" then
            reject("UNSUPPORTED_TYPE", "Only AGGREGATE materializations are supported in this milestone.")
        elseif freshness_rejection(candidate) ~= nil then
            reject(freshness_rejection(candidate))
        else
            for dimension_key, _ in pairs(required_dimension_keys) do
                if candidate.columns[dimension_key] == nil then
                    reject("MISSING_DIMENSION", "A selected or filtered dimension is not present.")
                    break
                end
            end
        end

        if not rejected then
            local extra_dimension_count = count_extra_dimensions(candidate, selected_dimension_keys)
            local needs_rollup = extra_dimension_count > 0
            local metric_rollup_policies = {}
            for _, metric in ipairs(selected_metrics or {}) do
                local column = materialization_column(candidate, metric)
                if column == nil then
                    reject("MISSING_METRIC", "A selected metric is not present.")
                    break
                end
                if not allowed_rollup_policy(column.rollup_policy) then
                    reject("UNSUPPORTED_ROLLUP_POLICY", "Metric rollup policy is not supported.")
                    break
                end
                local policy = missing(column.rollup_policy) and "DIRECT" or upper(column.rollup_policy)
                metric_rollup_policies[field_key(metric)] = policy
                if needs_rollup then
                    if policy ~= "SUM" then
                        reject("ROLLUP_POLICY_UNSAFE", "Metric rollup requires an explicit SUM policy.")
                        break
                    end
                    if upper(metric.metric_type) ~= "ADDITIVE" then
                        reject("NON_ADDITIVE_ROLLUP", "Only ADDITIVE metrics can be rolled up from aggregate materializations.")
                        break
                    end
                end
            end
            if not rejected then
                candidate.extra_dimension_count = extra_dimension_count
                candidate.rollup_required = needs_rollup
                candidate.metric_rollup_policies = metric_rollup_policies
                eligible[#eligible + 1] = candidate
            end
        end
    end

    if #eligible == 0 then
        diagnostics.selected_materialization = null
        return nil, diagnostics
    end

    table.sort(eligible, function(left, right)
        if left.extra_dimension_count ~= right.extra_dimension_count then
            return left.extra_dimension_count < right.extra_dimension_count
        end
        return tonumber(left.materialization_id) < tonumber(right.materialization_id)
    end)

    local selected = eligible[1]
    diagnostics.selected_materialization = selected.materialization_name
    diagnostics.selected_materialization_id = selected.materialization_id
    diagnostics.rollup_required = selected.rollup_required
    diagnostics.freshness = freshness_provenance(selected)
    return selected, diagnostics
end

-- Select one complete aggregate-state source for each physical leaf. A
-- rejected or partial candidate never changes the already proven base branch.
function M.select_branch_sources(ctx, physical_plan)
    local candidates = load_candidates(ctx)
    local required_dimensions = required_branch_dimensions(physical_plan)
    local selections = {}
    local diagnostics = {
        candidate_count = #candidates,
        rejected_materializations = {},
        selected_materialization = null,
        selected_materializations = {},
        branches = {},
    }

    for _, branch in ipairs(physical_plan.branches or {}) do
        local branch_diagnostic = {
            branch_id = branch.branch_id,
            leaf_entity_id = branch.leaf_entity_id,
            candidate_count = #candidates,
            rejected_materializations = {},
            selected_materialization = null,
            fallback_reason = "NO_ELIGIBLE_MATERIALIZATION",
        }
        local eligible = {}
        local states = sorted_states_for_branch(physical_plan, branch)
        local partition_branch = upper(branch.source and branch.source.source_kind)
            == "REPRESENTATION_PARTITION"
        for _, candidate in ipairs(partition_branch and {} or candidates) do
            local selection, reason_code, reason_message = branch_candidate(
                candidate, physical_plan, branch, required_dimensions, states)
            if selection == nil then
                local rejection = {
                    branch_id = branch.branch_id,
                    materialization_id = candidate.materialization_id,
                    materialization_name = candidate.materialization_name,
                    reason_code = reason_code,
                    reason_message = reason_message,
                }
                branch_diagnostic.rejected_materializations[
                    #branch_diagnostic.rejected_materializations + 1] = rejection
                diagnostics.rejected_materializations[
                    #diagnostics.rejected_materializations + 1] = rejection
            else
                eligible[#eligible + 1] = selection
            end
        end
        if partition_branch then
            branch_diagnostic.candidate_count = 0
            branch_diagnostic.fallback_reason = "FUSION_PARTITION_MATERIALIZATION_UNSUPPORTED"
        end
        table.sort(eligible, function(left, right)
            if left.extra_dimension_count ~= right.extra_dimension_count then
                return left.extra_dimension_count < right.extra_dimension_count
            end
            return tonumber(left.candidate.materialization_id)
                < tonumber(right.candidate.materialization_id)
        end)
        if #eligible > 0 then
            local selected = eligible[1]
            selections[key(branch.branch_id)] = selected
            branch_diagnostic.selected_materialization =
                selected.candidate.materialization_name
            branch_diagnostic.selected_materialization_id =
                selected.candidate.materialization_id
            branch_diagnostic.extra_dimension_count =
                selected.extra_dimension_count
            branch_diagnostic.freshness = freshness_provenance(selected.candidate)
            branch_diagnostic.fallback_reason = null
            diagnostics.selected_materializations[
                #diagnostics.selected_materializations + 1] = {
                branch_id = branch.branch_id,
                leaf_entity_id = branch.leaf_entity_id,
                materialization_id = selected.candidate.materialization_id,
                materialization_name = selected.candidate.materialization_name,
                extra_dimension_count = selected.extra_dimension_count,
                freshness = branch_diagnostic.freshness,
            }
        end
        diagnostics.branches[#diagnostics.branches + 1] = branch_diagnostic
    end
    return selections, diagnostics
end

select_materialization = M.select_materialization
select_branch_sources = M.select_branch_sources
-- For REGISTER_MATERIALIZATION, which imports this runtime so the vocabulary it
-- accepts is exactly the one the selector acts on.
freshness_policy = M.freshness_policy

if rawget(_G, "ESV_TEST_MODE") then
    ESV_MATERIALIZATION_TEST_API = {
        select_materialization = M.select_materialization,
        select_branch_sources = M.select_branch_sources,
        supported_freshness = supported_freshness,
        freshness_policy = M.freshness_policy,
        freshness_rejection = freshness_rejection,
        allowed_rollup_policy = allowed_rollup_policy,
    }
end
