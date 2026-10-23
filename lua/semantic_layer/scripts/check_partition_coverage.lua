--- Checks each temporal partition of a model against its coverage window, reading data and writing nothing; one row per partition holding rows outside its window.
-- @script SEMANTIC_ADMIN.CHECK_PARTITION_COVERAGE
-- @param MODEL_NAME
-- @returns TABLE

-- Coverage is trusted as declared, so rows a partition holds outside its window
-- are left out of every answer unless another partition covers them. This is
-- the check VALIDATE_MODEL reports as SEMANTIC_MODEL_074, on its own: it records
-- no validation run and leaves the compile cache alone, so a dashboard can poll
-- it and say "N rows are outside coverage". Each probe scans a partition; set
-- QUERY_TIMEOUT to bound it.
--
-- STRANDED_KEYS is how many of the out-of-window keys no other partition's
-- window holds -- the rows missing from answers. OUTSIDE_ROWS with no stranded
-- keys are copies, which an archive job leaves between its copy and its delete.

import("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "validator")

local output_rows = {}
for _, finding in ipairs(validator.check_partition_coverage(MODEL_NAME)) do
    output_rows[#output_rows + 1] = {
        finding.entity,
        finding.representation,
        finding.coverage_predicate or null,
        finding.outside_rows or null,
        finding.stranded_keys or null,
        finding.error or null,
    }
end

exit(output_rows, [[
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  COVERAGE_PREDICATE VARCHAR(2000000),
  OUTSIDE_ROWS DECIMAL(18,0),
  STRANDED_KEYS DECIMAL(18,0),
  PROBE_ERROR VARCHAR(2000000)
]])
