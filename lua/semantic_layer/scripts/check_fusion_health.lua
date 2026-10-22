--- Counts how each COALESCE or RECONCILE attribute is answered: by its first-ranked source, filled by another, or not at all; one row per fused attribute.
-- @script SEMANTIC_ADMIN.CHECK_FUSION_HEALTH
-- @param MODEL_NAME
-- @returns TABLE

-- Validation reports only conflicting values (SEMANTIC_MODEL_046). A key the
-- authoritative source leaves NULL is filled from a supplemental one, and a key
-- no source covers answers NULL, and neither was counted anywhere. This counts
-- both, over the keys of the entity's primary representation, with the
-- compiler's own fused expression, so a viewer can be told "2 of 8 segments come
-- from the CRM; 1 is unknown". It reads data and writes nothing; set
-- QUERY_TIMEOUT to bound it. Counts only -- no key values are returned.

import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local output_rows = {}
for _, finding in ipairs(compiler.fusion_health(MODEL_NAME)) do
    output_rows[#output_rows + 1] = {
        finding.entity,
        finding.attribute_type,
        finding.attribute,
        finding.strategy,
        finding.first_source or null,
        finding.total_keys or null,
        finding.from_first_source or null,
        finding.filled or null,
        finding.unresolved or null,
        finding.error or null,
    }
end

exit(output_rows, [[
  ENTITY_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32),
  ATTRIBUTE_NAME VARCHAR(256),
  FUSION_STRATEGY VARCHAR(32),
  FIRST_SOURCE VARCHAR(256),
  TOTAL_KEYS DECIMAL(18,0),
  FROM_FIRST_SOURCE DECIMAL(18,0),
  FILLED DECIMAL(18,0),
  UNRESOLVED DECIMAL(18,0),
  PROBE_ERROR VARCHAR(2000000)
]])
