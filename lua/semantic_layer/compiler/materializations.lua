local M = {}

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
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

local function supported_freshness(policy)
    if missing(policy) then
        return true
    end
    local normalized = upper(policy)
    return normalized == "ALWAYS" or normalized == "MANUAL" or normalized == "SNAPSHOT"
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
               PHYSICAL_OBJECT, MATERIALIZATION_TYPE, FRESHNESS_POLICY, STATUS
        FROM SYS_SEMANTIC.MATERIALIZATIONS
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
        FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS
        WHERE MATERIALIZATION_ID IN (
          SELECT MATERIALIZATION_ID
          FROM SYS_SEMANTIC.MATERIALIZATIONS
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
        elseif not supported_freshness(candidate.freshness_policy) then
            reject("UNSUPPORTED_FRESHNESS_POLICY", "Freshness policy is not supported by the deterministic selector.")
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
    return selected, diagnostics
end

select_materialization = M.select_materialization
