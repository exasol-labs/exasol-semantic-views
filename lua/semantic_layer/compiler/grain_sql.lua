-- Decision-free SQL renderer for validated single- and multi-branch plans.

local M = {VERSION = 1}

function M.render_single_branch(plan)
    local sql = {}
    sql[#sql + 1] = "SELECT " .. table.concat(plan.select_parts or {}, ", ")
    sql[#sql + 1] = "FROM " .. tostring(plan.from_sql)
    for _, join_sql in ipairs(plan.join_sql or {}) do sql[#sql + 1] = join_sql end
    if #(plan.where_predicates or {}) > 0 then
        sql[#sql + 1] = "WHERE " .. table.concat(plan.where_predicates, " AND ")
    end
    if #(plan.group_parts or {}) > 0 then
        sql[#sql + 1] = "GROUP BY " .. table.concat(plan.group_parts, ", ")
    end
    if #(plan.having_predicates or {}) > 0 then
        sql[#sql + 1] = "HAVING " .. table.concat(plan.having_predicates, " AND ")
    end
    if #(plan.order_by or {}) > 0 then
        sql[#sql + 1] = "ORDER BY " .. table.concat(plan.order_by, ", ")
    end
    if plan.limit ~= nil then sql[#sql + 1] = "LIMIT " .. tostring(plan.limit) end
    return table.concat(sql, "\n")
end

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local function render_branch(branch)
    local select_parts = {}
    local group_parts = {}
    for _, dimension in ipairs(branch.dimensions or {}) do
        select_parts[#select_parts + 1] = tostring(dimension.expression)
            .. " AS " .. quote_ident(dimension.column_alias)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, state in ipairs(branch.state_columns or {}) do
        select_parts[#select_parts + 1] = tostring(state.expression)
            .. " AS " .. quote_ident(state.column_alias)
    end
    local sql = {
        quote_ident(branch.cte_alias) .. " AS (",
        "  SELECT " .. table.concat(select_parts, ", "),
        "  FROM " .. tostring(branch.from_sql),
    }
    for _, join in ipairs(branch.joins or {}) do
        sql[#sql + 1] = "  " .. tostring(join.join_type) .. " JOIN "
            .. tostring(join.target_sql) .. " ON " .. tostring(join.condition)
    end
    local predicates = {}
    for _, predicate in ipairs(branch.where_predicates or {}) do
        predicates[#predicates + 1] = tostring(predicate.expression)
    end
    if #predicates > 0 then
        sql[#sql + 1] = "  WHERE " .. table.concat(predicates, " AND ")
    end
    if #group_parts > 0 then
        sql[#sql + 1] = "  GROUP BY " .. table.concat(group_parts, ", ")
    end
    sql[#sql + 1] = ")"
    return table.concat(sql, "\n")
end

function M.render_multi_branch(plan)
    local ctes = {}
    for _, branch in ipairs(plan.branches or {}) do
        ctes[#ctes + 1] = render_branch(branch)
    end

    local union_columns = {}
    for _, dimension in ipairs(plan.dimensions or {}) do
        union_columns[#union_columns + 1] = quote_ident(dimension.column_alias)
    end
    for _, state in ipairs(plan.states or {}) do
        union_columns[#union_columns + 1] = quote_ident(state.column_alias)
    end
    local union_queries = {}
    for _, branch in ipairs(plan.branches or {}) do
        union_queries[#union_queries + 1] = "  SELECT "
            .. table.concat(union_columns, ", ") .. " FROM "
            .. quote_ident(branch.cte_alias)
    end
    ctes[#ctes + 1] = quote_ident(plan.union.cte_alias) .. " AS (\n"
        .. table.concat(union_queries, "\n  UNION ALL\n") .. "\n)"

    local merge_parts = {}
    local group_parts = {}
    for _, dimension in ipairs(plan.dimensions or {}) do
        local alias = quote_ident(dimension.column_alias)
        merge_parts[#merge_parts + 1] = alias
        group_parts[#group_parts + 1] = alias
    end
    for _, state in ipairs(plan.states or {}) do
        local alias = quote_ident(state.column_alias)
        merge_parts[#merge_parts + 1] = tostring(state.merge_operator)
            .. "(" .. alias .. ") AS " .. alias
    end
    local merge_sql = {
        quote_ident(plan.merge.cte_alias) .. " AS (",
        "  SELECT " .. table.concat(merge_parts, ", "),
        "  FROM " .. quote_ident(plan.union.cte_alias),
    }
    if #group_parts > 0 then
        merge_sql[#merge_sql + 1] = "  GROUP BY " .. table.concat(group_parts, ", ")
    end
    merge_sql[#merge_sql + 1] = ")"
    ctes[#ctes + 1] = table.concat(merge_sql, "\n")

    return "WITH\n" .. table.concat(ctes, ",\n")
        .. "\nSELECT * FROM " .. quote_ident(plan.merge.cte_alias)
end

ESV_GRAIN_SQL = M
