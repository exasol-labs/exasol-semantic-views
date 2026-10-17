--- Records a pending model-evolution suggestion, reusing an identical pending one; returns one row for the suggestion.
-- @script SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION
-- @param MODEL_NAME
-- @param SUGGESTION_KIND NEW_CONCEPT, NEW_IDENTITY, REPRESENTATION_EQUIVALENCE, AUTHORITY_CHANGE or DRIFT_REPAIR.
-- @param OBJECT_TYPE MODEL, SEMANTIC_OBJECT, ENTITY, RELATIONSHIP, DIMENSION, FACT, METRIC or SEMANTIC_IDENTITY.
-- @param OBJECT_NAME Target object name; must exist unless NEW_CONCEPT. Ignored for OBJECT_TYPE MODEL.
-- @param PROPOSED_CHANGE_JSON Proposed change as a JSON object ({...}). Required.
-- @param RATIONALE Reason for the suggestion. Required.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.propose_model_evolution(
    MODEL_NAME,
    SUGGESTION_KIND,
    OBJECT_TYPE,
    OBJECT_NAME,
    PROPOSED_CHANGE_JSON,
    RATIONALE
)

exit(rows or {}, [[
  SUGGESTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  SUGGESTION_KIND VARCHAR(64),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  REVIEW_STATUS VARCHAR(64),
  IS_DUPLICATE BOOLEAN
]])
