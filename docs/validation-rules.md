# Validation Rules

Database-resident validation runs through:

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

If the model has no issues, the result set is empty. A model can remain valid
with warning rows. `ERROR` and `PRECONDITION` issues block certification; the
latter identifies a caller-session requirement rather than invalid model
metadata. Every run is also recorded in
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
| `SEMANTIC_MODEL_016` | error | Expression uses an unsupported function. Cast target types such as `VARCHAR(10)` are not interpreted as function calls; supported date bucketing includes `TRUNC` and `DATE_TRUNC`. |
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
| `SEMANTIC_MODEL_029` | error | Unique key column metadata is invalid or references an unresolvable source column/expression. Representation-specific attribute bindings do not redefine entity keys. |
| `SEMANTIC_MODEL_030` | error | Visible metric/dimension pair is invalid. |
| `SEMANTIC_MODEL_031` | warning | Relationship has no structured endpoint mapping; legacy compilation remains available but grain proofs cannot use it. Declare the endpoint unique key first, then ordered relationship mappings. |
| `SEMANTIC_MODEL_032` | error | Relationship endpoint mapping is malformed, non-contiguous, out of scope, or references an unknown source column. General expression or mapped-identity endpoint rewriting is not supported. |
| `SEMANTIC_MODEL_033` | error | Relationship endpoint mappings do not match the unique key required by the declared cardinality. |
| `SEMANTIC_MODEL_034` | error | An entity source alias is an Exasol reserved word and cannot be rendered safely. |
| `SEMANTIC_MODEL_035` | error | An active entity does not have exactly one active `PRIMARY` representation. |
| `SEMANTIC_MODEL_036` | error | An active representation has invalid F1 metadata, a duplicate name, a missing entity, an unstable alias, or unsupported temporal coverage. |
| `SEMANTIC_MODEL_037` | error | F1 equivalence cannot be proven: no key is declared, a key probe failed, or a representation violates a declared key's grain. |
| `SEMANTIC_MODEL_038` | error | An alternate representation's declared key cardinality or key set differs from the `PRIMARY` representation. |
| `SEMANTIC_MODEL_039` | error | An attribute binding has invalid ownership, role, priority, representation, or duplicate active membership. |
| `SEMANTIC_MODEL_040` | error | An attribute binding expression leaks another alias, uses a function outside the permitted set below, or references a column absent from its target representation. The unsupported-function diagnostic names the permitted set. |
| `SEMANTIC_MODEL_041` | precondition | A multi-representation F1/F3 key probe would run without a bounded session `QUERY_TIMEOUT` of 1 to 60 seconds. This is a blocking session precondition, not a defect in the model. The guard applies regardless of declared source kind or view dependencies. |
| `SEMANTIC_MODEL_042` | error | F3 `UNION` coverage is partial, gapped, overlapping, not open-ended, or its canonical predicate does not exactly encode the declared half-open interval. |
| `SEMANTIC_MODEL_043` | error | Once a model has active metrics, coverage partitions an entity that is the base of none of them and therefore can only use the unsupported partitioned joined-dimension path. |
| `SEMANTIC_MODEL_044` | error | F4 authority or attribute-fusion metadata is malformed, lacks two contributors or a physical unique key/complete semantic identity, has no single authority for `RECONCILE`, or conflicts with F3 partition fusion. |
| `SEMANTIC_MODEL_045` | error | `COALESCE` contributors have conflicting non-null values for one or more overlapping entity keys. |
| `SEMANTIC_MODEL_046` | warning | `RECONCILE` observed conflicting non-null values and deterministically selected the declared `AUTHORITATIVE` representation. |
| `SEMANTIC_MODEL_047` | error | F5 semantic identity or source-local binding metadata is malformed, ambiguous, incomplete, or uses an unsupported expression. |
| `SEMANTIC_MODEL_048` | error | A `DIRECT` binding incorrectly has a mapping, or a `MAPPED` binding lacks one visible `CERTIFIED` mapping relation. |
| `SEMANTIC_MODEL_049` | error | F5 data probes could not prove local uniqueness, mapping totality and bijection, or exact canonical semantic-key equivalence. |
| `SEMANTIC_MODEL_050` | warning | A relationship remains usable, but one or more endpoint representations lack the physical key and an anchored scalar `DIRECT` F5.1 remap, so joined requests exclude those candidates. |
| `SEMANTIC_MODEL_051` | error | A simple relationship equality joins incompatible physical type families. The diagnostic names the relationship, endpoints, and resolved representation types. |
| `SEMANTIC_MODEL_052` | error | A dimension or fact on an F3-partitioned entity lacks an active binding on one or more partitions. Each missing attribute/partition pair is reported. |

## Expression Validation Boundary

The static expression-function allow-list is:

`ABS`, `AVG`, `CAST`, `CEIL`, `COALESCE`, `CONCAT`, `COUNT`, `DATE_TRUNC`,
`DAY`, `EXTRACT`, `FLOOR`, `LOWER`, `LPAD`, `LTRIM`, `MAX`, `MIN`, `MONTH`,
`NULLIF`, `REPLACE`, `ROUND`, `RTRIM`, `SUBSTR`, `SUM`, `TO_CHAR`, `TO_DATE`,
`TRIM`, `TRUNC`, `UPPER`, and `YEAR`.

This is the validator's static safety boundary, not a guarantee that every
function is meaningful in every expression context. Agents and adapters can
discover the same set without trial and error:

```sql
SELECT FUNCTION_NAME, FUNCTION_CATEGORY
FROM SEMANTIC_AGENT.EXPRESSION_FUNCTIONS_FOR_AGENT
ORDER BY FUNCTION_NAME;
```

Expression validation checks alias scope, referenced source columns, and a
static unsupported-function policy. It does not ask Exasol to parse every
complete dimension, fact, metric, filter, identity, or binding expression.
Dialect-specific syntax can therefore pass static validation and still fail
when rendered.

Before registration, smoke test each physical expression against the exact
source relation and alias, for example:

```sql
SELECT YEAR(src.order_date)
FROM MART.ORDERS src
LIMIT 1;
```

SQL-native definition dry-run validates the simulated catalog state but does
not strengthen this expression boundary. Imported Databricks expressions need
the same Exasol-specific smoke testing.

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

Validation accepts same-entity pairs and non-fanout relationship paths. It rejects
paths that require many-to-many traversal without fanout policy.

For rejected connected pairs, `RELATIONSHIP_PATH` contains the attempted path
and annotates unsafe edges with their reason, for example
`line_to_order > shipment_to_order (rejected: FANOUT_REQUIRES_POLICY)`.
`NO_SAFE_JOIN_PATH` means no semantic-object root can reach the metric base
without traversing from the one-side to the many-side of a relationship. This
prevents attributing one fact row to multiple dimension rows; see
[Grain-Aware Result Semantics](architecture-decisions/001-grain-aware-result-semantics.md).
Declare a semantic object rooted at the metric's base entity to establish that
branch grain, or remove the metric from the incompatible object.

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
