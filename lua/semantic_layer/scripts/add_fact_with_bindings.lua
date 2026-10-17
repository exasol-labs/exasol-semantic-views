--- Adds a fact on an entity with per-representation attribute bindings; returns one row with the fact id and active binding count.
-- @script SEMANTIC_ADMIN.ADD_FACT_WITH_BINDINGS
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity the fact is defined on.
-- @param FACT_NAME New fact name, unique in the model's active version.
-- @param EXPRESSION Required SQL expression for the primary representation.
-- @param DATA_TYPE Required SQL data type of the fact.
-- @param ADDITIVE_POLICY ADDITIVE, SEMI_ADDITIVE or NON_ADDITIVE.
-- @param DISPLAY_NAME Optional display name; NULL stores none.
-- @param DESCRIPTION Optional description; NULL stores none.
-- @param IS_PRIVATE
-- @param IS_CERTIFIED
-- @param BINDINGS_JSON Array of {representation_name, source_expression, binding_role: PREFER|FALLBACK, binding_priority}.
-- @returns TABLE

query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.ATTRIBUTE_WITH_BINDINGS(
      'FACT', :model_name, NULL, :entity_name, :attribute_name,
      :expression, :data_type, :additive_policy, :display_name, :description, NULL,
      :is_private, :is_certified, :bindings_json
    )
]], {model_name = MODEL_NAME, entity_name = ENTITY_NAME,
      attribute_name = FACT_NAME, expression = EXPRESSION, data_type = DATA_TYPE,
      additive_policy = ADDITIVE_POLICY, display_name = DISPLAY_NAME,
      description = DESCRIPTION, is_private = IS_PRIVATE, is_certified = IS_CERTIFIED,
      bindings_json = BINDINGS_JSON})
local rows = query([[
    SELECT f.FACT_ID, m.MODEL_NAME, e.ENTITY_NAME, 'FACT',
           f.FACT_NAME, COUNT(ab.ATTRIBUTE_BINDING_ID)
    FROM SYS_SEMANTIC.FACTS f
    JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = f.MODEL_ID
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.ENTITY_ID = f.ENTITY_ID AND e.VERSION_ID = f.VERSION_ID
    LEFT JOIN SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab
      ON ab.ATTRIBUTE_TYPE = 'FACT' AND ab.ATTRIBUTE_ID = f.FACT_ID
     AND ab.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
      AND f.VERSION_ID = m.ACTIVE_VERSION_ID
      AND UPPER(f.FACT_NAME) = UPPER(:attribute_name)
      AND f.STATUS = 'ACTIVE'
    GROUP BY f.FACT_ID, m.MODEL_NAME, e.ENTITY_NAME, f.FACT_NAME
]], {model_name = MODEL_NAME, attribute_name = FACT_NAME})
local result = {}
for _, row in ipairs(rows or {}) do
    result[#result + 1] = {row[1], row[2], row[3], row[4], row[5], row[6]}
end
exit(result, [[
  ATTRIBUTE_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  BINDING_COUNT DECIMAL(18,0)
]])
