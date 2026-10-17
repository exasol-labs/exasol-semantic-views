--- Creates a semantic object by delegating to ADD_SEMANTIC_OBJECT with the same arguments; returns nothing.
-- @script SEMANTIC_ADMIN.CREATE_SEMANTIC_OBJECT
-- @param MODEL_NAME
-- @param OBJECT_NAME Name of the new semantic object (view).
-- @param ROOT_ENTITY_NAME Entity that is the root of the semantic object.
-- @param DESCRIPTION Optional description; NULL stores none.
-- @returns nothing

query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
      :model_name, :object_name, :root_entity_name, :description
    )
]], {
    model_name = MODEL_NAME,
    object_name = OBJECT_NAME,
    root_entity_name = ROOT_ENTITY_NAME,
    description = DESCRIPTION
})
