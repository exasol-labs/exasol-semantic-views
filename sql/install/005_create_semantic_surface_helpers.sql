ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

-- @lua lua/semantic_layer/scripts/semantic_guard.lua

-- @lua lua/semantic_layer/scripts/publish_model.lua

-- @lua lua/semantic_layer/scripts/refresh_semantic_surface.lua

-- @lua lua/semantic_layer/scripts/enable_semantic_sql.lua

-- @lua lua/semantic_layer/scripts/disable_semantic_sql.lua

-- Whether the semantic preprocessor records what it rewrites and refuses in
-- SYS_SEMANTIC.QUERY_LOG. DEPLOYMENT sets it for every session; SESSION
-- overrides it for the calling session, and LOGGING = NULL clears that
-- override. Writing SYS_SEMANTIC.SETTINGS is the authorisation: SEMANTIC_USER
-- is not granted it, so a caller cannot switch off the logging of its own
-- queries. Returns the setting as SEMANTIC_CATALOG.SETTINGS reports it.
-- @lua lua/semantic_layer/scripts/set_query_logging.lua
