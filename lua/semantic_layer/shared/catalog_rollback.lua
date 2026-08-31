-- Snapshot and restore a slice of SYS_SEMANTIC, for the two apply paths that
-- have to undo themselves.
--
-- `APPLY_SEMANTIC_DEFINITION` and `APPLY_FUSION_DECLARATION` need the same
-- thing: capture the rows a multi-step change is about to touch, run the steps,
-- validate, and put the rows back if anything refused. They arrived at it in
-- opposite ways.
--
-- admin/fusion_declaration.lua read its column lists from EXA_ALL_COLUMNS -- 45
-- lines, generic over a table list. admin/semantic_definition.lua wrote every
-- column out by hand, four times per table: in the snapshot SELECT, the restore
-- INSERT column list, its VALUES list, and the parameter map, the last carrying
-- ordinals that had to stay in lockstep with the first. 335 lines for eight
-- tables, and nothing checked that the four agreed. All four happened to agree
-- when this was written -- five of METRICS' 29 columns were added after it, and
-- somebody remembered each time. The next one restores as NULL.
--
-- So this is the fusion module's shape, lifted, and the DDL path now uses it.
-- The catalog is the source of truth for what a table's columns are; nothing
-- here restates them.
--
-- Two things the lift fixed rather than moved:
--
--   * `row[name] or row[lower] or row[position]` treats a boolean FALSE as
--     absent and falls through to the ordinal, which is usually nil -- so a
--     restored ATTRIBUTE_BINDINGS.IS_DEFAULT or OBJECT_COLUMNS.IS_VISIBLE could
--     come back NULL instead of FALSE. shared/rows.lua now owns that read for
--     every runtime.
--   * The DDL path cleared METRIC_DEPENDENCIES and METRIC_DIMENSION_MATRIX and
--     never restored them, because they were in the delete list and not the
--     snapshot. Declaring one list per table makes that impossible to express.

assert(ESV_ROWS, "shared row runtime is required")
local row_value = ESV_ROWS.row_value

local M = {}

-- A table's columns, in declaration order, as the catalog reports them.
function M.columns(query_fn, table_name, error_code)
    local declared = query_fn([[
        SELECT COLUMN_NAME
        FROM SYS.EXA_ALL_COLUMNS
        WHERE COLUMN_SCHEMA = 'SYS_SEMANTIC'
          AND COLUMN_TABLE = :table_name
        ORDER BY COLUMN_ORDINAL_POSITION
    ]], {table_name = table_name})
    local names = {}
    for _, row in ipairs(declared or {}) do
        names[#names + 1] = tostring(row_value(row, "COLUMN_NAME", 1))
    end
    if #names == 0 then
        error(tostring(error_code) .. ": cannot read the columns of SYS_SEMANTIC."
            .. tostring(table_name))
    end
    return names
end

-- Capture every row each table contributes, in the order the tables are declared.
--
-- A spec is `{name = "METRICS", where = "..."}`, plus for a table that is scoped
-- through a parent rather than by its own columns:
--
--   alias         the base table's alias, so the projection can qualify columns
--   join          the JOIN that reaches the parent carrying MODEL_ID
--   delete_where  the predicate for DELETE, which cannot see the join
--
-- `params` is bound to every statement, so the same `:model_id` / `:version_id`
-- reaches the scoped and unscoped forms alike.
function M.snapshot(query_fn, tables, params, error_code)
    local snapshot = {}
    for _, spec in ipairs(tables) do
        local columns = M.columns(query_fn, spec.name, error_code)
        local projection = {}
        for _, column in ipairs(columns) do
            projection[#projection + 1] =
                (spec.alias and (spec.alias .. ".") or "") .. column
        end
        snapshot[#snapshot + 1] = {
            name = spec.name,
            columns = columns,
            rows = query_fn("SELECT " .. table.concat(projection, ", ")
                .. " FROM SYS_SEMANTIC." .. spec.name
                .. (spec.alias and (" " .. spec.alias) or "")
                .. (spec.join and (" " .. spec.join) or "")
                .. " WHERE " .. spec.where, params) or {},
        }
    end
    return snapshot
end

-- Put the captured rows back, exactly.
--
-- Deletes run in reverse declaration order and inserts in forward order, so the
-- table list is read as parent-to-child once and both directions follow from it.
function M.restore(query_fn, tables, snapshot, params)
    for index = #tables, 1, -1 do
        local spec = tables[index]
        query_fn("DELETE FROM SYS_SEMANTIC." .. spec.name
            .. " WHERE " .. (spec.delete_where or spec.where), params)
    end
    for _, entry in ipairs(snapshot) do
        for _, row in ipairs(entry.rows) do
            local placeholders, bound = {}, {}
            for position, column in ipairs(entry.columns) do
                local key = "c" .. position
                placeholders[#placeholders + 1] = ":" .. key
                bound[key] = row_value(row, column, position)
            end
            query_fn("INSERT INTO SYS_SEMANTIC." .. entry.name .. " ("
                .. table.concat(entry.columns, ", ") .. ") VALUES ("
                .. table.concat(placeholders, ", ") .. ")", bound)
        end
    end
end

ESV_CATALOG_ROLLBACK = M
