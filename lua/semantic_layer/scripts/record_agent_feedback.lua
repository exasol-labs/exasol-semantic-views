--- Records feedback on an agent request or query log entry, plus a suggestion if a change is proposed; returns one row.
-- @script SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK
-- @param HANDLE_TYPE AGENT_REQUEST (or AGENT_REQUEST_ID, AGENT) or QUERY_LOG (or QUERY_LOG_ID, SQL).
-- @param HANDLE_ID Numeric id of the agent request or query log entry.
-- @param VERDICT ACCEPTED, HELPFUL, NEEDS_CHANGE, NOT_HELPFUL or REJECTED.
-- @param COMMENT_TEXT Optional comment; also used as the suggestion's rationale. NULL stores NULL.
-- @param PROPOSED_CHANGE_JSON Optional proposed change text; when given, a PROPOSED_CHANGE suggestion is also created.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.record_agent_feedback(
    HANDLE_TYPE,
    HANDLE_ID,
    VERDICT,
    COMMENT_TEXT,
    PROPOSED_CHANGE_JSON
)

exit(rows or {}, [[
  FEEDBACK_ID DECIMAL(18,0),
  SUGGESTION_ID DECIMAL(18,0),
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  VERDICT VARCHAR(64),
  REVIEW_STATUS VARCHAR(64)
]])
