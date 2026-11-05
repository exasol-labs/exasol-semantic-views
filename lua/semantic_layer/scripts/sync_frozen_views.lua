--- Retires each view compiled from a model that CHECK_FROZEN_VIEWS finds STALE, so reading it raises, and puts back a retired view that matches again; one row per view acted on.
-- @script SEMANTIC_ADMIN.SYNC_FROZEN_VIEWS
-- @param MODEL_NAME
-- @returns TABLE

-- A frozen view goes on answering with the model as it was, and nothing in the
-- answer says so: an agent handed one by a BI tool reads a number the model no
-- longer gives, with no warning and no error. Checking on every read would
-- cost every read. A definition changes rarely, and every change is validated,
-- so VALIDATE_MODEL calls this after a clean run and the check is paid once
-- per change instead.
--
-- A STALE view is retired: replaced, under the same name and columns, by one
-- that raises SEMANTIC_SURFACE_015, the way a published view raises without
-- the preprocessor. Its own text is kept, and put back once the model compiles
-- what it froze again -- which is also what undoes a retirement made by a
-- validation that a dry run or a refused change rolls back, since each of them
-- validates again after restoring the catalog.
--
-- Replacing a view drops its grants, so they are read first and re-applied.
-- A view this caller may not replace is reported FAILED and left answering.
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local missing = script_support.ESV_ROWS.missing
local row_value = script_support.ESV_ROWS.row_value

local function quote_ident(name)
    return '"' .. (string.gsub(tostring(name), '"', '""')) .. '"'
end
local function sql_string(value)
    return "'" .. (string.gsub(tostring(value), "'", "''")) .. "'"
end

if missing(MODEL_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local model_name = tostring(MODEL_NAME):match("^%s*(.-)%s*$")

local RESULT_COLUMNS = [[
  VIEW_SCHEMA VARCHAR(256),
  VIEW_NAME VARCHAR(256),
  OUTCOME VARCHAR(32),
  DETAIL VARCHAR(2000000)
]]

-- Every record of every view this model froze. A view can freeze several
-- objects, so it is acted on once, and only when all of its records agree.
local records = query([[
    SELECT fv.VIEW_SCHEMA, fv.VIEW_NAME, fv.OBJECT_NAME, fv.RETIRED_AT,
           fv.RETIRED_VIEW_TEXT, fv.RETIRED_SCOPE_SCHEMA, m.MODEL_NAME
      FROM SYS_SEMANTIC.FROZEN_VIEWS fv
      JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = fv.MODEL_ID
     WHERE EXISTS (
             SELECT 1
               FROM SYS_SEMANTIC.FROZEN_VIEWS f
               JOIN SYS_SEMANTIC.MODELS fm ON fm.MODEL_ID = f.MODEL_ID
              WHERE UPPER(fm.MODEL_NAME) = UPPER(:model_name)
                AND f.VIEW_SCHEMA = fv.VIEW_SCHEMA AND f.VIEW_NAME = fv.VIEW_NAME)
     ORDER BY fv.FROZEN_VIEW_ID
]], {model_name = model_name}) or {}
if #records == 0 then
    exit({}, RESULT_COLUMNS)
end

local status = {}
for _, row in ipairs(query("EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS("
        .. sql_string(model_name) .. ")") or {}) do
    local key = tostring(row_value(row, "VIEW_SCHEMA", 1)) .. "."
        .. tostring(row_value(row, "VIEW_NAME", 2))
    -- One verdict per view: any record that is not CURRENT decides it.
    local verdict = tostring(row_value(row, "STATUS", 3))
    if status[key] == nil or status[key] == "CURRENT" then
        status[key] = verdict
    end
end

local views, order = {}, {}
for _, row in ipairs(records) do
    local schema = tostring(row_value(row, "VIEW_SCHEMA", 1))
    local name = tostring(row_value(row, "VIEW_NAME", 2))
    local key = schema .. "." .. name
    local view = views[key]
    if view == nil then
        view = {schema = schema, name = name, objects = {}, other_model = false,
                retired = not missing(row_value(row, "RETIRED_AT", 4)),
                text = row_value(row, "RETIRED_VIEW_TEXT", 5),
                scope = row_value(row, "RETIRED_SCOPE_SCHEMA", 6)}
        views[key] = view
        order[#order + 1] = key
    end
    view.objects[#view.objects + 1] = tostring(row_value(row, "OBJECT_NAME", 3))
    if string.upper(tostring(row_value(row, "MODEL_NAME", 7))) ~= string.upper(model_name) then
        view.other_model = true
    end
end

local function grants_on(view)
    return query([[
        SELECT PRIVILEGE, GRANTEE FROM SYS.EXA_ALL_OBJ_PRIVS
         WHERE OBJECT_SCHEMA = :view_schema AND OBJECT_NAME = :view_name
    ]], {view_schema = view.schema, view_name = view.name}) or {}
end

local function regrant(view, grants)
    for _, grant in ipairs(grants) do
        query("GRANT " .. tostring(row_value(grant, "PRIVILEGE", 1)) .. " ON "
            .. quote_ident(view.schema) .. "." .. quote_ident(view.name) .. " TO "
            .. quote_ident(row_value(grant, "GRANTEE", 2)))
    end
end

local function mark(view, retired_text, scope)
    query([[
        UPDATE SYS_SEMANTIC.FROZEN_VIEWS
           SET RETIRED_AT = CASE WHEN :retired_text IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END,
               RETIRED_VIEW_TEXT = :retired_text,
               RETIRED_SCOPE_SCHEMA = :scope
         WHERE VIEW_SCHEMA = :view_schema AND VIEW_NAME = :view_name
    ]], {retired_text = retired_text, scope = scope,
         view_schema = view.schema, view_name = view.name})
end

local function retire(view)
    local live = query([[
        SELECT VIEW_TEXT, SCOPE_SCHEMA FROM SYS.EXA_ALL_VIEWS
         WHERE VIEW_SCHEMA = :view_schema AND VIEW_NAME = :view_name
    ]], {view_schema = view.schema, view_name = view.name}) or {}
    local columns = query([[
        SELECT COLUMN_NAME, COLUMN_TYPE FROM SYS.EXA_ALL_COLUMNS
         WHERE COLUMN_SCHEMA = :view_schema AND COLUMN_TABLE = :view_name
         ORDER BY COLUMN_ORDINAL_POSITION
    ]], {view_schema = view.schema, view_name = view.name}) or {}
    if #live == 0 or #columns == 0 then
        error("the view or its columns cannot be read")
    end
    local names, selected = {}, {}
    for _, column in ipairs(columns) do
        local name = quote_ident(row_value(column, "COLUMN_NAME", 1))
        names[#names + 1] = name
        -- In every column and in WHERE, as in a published view: a statement
        -- that selects no column, such as COUNT(*), evaluates no column.
        selected[#selected + 1] = "CAST(SEMANTIC_ADMIN.FROZEN_VIEW_GUARD() AS "
            .. tostring(row_value(column, "COLUMN_TYPE", 2)) .. ") AS " .. name
    end
    local grants = grants_on(view)
    -- Marked first, so a view replaced by a stand-in always has its own text
    -- kept: were a grant to fail after the swap with the mark still to come,
    -- the next sync would keep the stand-in's text as the view's.
    mark(view, row_value(live[1], "VIEW_TEXT", 1), row_value(live[1], "SCOPE_SCHEMA", 2))
    local replaced, failure = pcall(query, "CREATE OR REPLACE VIEW " .. quote_ident(view.schema)
        .. "." .. quote_ident(view.name)
        .. " (" .. table.concat(names, ", ") .. ") AS SELECT " .. table.concat(selected, ", ")
        .. " FROM DUAL WHERE SEMANTIC_ADMIN.FROZEN_VIEW_GUARD() IS NOT NULL COMMENT IS "
        .. sql_string("Retired: compiled from an earlier definition of " .. model_name .. "."
            .. table.concat(view.objects, ", ") .. ", which the model no longer compiles."
            .. " Reading it raises SEMANTIC_SURFACE_015. Re-create it over the semantic"
            .. " object; EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS("
            .. sql_string(model_name) .. ") says what changed."))
    if not replaced then
        mark(view, null, null)
        error(failure)
    end
    regrant(view, grants)
end

-- The kept text is the statement that created the view, and a plain CREATE
-- VIEW over the retired one would fail; OR REPLACE swaps them in one step, so a
-- restore that fails leaves the retired view rather than none.
local function restore(view)
    local text = tostring(view.text)
    local head = string.upper(string.sub(text, 1, 64))
    if head:match("^%s*CREATE%s+OR%s+REPLACE%s") == nil and head:match("^%s*CREATE%s") then
        text = (string.gsub(text, "^(%s*)[Cc][Rr][Ee][Aa][Tt][Ee](%s)", "%1CREATE OR REPLACE%2", 1))
    elseif head:match("^%s*CREATE%s") == nil then
        error("the kept text does not start with CREATE")
    end
    local grants = grants_on(view)
    -- Unqualified names in it resolve in the schema it was created in.
    local previous = query("SELECT CURRENT_SCHEMA")
    previous = previous and previous[1] and previous[1][1]
    if not missing(view.scope) then
        query("OPEN SCHEMA " .. quote_ident(view.scope))
    end
    local ok, failure = pcall(query, text)
    if missing(previous) then
        query("CLOSE SCHEMA")
    else
        query("OPEN SCHEMA " .. quote_ident(previous))
    end
    if not ok then
        error(failure)
    end
    regrant(view, grants)
    mark(view, null, null)
end

local output_rows = {}
for _, key in ipairs(order) do
    local view = views[key]
    local verdict = status[key]
    if verdict == "STALE" and not view.retired then
        local ok, failure = pcall(retire, view)
        output_rows[#output_rows + 1] = ok
            and {view.schema, view.name, "RETIRED",
                 "Compiled from an earlier definition; reading it now raises"
                 .. " SEMANTIC_SURFACE_015 until it is re-created."}
            or {view.schema, view.name, "FAILED",
                "Stale, and could not be retired, so it still answers with the earlier"
                .. " definition: " .. tostring(failure)}
    elseif verdict == "CURRENT" and view.retired and not view.other_model then
        local ok, failure = pcall(restore, view)
        output_rows[#output_rows + 1] = ok
            and {view.schema, view.name, "RESTORED",
                 "Matches what the model compiles again, so it answers again."}
            or {view.schema, view.name, "FAILED",
                "Matches what the model compiles again, and could not be put back: "
                .. tostring(failure)}
    end
end

exit(output_rows, RESULT_COLUMNS)
