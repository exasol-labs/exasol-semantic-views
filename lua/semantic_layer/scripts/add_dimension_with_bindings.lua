query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.ATTRIBUTE_WITH_BINDINGS(
      'DIMENSION', :model_name, :object_name, :entity_name, :attribute_name,
      :expression, :data_type, NULL, :display_name, :description, :format_hint,
      FALSE, :is_certified, :bindings_json
    )
]], {model_name = MODEL_NAME, object_name = OBJECT_NAME, entity_name = ENTITY_NAME,
      attribute_name = DIMENSION_NAME, expression = EXPRESSION, data_type = DATA_TYPE,
      display_name = DISPLAY_NAME, description = DESCRIPTION, format_hint = FORMAT_HINT,
      is_certified = IS_CERTIFIED, bindings_json = BINDINGS_JSON})
local rows = query([[
    SELECT d.DIMENSION_ID, m.MODEL_NAME, e.ENTITY_NAME, 'DIMENSION',
           d.DIMENSION_NAME, COUNT(ab.ATTRIBUTE_BINDING_ID)
    FROM SYS_SEMANTIC.DIMENSIONS d
    JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = d.MODEL_ID
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.ENTITY_ID = d.ENTITY_ID AND e.VERSION_ID = d.VERSION_ID
    LEFT JOIN SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab
      ON ab.ATTRIBUTE_TYPE = 'DIMENSION' AND ab.ATTRIBUTE_ID = d.DIMENSION_ID
     AND ab.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
      AND d.VERSION_ID = m.ACTIVE_VERSION_ID
      AND UPPER(d.DIMENSION_NAME) = UPPER(:attribute_name)
      AND d.STATUS = 'ACTIVE'
    GROUP BY d.DIMENSION_ID, m.MODEL_NAME, e.ENTITY_NAME, d.DIMENSION_NAME
]], {model_name = MODEL_NAME, attribute_name = DIMENSION_NAME})
local result = {}
for _, row in ipairs(rows or {}) do
    result[#result + 1] = {row[1], row[2], row[3], row[4], row[5], row[6]}
end
exit(result, [[
  ATTRIBUTE_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  BINDING_COUNT DECIMAL(18,0)
]])
