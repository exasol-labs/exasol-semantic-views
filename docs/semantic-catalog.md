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
SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION
SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION
```

F1 supports `RELATION` and `VIRTUAL_SCHEMA` sources. All active representations
must expose the same semantic alias and every column used by attributes that
have only a compatibility-default binding, filters, unique keys, and
relationship mappings. Adding, promoting, or removing
a representation clears compile cache entries and marks successful validation
runs stale. Validate before promotion, then validate and publish after it.
Validation executes data probes for every declared unique key: each
representation must preserve key uniqueness, and every alternate must have the
same key cardinality and bidirectional key set as the primary. Multiple
representations without a declared key fail validation. Probe errors also fail
closed, so the validating user must be able to query every representation.
These full key scans and set comparisons can be expensive for large or remote
sources. Validation runs them only after local catalog validation is clean and
caches each representation's key cardinality once per key; exact bidirectional
set comparisons still run for every alternate. They never run during compiled
business queries.

Identity and relationship metadata remains representation-invariant through
F2. Primary-key expressions, unique-key columns, relationship key mappings,
join conditions, and representation-blind metric filters must resolve against
the same case-sensitive physical column names in every representation. F2
attribute bindings cannot repair those differences. Normalize incompatible
sources behind a view with canonical aliases before registration; native
representation-specific identity mappings are reserved for Fusion Phase F5.

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
recorded in `plan_json.selected_representations[].selected_bindings`. Temporal
coverage, unions, reconciliation, and row-level coalescing remain later phases.

The read-only representation view is available as:

```text
SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS
SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS
```

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

Every key or relationship-mapping mutation deletes the affected model
version's compile-cache entries and marks its earlier successful validation
runs `STALE`. Run `SEMANTIC_ADMIN.VALIDATE_MODEL` after completing a related
set of changes.

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
