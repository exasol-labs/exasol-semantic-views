--- Adds an active agent instruction to a model scope, reusing an identical active one; returns one row with its id and status.
-- @script SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION
-- @param MODEL_NAME
-- @param SCOPE_TYPE What the instruction is attached to: MODEL, SEMANTIC_OBJECT, ENTITY, DIMENSION, FACT or METRIC.
-- @param SCOPE_NAME Name of the scoped object; ignored for MODEL, required for every other SCOPE_TYPE.
-- @param INSTRUCTION_KIND One of AMBIGUITY, DEFINITION, GENERAL, POLICY, PRECONDITION, PREFERENCE, SAFETY, STYLE.
-- @param INSTRUCTION_TEXT Required instruction text shown to agents.
-- @param APPLIES_TO_ROLE Optional role the instruction applies to; NULL stores no role.
-- @param PRIORITY Numeric priority; NULL or non-numeric defaults to 100.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_agent_instruction(
    MODEL_NAME,
    SCOPE_TYPE,
    SCOPE_NAME,
    INSTRUCTION_KIND,
    INSTRUCTION_TEXT,
    APPLIES_TO_ROLE,
    PRIORITY
)

exit(rows or {}, [[
  INSTRUCTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  SCOPE_TYPE VARCHAR(64),
  SCOPE_NAME VARCHAR(512),
  INSTRUCTION_KIND VARCHAR(64),
  STATUS VARCHAR(32)
]])
