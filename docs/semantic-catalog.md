# Semantic Catalog

Catalog schemas:

- `SYS_SEMANTIC`: authoritative semantic metadata tables.
- `SEMANTIC_CATALOG`: read-only metadata views for humans and tools.
- `SEMANTIC_AGENT`: role-scoped machine-readable context views for agents.
- `SEMANTIC_ADMIN`: Lua admin and compiler scripts.

Milestones 1 through the SQL-native metric definition work include
Exasol-compatible DDL for the catalog tables,
initial catalog views, validation run storage, validation issue storage, the
metric/dimension validity matrix, structured compiler scripts, SQL compiler
wrapper, guarded published views, SQL preprocessor, agent context views, agent
feedback tables, the manual materialization registry, SQL-native metric
definition sources, metric input metadata, metric filter metadata, and
introspection views. Apache Ossie / OSI import/export foundation metadata adds
generic custom extensions and entity unique-key metadata for lossless round
trips.

## Install Files

Run the installer to apply all catalog files in order:

```sh
python3 tools/install.py
```

The installer packages the Lua runtime and runs these seven files in sequence:

```text
sql/install/000_create_schemas.sql
sql/install/001_create_semantic_catalog.sql
sql/install/002_create_semantic_catalog_views.sql
sql/install/003_create_semantic_admin_scripts.sql
sql/install/004_create_semantic_preprocessor.sql
sql/install/005_create_semantic_surface_helpers.sql
sql/install/006_create_semantic_agent_views.sql
```

The catalog avoids unsupported Exasol `CHECK` and generic `UNIQUE` constraints.
Semantic uniqueness and allowed values are enforced by Lua admin scripts.

## Entity Representations

Phase F0 separated semantic entities from their physical source bindings through
`SYS_SEMANTIC.ENTITY_REPRESENTATIONS`. `ADD_ENTITY` creates one active
`PRIMARY` representation automatically, and installation backfills one for
every existing entity. `VALIDATE_MODEL` rejects active entities that do not
have exactly one active primary representation.

Phase F1 allows additional active `ALTERNATE` representations for the same
entity. Without F2 bindings, selection remains manual and static:
`SET_PRIMARY_REPRESENTATION` chooses the single source used by every compile.
The grain-metadata assistant and semantic-definition export resolve source
schema, object, and alias through the primary representation.
The corresponding columns on `SYS_SEMANTIC.ENTITIES` remain mandatory and are
kept as compatibility mirrors, including after promotion.

Manage the F1 lifecycle through:

```text
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE
SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE
SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH
SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION
SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION
```

F1 supports `RELATION` and `VIRTUAL_SCHEMA` sources. All active representations
must expose the same semantic alias and every column used by attributes that
have only a compatibility-default binding, filters, unique keys, and
relationship mappings. Adding, promoting, or removing
a representation clears compile cache entries and marks successful validation
runs stale. Validate before promotion, then validate and publish after it.
Promotion does not rely on that current-state result alone: before changing
roles it verifies that the target physically exposes every declared unique-key
column and that any F5.1 relationship-key identity is a bare `DIRECT` binding
to the canonical key. A cast-bound alternate therefore remains usable for
routing but is rejected as primary with `SEMANTIC_ADMIN_058`. A prior clean run
marked `STALE` remains valid recovery evidence only while the current primary
fails those canonical-anchor checks, so an older trapped promotion can be
reversed without allowing unrelated stale state to authorize promotion.
Validation executes data probes for every declared unique key: each
representation must preserve key uniqueness, and every alternate must have the
same key cardinality and bidirectional key set as the primary. Multiple
representations without a declared key fail validation. Probe errors also fail
closed, so the validating user must be able to query every representation.
F3 partitioned entities are the exception to key-set equality: validation
proves uniqueness within each certified non-overlapping partition instead.
These full key scans and set comparisons can be expensive for large or remote
sources. Validation runs them only after local catalog validation is clean and
caches each representation's key cardinality once per key; exact bidirectional
set comparisons still run for every alternate. They never run during compiled
business queries.

Set a bounded timeout before validating any entity with multiple active
representations:

```sql
ALTER SESSION SET QUERY_TIMEOUT=60;
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

Validation does not attempt to classify sources as local or federated. Views
can hide Virtual Schema dependencies at arbitrary depth, and local scans can
also be expensive. Every multi-representation F1/F3 key probe is refused when
the session timeout is unlimited or greater than 60 seconds. Exasol applies
`QUERY_TIMEOUT` to the complete `EXECUTE SCRIPT`, including nested federated
statements; a script cannot lower its own active timeout.

Without an F5 semantic identity, identity and relationship metadata remains
representation-invariant. Primary-key expressions, unique-key columns,
relationship key mappings, join conditions, and representation-blind metric
filters must resolve against the same case-sensitive physical column names in
every representation. F2 attribute bindings cannot repair those differences.
F5 can map one scalar source-local entity key per representation; it does not
rewrite relationship SQL or arbitrary filter columns.

Phase F2 separates semantic dimensions and facts from their source expressions
through `SYS_SEMANTIC.ATTRIBUTE_BINDINGS`. `ADD_DIMENSION` and `ADD_FACT`
automatically create a `PREFER` binding on the current primary representation;
installation backfills the same binding for existing attributes. Additional
bindings are managed with:

```text
SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING
SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING
```

Compatibility defaults have `IS_DEFAULT = TRUE`. Promoting a representation
moves a default only when the incoming representation has no explicit binding
for that attribute, so pre-F2 models retain static-primary behavior without
overriding representation-specific expressions. Explicit bindings have
`IS_DEFAULT = FALSE` and never move during promotion. The promotion script
also repairs stale default/explicit collisions produced by older F2 installs
before checking the validation gate, allowing a trapped model to promote back.

At compile time, F2 chooses one active representation per required entity. A
candidate must bind every requested dimension and every fact used transitively
by requested metrics. Candidates are ordered by `PREFER` before `FALLBACK`,
then binding priority, `PRIMARY` role, representation priority, and
representation ID. Promotion therefore controls otherwise-equivalent complete
candidates without overriding an intentional binding-role or binding-priority
fallback. This is deterministic source fallback, not row-level `COALESCE`:
values from different representations are never combined. If no representation
covers the complete attribute set, compilation fails with
`SEMANTIC_REQUEST_080`.

Binding expressions are validated against only their target representation.
Binding creation is baseline-aware because renamed-column representations can
be temporarily invalid while several bindings are authored. The admin script
accepts a candidate when post-application validation introduces no new error
signature; malformed candidates are rolled back. Existing errors continue to
block publication until subsequent bindings resolve them.

The selected representation, reason, expressions, roles, and priorities are
recorded in `plan_json.selected_representations[].selected_bindings`.

### F3 Temporal Partition Fusion

F3 combines hot/cold representations of a metric-leaf entity. Configure each
active representation with `SET_REPRESENTATION_COVERAGE`. The predicate is SQL
executed against that representation and must use one qualified temporal column
under its stable entity alias. It is certifiable only in canonical half-open
form: `column >= VALID_FROM` and `column < VALID_TO`, omitting the comparison
whose bound is `NULL`. Timestamp literals must exactly match the corresponding
validity metadata. Free-form predicates are rejected because independent SQL
and interval declarations cannot prove the rows are disjoint and complete.
Once the model has active metrics, `VALIDATE_MODEL` also requires every
partitioned entity to be the base entity of at least one of them. Coverage on an
entity used only to supply joined dimensions fails `SEMANTIC_MODEL_043`,
preventing publication of a model whose existing dimension queries would be
rejected at compile time. An empty model may still add its first metric during
incremental authoring; that metric must satisfy the rule or validation fails.

Every active representation of the entity must participate. The first interval
must have `VALID_FROM = NULL`, the last must have `VALID_TO = NULL`, and every
adjacent `VALID_TO`/`VALID_FROM` boundary must be equal. Together with canonical
predicate validation, this proves the predicates executed by `UNION ALL` are
complete, contiguous, and non-overlapping. Passing `NULL` for predicate and both
bounds clears a declaration.

For a model whose status is `PUBLISHED`, coverage changes are validated as
candidates. Use `SET_REPRESENTATION_COVERAGE_BATCH` when starting, clearing, or
repartitioning F3: it requires exactly one declaration for every active
representation, applies the complete set before validating, and retains it only
when the assembled model is valid. On error it restores every previous
predicate and bound, revalidates the restored catalog, and returns
`SEMANTIC_ADMIN_059`. Use the single-row call only for a change that leaves an
already-complete coverage set valid by itself.

If a genuine hot/cold source is not registered yet, ordinary
`ADD_ENTITY_REPRESENTATION` may fail published F1 key-set equality before
coverage can be declared. Use `ADD_ENTITY_REPRESENTATION_WITH_COVERAGE` with
the new source and the complete coverage JSON set. It stages the representation,
creates explicit dimension/fact bindings from the governed legacy expressions,
and applies all coverage as one candidate. A failed candidate removes the
representation and generated bindings and restores the prior certification.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE(
  'sales', 'order', 'lakehouse',
  'o.order_ts < TIMESTAMP ''2026-01-01 00:00:00''',
  NULL, TIMESTAMP '2026-01-01 00:00:00'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE(
  'sales', 'order', 'primary',
  'o.order_ts >= TIMESTAMP ''2026-01-01 00:00:00''',
  TIMESTAMP '2026-01-01 00:00:00', NULL
);
```

When configuring an existing published model, submit those declarations as one
JSON array instead:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH(
  'sales', 'order',
  '[{"representation_name":"lakehouse",'
  || '"coverage_predicate":"o.order_ts < TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":null,"valid_to":"2026-01-01 00:00:00"},'
  || '{"representation_name":"primary",'
  || '"coverage_predicate":"o.order_ts >= TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":"2026-01-01 00:00:00","valid_to":null}]'
);
```

Validation still proves unique-key grain independently on every partition, but
does not require key-set equality because temporal partitions are expected to
contain different identities. Compilation requires every requested dimension
and transitive metric fact to have a binding on every partition. It supports
mergeable `SUM` and `COUNT` aggregate states and records all partitions under
`selected_representations[].partitions` and `physical_plan.fusion_plan`.
Partitioned joined dimensions and materialization substitution are not supported
in F3; both remain explicit, fail-closed boundaries.

### F4 Authority And Reconciliation

F4 adds row-level value fusion for dimensions and facts whose representations
already satisfy F1 identity equivalence. Configure source precedence and the
attribute operation with:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
  'customer_360', 'customer', 'mdm', 'AUTHORITATIVE'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
  'customer_360', 'customer', 'crm', 'SUPPLEMENTAL'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY(
  'customer_360', 'DIMENSION', 'customer_name', 'RECONCILE'
);
```

`PREFER` retains F2 single-source behavior. `COALESCE` fills null values from
ordered equivalent representations, but validation rejects any overlapping key
whose non-null values conflict (`SEMANTIC_MODEL_045`). `RECONCILE` uses the
single bound `AUTHORITATIVE` representation first and permits conflicting
non-null values, reporting the number resolved as `SEMANTIC_MODEL_046`.
Authority ordering is `AUTHORITATIVE`, `PREFER`, then `SUPPLEMENTAL`, followed
by binding and representation priority.

F4 requires active bindings on at least two representations and either a
physical-column unique key shared by every representation or a complete F5
semantic identity. Validation proves unique grain and exact canonical key-set
equivalence before checking value conflicts. F3 partition `UNION` and F4
attribute reconciliation cannot be enabled on the same entity. Conflict probes
obey the same session `QUERY_TIMEOUT` gate as F1/F3 probes.

Compilation keeps the selected representation as the entity relation and uses
key-preserving `LEFT JOIN`s for alternate values. Validated uniqueness prevents
fanout. The generated
`COALESCE` expression and each contributor's binding, authority, source, and
expression appear in
`plan_json.selected_representations[].selected_bindings[].fusion_contributors`.
Materialization substitution is bypassed while reconciliation is active, and
multi-fact branch requests fail closed; use a canonical pre-reconciled source
for those shapes.

The read-only representation view is available as:

```text
SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS
SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS
SEMANTIC_CATALOG.REPRESENTATION_AUTHORITIES
SEMANTIC_CATALOG.ATTRIBUTE_FUSION_POLICIES
```

### F5 Identity Graph

F5 lets one entity use different scalar keys in different systems without
fuzzy runtime matching. Declare one model-global semantic identity name, bind
each active representation's source-local expression, and use a certified
two-column mapping relation where a local value is not already the semantic
key:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY(
  'customer_360', 'customer', 'customer_identity', 'GLOBAL',
  'DECIMAL(18,0)', 'Certified customer identity'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'primary',
  'c.customer_id', 'DIRECT'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'crm',
  'c.account_id', 'MAPPED'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION(
  'customer_360', 'customer_identity', 'crm',
  'IDENTITY_MAP', 'CUSTOMER_XREF', 'ACCOUNT_ID', 'CUSTOMER_ID', 'CERTIFIED'
);
```

The MVP permits one active semantic identity per entity and requires a binding
for every active representation. `DIRECT` means the local expression already
produces the semantic key. `MAPPED` requires one visible, certified relation
whose local and semantic columns are non-null and one-to-one. Validation proves
local expression uniqueness, mapping totality, bijection, and exact canonical
key-set equality with the primary. Incomplete, ambiguous, uncertified, or
probabilistic mappings fail closed as `SEMANTIC_MODEL_047` to `_049`.

F4 compilation joins contributors on the semantic key. Mapped contributors are
joined through the certified relation, and the plan records semantic identity,
binding, and mapping IDs. Mapping is deterministic and validation-time
certified; the compiler never performs fuzzy matching. Composite identities,
general relationship remapping, F3 identity mapping, and multi-fact
reconciliation are not supported in F5. The scalar `DIRECT` F5.1 exception is
described below.

F5.1 routes relationships through scalar `DIRECT` identity bindings. No new
declaration is required: the structured relationship endpoint must match one
declared scalar unique key, and the primary identity binding must be exactly
that key column. An alternate `DIRECT` binding may use a deterministic
expression such as `CAST(c."customer_id" AS DECIMAL(18,0))`; when its source
lacks the canonical relationship column, compilation substitutes that
expression on the endpoint.

Validation reports `_050` when a relationship remains usable but excludes some
representations. Request planning evaluates only relationships traversed by the
request, removes incompatible candidates, and returns `_080` naming the
relationship and side only when no complete candidate remains. Successful plan
JSON records `relationship_identity_remaps`; candidate degradation records
`relationship_candidate_rejections`. Models that need no remap retain their
existing SQL and omit both fields.

`MAPPED` relationship endpoints still require a canonical source view. They
need a bounded foreign-key referential-coverage proof beyond F5's identity-set
proof. Composite endpoints, expression-valued relationship mappings, and
identity bindings not anchored to the mapped unique key also fail closed.

Read-only metadata is exposed through:

```text
SEMANTIC_CATALOG.SEMANTIC_IDENTITIES
SEMANTIC_CATALOG.IDENTITY_BINDINGS
SEMANTIC_CATALOG.IDENTITY_MAPPING_RELATIONS
```

F5 declarations are reversible, but removal is dependency ordered. Remove each
mapped binding's relation first, then every identity binding, and finally the
semantic identity:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION(
  'customer_360', 'customer_identity', 'crm'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'crm'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'primary'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY(
  'customer_360', 'customer', 'customer_identity'
);
```

The APIs refuse out-of-order removal. `REMOVE_ENTITY_REPRESENTATION` also
refuses a representation with an active identity binding; it never silently
withdraws identity governance. After the final identity removal, F3 coverage
may be declared for the entity. Every removal clears compile cache entries and
marks successful validation runs stale, so validate after the complete
transition.

## Validation Tables

- `VALIDATION_RUNS`: one row per `VALIDATE_MODEL` execution.
- `VALIDATION_RESULTS`: structured validation issues with stable rule codes.
- `METRIC_DIMENSION_MATRIX`: query-time lookup for whether a metric can be
  grouped or filtered by a dimension.

The public views are available as:

```text
SEMANTIC_CATALOG.VALIDATION_RUNS
SEMANTIC_CATALOG.VALIDATION_RESULTS
SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX
```

`VALIDATION_RESULTS` is a history table. Use
`CURRENT_VALIDATION_ISSUES` when an admin, agent, or dashboard needs the issues
from the latest validation run only.

## Apache Ossie / OSI Import/Export Metadata

Milestone 1 adds catalog tables used by future Ossie/OSI import/export tooling:

- `CUSTOM_EXTENSIONS`: raw vendor extension payloads keyed by model version,
  scope type, scope id, vendor name, extension name, and source format.
- `UNIQUE_KEYS`: optional entity-level key definitions imported from Ossie/OSI
  or preserved for later Ossie/OSI export.
- `UNIQUE_KEY_COLUMNS`: ordered source columns or expressions that make up a
  unique key.
- `RELATIONSHIP_KEY_MAPPINGS`: ordered source-column or expression pairs that
  identify the two endpoints of a relationship without parsing
  `JOIN_CONDITION`.

The public views are available as:

```text
SEMANTIC_CATALOG.CUSTOM_EXTENSIONS
SEMANTIC_CATALOG.UNIQUE_KEYS
SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS
SEMANTIC_CATALOG.RELATIONSHIP_KEY_MAPPINGS
```

Extension payloads intentionally remain raw JSON strings. This matches Ossie
`custom_extensions[].data`, which is a JSON string rather than a nested object.
`VALIDATE_MODEL` checks that the payload parses as JSON and that its scope
points to an existing model, semantic object, entity, relationship, dimension,
fact, or metric.

Use the admin helpers instead of direct DML:

```text
SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION
SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS
SEMANTIC_ADMIN.DROP_MODEL
SEMANTIC_ADMIN.ADD_UNIQUE_KEY
SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN
SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS
SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_COLUMN
SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY
SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING
SEMANTIC_ADMIN.SUGGEST_GRAIN_METADATA
```

`DROP_MODEL(model_name)` removes one model's catalog and runtime history. It
drops the published schema only when no other model references that schema and
the schema is not protected; physical source schemas are never removed.

`ADD_CUSTOM_EXTENSION` accepts non-Exasol vendor names without interpretation,
so import/export can preserve third-party Ossie/OSI extensions. `ADD_UNIQUE_KEY`
accepts `PRIMARY`, `UNIQUE`, and `ALTERNATE` key kinds. Unique key columns can
store either a simple source column name or a native expression, but not both.
Relationship mappings follow the same rule independently for each endpoint.
They are optional for legacy single-branch compilation but required for
grain-aware relationship proofs.

On a published model, use `ADD_UNIQUE_KEY_WITH_COLUMNS` for a new key. Its JSON
array contains ordered objects with `column_name` or `expression` and optional
`ordinal_position`; all components are inserted before one validation. The
sequential `ADD_UNIQUE_KEY` then `ADD_UNIQUE_KEY_COLUMN` form remains suitable
for drafts, but its empty intermediate key is invalid on a published model.

Every key or relationship-mapping mutation deletes the affected model
version's compile-cache entries and marks its earlier successful validation
runs `STALE`. Run `SEMANTIC_ADMIN.VALIDATE_MODEL` after completing a related
set of changes.

Remove a key in dependency order: call `REMOVE_UNIQUE_KEY_COLUMN` for every
component, then `REMOVE_UNIQUE_KEY`. The latter refuses keys that still have
columns. On a published model, key additions, updates, and removals are
prospective: a candidate that introduces a validation error is restored and
re-certified before returning `SEMANTIC_ADMIN_094`.

`SUGGEST_GRAIN_METADATA(model_name)` is dry-run only. It proposes a one-column
primary key when a legacy `PRIMARY_KEY_EXPR` is exactly `alias.column`, and a
one-column relationship mapping when `JOIN_CONDITION` is exactly one equality
between the endpoint aliases. It does not canonicalize expressions, infer
composite keys, execute admin helpers, or change the catalog. Review its
`PROPOSED_METADATA_JSON` before applying anything.

## SQL-Native Metric Definition Metadata

SQL-native metric definitions are persisted in catalog tables instead of YAML
or external files:

- `SEMANTIC_DEFINITION_SOURCES`: original Semantic SQL, normalized JSON,
  definition hash, apply status, and validation run.
- `METRIC_INPUTS`: structured fact and metric inputs with roles such as
  `MEASURE`, `NUMERATOR`, and `DENOMINATOR`.
- `METRIC_FILTERS`: semantic filters, resolved SQL filters, and required filter
  dimensions.
- `CALCULATION_GROUPS` and `CALCULATION_ITEMS`: future calculation item
  metadata, using `DISPLAY_ORDER` for deterministic ordering.

Human-oriented views:

- `SEMANTIC_CATALOG.METRIC_OVERVIEW`
- `SEMANTIC_CATALOG.METRIC_LINEAGE`
- `SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS`
- `SEMANTIC_CATALOG.METRIC_FILTER_OVERVIEW`
- `SEMANTIC_CATALOG.SEMANTIC_DEFINITION_SOURCE`
- `SEMANTIC_CATALOG.MODEL_EVOLUTION_SUGGESTIONS`
- `SEMANTIC_CATALOG.MODEL_EVOLUTION_REVIEWS`

## Governed Model Evolution

F7 keeps agent inference outside the deterministic query path. Agents can
propose `NEW_CONCEPT`, `NEW_IDENTITY`, `REPRESENTATION_EQUIVALENCE`,
`AUTHORITY_CHANGE`, or `DRIFT_REPAIR` changes:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION(
  'sales', 'DRIFT_REPAIR', 'ENTITY', 'orders',
  '{"source_column":"ORDER_STATUS","observed_type":"VARCHAR(40)"}',
  'Source metadata differs from the last reviewed model.'
);
```

Proposals are pinned to the model's active version and duplicate pending
payloads are idempotent. They do not change model metadata. A human reviewer
records the decision separately:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION(
  <suggestion_id>, 'CERTIFIED', 'Source owner confirmed the change.'
);
```

The other terminal decision is `REJECTED`. A decision is one-way, review notes
are retained in `MODEL_EVOLUTION_REVIEWS`, and stale proposals cannot be
certified after the active version changes. `CERTIFIED` means the proposal may
be implemented; it does not activate it. Apply the reviewed change through the
normal admin DDL, then validate and publish. The compiler does not read either
evolution table.

## Materialization Registry

- `MATERIALIZATIONS`: active model-version materialized aggregates and their
  physical Exasol relation.
- `MATERIALIZATION_COLUMNS`: mapping from materialized columns to semantic
  dimensions and metrics with explicit rollup policy.

Materializations are registered through Lua admin scripts, not direct catalog
DML:

```text
SEMANTIC_ADMIN.REGISTER_MATERIALIZATION
SEMANTIC_ADMIN.ADD_MATERIALIZATION_COLUMN
SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS
```

The compiler treats this registry as an optimizer input. It never uses a
materialization to make an invalid metric/dimension request valid.
For a multi-fact plan, one registry entry may replace one complete leaf branch
when it maps every required dimension and aggregate-state producer with the
state's merge policy. Producer metrics may be private. A partial or unsafe
entry leaves the entire branch on its already proven base source; branches are
never split across sources.

## Agent Views

Milestone 5 adds role-aware context views in `SEMANTIC_AGENT`. These are the
preferred discovery surface for agents and thin MCP/REST adapters.

Important views:

- `MODELS_FOR_AGENT`
- `OBJECTS_FOR_AGENT`
- `FIELDS_FOR_AGENT`
- `VALID_COMBINATIONS_FOR_AGENT`
- `MEASURE_GROUPS_FOR_AGENT`
- `VERIFIED_QUERIES_FOR_AGENT`
- `INSTRUCTIONS_FOR_AGENT`
- `BUSINESS_GLOSSARY_FOR_AGENT`
- `VALIDATION_ERRORS_FOR_AGENT`
- `COMPILE_REQUEST_SCHEMA_FOR_AGENT`
- `REQUEST_HISTORY_FOR_AGENT`

`FIELDS_FOR_AGENT` includes `FIELD_KIND` and the compatibility alias
`FIELD_ROLE`, plus semantic and resolved SQL filter expressions when a metric
has a filter. `VALIDATION_ERRORS_FOR_AGENT` contains the latest blocking
validation issues for visible models. `COMPILE_REQUEST_SCHEMA_FOR_AGENT`
contains the accepted structured-request keys, filter aliases, operators,
order-by fields, handle types, and enum values. `REQUEST_HISTORY_FOR_AGENT`
includes `STARTED_AT` and the compatibility alias `REQUEST_TIME`. Use the
aliases when integrating with generic agent protocols that expect those names.

Use `SEMANTIC_AGENT` and `SEMANTIC_CATALOG` for integrations and docs examples.
Direct `SYS_SEMANTIC` reads are for internal maintenance; those tables are
normalized around ids and do not repeat every convenience column such as
`MODEL_NAME`.

## Discovery Helpers

Some generic metadata tools list base tables but not views. To keep semantic
schemas visible through those tools, the install creates small physical
discovery tables:

```text
SEMANTIC_CATALOG.SEMANTIC_CATALOG_DISCOVERY
SEMANTIC_AGENT.SEMANTIC_AGENT_DISCOVERY
SEMANTIC_<MODEL>.SEMANTIC_DISCOVERY
```

These tables are entry points only. The authoritative semantic metadata remains
in the catalog tables and views described above.
