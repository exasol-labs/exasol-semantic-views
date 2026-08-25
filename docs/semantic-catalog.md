# Semantic Catalog

Catalog schemas:

- `SYS_SEMANTIC`: authoritative semantic metadata tables.
- `SEMANTIC_CATALOG`: read-only metadata views for humans and tools.
- `SEMANTIC_AGENT`: role-scoped machine-readable context views for agents.
- `SEMANTIC_ADMIN`: Lua admin and compiler scripts.

The installed catalog includes Exasol-compatible DDL for catalog tables,
read-only catalog views, validation run storage, validation issue storage, the
metric/dimension validity matrix, structured compiler scripts, SQL compiler
wrapper, guarded published views, SQL preprocessor, agent context views, agent
feedback tables, the manual materialization registry, SQL-native metric
definition sources, metric input metadata, metric filter metadata, and
introspection views. Apache Ossie / OSI import/export foundation metadata adds
generic custom extensions and entity unique-key metadata for lossless round
trips.

## Which Build Is Installed

The runtime lives inside the database, so the build serving a deployment is a
property of that deployment, not of your checkout. `tools/install.py` records
one row per run and the answer is one query:

```sql
SELECT * FROM SEMANTIC_CATALOG.PRODUCT_VERSION;
```

| Column | Meaning |
|---|---|
| `PRODUCT_VERSION` | Newest released version in `CHANGELOG.md` at install time. |
| `DISPLAY_VERSION` | `PRODUCT_VERSION`, suffixed `+dev` when the tree carried unreleased changes. |
| `RELEASE_STATE` | `RELEASED`, `DEVELOPMENT`, or `UNKNOWN`. |
| `GIT_COMMIT` / `GIT_STATE` | Commit installed from, and whether the tree was `CLEAN`, `DIRTY`, or `UNKNOWN`. |
| `RUNTIME_CHECKSUM` | SHA-256 over the install SQL files as executed. |
| `INSTALLED_AT` / `INSTALLED_BY` | When, and by which database user. |

`RUNTIME_CHECKSUM` is the reliable discriminator: git provenance is absent for a
tarball, a vendored copy, or uncommitted edits, but the checksum always
identifies the SQL that was actually installed. Two deployments that disagree in
behaviour while reporting identical catalogs will disagree here.

`SEMANTIC_CATALOG.PRODUCT_INSTALL_HISTORY` keeps every install recorded against
the database. A re-install without `--reset` appends, so a runtime upgrade
stays visible afterwards; `--reset` drops the history with the rest of
`SYS_SEMANTIC`. Installing by running the SQL files directly, rather than
through `tools/install.py`, records nothing — an empty `PRODUCT_VERSION` means
exactly that.

Quote both `DISPLAY_VERSION` and `RUNTIME_CHECKSUM` in bug reports.

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

Semantic entities are separated from their physical source bindings through
`SYS_SEMANTIC.ENTITY_REPRESENTATIONS`. `ADD_ENTITY` creates one active
`PRIMARY` representation automatically, and installation backfills one for
every existing entity. `VALIDATE_MODEL` rejects active entities that do not
have exactly one active primary representation.

Additional active `ALTERNATE` representations may serve the same entity.
Without explicit attribute bindings, selection remains manual and static:
`SET_PRIMARY_REPRESENTATION` chooses the single source used by every compile.
The grain-metadata assistant and semantic-definition export resolve source
schema, object, and alias through the primary representation.
The corresponding columns on `SYS_SEMANTIC.ENTITIES` remain mandatory and are
kept as compatibility mirrors, including after promotion.

Manage the F1 lifecycle through:

```text
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE
SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING
SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE
SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH
SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION
SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION
```

`ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS` is the general form: the same eight
positional arguments as `ADD_ENTITY_REPRESENTATION`, plus a `DECLARATIONS_JSON`
block carrying any of `authority`, `coverage`, and `identity`. The three
one-dimensional `_WITH_*` calls remain supported and are equivalent to passing
the corresponding single key. Reach for the collapsed form when a published
entity needs more than one of them at once — most often `authority` together
with `identity`, which no single-purpose call covers. Unknown keys are refused
(`SEMANTIC_ADMIN_214`), as is `coverage` together with `identity`
(`SEMANTIC_ADMIN_215`) — `SEMANTIC_MODEL_047` rejects F3 temporal coverage and an
F5 semantic identity on the same entity, so that pair has no valid outcome to
reach. Whatever the block declares lands as one candidate, so a validation
failure removes the representation and everything the call generated.

Representations support `RELATION` and `VIRTUAL_SCHEMA` sources. All active representations
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

`SET_PRIMARY_REPRESENTATION` returns a `WARNINGS` column for the outcomes that
are legal but leave a catalog state whose next reader draws the wrong
conclusion. Both are advisory — the promotion happened and the numbers stay
correct — and nothing else reports them, because `VALIDATE_MODEL` sees a legal
model afterwards:

| Code | Raised when |
|---|---|
| `SEMANTIC_ADMIN_W060` | The promoted representation has a `VALID_TO`, so it is not the open-ended partition and rows past that bound are answered by an `ALTERNATE`. Deliberate during an F3 rebuild, a mistake otherwise; only the caller knows which. A representation with only a `VALID_FROM` is still open-ended and does not warn. |
| `SEMANTIC_ADMIN_W061` | The representation that lost the role is *named* `primary` — the conventional name for the F0 compatibility row — so its name and its role now disagree in `ENTITY_REPRESENTATIONS`. |
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

Without a semantic identity, identity and relationship metadata remains
representation-invariant. Primary-key expressions, unique-key columns,
relationship key mappings, join conditions, and representation-blind metric
filters must resolve against the same case-sensitive physical column names in
every representation. Attribute bindings cannot repair those differences.
A semantic identity can map one scalar source-local entity key per
representation. Relationship-aware compilation can remap a simple scalar
endpoint through complete anchored `DIRECT` identity bindings; general `MAPPED`
relationship remapping and arbitrary filter-column rewriting remain unsupported.
Relationship key mappings store raw physical column names and support names
that require SQL quoting, including spaces, reserved words, and JSON Tables
markers such as `profile|object`. Rendered join conditions remain responsible
for SQL quoting; do not include surrounding double quotes in mapping values.

Attribute bindings separate semantic dimensions and facts from their source expressions
through `SYS_SEMANTIC.ATTRIBUTE_BINDINGS`. `ADD_DIMENSION` and `ADD_FACT`
automatically create a `PREFER` binding on the current primary representation.
When the entity already has complete F3 coverage, they seed the governed
expression on every active partition in the same validated operation.
For heterogeneous representations, `ADD_DIMENSION_WITH_BINDINGS` and
`ADD_FACT_WITH_BINDINGS` create the attribute, its primary binding, and one
explicit binding for every active alternate before validating once. The JSON
must cover every alternate and must not include the primary; the top-level
`EXPRESSION` supplies the primary binding. A source that genuinely lacks the
concept can declare `"source_expression":"NULL"` explicitly. Non-primary F3
partitions with coverage predicates are seeded from `EXPRESSION` automatically
and must not appear in the JSON.
Installation backfills the primary binding for existing attributes. Additional
bindings are managed with:

```text
SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING
SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING
SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING
SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS
SEMANTIC_ADMIN.ADD_FACT_WITH_BINDINGS
```

`REPLACE_ATTRIBUTE_BINDING` updates an existing binding through a prospective
validation gate. It accepts a repair that removes an existing draft error, but
restores the previous expression, role, and priority if the candidate
introduces a new error. `ADD_ATTRIBUTE_BINDING` reports
`SEMANTIC_ADMIN_024` with this replacement remedy when the target already
exists.

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
and transitive metric fact to have a binding on every partition; validation
reports every missing pair as `SEMANTIC_MODEL_052`. It supports
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
Materialization substitution is bypassed while reconciliation is active.
Reconciled dimensions may participate in multi-fact requests: their
key-preserving joins execute independently in every fact branch. Reconciled
facts remain unsupported in multi-fact plans and fail closed with
`SEMANTIC_REQUEST_074`; use a canonical pre-reconciled measure source for that
shape.

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

The mapping relation's two column names are **case-insensitive**, like every
other declared column name: `account_id` and `ACCOUNT_ID` both resolve to
whatever the source actually carries. Both names go through
`lua/semantic_layer/shared/source_columns.lua`, so the validator's probes and the
compiler's rendering of the same join cannot disagree about the spelling. They
were the last pair of declared names quoted verbatim, which made a lower-case
declaration fail validation with `SEMANTIC_MODEL_049` while the neighbouring
`ADD_UNIQUE_KEY_WITH_COLUMNS` accepted either case — an inconsistency a modeller
had no way to predict.

`ADD_SEMANTIC_IDENTITY_WITH_BINDINGS` installs the identity, exactly one binding
for every active representation, and nested mapping metadata for each `MAPPED`
binding as one prospective candidate. Use it for published models, where the
standalone identity declaration is necessarily incomplete and is restored with
`SEMANTIC_ADMIN_094`. A failed compound candidate removes all inserted mapping,
binding, and identity rows before re-certifying the previous surface.

When a published entity already has an F5 identity, use
`ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING` to register a heterogeneous
source together with its `DIRECT` or `MAPPED` binding — or
`ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS` with an `identity` key, which
accepts the same fields and can declare an authority role in the same call.
`MAPPED` registration takes the same certified relation fields in
`MAPPING_JSON`. The complete
candidate also seeds explicit dimension and fact bindings from the governed
expressions, then validates once. If validation fails, the error lists every
failing object and the operation removes the generated attribute bindings,
identity mapping, identity binding, and representation before recertifying the
published surface.

Identity mapping normalizes key names and types; it does not flatten a source
or join nested child relations. Generated attribute bindings require the new
representation to expose the governed canonical columns. Use a canonicalizing
view when the alternate has a different physical shape.

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

The catalog stores metadata used by the implemented Ossie/OSI import/export tooling:

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
SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS
SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING
SEMANTIC_ADMIN.REMOVE_RELATIONSHIP_KEY_MAPPING
SEMANTIC_ADMIN.SET_RELATIONSHIP
SEMANTIC_ADMIN.REMOVE_RELATIONSHIP
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
Simple equality relationships must join compatible physical type families on
every active representation.

`SET_RELATIONSHIP` edits one relationship in place:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP(
  'sales', 'order_to_shipment',
  NULL,               -- JOIN_CONDITION: NULL keeps the stored value
  'MANY_TO_ONE',      -- CARDINALITY
  NULL,               -- JOIN_TYPE
  'NONE');            -- FANOUT_POLICY: 'NONE' clears it
```

Any argument left `NULL` keeps its stored value, and key mappings survive the
edit. Endpoints are deliberately not editable: changing them makes it a
different relationship whose key mappings no longer describe it, so remove and
re-add for that. Remove a relationship in dependency order: remove its key
mappings from highest ordinal to lowest, then call `REMOVE_RELATIONSHIP`.

Published additions, updates, and removals validate prospectively and restore
the prior relationship state on error (`SEMANTIC_ADMIN_094` for a removal,
`SEMANTIC_ADMIN_098` for an update). On a draft model the change is applied and
the model's validation runs are marked stale; compilation is gated on
validation status, so nothing can query the model until it is revalidated, and
reverting would block the repair the edit was for.

The installer test enumerates every `ADD_*` admin script and requires a direct,
compound, or governed-DDL inverse. These intentionally one-way operations are
the explicit exceptions in this release:

- `ADD_CUSTOM_EXTENSION`: extension removal waits for defined ownership semantics.
- `ADD_ENTITY`: dependent structure has no scoped transactional cascade; use `DROP_MODEL`.
- `ADD_FACT`: removal waits for transactional dependent-metric rewrites.
- `ADD_MATERIALIZATION_COLUMN`: deactivate the owning materialization instead.
- `ADD_SEMANTIC_OBJECT`: published contract removal currently requires model rebuild.
- `ADD_SYNONYM`: removal waits for transactional ambiguity revalidation.

Adding another `ADD_*` operation fails the installer test until it has an
inverse or an explicit reviewed exception with a reason.

On a published model, use `ADD_UNIQUE_KEY_WITH_COLUMNS` for a new key. Its JSON
array contains ordered objects with `column_name` or `expression` and optional
`ordinal_position`; all components are inserted before one validation. The
sequential `ADD_UNIQUE_KEY` then `ADD_UNIQUE_KEY_COLUMN` form remains suitable
for drafts, but its empty intermediate key is invalid on a published model.

Every key or relationship-mapping mutation deletes the affected model
version's compile-cache entries and marks its earlier successful validation
runs `STALE`. Run `SEMANTIC_ADMIN.VALIDATE_MODEL` after completing a related
set of changes.

Published mutators revalidate before returning. Standalone valid changes leave
the surface certified immediately. Prospectively guarded operations reject and
restore invalid intermediate states; use their compound forms when the complete
declaration spans several catalog rows. Draft mutators do not run automatic
validation.

On a draft, remove a key in dependency order: call `REMOVE_UNIQUE_KEY_COLUMN`
for every component, then `REMOVE_UNIQUE_KEY`. The latter refuses keys that
still have columns. On a published model, use
`REMOVE_UNIQUE_KEY_WITH_COLUMNS`; it provisionally deactivates the complete key,
validates once, and then removes the key and components. A candidate needed by
relationship grain proofs is reactivated and re-certified before returning
`SEMANTIC_ADMIN_094`.

### The Legacy Key Expression

`ADD_ENTITY` takes a key expression, stored as
`SYS_SEMANTIC.ENTITIES.PRIMARY_KEY_EXPR` and exposed by
`SEMANTIC_CATALOG.ENTITIES` as **`LEGACY_PRIMARY_KEY_EXPR`**. The name is
deliberate: it is a bootstrap hint, not the entity's key. Grain proofs, path
safety, and relationship key matching all use `UNIQUE_KEYS` /
`UNIQUE_KEY_COLUMNS`. The expression is read in exactly two places, and only
when it is exactly `alias.column`: `SUGGEST_GRAIN_METADATA` proposes a
one-column key from it, and OSI export falls back to it when an entity declares
no primary unique key.

Because nothing else consumes it, an expression that is not unique at the
entity's grain used to sit in the catalog unremarked — and it is the first thing
a reader inspecting `ENTITIES` takes for the key. `VALIDATE_MODEL` now reports
`SEMANTIC_MODEL_054` (warning) when the expression does not reference every
column of the entity's declared primary key, naming the columns it misses.
Correct the expression or drop it; the declared key is what the compiler proves
against either way.

`SUGGEST_GRAIN_METADATA(model_name)` is dry-run only. It proposes a one-column
primary key when a legacy key expression is exactly `alias.column`, and a
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
- `CALCULATION_GROUPS` and `CALCULATION_ITEMS`: reserved calculation-item
  metadata. They are persisted but are not currently consumed by compilation.

Human-oriented views:

- `SEMANTIC_CATALOG.METRIC_OVERVIEW` — includes dropped metrics as `STATUS = 'INACTIVE'` rows with a `NULL` `OBJECT_NAME`; filter `STATUS = 'ACTIVE'` for the live surface
- `SEMANTIC_CATALOG.METRIC_LINEAGE`
- `SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS`
- `SEMANTIC_CATALOG.METRIC_FILTER_OVERVIEW`
- `SEMANTIC_CATALOG.SEMANTIC_DEFINITION_SOURCE`
- `SEMANTIC_CATALOG.MODEL_EVOLUTION_SUGGESTIONS`
- `SEMANTIC_CATALOG.MODEL_EVOLUTION_REVIEWS`

## Governed Model Evolution

Governed model evolution keeps agent inference outside the deterministic query path. Agents can
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

Role-aware context views in `SEMANTIC_AGENT` are the
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
- `EXPRESSION_FUNCTIONS_FOR_AGENT`
- `COMPILE_REQUEST_SCHEMA_FOR_AGENT`
- `COMPILE_RESULT_SCHEMA_FOR_AGENT`
- `FUSION_FOR_AGENT`
- `REQUEST_HISTORY_FOR_AGENT`
- `MODEL_EVOLUTION_REVIEW_QUEUE`

`FIELDS_FOR_AGENT` includes `FIELD_KIND` and the compatibility alias
`FIELD_ROLE`, plus semantic and resolved SQL filter expressions when a metric
has a filter. `VALIDATION_ERRORS_FOR_AGENT` contains the latest blocking
validation errors and session preconditions for visible models.
`EXPRESSION_FUNCTIONS_FOR_AGENT` enumerates the built-in functions accepted by
static expression validation, including binding expressions.
`COMPILE_REQUEST_SCHEMA_FOR_AGENT` contains the accepted structured-request
keys, filter aliases, operators, order-by fields, handle types, and enum values.
`COMPILE_RESULT_SCHEMA_FOR_AGENT` contains the nine result columns of each
compile entrypoint with their order, null conditions, and meanings.
`FUSION_FOR_AGENT` contains every fusion declaration in the model — partitions
with their coverage, authority roles, attribute policies, and certified identity
mappings — and `OBJECTS_FOR_AGENT`/`FIELDS_FOR_AGENT` summarise it per object
and per field as `SOURCE_COUNT` and `FUSION_STRATEGY`.
`REQUEST_HISTORY_FOR_AGENT` includes `STARTED_AT` and the compatibility alias
`REQUEST_TIME`. Use the aliases when integrating with generic agent protocols
that expect those names.
`MODELS_FOR_AGENT` also exposes `SESSION_SETUP_REQUIRED` and executable
`SESSION_SETUP_SQL`. Every published model contributes system session-safety
and precondition rows to `INSTRUCTIONS_FOR_AGENT`, so valid readiness cannot have
an empty instruction surface merely because no manual guidance was authored.

Use `SEMANTIC_AGENT` and `SEMANTIC_CATALOG` for integrations and docs examples.
Direct `SYS_SEMANTIC` reads are for internal maintenance; those tables are
normalized around ids and do not repeat every convenience column such as
`MODEL_NAME`.

## Calling Admin Scripts

Every callable `SEMANTIC_ADMIN` script publishes its signature:

```sql
SELECT ORDINAL_POSITION, PARAMETER_NAME, CALL_TEMPLATE
FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS
WHERE SCRIPT_NAME = 'ADD_SYNONYM' ORDER BY ORDINAL_POSITION;
```

The rows are generated from the install SQL itself, so they cannot drift from
the scripts they describe, and `CALL_TEMPLATE` is a ready-made call shape.

"Cannot drift" is enforced rather than intended: packaging fails if a declared
`SEMANTIC_ADMIN` script publishes no signature and is not on the explicit
runtime-library exclusion list in `tools/package_lua_scripts.py`
(`NON_CALLABLE_SCRIPTS`), and fails again if that list names a script that no
longer exists. The seven runtime libraries — the `*_RUNTIME` modules that other
scripts `import`, plus `SEMANTIC_GUARD` and `SEMANTIC_PREPROCESSOR`, which Exasol
invokes itself — are the only scripts absent, because they are not callable.

This mattered: the generator used to require a `RETURNS` clause, so the nine
mutators declared `) AS` because they complete without returning rows
(`CREATE_MODEL`, `ADD_ENTITY`, `ADD_SEMANTIC_OBJECT`, `ADD_RELATIONSHIP`,
`ADD_RELATIONSHIP_KEY_MAPPING`, `CREATE_SEMANTIC_OBJECT`,
`REGISTER_MATERIALIZATION`, `SET_MATERIALIZATION_STATUS`,
`ADD_MATERIALIZATION_COLUMN`) published nothing — and since `CALL_ADMIN_JSON`
resolves names from this view and nothing else, the named path could not perform
a single step of a model bootstrap while working normally on every script that
did return a table.

Positional calls are still the primary form, but Exasol checks parameter arity
in the SQL layer — *before* a script body runs — so a miscount can only ever
surface as `expected 5 script parameters but got 4`, with no script name and no
parameter name. No script can improve that message. Named arguments remove the
failure mode instead:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.CALL_ADMIN_JSON('ADD_SYNONYM', '{
  "model_name": "sales", "object_type": "METRIC",
  "object_name": "total_revenue", "synonym": "turnover", "source": "MANUAL"}');
```

Omitted parameters are passed as `NULL`; an unknown one is refused by name
against the published signature (`SEMANTIC_ADMIN_101`), and an unknown script is
refused with `SEMANTIC_ADMIN_100`. The call returns `STATUS`, `SCRIPT_NAME`,
`ROW_COUNT`, the called script's rows as `RESULT_JSON`, and the
`EXECUTED_STATEMENT` it ran.

**Omit an optional parameter; do not pass `null` for it.** Omission becomes SQL
`NULL`, which is what the positional form wants, but an explicit JSON `null`
reaches the script as the text `null` and is rejected on its own terms — for
example `SEMANTIC_ADMIN_003: invalid FANOUT_POLICY: null`, or
`SEMANTIC_ADMIN_064: DIRECT binding must not include MAPPING_JSON` for a
`DIRECT` identity binding, where the positional form wants exactly `NULL` in that
slot. The two conventions are not interchangeable.

A script that completes without returning rows is not a special case for the
caller: it comes back `STATUS = OK` with `ROW_COUNT = 0` and an empty
`RESULT_JSON`.

## Column Introspection

The catalog is 40+ views, and a column name is not always guessable from the
concept it exposes: `CURRENT_VALIDATION_ISSUES` names the rule `RULE_CODE`, not
`ISSUE_CODE`, and `VALIDATION_RUNS` ends a run at `FINISHED_AT`, not
`COMPLETED_AT`. `SEMANTIC_CATALOG.CATALOG_COLUMNS` answers "what are the columns
of X?" in one query:

```sql
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE
FROM SEMANTIC_CATALOG.CATALOG_COLUMNS
WHERE SURFACE_NAME = 'VALIDATION_RUNS'
ORDER BY ORDINAL_POSITION;
```

`SURFACE_KIND` separates the surfaces:

| `SURFACE_KIND` | Schema | Use |
|---|---|---|
| `CATALOG` | `SEMANTIC_CATALOG` | human and tool introspection |
| `AGENT` | `SEMANTIC_AGENT` | role-scoped agent discovery |
| `CORE` | `SYS_SEMANTIC` | internal maintenance only |
| `PUBLISHED` | `SEMANTIC_<MODEL>` | typed BI views a `PUBLISH_MODEL` created |

To list the surfaces themselves rather than their columns:

```sql
SELECT DISTINCT SURFACE_KIND, SURFACE_NAME, SURFACE_TYPE
FROM SEMANTIC_CATALOG.CATALOG_COLUMNS
ORDER BY SURFACE_KIND, SURFACE_NAME;
```

The view is derived from `EXA_ALL_COLUMNS`, so it cannot drift from the objects
actually installed — there is no hand-maintained column list to fall behind a
release. `EXA_ALL_COLUMNS` is filtered by the querying session's own privileges,
so each caller sees exactly the surfaces they are allowed to read; a user with
`SELECT` on `SEMANTIC_CATALOG` alone sees the `CATALOG` rows and nothing else.

Script result sets are not catalog objects, so they are not in
`CATALOG_COLUMNS`. The compile entrypoints publish their layout as data in
`SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT`; see
[the compiler doc](semantic-compiler.md#reading-the-compile-result).

## Join Introspection

`CATALOG_COLUMNS` answers "what are the columns of X?".
`SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS` answers the other half — "how is X
connected to anything else?" — so nothing has to guess a join or reverse-engineer
one from the compiler's Lua:

```sql
SELECT RELATIONSHIP_KIND, CHILD_COLUMN, PARENT_SURFACE, JOIN_TEMPLATE
FROM SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS
WHERE CHILD_SURFACE = 'METRIC_INPUTS'
ORDER BY RELATIONSHIP_KIND, CHILD_COLUMN;
```

`JOIN_TEMPLATE` is the ON clause, ready to paste. Three kinds of edge exist and
only the first is expressible as a SQL constraint, which is why a consumer that
reads `EXA_ALL_CONSTRAINT_COLUMNS` alone sees roughly half the graph:

| `RELATIONSHIP_KIND` | Where it comes from |
|---|---|
| `FOREIGN_KEY` | Declared constraints on the `SYS_SEMANTIC` tables, read back from `EXA_ALL_CONSTRAINT_COLUMNS` |
| `DISCRIMINATED` | Polymorphic references whose target table is chosen by a sibling discriminator column; one row per discriminator value |
| `VIEW_REFERENCE` | An ID column a `SEMANTIC_CATALOG` or `SEMANTIC_AGENT` view exposes, pointing out to another surface |
| `VIEW_IDENTITY` | An ID column that is the view's own row key rather than a pointer; `JOIN_TEMPLATE` is `NULL` |

### Declared, not enforced

Every foreign key on `SYS_SEMANTIC` is created `DISABLE`: declared and fully
visible in `EXA_ALL_CONSTRAINTS`, but not enforced on write. `IS_ENFORCED`
reports this honestly (`FALSE` on every `FOREIGN_KEY` row) rather than implying
integrity nobody checks. The constraints exist to describe the schema, and
enforcing them would be a different change — the catalog soft-deletes through
`STATUS` columns, keeps run history whose parents a re-publish can legitimately
rebuild, and `MODELS.ACTIVE_VERSION_ID` and `MODEL_VERSIONS.MODEL_ID` reference
each other, so no insert order satisfies both under enforcement.

### Discriminated references

A discriminated reference is a foreign key in every sense except the one SQL can
express: the table it points at is chosen at runtime by a sibling column, so no
single `REFERENCES` clause is correct. `METRIC_INPUTS.INPUT_OBJECT_ID` is a
`FACT_ID` or a `METRIC_ID` depending on `INPUT_OBJECT_TYPE`. **Join on the
discriminator as well as the id** — the generated `JOIN_TEMPLATE` already does,
and omitting it silently mixes rows of different object kinds that happen to
share an id. Each such column also carries a `COMMENT` describing its targets,
which surfaces as `CATALOG_COLUMNS.DESCRIPTION`.

### Views resolve to the caller's own schema

A view carries no constraints, so `VIEW_REFERENCE` edges are derived by matching
a view column against the declared foreign-key column names. Their parents
resolve to a sibling view in the caller's own schema where one exists, because a
caller granted only `SEMANTIC_CATALOG` cannot follow an edge into
`SYS_SEMANTIC`. Column names that are polymorphic anywhere in the catalog are
excluded from this inference — `OBJECT_ID` means `SEMANTIC_OBJECTS` in
`OBJECT_COLUMNS` but is discriminated in `OBJECT_PRIVILEGES` — so those edges
come from the `DISCRIMINATED` rows instead of a guess that would be wrong half
the time.

Like `CATALOG_COLUMNS`, the whole view is derived from `EXA_ALL_*`, so it cannot
drift from what is installed, and each caller sees edges only between surfaces
they may actually read.

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
