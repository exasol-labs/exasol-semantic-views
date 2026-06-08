# Validation Rules

Milestone 2 adds database-resident validation through:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

The script returns one row per issue:

```text
SEVERITY
OBJECT_TYPE
OBJECT_NAME
RULE_CODE
MESSAGE
```

If the model is valid, the result set is empty. Every run is also recorded in
`SYS_SEMANTIC.VALIDATION_RUNS` and `SYS_SEMANTIC.VALIDATION_RESULTS`, exposed
through `SEMANTIC_CATALOG.VALIDATION_RUNS` and
`SEMANTIC_CATALOG.VALIDATION_RESULTS`.

`VALIDATION_RESULTS` is historical. To review only the latest run for each
model version, use:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = 'sales'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

SQL-native definition applies run validation before reporting success. If an
apply fails validation, the previous catalog state is restored and the current
validation views show the restored model state.

## Rule Codes

| Code | Severity | Meaning |
| --- | --- | --- |
| `SEMANTIC_MODEL_000` | error | Model name is missing or the model does not exist. |
| `SEMANTIC_MODEL_001` | error | Entity source table or view is not visible. |
| `SEMANTIC_MODEL_002` | error | Model has no active version. |
| `SEMANTIC_MODEL_003` | error | Entity alias is duplicated in one model version. |
| `SEMANTIC_MODEL_004` | error | Object, dimension, or fact references a missing entity. |
| `SEMANTIC_MODEL_005` | error | Semantic object column references a missing catalog object. |
| `SEMANTIC_MODEL_006` | error | Relationship endpoint is missing. |
| `SEMANTIC_MODEL_007` | error | Relationship join condition references an invalid alias. |
| `SEMANTIC_MODEL_008` | error | Relationship cardinality is unsupported. |
| `SEMANTIC_MODEL_009` | error | Relationship join type is unsupported. |
| `SEMANTIC_MODEL_010` | error | Many-to-many relationship lacks explicit fanout policy. |
| `SEMANTIC_MODEL_011` | error | Metric expression references an unknown fact or metric. |
| `SEMANTIC_MODEL_012` | error | Metric dependencies contain a cycle. |
| `SEMANTIC_MODEL_013` | error | Dimension, fact, or filter expression uses an out-of-scope alias. |
| `SEMANTIC_MODEL_014` | error | Metric base entity is missing. |
| `SEMANTIC_MODEL_016` | error | Expression uses an unsupported MVP function. |
| `SEMANTIC_MODEL_017` | error | Expression references an unknown source column. |
| `SEMANTIC_MODEL_020` | warning | Public metric is missing a description. |
| `SEMANTIC_MODEL_021` | error | Certified synonym is ambiguous. |
| `SEMANTIC_MODEL_022` | warning | Public numeric metric is missing a unit or format hint. |
| `SEMANTIC_MODEL_023` | error | Verified query references missing semantic objects, metrics, or dimensions. |
| `SEMANTIC_MODEL_024` | error | Agent instruction scope type is unsupported. |
| `SEMANTIC_MODEL_025` | error | Agent instruction kind is unsupported. |
| `SEMANTIC_MODEL_026` | error | Custom extension scope type is unsupported or points to a missing object. |
| `SEMANTIC_MODEL_027` | error | Custom extension metadata is incomplete or `DATA_JSON` is not valid JSON. |
| `SEMANTIC_MODEL_028` | error | Unique key metadata is invalid, references a missing entity, has an unsupported key kind, or has no columns. |
| `SEMANTIC_MODEL_029` | error | Unique key column metadata is invalid or references an unresolvable source column/expression. |
| `SEMANTIC_MODEL_030` | error | Visible metric/dimension pair is invalid. |

## Metric/Dimension Matrix

Validation rebuilds `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX` for the active model
version. The compiler must use this table before planning a metric grouped or
filtered by a dimension.

The matrix records:

- `MODEL_ID`
- `VERSION_ID`
- `METRIC_ID`
- `DIMENSION_ID`
- `IS_VALID`
- `REASON_CODE`
- `RELATIONSHIP_PATH`

The MVP accepts same-entity pairs and non-fanout relationship paths. It rejects
paths that require many-to-many traversal without fanout policy.

## Test Coverage

Run the Nano smoke:

```sh
PYTHON_BIN=python3 sh tools/run_nano_smoke.sh
```

The smoke now verifies:

- valid sales model has no validation errors
- sales metric/dimension matrix has 20 valid rows
- metric dependencies are extracted into `METRIC_DEPENDENCIES`
- missing source object returns `SEMANTIC_MODEL_001`
- invalid metric dependency returns `SEMANTIC_MODEL_011`
- cyclic metric dependency returns `SEMANTIC_MODEL_012`
- many-to-many traversal without fanout returns `SEMANTIC_MODEL_010`
- ambiguous certified synonym returns `SEMANTIC_MODEL_021`
- stale verified query references return `SEMANTIC_MODEL_023`
- invalid OSI extension scope or JSON returns `SEMANTIC_MODEL_026` or
  `SEMANTIC_MODEL_027`
- invalid unique-key metadata returns `SEMANTIC_MODEL_028` or
  `SEMANTIC_MODEL_029`
