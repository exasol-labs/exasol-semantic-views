--- Records a review decision on a pending model evolution suggestion; returns one row with the new review status.
-- @script SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION
-- @param SUGGESTION_ID Positive id of a PENDING suggestion in MODEL_EVOLUTION_SUGGESTIONS.
-- @param DECISION CERTIFIED or REJECTED; CERTIFIED is refused if the suggestion's version is not the active one.
-- @param REVIEW_NOTE Required review note text.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.review_model_evolution(
    SUGGESTION_ID,
    DECISION,
    REVIEW_NOTE
)

exit(rows or {}, [[
  SUGGESTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  SUGGESTION_KIND VARCHAR(64),
  REVIEW_STATUS VARCHAR(64),
  REVIEWED_BY VARCHAR(256),
  ACTIVATION_STATUS VARCHAR(64)
]])
