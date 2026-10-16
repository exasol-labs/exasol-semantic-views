-- Which views compiled from this model no longer match what it would compile.
--
-- This is the exact question, and it needs the compiler to answer, which is why
-- it is a script rather than a VALIDATE_MODEL rule. The cheaper proxies do not
-- work here: ESV creates exactly one model version -- CREATE_MODEL makes version
-- 1 and nothing makes a second -- and MODELS.UPDATED_AT does not move on
-- authoring either, so there is nothing to compare a version against. What does
-- move is the definition, and the only faithful test of that is to compile the
-- same columns again and see whether the SQL comes back the same.
--
-- STATUS is CURRENT, STALE or DROPPED. A STALE view still answers; it answers
-- with the model as it was when the view was made.
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end
local function sql_string(value)
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

if missing(MODEL_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local model_name = trim(MODEL_NAME)

local model_rows = query([[
    SELECT MODEL_ID, PUBLISHED_SCHEMA FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 2)

local frozen = query([[
    SELECT fv.VIEW_SCHEMA, fv.VIEW_NAME, fv.OBJECT_NAME, fv.FROZEN_COLUMNS,
           fv.FROZEN_SQL,
           CASE WHEN v.VIEW_NAME IS NULL THEN 0 ELSE 1 END AS STILL_EXISTS
      FROM SYS_SEMANTIC.FROZEN_VIEWS fv
      LEFT JOIN SYS.EXA_ALL_VIEWS v
        ON UPPER(v.VIEW_SCHEMA) = UPPER(fv.VIEW_SCHEMA)
       AND UPPER(v.VIEW_NAME) = UPPER(fv.VIEW_NAME)
     WHERE fv.MODEL_ID = :model_id
     ORDER BY fv.FROZEN_VIEW_ID
]], {model_id = model_id})

local output_rows = {}
for _, row in ipairs(frozen or {}) do
    local view_schema = tostring(row_value(row, "VIEW_SCHEMA", 1))
    local view_name = tostring(row_value(row, "VIEW_NAME", 2))
    local object_name = row_value(row, "OBJECT_NAME", 3)
    local frozen_columns = tostring(row_value(row, "FROZEN_COLUMNS", 4) or "")
    local frozen_sql = row_value(row, "FROZEN_SQL", 5)
    local still_exists = tonumber(row_value(row, "STILL_EXISTS", 6) or 0) == 1

    if not still_exists then
        output_rows[#output_rows + 1] = {view_schema, view_name, "DROPPED",
            "The view is gone; the record can be deleted."}
    elseif missing(frozen_sql) or frozen_columns == "" then
        -- Frozen by a build that did not record a baseline. Saying so beats
        -- reporting CURRENT, which would be a guess wearing an answer's clothes.
        output_rows[#output_rows + 1] = {view_schema, view_name, "UNKNOWN",
            "No compiled baseline was recorded for this view; re-create it to"
            .. " start tracking it."}
    else
        local parts = {}
        for column in string.gmatch(frozen_columns, "[^,]+") do
            parts[#parts + 1] = quote_ident(column)
        end
        local probe = "SELECT " .. table.concat(parts, ", ") .. " FROM "
            .. quote_ident(published_schema) .. "." .. quote_ident(tostring(object_name))
        local compiled = query("EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL("
            .. sql_string(probe) .. ")")
        local status = row_value(compiled and compiled[1], "STATUS", 1)
        local current_sql = row_value(compiled and compiled[1], "GENERATED_SQL", 5)
        if status ~= "OK" then
            output_rows[#output_rows + 1] = {view_schema, view_name, "STALE",
                "The model no longer compiles the columns this view froze: "
                .. tostring(row_value(compiled and compiled[1], "ERROR_MESSAGE", 3))}
        elseif tostring(current_sql) ~= tostring(frozen_sql) then
            output_rows[#output_rows + 1] = {view_schema, view_name, "STALE",
                "The model now compiles different SQL for the same columns."
                .. " This view still answers, with the definition as it was when"
                .. " the view was created. Re-create it to pick the change up."}
        else
            output_rows[#output_rows + 1] = {view_schema, view_name, "CURRENT",
                "Matches what the model compiles today."}
        end
    end
end

if #output_rows == 0 then
    output_rows[#output_rows + 1] = {null, null, "NONE",
        "No view has been compiled from this model."}
end

exit(output_rows, [[
  VIEW_SCHEMA VARCHAR(256),
  VIEW_NAME VARCHAR(256),
  STATUS VARCHAR(32),
  DETAIL VARCHAR(2000000)
]])
