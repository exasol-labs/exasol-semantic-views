# OSI Import And Export

Exasol Semantic Views supports Open Semantic Interchange (OSI) as an import and
export format for semantic model lifecycle workflows. OSI is an interchange
artifact, not the authoritative runtime store. The authoritative model remains
the Exasol catalog in `SYS_SEMANTIC`, and query-time behavior remains the
SQL/Lua runtime.

Use OSI for:

- exchanging semantic model definitions with OSI-compatible tools.
- reviewing exported model definitions in source control.
- moving semantic models between Exasol Semantic Views environments.
- validating semantic model interchange behavior in CI.

## Supported Version

The supported OSI schema is pinned at:

```text
schemas/osi/0.2.0.dev0/osi-schema.json
```

Only OSI `0.2.0.dev0` is accepted. Documents with other versions, such as
`0.1.1`, fail with an unsupported-version diagnostic instead of being partially
imported.

YAML examples quote the top-level version as `"0.2.0.dev0"` so parsers keep it
as the string required by the schema.

## CLI

The host-side OSI CLI is `tools/osi.py`. It validates OSI documents, exports
Exasol semantic models, plans imports offline, and applies import plans to
Exasol.

Validate an OSI file offline:

```sh
python3 tools/osi.py validate sql/examples/sales_osi.yaml
```

Export a published semantic object for a generic OSI consumer:

```sh
python3 tools/osi.py export \
  --model sales \
  --object SALES \
  --profile interoperability \
  --format yaml \
  --output /tmp/sales_osi.yaml \
  --warnings-output /tmp/sales_osi_warnings.json
```

Export the full model for Exasol-to-Exasol round trips:

```sh
python3 tools/osi.py export \
  --model sales \
  --profile lossless \
  --format json \
  --output /tmp/sales_osi_lossless.json \
  --warnings-output /tmp/sales_osi_lossless_warnings.json
```

Plan an import without connecting to Exasol:

```sh
python3 tools/osi.py import \
  --dry-run \
  --strict \
  --target-model sales_osi_import \
  --output /tmp/sales_osi_import_plan.json \
  sql/examples/sales_osi.yaml
```

Apply an import through the public admin helper surface:

```sh
python3 tools/osi.py import \
  --apply \
  --target-model sales_osi_import \
  --collision-policy replace_draft \
  --apply-mode script \
  --output /tmp/sales_osi_import_result.json \
  sql/examples/sales_osi.yaml
```

Apply a lossless Exasol-to-Exasol import through the batch helper:

```sh
python3 tools/osi.py import \
  --apply \
  --strict \
  --target-model sales_osi_roundtrip \
  --collision-policy replace_draft \
  --apply-mode batch \
  --output /tmp/sales_osi_roundtrip_result.json \
  /tmp/sales_osi_lossless.json
```

Connection defaults match the local Nano setup: `localhost:8563`, user `sys`,
password `exasol`, with TLS certificate verification disabled. Override them
with `--host`, `--port`, `--user`, `--password`, and `--tls-verify`.

Optional OSI tool dependencies are listed in:

```text
tools/requirements-osi.txt
```

JSON input and output work without optional YAML dependencies. YAML input and
output require PyYAML. If `jsonschema` is installed, validation uses the
vendored OSI JSON Schema; otherwise the CLI uses the built-in structural
validator for the supported `0.2.0.dev0` document shape. In both cases,
`custom_extensions[].data` must parse as JSON.

## Profiles

### Interoperability

Use `--profile interoperability` when the target is a generic OSI consumer.

This profile writes OSI core fields wherever possible and keeps Exasol-specific
metadata to the minimum needed for safe import back into Exasol. Native concepts
that OSI core does not model are omitted or reported as warnings. Examples are
semantic object membership, private implementation facts, private metrics,
complex join SQL, expression-based keys, metric filters, materializations,
validation history, query logs, and privileges.

`--object` is supported for interoperability export. It exports the selected
published semantic object and the entities, fields, relationships, metrics, and
context needed by that object.

### Lossless

Use `--profile lossless` for Exasol-to-Exasol workflows, Git review, backups,
and migrations between Exasol Semantic Views environments.

The lossless profile writes OSI core plus `custom_extensions` with
`vendor_name: EXASOL`. These extensions preserve native metadata such as:

- published schema and owner metadata.
- semantic objects, root entities, object membership, visibility, and column
  order.
- source aliases and Exasol physical source metadata.
- Exasol field and metric data types.
- primary-key expressions and native unique-key metadata.
- relationship join SQL, cardinality, join type, fanout policy, description, and
  path priority.
- fact metadata, additive policy, privacy, certification, display metadata, and
  format hints.
- metric kind, aggregation function, measure expression, semantic and SQL
  filters, type params, owner/display metadata, privacy, and certification.
- third-party OSI custom extensions.

For import, `--profile auto` detects Exasol lossless extensions when they are
present. Use `--strict` for lossless workflows so ambiguous or lossy documents
block instead of being accepted with best-effort defaults.

## Import Planning And Apply

Import starts with host-side OSI validation and deterministic planning. The dry
run plan contains ordered operations with:

- `operation`
- `target`
- `arguments`
- `source_path`
- optional `metadata`
- `diagnostics`

`--dry-run` never connects to Exasol and never mutates the catalog. It is the
right mode for CI checks, reviews, and diagnosing how an OSI document maps to
Exasol.

`--apply` validates and plans the same document, runs live preflight checks, and
applies the normalized operations to Exasol. The database receives normalized
Exasol operations, not raw OSI YAML or JSON.

Apply supports:

- `--collision-policy fail`
- `--collision-policy replace_draft`
- `--no-rollback`
- `--no-validate`
- `--warnings-as-errors`
- `--apply-mode script`
- `--apply-mode batch`

By default, apply validates the imported model with `VALIDATE_MODEL` and rolls
back newly created target models after apply failure.

### Script Apply

`--apply-mode script` applies through public `SEMANTIC_ADMIN.ADD_*` helpers. It
is useful for simple interoperability imports and for checking the public helper
surface.

Script apply reports `OSI_IMPORT_120` warnings for lossless metadata that is
preserved in the plan but cannot be fully applied by the public helper surface:

- exact semantic object column order.
- dimension, fact, and metric object-column ordinal and visibility metadata.
- hidden fact object-column membership.
- relationship description and path priority.
- full native metric metadata such as aggregation internals, measure expression,
  semantic filters, SQL filters, and display policy.

### Batch Apply

`--apply-mode batch` sends the normalized plan to:

```text
SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT
```

Batch apply is the expected mode for lossless Exasol-to-Exasol imports. It
applies post-operation metadata patches for:

- exact semantic object column order and visibility.
- hidden fact object-column membership.
- dimension, fact, and metric object-column ordinals.
- relationship description and path priority.
- native metric metadata, including metric kind, aggregation function, measure
  expression, semantic and SQL filters, type params, owner/display metadata, and
  derived metric input/filter metadata.

## Mapping And Limitations

OSI core does not model every Exasol Semantic Views concept. The converter is
explicit about what is represented in OSI core, what is preserved in `EXASOL`
extensions, and what remains outside the OSI artifact.

| Exasol semantic information | OSI core support | Behavior |
| --- | --- | --- |
| Semantic objects and published views | No direct core concept | `--object` can produce an object-scoped interoperability export. Lossless export stores semantic objects, object membership, visibility, and column order in the model `EXASOL` extension. |
| Entities and physical sources | Datasets with `source` | Datasets map to entities. Lossless extensions preserve source schema, source object, source alias, primary-key expression, grain description, and native entity metadata. |
| Dimensions | Dataset fields with `dimension` | Dimensions map cleanly to OSI fields. Lossless extensions preserve data type, display metadata, certification, visibility, object membership, and catalog extensions. |
| Facts | No explicit fact object | Facts export as dataset `fields` with `label: fact`. Native fact kind, data type, additive policy, privacy, certification, and object-column metadata live in `EXASOL` extensions. Private facts are omitted from interoperability export with `OSI_EXPORT_020`. |
| Metrics | Metrics with expression text | Metric expression text exports to OSI core. Filter expressions, aggregation function, measure expression, metric kind, type params, display policy, certification, and owner metadata live in `EXASOL` extensions. Private metrics are omitted from interoperability export with `OSI_EXPORT_021`. |
| Data types | No core field or metric data type | Exasol data types are stored in `EXASOL` extensions. Strict import blocks fields or metrics without resolvable data types because Exasol compilation needs typed metadata. |
| Metric filters and metric internals | No core filter or aggregate-internal metadata | Preserved in metric `EXASOL` extensions and applied by batch mode. |
| Materializations | No core concept | Materialization definitions and selection history are not exported. Imported models can define materializations separately after import. |
| Privileges and security policies | No core concept | OSI artifacts do not grant privileges or carry Exasol database access policy. Imported models still execute under normal Exasol privileges. |
| Relationship join SQL | Core relationships use `from_columns` and `to_columns` arrays | Simple equality joins export to core arrays. Complex joins are omitted from core with `OSI_EXPORT_040` and preserved in lossless native relationship metadata. |
| Relationship cardinality, join type, and path priority | No complete core equivalent | Stored in `EXASOL` relationship extensions. Batch apply preserves path priority and description. |
| Primary and unique keys | Simple column keys are supported | Simple primary and unique keys export to core. Expression-based keys are preserved in extensions and produce `OSI_EXPORT_030` for the core loss. |
| Agent instructions | Core `ai_context.instructions` is plain text | Instruction text round-trips. Native kind, priority, and role are not represented in OSI core. |
| Synonyms | Core synonyms are plain strings | Synonym text round-trips. Native synonym source metadata is not represented in OSI core. |
| Verified queries and examples | Core examples are text only | Natural-language example text can export to OSI. Exasol verified queries need request JSON and result-shape metadata, so examples are not recreated as verified queries on import. |
| Third-party custom extensions | Supported as opaque `vendor_name` and JSON string `data` | Non-Exasol extension payloads are preserved exactly by vendor, scope, and JSON string. Native catalog extension names are not represented by OSI and are regenerated deterministically for imported raw OSI extensions. |
| Validation runs, query logs, and compile cache | No core concept | Operational history is not exported. Import runs normal `VALIDATE_MODEL` after apply unless `--no-validate` is used. |

## Round-Trip Fidelity

Lossless export/import/export preserves supported semantic model content:

- entities and physical source metadata.
- relationships and native join metadata.
- dimensions, facts, and metrics.
- semantic object membership, order, and visibility.
- metric filters and native metric metadata.
- unique keys and expression-key metadata.
- synonyms and instruction text.
- Exasol and third-party custom extensions.

The lossless comparison intentionally excludes operational artifacts that OSI
does not carry:

- verified-query request JSON and expected result-shape metadata.
- instruction kind, priority, and role.
- synonym source.
- native catalog names for raw OSI custom extensions.
- materializations.
- validation runs.
- query logs.
- compile cache entries.

The importer assigns deterministic `osi_N` native extension names to raw OSI
extensions so repeated extensions from the same vendor and scope do not collapse
into one catalog row during import.

## Diagnostics

Export warnings are written to `--warnings-output` when supplied, or to stderr
when warnings exist and no file is supplied.

Import diagnostics appear in the dry-run plan or apply result. Blocking
diagnostics produce `status: "blocked"` and a nonzero CLI exit code.

Common diagnostic families:

- `OSI_EXPORT_*`: export-side losses or omissions.
- `OSI_IMPORT_*`: OSI validation, mapping, and helper-surface diagnostics.
- `OSI_APPLY_*`: live apply, preflight, validation, and rollback diagnostics.
- `OSI_ROUNDTRIP_*`: normalized round-trip comparison diagnostics.

Use `--warnings-as-errors` when warning-level losses should block import or
apply.

## Reference Files

Example OSI document:

```text
sql/examples/sales_osi.yaml
```

Fixture directory:

```text
tests/fixtures/osi/
```

Fixtures:

- `minimal_model.yaml`: smallest useful import/export shape.
- `sales_interoperability.yaml`: OSI core representation of the sales example.
- `sales_lossless.yaml`: sales example with Exasol round-trip extensions.
- `complex_relationship.yaml`: relationship fixture that needs native join SQL
  extensions for full fidelity.
- `missing_datatype.yaml`: valid OSI that fails strict Exasol import planning
  because OSI core has no data type field.
- `invalid_relationship.yaml`: valid OSI that fails import planning with
  `OSI_IMPORT_060` because relationship key arrays have different lengths.

`tests/test_osi_tool.py` fails if `sql/examples/sales_osi.yaml` diverges from
`tests/fixtures/osi/sales_interoperability.yaml`.

## Verification

The OSI surface is covered by offline unit/fixture tests and Nano integration
verifiers.

Offline:

- `tests/test_osi_tool.py` covers schema validation, JSON/YAML loading,
  simulated no-PyYAML behavior, fixture drift, JSON planning parity for rich
  YAML fixtures, import planning, dialect fallback diagnostics, extension
  preservation, helper-surface loss diagnostics, validation warnings-as-errors,
  batch warning decoding, lossy export warnings, native key precedence, invalid
  relationship diagnostics, and round-trip normalization helpers.

Live Nano verifiers:

- `tools/verify_osi_export.py` checks live export, schema validation, simple key
  extraction, relationship column ordering, Exasol extensions, YAML output, and
  third-party extension preservation.
- `tools/verify_osi_import.py` checks script apply, collision preflight,
  validation after import, catalog row counts, semantic object creation, and
  representative compile/query execution.
- `tools/verify_osi_batch_import.py` checks normalized batch apply, returned row
  shape, metadata patches, validation run id, and representative compile/query
  execution.
- `tools/verify_osi_roundtrip.py` checks lossless export/import/export
  equivalence, normalized catalog equivalence, representative compiler SQL and
  result equivalence, third-party custom-extension preservation, expected
  script-mode loss diagnostics, and rollback on injected batch failures.

Run the full local Nano smoke suite with:

```sh
sh tools/run_nano_smoke.sh
```

The smoke suite includes the live OSI verifiers.

## Implementation Boundary

The OSI converter is a host-side Python tool. Python handles YAML, JSON Schema
validation, file I/O, diagnostics, versioned OSI mapping, and fixture tests.

Lua remains the database-resident runtime for validation, compilation,
publishing, the SQL preprocessor, and normalized plan application. Database-side
OSI helpers accept normalized Exasol operations; they do not parse OSI YAML or
make schema-version decisions.
