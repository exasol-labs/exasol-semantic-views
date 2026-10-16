ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

CREATE OR REPLACE LUA PREPROCESSOR SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR AS
-- @lua lua/semantic_layer/scripts/semantic_preprocessor.lua
/

-- Database-wide activation is the supported BI deployment mode
-- (docs/admin-db-wide-setup.md), and Exasol runs the preprocessor as the caller.
-- Without this grant, `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT` denies *every*
-- statement to every principal that has not been granted SEMANTIC_USER --
-- including `SELECT 1` from a user with no relationship to this layer at all.
-- The supported deployment mode was a database-wide outage.
--
-- The grant is safe to make to PUBLIC because this script decides whether a
-- statement is semantic and does nothing else. It reads no model data of its
-- own: the catalog probe below is wrapped, and the runtimes that can read the
-- catalog are imported only when the statement could possibly need them and are
-- still subject to the caller's own privileges.
GRANT EXECUTE ON SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR TO PUBLIC;
