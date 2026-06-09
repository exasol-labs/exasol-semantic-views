# OSI Import And Export Format

Exasol Semantic Views supports Open Semantic Interchange (OSI) as an
import/export format for semantic model lifecycle workflows. OSI is not the
authoritative store for this project. The authoritative model remains the
database catalog in `SYS_SEMANTIC`, and query-time behavior remains the existing
SQL/Lua runtime.

## Supported Versions

The pinned schema is:

```text
schemas/osi/0.2.0.dev0/osi-schema.json
```

Only OSI `0.2.0.dev0` is accepted by the initial implementation plan. OSI
`0.1.1` input should fail with a clear unsupported-version diagnostic instead
of being partially imported. A compatibility adapter can be added later if
there is a real migration need.

The reason for pinning is practical: the OSI spec is still a draft, and the
schema currently uses `const: "0.2.0.dev0"` for the top-level `version`.
YAML examples quote the version as `"0.2.0.dev0"` so every parser treats it as
the string required by the schema.

## CLI

The host-side OSI CLI provides validation, export, dry-run planning, and apply:

```sh
python3 tools/osi.py validate sql/examples/sales_osi.yaml

python3 tools/osi.py export \
  --model sales \
  --object SALES \
  --profile interoperability \
  --format yaml \
  --output sql/examples/sales_osi.yaml \
  --warnings-output /tmp/sales_osi_warnings.json

python3 tools/osi.py export \
  --model sales \
  --profile lossless \
  --format json

python3 tools/osi.py import \
  --dry-run \
  --strict \
  --target-model sales_osi_import \
  --output /tmp/sales_osi_import_plan.json \
  sql/examples/sales_osi.yaml
```

`validate` works offline against the vendored OSI schema. If `jsonschema` is
installed, the CLI uses it; otherwise it uses the built-in structural validator
for the pinned OSI `0.2.0.dev0` shape and also validates that each
`custom_extensions[].data` string parses as JSON.

`export` reads from `SEMANTIC_CATALOG` and `SEMANTIC_AGENT` views and writes
JSON or YAML. JSON output has no YAML dependency. YAML input/output requires
PyYAML, and generated YAML quotes the top-level `version`.

`import --dry-run` validates OSI input and writes a normalized JSON import plan.
It does not connect to Exasol or mutate the catalog. The plan contains ordered
operations with `operation`, `target`, `arguments`, `source_path`, and
`diagnostics`. Blocking diagnostics produce `status: "blocked"` and a nonzero
CLI exit code. JSON input works without optional YAML dependencies; YAML input
requires PyYAML.

Optional tool dependencies are listed in:

```text
tools/requirements-osi.txt
```

## Profiles

Two profiles are implemented for export.

### Interoperability

Use this when the target is a generic OSI consumer.

The interoperability profile exports OSI core fields wherever possible and
keeps Exasol-specific details to the minimum needed for safe import back into
Exasol. It may omit or warn about native concepts that OSI core does not model,
such as semantic-object membership, complex join SQL, private implementation
facts, metric filters, materializations, validation history, and privileges.

### Lossless

Use this for round-trip workflows, Git review, backups, and migration between
Exasol environments.

The lossless profile exports OSI core plus `custom_extensions` with
`vendor_name: EXASOL`. These extensions preserve native metadata such as
published schema, semantic objects, object column order, source aliases, Exasol
data types, primary-key expressions, relationship join SQL, metric type,
metric base entity, filters, certification, and format hints.

Use interoperability when the target is another OSI implementation and should
not need Exasol-specific semantics. Use lossless when the target is another
Exasol Semantic Views environment or a Git review workflow that must preserve
native model behavior. For import, `--profile auto` detects Exasol lossless
extensions when they are present; use `--strict` to block ambiguous or lossy
documents instead of accepting best-effort defaults.

## Interoperability Limitations

OSI core does not model every Exasol Semantic Views concept. The converter is
therefore explicit about what is represented in core OSI, what is preserved in
`EXASOL` extensions, and what remains outside the OSI artifact.

| Exasol semantic information | OSI core support | Current behavior |
| --- | --- | --- |
| Semantic objects and published views | No direct core concept | `--object` can produce an object-scoped interoperability export. Lossless export stores all semantic objects, object membership, visibility, and column order in the model `EXASOL` extension. |
| Facts | No explicit fact object | Facts export as dataset `fields` with `label: fact`; native fact kind, data type, additive policy, privacy, certification, and object-column metadata live in `EXASOL` extensions. Private facts are omitted from interoperability export with `OSI_EXPORT_020`. |
| Data types | No core field or metric data type | Exasol data types are stored in `EXASOL` extensions. Strict import blocks fields or metrics without resolvable data types because Exasol compilation needs typed metadata. |
| Metric filters and metric internals | No core filter, aggregation-internal, display, or additive metadata | Metric expression text is exported to OSI core. Filter expressions, aggregation function, measure expression, metric kind, type params, display policy, certification, and owner metadata live in `EXASOL` extensions. |
| Materializations | No core concept | Materialization definitions and selection history are not exported. Round-trip verification avoids materialization-eligible requests until an explicit extension is added. |
| Privileges and security policies | No core concept | OSI artifacts do not grant privileges or carry Exasol database access policy. Imported models still execute under normal Exasol privileges. |
| Relationship join SQL | Core relationships use `from_columns` and `to_columns` arrays | Simple equality joins export to core arrays. Complex joins are omitted from core with `OSI_EXPORT_040` and preserved in lossless `EXASOL` relationship metadata. |
| Relationship cardinality, join type, and path priority | No complete core equivalent | Stored in `EXASOL` relationship extensions. Batch apply preserves path priority and description. |
| Primary and unique keys | Simple column keys are supported | Simple primary and unique keys export to core. Expression-based keys are preserved in extensions and produce `OSI_EXPORT_030` for the core loss. |
| Agent instructions | Core `ai_context.instructions` is plain text | Instruction text round-trips. Native kind, priority, and role are not represented unless a future extension carries them. |
| Synonyms | Core synonyms are plain strings | Synonym text round-trips. Native synonym source metadata is not represented. |
| Verified queries and examples | Core examples are text only | Natural-language example text can export to OSI. Exasol verified queries need request JSON and result-shape metadata, so examples are not recreated as verified queries on import. |
| Third-party custom extensions | Supported as opaque `vendor_name` and JSON string `data` | Non-Exasol extension payloads are preserved exactly by vendor, scope, and JSON string. Native catalog extension names are not represented by OSI and are regenerated deterministically for imported raw OSI extensions. |
| Validation runs, query logs, and compile cache | No core concept | Operational history is not exported. Import runs normal `VALIDATE_MODEL` after apply unless `--no-validate` is used. |

## Import Apply Modes

Import always starts with host-side OSI validation and deterministic planning.
The database receives normalized Exasol operations, not raw OSI YAML or JSON.

`--apply-mode script` applies through public `SEMANTIC_ADMIN.ADD_*` helpers. It
is useful for simple interoperability imports and for checking the public helper
surface, but it reports `OSI_IMPORT_120` warnings for lossless metadata that the
helpers cannot currently apply.

`--apply-mode batch` sends the normalized plan to
`SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT`. This is the expected mode for
lossless Exasol-to-Exasol workflows because it applies post-operation metadata
patches for object-column order, hidden fact membership, relationship priority,
and native metric metadata.

Both apply modes run live preflight checks, support target model collision
policies, and roll back newly created target models after apply failure unless
`--no-rollback` is specified.

## Implementation Language

The primary converter should be an external Python tool, not a Lua script
inside Exasol. Python is a better fit for YAML, JSON Schema validation,
versioned OSI adapters, file I/O, diagnostics, and round-trip fixture tests.

Lua remains the correct language for database-resident runtime behavior:
validation, compilation, publishing, the SQL preprocessor, and small admin
helpers. Any database helper added for OSI should accept normalized Exasol
operations, not raw OSI YAML.

## Upstream Converter Contribution Plan

The current implementation starts in this repository for speed, but the Python
converter should stay shaped so it can become an upstream
`open-semantic-interchange/OSI/converters/exasol` contribution.

Recommended upstream package boundary:

- Keep pure OSI concerns portable: document loading, schema validation,
  diagnostics, extension-envelope parsing, Exasol catalog-to-OSI mapping,
  OSI-to-normalized-plan mapping, JSON/YAML serialization, and fixture tests.
- Keep Exasol database execution in this repository: connection handling,
  `SEMANTIC_CATALOG` queries, `SEMANTIC_ADMIN` script execution, batch helper
  invocation, cleanup, and Nano smoke tests.
- Keep database-resident Lua limited to normalized plan execution. Do not move
  YAML parsing, schema-version checks, or OSI dialect policy into Lua.

Suggested upstream shape:

```text
converters/exasol/
  README.md
  pyproject.toml
  exasol_osi/
    __init__.py
    cli.py
    diagnostics.py
    exporter.py
    extensions.py
    importer.py
    schema.py
  tests/
    fixtures/
```

The upstream `README.md` should document both profiles, the limitations matrix
above, the pinned OSI version, and the `EXASOL` custom-extension envelope. Tests
should run without an Exasol database by using normalized catalog fixtures and
OSI files. Live Exasol/Nano verification should remain in this repository unless
the upstream project explicitly wants optional integration tests.

Open upstream coordination items:

- whether OSI should add `EXASOL` to its expression dialect enum or continue to
  use `ANSI_SQL` for Exasol-compatible SQL with native dialect metadata in
  extensions.
- whether OSI wants a standardized way to represent published semantic views or
  semantic-object subsets.
- whether OSI examples should grow request/result metadata that can represent
  verified-query repositories across vendors.

## Fixture Directory

Fixtures live under:

```text
tests/fixtures/osi/
```

Current fixtures:

- `minimal_model.yaml`: smallest useful import/export shape.
- `sales_interoperability.yaml`: OSI core representation of the sales example.
- `sales_lossless.yaml`: sales example with Exasol round-trip extensions.
- `complex_relationship.yaml`: relationship fixture that needs native join SQL
  extensions for full fidelity.
- `missing_datatype.yaml`: valid OSI that should fail strict Exasol import
  planning because OSI core has no data type field.

`sql/examples/sales_osi.yaml` is generated from `tools/osi.py export` and
mirrors the sales interoperability fixture as a human-facing example next to
the existing sales SQL examples.

## Milestone 0 Review Learnings

The pinned schema is intentionally strict: most objects reject unknown
properties. Future converter code must validate against
`schemas/osi/0.2.0.dev0/osi-schema.json` before mapping and must use
`custom_extensions` for Exasol-specific metadata.

`custom_extensions[].data` is a JSON string, not an embedded object. The
converter and catalog extension storage should preserve this raw string while
also validating that it parses as JSON.

The sales example and sales interoperability fixture currently mirror each
other. `tests/test_osi_tool.py` fails if `sql/examples/sales_osi.yaml` diverges
from `tests/fixtures/osi/sales_interoperability.yaml`; a future generated-export
drift check can strengthen that by regenerating both from the exporter.

The first import planner should produce diagnostics in a deterministic order:
schema validation, extension JSON validation, source and alias resolution,
field classification, data-type resolution, relationship resolution, and metric
base-entity resolution.

## Milestone 1 Catalog Foundation

The catalog now has native storage for OSI round-trip metadata:

- `SYS_SEMANTIC.CUSTOM_EXTENSIONS`
- `SYS_SEMANTIC.UNIQUE_KEYS`
- `SYS_SEMANTIC.UNIQUE_KEY_COLUMNS`

The corresponding read surface is exposed through `SEMANTIC_CATALOG`.
Admin scripts add and read extension payloads and manage unique-key metadata:

- `SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION`
- `SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS`
- `SEMANTIC_ADMIN.ADD_UNIQUE_KEY`
- `SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN`

Extension payloads are stored as raw JSON strings to match OSI
`custom_extensions[].data`. `VALIDATE_MODEL` now rejects malformed extension
JSON, extension scopes that point to missing objects, unsupported unique-key
kinds, empty unique keys, and simple unique-key columns that do not resolve to
source columns.

This keeps the future Python converter focused on OSI schema validation and
mapping while the database catalog enforces the Exasol-side invariants needed
for safe import, export, publish, and compile workflows.

## Milestone 2 Export Tool

The exporter currently supports:

- `interoperability` and `lossless` profiles.
- JSON and YAML output.
- deterministic entity, field, relationship, and metric ordering.
- simple primary-key extraction from native primary key expressions.
- simple primary/unique key export from `UNIQUE_KEYS` and
  `UNIQUE_KEY_COLUMNS`.
- simple equality relationship export to OSI `from_columns` and `to_columns`.
- native relationship metadata in Exasol extensions.
- field and metric Exasol metadata in canonical `vendor_name: EXASOL`
  extensions.
- non-Exasol custom extension `data` string preservation.
- model, dataset, field, relationship, and metric `ai_context` from synonyms,
  agent instructions, and verified-query natural-language examples where
  available.

Relationships that cannot be reduced to equality column pairs are omitted from
OSI core with a warning and preserved in the lossless model extension as native
relationship metadata.

## Milestone 3 Import Dry-Run Planner

The importer supports deterministic planning through:

- `tools/osi.py import --dry-run`.
- `--profile auto`, `interoperability`, and `lossless`.
- `--strict` for blocking lossy mappings such as missing field or metric
  datatypes.
- `--warnings-as-errors`.
- `--target-model` and `--published-schema` overrides.
- deterministic model, entity, semantic object, relationship, field, fact,
  metric, custom extension, synonym, instruction, and unique-key operations.
- canonical `vendor_name: EXASOL` extension envelope validation.
- native Exasol relationship `join_condition` preference.
- deterministic names for unnamed OSI core unique keys.
- raw non-Exasol custom extension payload preservation.

The dry-run artifact is the contract consumed by apply. Existing admin helpers
are referenced where possible. Metadata that the current helper surface cannot
apply losslessly, such as hidden fact object-column membership, is kept in
operation `metadata`.

## Milestone 4 Import Apply

The apply path supports:

- `tools/osi.py import --apply`.
- exactly one of `--dry-run` or `--apply` for import commands.
- script-by-script application through existing `SEMANTIC_ADMIN` helpers.
- model, entity, semantic object, relationship, dimension, fact, metric,
  synonym, instruction, custom extension, and unique-key operations.
- live preflight for blocked plans, target model collisions, and visible source
  table/view existence.
- collision policies `fail` and `replace_draft`.
- optional `--no-rollback` and default best-effort rollback for models created
  during failed apply.
- default `VALIDATE_MODEL` after apply, with `--no-validate` for diagnostics or
  migration work.
- structured apply output with operation results, planner/apply diagnostics,
  and validation rows.
- `--warnings-as-errors` promotion for planner warnings, helper-surface loss
  warnings, and post-apply validation warnings.

Example:

```sh
python3 tools/osi.py import --apply sales_osi.yaml \
  --target-model sales_osi_import \
  --collision-policy replace_draft \
  --output /tmp/sales_osi_import_result.json
```

`tools/verify_osi_import.py` exports the live `sales` model as lossless OSI,
imports it into `sales_osi_import`, validates the imported model, compiles and
runs a representative structured request, and verifies collision preflight.

## Milestone 5 Normalized Batch Apply

Milestone 5 adds an optional database-side batch helper:

- `tools/osi.py import --apply --apply-mode batch`.
- `SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT`.
- normalized plan JSON input, not raw OSI JSON/YAML.
- per-operation result rows from the database helper.
- warning JSON and validation run id in the helper result.
- post-operation metadata patches for lossless Exasol details that public
  `ADD_*` helpers cannot set directly.

Example:

```sh
python3 tools/osi.py import --apply sales_osi.yaml \
  --target-model sales_osi_import \
  --collision-policy replace_draft \
  --apply-mode batch \
  --output /tmp/sales_osi_import_result.json
```

The batch helper currently applies:

- exact semantic object column order and visibility.
- hidden fact object-column membership.
- dimension, fact, and metric object-column ordinals.
- relationship description and path priority.
- native metric metadata including metric kind, aggregation function, measure
  expression, semantic and SQL filters, type params, owner/display metadata,
  and derived metric input/filter metadata.

`tools/verify_osi_batch_import.py` exports the live `sales` model as lossless
OSI, imports it through the batch helper, verifies the returned table shape,
checks lossless metadata patches in `SYS_SEMANTIC`, and compiles/runs a
representative structured request.

## Milestone 6 Lossless Round-Trip

Milestone 6 adds `tools/verify_osi_roundtrip.py`, a live Nano verifier for
lossless export/import/export fidelity.

The verifier:

- prepares non-Exasol `custom_extensions` at model, semantic object, entity,
  relationship, dimension, fact, and metric scope.
- adds a duplicate-safe metric instruction fixture so `ai_context.instructions`
  is covered.
- exports the live `sales` model as lossless OSI.
- plans strict lossless import into `sales_osi_roundtrip`.
- confirms script mode still reports expected `OSI_IMPORT_120` loss warnings for
  helper-surface metadata.
- applies the same plan with `--apply-mode batch`.
- exports the imported model again.
- compares normalized OSI documents after canonicalizing the target model name.
- compares a normalized catalog snapshot keyed by stable names and excluding
  generated ids, audit timestamps, validation rows, materializations, and query
  logs.
- compiles representative requests against the source and imported models and
  compares generated SQL plus query results.
- injects unsupported-operation and metadata-patch failures and verifies batch
  rollback leaves no target model rows.

The comparison intentionally focuses on semantic model content that OSI
currently supports or preserves through Exasol extensions: entities,
relationships, dimensions, facts, metrics, object-column membership/order,
metric filters/native metadata, unique keys, synonyms, instructions, and custom
extensions.

Known round-trip comparison exclusions:

- `ai_context.examples` exported from verified-query natural-language text are
  not compared yet. OSI examples contain text only, while Exasol verified queries
  require request and result-shape metadata to recreate them faithfully.
- instruction kind, priority, and role are not compared because OSI
  `ai_context.instructions` is a plain string.
- synonym source is not compared because OSI `ai_context.synonyms` is a string
  array.
- native extension names for raw non-Exasol OSI extensions, and for raw
  semantic-object extensions, are not compared because OSI `custom_extensions`
  only carries `vendor_name` and `data`.

The importer assigns deterministic `osi_N` native extension names to raw OSI
extensions so repeated extensions from the same vendor and scope do not collapse
into one catalog row during import.

## Script-Mode Limitations

Script mode intentionally applies through the public helper surface. The apply
result emits `OSI_IMPORT_120` warnings for lossless metadata that is preserved
in the plan but not fully applied by those helpers:

- exact semantic object column order.
- dimension and metric object-column ordinal/visibility metadata.
- hidden fact object-column membership.
- relationship description and path priority.
- full native metric metadata such as aggregation internals, measure
  expression, semantic filters, and display policy.

Use batch mode when those fields need to be applied in the imported model.

## Verification Coverage

The OSI surface is covered by offline unit/fixture tests and Nano integration
verifiers:

- `tests/test_osi_tool.py` covers schema validation, JSON/YAML loading,
  diagnostic shape, import planning, extension preservation, helper-surface loss
  diagnostics, batch warning decoding, and round-trip normalization helpers.
- `tools/verify_osi_export.py` checks live export, schema validation, simple key
  extraction, relationship column ordering, Exasol extensions, and third-party
  extension preservation.
- `tools/verify_osi_import.py` checks dry-run and apply behavior, collision
  preflight, strict-mode diagnostics, validation after import, simple unique-key
  import, native Exasol extension mapping, and representative compile execution.
- `tools/verify_osi_batch_import.py` checks normalized batch apply, returned row
  shape, metadata patches, and representative compile execution.
- `tools/verify_osi_roundtrip.py` checks lossless export/import/export
  equivalence, normalized catalog equivalence, representative compiler SQL and
  result equivalence, third-party custom-extension preservation, and rollback on
  injected batch failures.

`tools/run_nano_smoke.sh` runs the live OSI verifiers as part of the local Nano
smoke suite.
