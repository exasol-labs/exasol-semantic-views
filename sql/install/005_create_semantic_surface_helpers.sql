ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

CREATE OR REPLACE LUA SCALAR SCRIPT SEMANTIC_ADMIN.SEMANTIC_GUARD()
RETURNS VARCHAR(2000000) AS
-- @lua lua/semantic_layer/scripts/semantic_guard.lua
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(
  MODEL_NAME
)
RETURNS TABLE AS
-- @lua lua/semantic_layer/scripts/publish_model.lua
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REFRESH_SEMANTIC_SURFACE(
  MODEL_NAME
)
RETURNS TABLE AS
-- @lua lua/semantic_layer/scripts/refresh_semantic_surface.lua
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()
RETURNS TABLE AS
-- @lua lua/semantic_layer/scripts/enable_semantic_sql.lua
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()
RETURNS TABLE AS
-- @lua lua/semantic_layer/scripts/disable_semantic_sql.lua
/

-- Whether the semantic preprocessor records what it rewrites and refuses in
-- SYS_SEMANTIC.QUERY_LOG. DEPLOYMENT sets it for every session; SESSION
-- overrides it for the calling session, and LOGGING = NULL clears that
-- override. Writing SYS_SEMANTIC.SETTINGS is the authorisation: SEMANTIC_USER
-- is not granted it, so a caller cannot switch off the logging of its own
-- queries. Returns the setting as SEMANTIC_CATALOG.SETTINGS reports it.
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_QUERY_LOGGING(SCOPE, LOGGING)
RETURNS TABLE AS
-- @lua lua/semantic_layer/scripts/set_query_logging.lua
/
