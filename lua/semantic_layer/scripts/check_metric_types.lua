--- Compares each published metric's declared type with the type its compiled SQL returns; one row per metric.
-- @script SEMANTIC_ADMIN.CHECK_METRIC_TYPES
-- @param MODEL_NAME
-- @returns TABLE

-- The published view and FIELDS_FOR_AGENT advertise DECLARED_TYPE; a query
-- returns COMPILED_TYPE. COMPATIBLE is false when they are different kinds of
-- number (DOUBLE against DECIMAL) or a DECIMAL's scale differs -- what
-- VALIDATE_MODEL reports as SEMANTIC_MODEL_076. A SUM widening the precision at
-- the same scale is shown but compatible. Reads no data: the type is taken
-- with TYPEOF over the compiled SQL under WHERE FALSE.

import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local output_rows = {}
for _, row in ipairs(compiler.metric_result_types(MODEL_NAME)) do
    output_rows[#output_rows + 1] = {
        row.object,
        row.metric,
        row.declared_type,
        row.compiled_type or null,
        row.compatible == nil and null or row.compatible,
        row.error or null,
    }
end

exit(output_rows, [[
  OBJECT_NAME VARCHAR(256),
  METRIC_NAME VARCHAR(256),
  DECLARED_TYPE VARCHAR(256),
  COMPILED_TYPE VARCHAR(256),
  COMPATIBLE BOOLEAN,
  PROBE_ERROR VARCHAR(2000000)
]])
