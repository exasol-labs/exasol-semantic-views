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
