-- Whether this model's published objects may be composed with other relations
-- in ordinary SQL.
--
-- Reference expansion turns a semantic object into a derived table, and a
-- derived table can be joined. That join can repeat the semantic result's rows,
-- and anything re-aggregating above it then double-counts -- the same fan-out a
-- Virtual Schema would produce, arriving by a different route. One thing is
-- better here: the author wrote the join themselves, so the boundary is visible
-- in their own SQL rather than chosen by an optimizer. That makes it
-- explainable, not safe, which is why the default is FALSE and refusing.
--
-- TRUE is for deployments that would rather have ordinary-SQL semantics over a
-- derived table than a refusal. It is a real choice with a real cost, so it is
-- made per model, by an administrator, in a statement that says so.
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

if missing(MODEL_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local model_name = trim(MODEL_NAME)

if missing(ALLOWED) then
    error("SEMANTIC_ADMIN_001: ALLOWED is required (TRUE or FALSE)")
end
local raw = string.upper(trim(ALLOWED))
local allowed
if raw == "TRUE" or raw == "YES" or raw == "1" then
    allowed = true
elseif raw == "FALSE" or raw == "NO" or raw == "0" then
    allowed = false
else
    error("SEMANTIC_ADMIN_002: ALLOWED must be TRUE or FALSE, got: " .. raw)
end

local rows = query([[
    SELECT MODEL_ID, ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end

query([[
    UPDATE SYS_SEMANTIC.MODELS
    SET ALLOW_DERIVED_COMPOSITION = :allowed,
        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {allowed = allowed, model_name = model_name})

-- Compiled SQL does not depend on this flag -- it decides whether a statement is
-- refused, not what it compiles to -- but a statement refused under FALSE was
-- never cached, and one accepted under TRUE must not survive the flag going
-- back. Clearing is cheap and removes the need to reason about which of those
-- applies.
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID IN (
      SELECT ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS
      WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    )
]], {model_name = model_name})
