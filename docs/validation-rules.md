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

**Adding one.** A new condition gets a new code unless it is genuinely the same
defect seen from another angle. Every family has three digits and there is no
cost to using them; the cost runs the other way. `SEMANTIC_MODEL_047` accumulated
fourteen distinct meanings — duplicate identity name, unknown entity, bad kind, missing
data type, unsupported function, alias escape, and "no binding for active
representation" among them — and once a code means fourteen things, neither a
caller nor the code itself can branch on it. That last condition is the *cause*
of the key, expression and attribute failures reported against the same
representation, so leading the report with it meant searching the message text
for a sentence any edit could have reworded. It is now `SEMANTIC_MODEL_060`, and
the check is a comparison.

So: when a rule you are touching already carries several meanings, split out the
one you came for. `tests/test_conventions.py` pins the per-code count of distinct
messages — it may fall, and it may not rise.

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
| `SEMANTIC_MODEL_010` | error | Many-to-many relationship lacks an explicit fanout policy. See [Fanout policy](#fanout-policy). |
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
| `SEMANTIC_MODEL_038` | error | An alternate representation's declared key cardinality or key set differs from the `PRIMARY` representation. The message names this as a difference in rows rather than columns, and points at presenting the source over the full key set; attribute bindings cannot settle it. |
| `SEMANTIC_MODEL_039` | error | An attribute binding has invalid ownership, role, priority, representation, or duplicate active membership. |
| `SEMANTIC_MODEL_040` | error | An attribute binding expression leaks another alias, uses a function outside the permitted set below, or references a column absent from its target representation. The unsupported-function diagnostic names the permitted set. |
| `SEMANTIC_MODEL_041` | precondition | A multi-representation F1/F3 key probe would run without a bounded session `QUERY_TIMEOUT` of 1 to 60 seconds. This is a blocking session precondition, not a defect in the model. The guard applies regardless of declared source kind or view dependencies. |
| `SEMANTIC_MODEL_042` | error | F3 `UNION` coverage is partial, gapped, overlapping, not open-ended, or its canonical predicate does not exactly encode the declared half-open interval. |
| `SEMANTIC_MODEL_043` | error | Once a model has active metrics, coverage partitions an entity that is the base of none of them and therefore can only use the unsupported partitioned joined-dimension path. |
| `SEMANTIC_MODEL_044` | error | F4 authority or attribute-fusion metadata is malformed, lacks a physical unique key/complete semantic identity, or conflicts with F3 partition fusion. The two contributor-counting conditions it used to carry are now `SEMANTIC_MODEL_070` and `SEMANTIC_MODEL_071`. |
| `SEMANTIC_MODEL_045` | error | `COALESCE` contributors have conflicting non-null values for one or more overlapping entity keys. |
| `SEMANTIC_MODEL_046` | warning | `RECONCILE` observed conflicting non-null values and deterministically selected the declared `AUTHORITATIVE` representation. |
| `SEMANTIC_MODEL_047` | error | F5 semantic identity or source-local binding metadata is malformed, ambiguous, incomplete, or uses an unsupported expression. Covers the identity's own declaration and each binding's expression; a representation with *no* binding at all is `SEMANTIC_MODEL_060`. |
| `SEMANTIC_MODEL_048` | error | A `DIRECT` binding incorrectly has a mapping, or a `MAPPED` binding lacks one visible `CERTIFIED` mapping relation. |
| `SEMANTIC_MODEL_049` | error | F5 data probes could not prove local uniqueness, mapping totality and bijection, or exact canonical semantic-key equivalence. |
| `SEMANTIC_MODEL_050` | warning | A relationship remains usable, but one or more endpoint representations lack the physical key and an anchored scalar `DIRECT` F5.1 remap, so joined requests exclude those candidates. |
| `SEMANTIC_MODEL_051` | error | A simple relationship equality joins incompatible physical type families. The diagnostic names the relationship, endpoints, and resolved representation types. |
| `SEMANTIC_MODEL_052` | error | A dimension or fact on an F3-partitioned entity lacks an active binding on one or more partitions. Each missing attribute/partition pair is reported. |
| `SEMANTIC_MODEL_053` | warning | Fanout policy value is unrecognized, or declared on a cardinality where it has no meaning. See [Fanout policy](#fanout-policy). |
| `SEMANTIC_MODEL_054` | warning | Legacy entity key expression does not cover the declared primary key, so it is not unique at the entity's grain. It is a bootstrap hint; grain proofs use `UNIQUE_KEYS`. |
| `SEMANTIC_MODEL_055` | warning | Two entities are connected by more than one safe relationship path of differing length. Compilation selects the shortest; the alternative can attribute a row differently. See [Path ambiguity](#path-ambiguity). |
| `SEMANTIC_MODEL_056` | error | The planner cannot determine the metric's input grain: it aggregates no fact (`COUNT(*)`), or aggregates facts from several entities in one state. The metric could never be compiled. |
| `SEMANTIC_MODEL_057` | error | The metric's aggregate has no mergeable state (`AVG`, `MIN`, `MAX`, `COUNT DISTINCT`) and its leaves force state merging — a partitioned (F3) entity, or facts from several entities. The metric could never be compiled. |
| `SEMANTIC_MODEL_058` | warning | A semantic view exposes metrics and no dimensions, so it publishes as a single grand-total column that can only be grouped by nothing. |
| `SEMANTIC_MODEL_059` | error | A visible metric aggregates at an entity **coarser** than its object's root, so the join repeats each row and the aggregate is multiplied by the fan-out. See [Metric grain versus object root](#metric-grain-versus-object-root). |
| `SEMANTIC_MODEL_060` | error | An active representation of an entity that has an F5 semantic identity carries no identity binding, so the representation cannot be joined on the canonical key and is unusable. Split out of `SEMANTIC_MODEL_047` because it is the *cause* of the key, expression and attribute failures reported against that representation, and validation promotes it to the head of the report. |
| `SEMANTIC_MODEL_061` | error | A metric is based on one entity but aggregates a fact belonging to another. The fact's expression is rendered against the base entity's source without joining its own, so the metric compiles to SQL that references an alias it never joins — `STATUS = OK` and a runtime `object ... not found`. Both directions fail this way, so it is not about fan-out safety: a metric's declared grain and its inputs' grain must be the same entity. |
| `SEMANTIC_MODEL_062` | error | A catalog row's `MODEL_ID` disagrees with the model its `VERSION_ID` belongs to. `MODEL_ID` is denormalised onto 29 tables because almost every read filters by model, so the invariant is held up only by every writer passing both columns consistently — Exasol's foreign keys are declared `DISABLE`, and cannot catch it. A row filed under the wrong model is read by neither. The rule derives its table list from `EXA_ALL_COLUMNS`, so a new catalog table carrying both columns is checked from the day it is added. |
| `SEMANTIC_MODEL_063` | error | A binding whose expression is a literal `NULL` carries role `PREFER` while another representation binds real data for the same attribute. The placeholder is how a caller says *this source does not have the column* — `ADD_DIMENSION_WITH_BINDINGS` takes the primary's expression from `EXPRESSION`, so surfacing an attribute only a supplemental source carries means writing `CAST(NULL AS …)` there. The compiler picks a whole representation per entity and prefers the candidate needing the fewest `FALLBACK` bindings, so a `PREFER` placeholder wins and every row returns `NULL` on a model that otherwise validates, publishes and answers `STATUS = OK`. Each binding is individually well-formed; the pair is the defect. An attribute whose bindings are *all* placeholders is a stub, not a wrong answer, and is not flagged. |
| `SEMANTIC_MODEL_064` | error | A representation reads a base table directly while the model runs in `GOVERNED` mode, where every representation must resolve through a view that can carry row and column policy. |
| `SEMANTIC_MODEL_065` | error in `GOVERNED`, warning otherwise | A materialization reads relations none of the model's representations read. Substituting it drops whatever row or column policy those representations carry, silently and for every caller — a rollup over the raw mart returned every region to a principal entitled to one. |
| `SEMANTIC_MODEL_066` | error in `GOVERNED`, warning otherwise | The transitive base relations of a representation or materialization cannot be resolved, so its trust class is unknown. A virtual-schema relation, or a view whose dependencies Exasol does not record, will do this. |
| `SEMANTIC_MODEL_067` | warning | Views compiled from this model are frozen: they answer with the model as it was when each was made, for anyone granted them, with no preprocessor. Whether any still matches what the model would compile today **cannot be answered from the catalog** — the version never changes, `MODELS.UPDATED_AT` does not move on authoring, and `METRICS`/`DIMENSIONS`/`FACTS` carry no timestamps. The notice names `CHECK_FROZEN_VIEWS`, which recompiles each one and answers exactly. It clears when the views are dropped. |
| `SEMANTIC_MODEL_068` | error in `GOVERNED`, warning otherwise | A view compiled from this model reads a relation the model no longer vouches for: retired, or diverged from the representations it substitutes for. The view keeps answering for every principal granted it, without the policy those representations carry. Whether a frozen view still matches what the model *compiles* is a separate, exact question answered by `SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS`. |
| `SEMANTIC_MODEL_069` | warning | `DISPLAY_POLICY` holds a value this layer does not apply. The only value with an effect is `MASK`, which withholds the field from results while still permitting filters on it. A policy nobody applies is worse than none, because the vocabulary reads like a control. For a value that is only meant to inform, use `SENSITIVITY_LABEL`, which is a hint and is documented as one. |
| `SEMANTIC_MODEL_070` | error | A `COALESCE` or `RECONCILE` attribute is bound on fewer than two representations, so there is nothing to fuse. The message names the representations that *were* counted, because the catalog can show rows the validator does not count: a binding is counted only when its `STATUS` is `ACTIVE`, it sits on the model's active version, and the representation it names is itself `ACTIVE`. Split from `SEMANTIC_MODEL_044`. |
| `SEMANTIC_MODEL_071` | error | A `RECONCILE` attribute does not have exactly one representation that *both* binds it and is declared `AUTHORITATIVE`. An `AUTHORITATIVE` representation carrying no active binding for that attribute does not count, which is why this can fire while `REPRESENTATION_AUTHORITIES` shows exactly one authority; the message names both sets. Split from `SEMANTIC_MODEL_044`. |
| `SEMANTIC_MODEL_072` | error | A dimension, fact or attribute-binding expression does not parse or bind against the relation it is rendered over. The validator runs `SELECT <expression> FROM <source> <alias> WHERE FALSE`, which reads no rows, and reports the database's own error. This is what catches a bare word the static checks cannot see: a string literal missing its quotes, or a reserved word such as `OPEN`. A virtual-schema table is bound against a local stand-in built from its column metadata, so the adapter is never called. Because `ADD_DIMENSION`, `ADD_FACT` and the semantic DDL validate before committing, the expression is refused there; see [Expression binding](#expression-binding). |
| `SEMANTIC_MODEL_073` | error | A dimension, fact or metric declares a `DATA_TYPE` that is not an Exasol data type. The shape is checked first: words, plus parenthesized groups of words, digits and commas. Then the validator runs `CAST(NULL AS <type>)`. `PUBLISH_MODEL` writes this type into the published view, so without this check it was the first place to refuse (`SEMANTIC_SURFACE_005`). The usual cause is a clause the DDL parser used to absorb into `RETURNS`, such as `DECIMAL(18,2) UNIT 'kg'`. |
| `SEMANTIC_REQUEST_028` / `SEMANTIC_QUERY_028` | refusal | The model runs in `GOVERNED` mode and the SQL for this request reads a relation the model does not vouch for — `DIVERGENT`, `UNKNOWN`, or not classified since the relation set last changed. Answering would return rows the caller may not be entitled to, because the relation does not necessarily carry the row or column policy the representations carry. `RAW` is deliberately not refused: a materialization built *from* the governed views is a table, so it classifies `RAW` while carrying their policy, and refusing it would make the mode unusable with any pre-aggregate. |

## Metric Grain Versus Object Root

A metric aggregates at its **base entity's** grain. The object root decides the
grain that aggregate is evaluated at. Those are two different questions, and
passing one does not settle the other:

| Question | Direction proven | Rule |
|---|---|---|
| Can the root read an attribute on that entity? | root → entity | `SEMANTIC_MODEL_030` |
| Can an aggregate at that entity be evaluated at the root's grain? | entity → root | `SEMANTIC_MODEL_059` |

Consider a view rooted at `order_line` with a `freight` fact on `order`
(`order_line → order` is `MANY_TO_ONE`):

- **root → leaf is safe.** Each line has exactly one order, so `order`'s columns
  are legitimate line attributes. A dimension on `order` is fine.
- **leaf → root is not.** Several lines share one order, so joining lines to
  orders repeats each order's freight once per line. `SUM(freight)` returns the
  freight multiplied by the line count.

Only the first direction used to be checked, and it was checked through the
metric/dimension matrix — which reports only when some dimension is
incompatible. A view whose dimensions all sat on safe branches, or which had no
dimensions at all, validated clean, published, and returned an inflated number
through both query paths while every agent surface called the metric valid. On
the reference data that is `149` against a truth of `105.25`.

`SEMANTIC_MODEL_059` closes that direction. The remedy is object membership, not
a declaration: `FANOUT_POLICY` records intent for a many-to-many traversal and is
explicitly not an allocation proof, so no relationship declaration makes a
fanning aggregation safe. Expose the metric in a semantic object rooted at the
fact's own entity, or remove it from the object where it fans out.

The mirror-image shape — a metric on a **finer** entity than the root, such as
line revenue in an order-rooted view — is refused by `SEMANTIC_MODEL_030`
instead, because the root cannot safely reach the base at all.

Splitting a model this way has consequences the author meets later and
separately: a dimension cannot be shared between the two views
(`SEMANTIC_ADMIN_019`), a field of one is refused on the other
(`SEMANTIC_QUERY_020`), and the two published views cannot be joined back
together (`SEMANTIC_QUERY_012`). They are set out in one place under
[When a model has to split by grain](creating-metrics.md#when-a-model-has-to-split-by-grain-and-what-it-costs),
because deciding the shape up front is much cheaper than meeting three refusals.

### Why the base entity and not the fact's entity

The test is the metric's own base entity, not the fact entities its dependency
graph bottoms out in. For the **multi-fact** pattern those differ, and testing
the graph's leaves would refuse the very shape that avoids fan-out: a public
`DERIVED` metric based at the root composes private state metrics based at each
sibling fact's own grain, and the planner aggregates each state in its own branch
before joining. `grain_d1`'s `ticket_count` and `payment_total` reach
`ticket_fact` and `payment_fact` across an unsafe edge through the conformed
`customer` dimension, and are correct precisely because nothing is aggregated at
the root's grain. The private state metrics are not checked at all — they are not
exposed columns, and aggregating off-root in a branch of their own is their
purpose.

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
static unsupported-function policy.

### Expression binding

Dimension, fact and attribute-binding expressions are also bound against their
source (`SEMANTIC_MODEL_072`): the validator runs
`SELECT <expression> FROM <source> <alias> WHERE FALSE`. It sends one query per
relation, and one per expression only when that query fails. So invalid syntax,
an unquoted literal, and an unknown bare identifier are refused before
publication, instead of compiling to `STATUS = OK` and failing when the query
runs.

A virtual-schema table is not queried, not even with `WHERE FALSE`. That query
would still go through the adapter's pushdown, which costs a remote round trip
and fails while the remote is down. The expression is bound instead against a
local stand-in with the same column names and types, taken from
`EXA_ALL_COLUMNS`:
`SELECT <expression> FROM (SELECT CAST(NULL AS <type>) AS "<column>", …) <alias> WHERE FALSE`.
That catches the same parse and bind errors without leaving the database. If
the stand-in cannot be built (no column metadata) or does not bind on its own,
the expression is not reported.

Two kinds of expression are not probed: metric expressions and filters, and
identity expressions. For those, the static checks are the only gate, and
dialect-specific syntax can still pass them and fail when rendered.

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

## Fanout Policy

`FANOUT_POLICY` is a column on `SYS_SEMANTIC.RELATIONSHIPS`, set through the
eighth argument of `SEMANTIC_ADMIN.ADD_RELATIONSHIP`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales', 'order_to_shipment', 'order', 'shipment',
  'o.order_id = s.order_id', 'MANY_TO_MANY', 'LEFT', 'REFERENCE_ONLY');
```

`SEMANTIC_ADMIN.SET_RELATIONSHIP` changes it on an existing relationship, and
`'NONE'` there clears the column.

It is a closed set, matched case-insensitively and stored upper-case:

| Value | Meaning |
|---|---|
| `REFERENCE_ONLY` | The relationship exists for navigation, lineage, and documentation. Metric attribution across it is not intended. |
| `DEDUPLICATE` | Intent: attribute a measure once per base-entity key, however many partners it matches. Reserved; no planner implements it. |
| `ALLOCATE` | Intent: split a measure across the partners it matches. Reserved; no planner implements it, and the weights are not modeled. |

**No value authorizes traversal.** The policy records what a modeler intends a
planner to do if the technique is ever proven; it is not an allocation proof, so
a many-to-many edge stays unsafe in both proof modes whatever the policy says
(see [Three grains, kept distinct](glossary.md#three-grains-kept-distinct)).
A relationship whose declared cardinality is not `MANY_TO_MANY` gains nothing
from a policy either: traversal against the declared direction is refused as
`ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED` with or without one.

Enforcement is split so that tightening the set does not break stored models:

- `ADD_RELATIONSHIP` refuses an unrecognized value on write with
  `SEMANTIC_ADMIN_003`, the same way it refuses an unrecognized cardinality or
  join type. Semantic DDL and OSI import write through the same script, so they
  inherit the check.
- `VALIDATE_MODEL` reports `SEMANTIC_MODEL_053` as a **warning** for a row that
  predates the check, or for a policy declared on a cardinality where it means
  nothing. The model stays valid; the value is recorded and carries no meaning.
- `SEMANTIC_MODEL_010` still requires *some* policy on a many-to-many
  relationship. The requirement is a declaration of intent, not an
  authorization: it makes the modeler state what the fanning relationship is
  for.

The remedy for a rejected pair is never a policy — it is object membership.
Expose a metric only alongside dimensions reachable from its base entity
without fan-out, in the same or a separate semantic object. `SEMANTIC_MODEL_030`
spells this out in its message.

## Metric Plannability

Validation classifies every active metric with the planner's own code and
rejects a metric the compiler could never plan. Two shapes used to validate
clean, publish, be reported `VALID` by every agent surface, and fail only when
someone queried them — taking `SELECT *` on the whole object with them:

| Shape | Code | Why it cannot compile |
|---|---|---|
| `COUNT(*)` | `SEMANTIC_MODEL_056` | No fact input, so the aggregate has no grain (`METRIC_INPUT_GRAIN_MISSING`) |
| One aggregate over facts from several entities | `SEMANTIC_MODEL_056` | Undefined input grain (`METRIC_INPUT_GRAIN_AMBIGUOUS`) |
| `AVG` on an F3-partitioned entity | `SEMANTIC_MODEL_057` | Partitions merge aggregate states; `AVG` has none |
| `AVG` over facts from several entities | `SEMANTIC_MODEL_057` | Multi-entity metrics merge states |

A row count needs something to count. Both supported forms are exact:

```sql
FACT   line_one   ON ENTITY order_line AS 1 ...
METRIC line_count AS SUM(line_one)     ...   -- sum a literal fact
METRIC line_count AS COUNT(net_revenue) ...  -- count a non-null fact
```

Non-mergeable aggregates stay valid where the single-branch renderer can
compile them: `AVG` on an unpartitioned single-fact entity is accepted, and a
`RATIO` of two mergeable metrics (`total / NULLIF(count, 0)`) is exact on a
partitioned entity. The gate judges each metric alone — a metric that cannot be
planned by itself can never be queried, while a *combination* that only fails
together stays a request-time concern.

The rule re-runs on every validation, so it also catches the reverse order:
declaring F3 coverage on an entity that already carries a non-mergeable metric
is refused by the mutation that would otherwise complete the partitioning.

## Path Ambiguity

Two entities can be connected by more than one safe relationship path. The paths
are not interchangeable: each attributes a row of the source entity to a
possibly different row of the target, so the path decides the number.

How a model is treated depends on the shape of the ambiguity, and on the proof
mode:

| Shape | Default `LEGACY_JOIN` | `STRICT_GRAIN` |
|---|---|---|
| One safe path | Compiles. | Compiles. |
| Several safe paths of **equal** length | Refused at authoring time: `SEMANTIC_MODEL_030` / `AMBIGUOUS_RELATIONSHIP_PATH`, so no query compiles. | Refused: `RELATIONSHIP_PATH_AMBIGUOUS`. |
| Several safe paths of **differing** length | Compiles using the shortest, and reports the choice: `SEMANTIC_MODEL_055` at authoring time, a `RELATIONSHIP_PATH_ALTERNATIVES` plan warning at compile time. | Refused: `RELATIONSHIP_PATH_AMBIGUOUS`. |

A tie is an error because nothing distinguishes the candidates. A differing
length is a warning, not an error, because the shortest path is a defensible
default — a denormalized shortcut edge alongside the long way round is a common
and harmless shape — while the engine cannot tell that case apart from two
genuinely different roles. It reports the choice rather than deciding quietly on
the modeler's behalf, and `STRICT_GRAIN` refuses to choose at all.

Length is the whole of the selection rule. `PATH_PRIORITY` orders relationship
traversal deterministically but does **not** select between candidate paths in
either proof mode, so neither message offers it as a remedy. The remedies that
do exist are to remove the redundant relationship, or to model the paths as
separate entities with their own dimensions, so each role is named.

Both messages name the selected path and each path not selected. The compile
plan additionally carries the full candidate list on the relationship proof:

```json
"warnings": [{
  "code": "RELATIONSHIP_PATH_ALTERNATIVES",
  "severity": "WARNING",
  "target_entity": "beta",
  "selected_path": "fact_to_beta",
  "selection_reason": "SHORTEST_SAFE_PATH",
  "candidate_paths": ["fact_to_beta", "fact_to_alpha > alpha_to_beta"],
  "alternate_paths": ["fact_to_alpha > alpha_to_beta"]
}]
```

The enumeration behind this is bounded (path length, candidate count, and work
done). A search that hits a cap sets `candidate_search_truncated` on the
relationship proof, so a plan never reports "no alternative" from a walk that
stopped early. The caps are far above any realistic relationship graph.

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

Validation also rejects a pair whose dimension entity carries F3 temporal
coverage while the metric is based somewhere else
(`FUSION_PARTITION_DIMENSION_UNSUPPORTED`). F3 merges aggregate states across
partitions of a *metric-leaf* entity; reached as a joined dimension, the same
entity has no defined attribution, and the compiler refuses every such request
(`SEMANTIC_REQUEST_074`). Declaring coverage on an entity that another object
reaches this way used to leave that object's published dimensions permanently
unqueryable with no validation error at all.

The same rejection applies when the partitioned entity is not where the
dimension lives but somewhere on the **proven join path** to it
(`FUSION_PARTITION_JOIN_UNSUPPORTED`). That case was invisible for as long as the
rule was keyed on the dimension's own entity: for

```
order_line --INNER--> order (F3 hot/cold) --LEFT--> customer
```

a line-grain metric grouped by a customer attribute validated clean, published,
and returned the primary partition's subtotal as the whole — 43 700.32 of a true
412 907.22 on the study fixture — because F3 expands partitions for a metric leaf
only and `order` is merely traversed here. The plan recorded
`fusion_strategy = UNION` with two partitions next to SQL that read one table.
Keying on the path covers both shapes, since a dimension's own entity is the last
node of its path. The remedy is the same: expose the dimension alongside metrics
based at the partitioned entity, or drop the coverage declarations.

Validation accepts same-entity pairs and non-fanout relationship paths. It
rejects paths that fan out: traversing from the one-side to the many-side of a
relationship (`ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED`), and any many-to-many
traversal (`MANY_TO_MANY_UNSUPPORTED`). Both reason codes name the cardinality
that blocks the walk, because neither has a remedy at the relationship level. A
declared `FANOUT_POLICY` records modeler intent for a many-to-many relationship;
it is not an allocation proof and does not make the edge traversable in either
proof mode (see [Fanout policy](#fanout-policy)). The remedy is object
membership: expose a metric only alongside dimensions reachable from its base
entity without fan-out, which is what `SEMANTIC_MODEL_030`'s message spells
out.

For rejected connected pairs, `RELATIONSHIP_PATH` contains the attempted path
and annotates unsafe edges with their reason, for example `line_to_order >
shipment_to_order (rejected: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED)`. The compiler
refuses the same traversal with `SEMANTIC_REQUEST_042` and the same annotated
path.
`NO_SAFE_JOIN_PATH` means no semantic-object root can reach the metric base
without traversing from the one-side to the many-side of a relationship. This
prevents attributing one fact row to multiple dimension rows; see
[Three grains, kept distinct](glossary.md#three-grains-kept-distinct).
Declare a semantic object rooted at the metric's base entity to establish that
branch grain, or remove the metric from the incompatible object.

`RELATIONSHIP_PATH` for a valid pair contains the single path the compiler will
use. When more than one safe path connects the pair, that column still holds one
path — the selected one — and the choice is reported separately; see
[Path ambiguity](#path-ambiguity).

## Test Coverage

Run the smoke suite:

```sh
PYTHON_BIN=python3 sh tools/run_smoke.sh
```

The smoke now verifies:

- valid sales model has no validation errors
- sales metric/dimension matrix has 35 valid rows and one deliberately invalid
  pair: `total_freight` x `product_category`, which no policy can make safe
  (`tools/verify_fanout_guardrails.py`)
- metric dependencies are extracted into `METRIC_DEPENDENCIES`
- missing source object returns `SEMANTIC_MODEL_001`
- invalid metric dependency returns `SEMANTIC_MODEL_011`
- cyclic metric dependency returns `SEMANTIC_MODEL_012`
- many-to-many without a declared fanout policy returns `SEMANTIC_MODEL_010`,
  and an unrecognized or misplaced policy value warns with `SEMANTIC_MODEL_053`
- a visible metric/dimension pair that needs a many-to-many edge returns
  `SEMANTIC_MODEL_030` with reason `MANY_TO_MANY_UNSUPPORTED`, and the compiler
  refuses the same request (`tools/verify_many_to_many_refusal.py`)
- ambiguous certified synonym returns `SEMANTIC_MODEL_021`
- stale verified query references return `SEMANTIC_MODEL_023`
- invalid OSI extension scope or JSON returns `SEMANTIC_MODEL_026` or
  `SEMANTIC_MODEL_027`
- invalid unique-key metadata returns `SEMANTIC_MODEL_028` or
  `SEMANTIC_MODEL_029`
