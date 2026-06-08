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
introspection views. OSI import/export foundation metadata adds generic custom
extensions and entity unique-key metadata for lossless round trips.

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

## OSI Import/Export Metadata

Milestone 1 adds catalog tables used by future OSI import/export tooling:

- `CUSTOM_EXTENSIONS`: raw vendor extension payloads keyed by model version,
  scope type, scope id, vendor name, extension name, and source format.
- `UNIQUE_KEYS`: optional entity-level key definitions imported from OSI or
  preserved for later OSI export.
- `UNIQUE_KEY_COLUMNS`: ordered source columns or expressions that make up a
  unique key.

The public views are available as:

```text
SEMANTIC_CATALOG.CUSTOM_EXTENSIONS
SEMANTIC_CATALOG.UNIQUE_KEYS
SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS
```

Extension payloads intentionally remain raw JSON strings. This matches OSI
`custom_extensions[].data`, which is a JSON string rather than a nested object.
`VALIDATE_MODEL` checks that the payload parses as JSON and that its scope
points to an existing model, semantic object, entity, relationship, dimension,
fact, or metric.

Use the admin helpers instead of direct DML:

```text
SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION
SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS
SEMANTIC_ADMIN.ADD_UNIQUE_KEY
SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN
```

`ADD_CUSTOM_EXTENSION` accepts non-Exasol vendor names without interpretation,
so import/export can preserve third-party OSI extensions. `ADD_UNIQUE_KEY`
accepts `PRIMARY`, `UNIQUE`, and `ALTERNATE` key kinds. Unique key columns can
store either a simple source column name or a native expression, but not both.

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
