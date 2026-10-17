--- Always raises SEMANTIC_SURFACE_001, telling the caller that semantic queries need the Lua SQL preprocessor.
-- @script SEMANTIC_ADMIN.SEMANTIC_GUARD
-- @kind scalar
-- @returns VARCHAR(2000000)

function run(ctx)
    error("SEMANTIC_SURFACE_001: semantic query requires the Lua SQL preprocessor. Run EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL() for this session, or ask an administrator to set it database-wide. If it is already active, this session lacks the privileges to run it: SEMANTIC_USER carries them, and GRANT_MODEL_ROLE grants it.", 0)
end
