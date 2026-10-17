--- Clears the session's SQL preprocessor script, turning Semantic SQL off for this session; returns one status row.
-- @script SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL
-- @returns TABLE

query([[ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL]])
exit({{"OK", "SESSION", null, "Semantic SQL disabled for this session."}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(256),
  MESSAGE VARCHAR(2000000)
]])
