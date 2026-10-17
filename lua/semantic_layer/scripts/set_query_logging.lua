--- Sets preprocessor query logging for the deployment or the current session; returns one row with the effective setting.
-- @script SEMANTIC_ADMIN.SET_QUERY_LOGGING
-- @param SCOPE DEPLOYMENT or SESSION (case-insensitive).
-- @param LOGGING ON or OFF (case-insensitive); NULL with SCOPE SESSION clears the session override.
-- @returns TABLE

local function word(value)
    if value == nil or value == null then return "" end
    return string.upper(tostring(value):match("^%s*(.-)%s*$"))
end
local scope, logging = word(SCOPE), word(LOGGING)
if scope ~= "DEPLOYMENT" and scope ~= "SESSION" then
    error("SEMANTIC_ADMIN_224: SCOPE must be DEPLOYMENT or SESSION.", 0)
end
if logging ~= "ON" and logging ~= "OFF" and not (scope == "SESSION" and logging == "") then
    error("SEMANTIC_ADMIN_225: LOGGING must be ON or OFF; NULL clears a SESSION override.", 0)
end
-- Overrides of sessions that have ended go on the way, so the table holds at
-- most one row per live session.
query([[DELETE FROM SYS_SEMANTIC.SETTINGS WHERE SETTING_NAME = 'PREPROCESSOR_QUERY_LOG' AND ]]
    .. (scope == "DEPLOYMENT" and "SESSION_ID IS NULL"
        or "(SESSION_ID = CURRENT_SESSION OR SESSION_ID NOT IN (SELECT SESSION_ID FROM EXA_ALL_SESSIONS))"))
if logging ~= "" then
    query([[INSERT INTO SYS_SEMANTIC.SETTINGS (SETTING_NAME, SESSION_ID, SETTING_VALUE)
            VALUES ('PREPROCESSOR_QUERY_LOG', ]] .. (scope == "SESSION" and "CURRENT_SESSION" or "NULL")
        .. [[, :logging)]], {logging = logging})
end
local row = query([[SELECT SETTING_NAME, DEPLOYMENT_VALUE, SESSION_VALUE, EFFECTIVE_VALUE
                     FROM SEMANTIC_CATALOG.SETTINGS WHERE SETTING_NAME = 'PREPROCESSOR_QUERY_LOG']])[1]
exit({{row[1], row[2], row[3], row[4]}}, [[
  SETTING_NAME VARCHAR(128),
  DEPLOYMENT_VALUE VARCHAR(2000),
  SESSION_VALUE VARCHAR(2000),
  EFFECTIVE_VALUE VARCHAR(2000)
]])
