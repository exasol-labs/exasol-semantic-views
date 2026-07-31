-- SQL renderer for the typed single-branch physical plan.

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

ESV_GRAIN_SQL = M
