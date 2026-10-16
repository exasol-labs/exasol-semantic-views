local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return trim(value)
end

local function validate_physical_column(value, label)
    if value == null then return end
    if value == "" or #value > 256 or string.find(value, "%c") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. tostring(value))
    end
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or rows[1][1]
end

if missing(MODEL_NAME) or missing(RELATIONSHIP_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required")
end
local ordinal = tonumber(ORDINAL_POSITION)
if ordinal == nil or ordinal < 1 or ordinal % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: ORDINAL_POSITION must be a positive integer")
end
local from_column = optional_text(FROM_COLUMN_NAME)
local from_expression = optional_text(FROM_EXPRESSION)
local to_column = optional_text(TO_COLUMN_NAME)
local to_expression = optional_text(TO_EXPRESSION)
if (from_column == null) == (from_expression == null) then
    error("SEMANTIC_ADMIN_003: exactly one of FROM_COLUMN_NAME and FROM_EXPRESSION is required")
end
if (to_column == null) == (to_expression == null) then
    error("SEMANTIC_ADMIN_003: exactly one of TO_COLUMN_NAME and TO_EXPRESSION is required")
end
if from_expression ~= null or to_expression ~= null then
    error("SEMANTIC_ADMIN_043: expression relationship key mappings are not supported by typed grain proofs; normalize the expression into a source view and map a column")
end
validate_physical_column(from_column, "FROM_COLUMN_NAME")
validate_physical_column(to_column, "TO_COLUMN_NAME")

local relationship_id = scalar([[
    SELECT r.RELATIONSHIP_ID
    FROM SYS_SEMANTIC.RELATIONSHIPS r
    JOIN SYS_SEMANTIC.MODELS m
      ON m.MODEL_ID = r.MODEL_ID
     AND m.ACTIVE_VERSION_ID = r.VERSION_ID
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
      AND UPPER(r.RELATIONSHIP_NAME) = UPPER(:relationship_name)
      AND r.STATUS = 'ACTIVE'
]], {
    model_name = trim(MODEL_NAME),
    relationship_name = trim(RELATIONSHIP_NAME),
})
if relationship_id == nil then
    error("SEMANTIC_ADMIN_016: relationship not found: " .. trim(RELATIONSHIP_NAME))
end

local existing = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
    WHERE RELATIONSHIP_ID = :relationship_id
      AND ORDINAL_POSITION = :ordinal_position
]], {relationship_id = relationship_id, ordinal_position = ordinal})
if tonumber(existing or 0) > 0 then
    query([[
        UPDATE SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
        SET FROM_COLUMN_NAME = :from_column_name,
            FROM_EXPRESSION = :from_expression,
            TO_COLUMN_NAME = :to_column_name,
            TO_EXPRESSION = :to_expression
        WHERE RELATIONSHIP_ID = :relationship_id
          AND ORDINAL_POSITION = :ordinal_position
    ]], {
        relationship_id = relationship_id,
        ordinal_position = ordinal,
        from_column_name = from_column,
        from_expression = from_expression,
        to_column_name = to_column,
        to_expression = to_expression,
    })
else
    query([[
        INSERT INTO SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS (
          RELATIONSHIP_ID, ORDINAL_POSITION, FROM_COLUMN_NAME, FROM_EXPRESSION,
          TO_COLUMN_NAME, TO_EXPRESSION
        ) VALUES (
          :relationship_id, :ordinal_position, :from_column_name, :from_expression,
          :to_column_name, :to_expression
        )
    ]], {
        relationship_id = relationship_id,
        ordinal_position = ordinal,
        from_column_name = from_column,
        from_expression = from_expression,
        to_column_name = to_column,
        to_expression = to_expression,
    })
end
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = (
        SELECT VERSION_ID FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE RELATIONSHIP_ID = :relationship_id
    )
]], {relationship_id = relationship_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS
    SET STATUS = 'STALE'
    WHERE VERSION_ID = (
        SELECT VERSION_ID FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE RELATIONSHIP_ID = :relationship_id
    )
      AND STATUS IN ('OK', 'WARNING')
]], {relationship_id = relationship_id})
query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
    {model_name = trim(MODEL_NAME)})
