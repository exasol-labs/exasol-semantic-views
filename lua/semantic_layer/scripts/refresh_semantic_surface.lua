--- Re-runs PUBLISH_MODEL for a model; returns one row per published view.
-- @script SEMANTIC_ADMIN.REFRESH_SEMANTIC_SURFACE
-- @param MODEL_NAME
-- @returns TABLE

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local rows = query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)
]], {model_name = MODEL_NAME})

local out = {}
for _, row in ipairs(rows or {}) do
    out[#out + 1] = {
        row_value(row, "MODEL_NAME", 1),
        row_value(row, "PUBLISHED_SCHEMA", 2),
        row_value(row, "OBJECT_NAME", 3),
        row_value(row, "COLUMN_COUNT", 4),
        row_value(row, "STATUS", 5),
    }
end

exit(out, [[
  MODEL_NAME VARCHAR(256),
  PUBLISHED_SCHEMA VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  COLUMN_COUNT DECIMAL(18,0),
  STATUS VARCHAR(32)
]])
