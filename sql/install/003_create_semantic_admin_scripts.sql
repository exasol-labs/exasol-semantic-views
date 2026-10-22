-- Shared by the script bodies below, which import it rather than carry a copy.
-- @generated SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME

-- @lua lua/semantic_layer/scripts/create_model.lua

-- @lua lua/semantic_layer/scripts/drop_model.lua

-- @lua lua/semantic_layer/scripts/add_entity.lua

-- @lua lua/semantic_layer/scripts/new_validation_errors.lua

-- @lua lua/semantic_layer/scripts/recertify_model_if_published.lua

-- @lua lua/semantic_layer/scripts/add_entity_representation.lua

-- @lua lua/semantic_layer/scripts/call_admin_json.lua

-- @lua lua/semantic_layer/scripts/add_entity_representation_with_authority.lua

-- @lua lua/semantic_layer/scripts/add_semantic_identity.lua

-- @lua lua/semantic_layer/scripts/add_semantic_identity_with_bindings.lua

-- @lua lua/semantic_layer/scripts/add_identity_binding.lua

-- @lua lua/semantic_layer/scripts/add_identity_mapping_relation.lua

-- @lua lua/semantic_layer/scripts/remove_identity_mapping_relation.lua

-- @lua lua/semantic_layer/scripts/remove_identity_binding.lua

-- @lua lua/semantic_layer/scripts/remove_semantic_identity.lua

-- @lua lua/semantic_layer/scripts/set_representation_authority.lua

-- @lua lua/semantic_layer/scripts/set_attribute_fusion_policy.lua

-- @lua lua/semantic_layer/scripts/set_representation_coverage.lua

-- @lua lua/semantic_layer/scripts/set_representation_coverage_batch.lua

-- @lua lua/semantic_layer/scripts/add_entity_representation_with_coverage.lua

-- @lua lua/semantic_layer/scripts/add_entity_representation_with_identity_binding.lua

-- @lua lua/semantic_layer/scripts/add_entity_representation_with_declarations.lua

-- @lua lua/semantic_layer/scripts/set_primary_representation.lua

-- @lua lua/semantic_layer/scripts/rename_entity_representation.lua

-- @lua lua/semantic_layer/scripts/remove_entity_representation.lua

-- @lua lua/semantic_layer/scripts/add_semantic_object.lua

-- @lua lua/semantic_layer/scripts/create_semantic_object.lua

-- @lua lua/semantic_layer/scripts/add_relationship.lua

-- @lua lua/semantic_layer/scripts/add_relationship_key_mapping.lua

-- @lua lua/semantic_layer/scripts/remove_relationship_key_mapping.lua

-- @lua lua/semantic_layer/scripts/remove_relationship.lua

-- @lua lua/semantic_layer/scripts/set_relationship.lua

-- @lua lua/semantic_layer/scripts/add_dimension.lua

-- @lua lua/semantic_layer/scripts/add_or_replace_dimension.lua

-- @lua lua/semantic_layer/scripts/remove_dimension.lua

-- @lua lua/semantic_layer/scripts/add_fact.lua

-- @lua lua/semantic_layer/scripts/attribute_with_bindings.lua

-- @lua lua/semantic_layer/scripts/add_dimension_with_bindings.lua

-- @lua lua/semantic_layer/scripts/add_fact_with_bindings.lua

-- @lua lua/semantic_layer/scripts/add_attribute_binding.lua

-- @lua lua/semantic_layer/scripts/replace_attribute_binding.lua

-- @lua lua/semantic_layer/scripts/remove_attribute_binding.lua

-- @lua lua/semantic_layer/scripts/add_metric.lua

-- @lua lua/semantic_layer/scripts/add_custom_extension.lua

-- @lua lua/semantic_layer/scripts/get_custom_extensions.lua

-- @lua lua/semantic_layer/scripts/add_unique_key.lua

-- @lua lua/semantic_layer/scripts/add_unique_key_column.lua

-- @lua lua/semantic_layer/scripts/add_unique_key_with_columns.lua

-- @lua lua/semantic_layer/scripts/remove_unique_key_column.lua

-- @lua lua/semantic_layer/scripts/remove_unique_key.lua

-- @lua lua/semantic_layer/scripts/remove_unique_key_with_columns.lua

-- @lua lua/semantic_layer/scripts/add_synonym.lua

-- @lua lua/semantic_layer/scripts/register_materialization.lua

-- @lua lua/semantic_layer/scripts/add_materialization_column.lua

-- @lua lua/semantic_layer/scripts/set_model_governance_mode.lua

-- @lua lua/semantic_layer/scripts/remove_semantic_object.lua

-- @lua lua/semantic_layer/scripts/set_field_policy.lua

-- @lua lua/semantic_layer/scripts/check_frozen_views.lua

-- @lua lua/semantic_layer/scripts/check_partition_coverage.lua

-- @lua lua/semantic_layer/scripts/set_model_derived_composition.lua

-- @lua lua/semantic_layer/scripts/set_materialization_status.lua

-- Record that a materialization was rebuilt. Called by the refresh job -- a dbt
-- post-hook, a scheduler step -- after it writes the physical object.
--
-- The registry used to state only an intent (FRESHNESS_POLICY) and could not
-- answer "is this stale right now?" (BUG-27). This writes the state that
-- question needs. The row count is *measured* here, not passed in, so it
-- describes the object as it is rather than as the job believed it to be.
-- REFRESHED_AT defaults to now; a job that knows when its source snapshot was
-- taken may pass that instead, but not a time in the future. STATUS is left
-- alone: a manual STALE or INACTIVE is an operator's decision, and
-- SET_MATERIALIZATION_STATUS is the one place that changes it.
-- @lua lua/semantic_layer/scripts/mark_materialization_refreshed.lua

-- @lua lua/semantic_layer/scripts/grant_model_role.lua

-- @lua lua/semantic_layer/scripts/revoke_model_role.lua

-- @generated SEMANTIC_ADMIN.VALIDATOR_RUNTIME

-- @lua lua/semantic_layer/scripts/validate_model.lua

-- @generated SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME
-- @generated SEMANTIC_ADMIN.COMPILER_RUNTIME
-- @lua lua/semantic_layer/scripts/compile_request_json.lua

-- @lua lua/semantic_layer/scripts/compile_sql.lua

-- @lua lua/semantic_layer/scripts/compile_sql_debug.lua

-- @lua lua/semantic_layer/scripts/suggest_grain_metadata.lua

-- @generated SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME
-- @lua lua/semantic_layer/scripts/apply_semantic_definition.lua

-- @lua lua/semantic_layer/scripts/apply_semantic_definition_or_fail.lua

-- @lua lua/semantic_layer/scripts/apply_normalized_osi_import.lua

-- @lua lua/semantic_layer/scripts/import_databricks_metric_view.lua

-- @lua lua/semantic_layer/scripts/describe_semantic_metric.lua

-- @lua lua/semantic_layer/scripts/explain_semantic_metric.lua

-- @lua lua/semantic_layer/scripts/export_semantic_definition.lua

-- @generated SEMANTIC_ADMIN.FUSION_RUNTIME
-- @lua lua/semantic_layer/scripts/export_fusion_declaration.lua

-- @lua lua/semantic_layer/scripts/apply_fusion_declaration.lua
