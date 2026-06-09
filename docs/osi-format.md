# OSI Import And Export Format

Exasol Semantic Views will support Open Semantic Interchange (OSI) as an
import/export format for semantic model lifecycle workflows. OSI is not the
authoritative store for this project. The authoritative model remains the
database catalog in `SYS_SEMANTIC`, and query-time behavior remains the existing
SQL/Lua runtime.

## Supported Versions

The pinned Milestone 0 schema is:

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

Milestones 2 and 3 add a host-side OSI CLI:

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

## Implementation Language

The primary converter should be an external Python tool, not a Lua script
inside Exasol. Python is a better fit for YAML, JSON Schema validation,
versioned OSI adapters, file I/O, diagnostics, and round-trip fixture tests.

Lua remains the correct language for database-resident runtime behavior:
validation, compilation, publishing, the SQL preprocessor, and small admin
helpers. Any database helper added for OSI should accept normalized Exasol
operations, not raw OSI YAML.

## Fixture Directory

Milestone 0 fixtures live under:

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

The sales example and sales interoperability fixture are currently duplicated
by hand. Once export tooling exists, generate `sql/examples/sales_osi.yaml`
from the exporter or add a drift check against
`tests/fixtures/osi/sales_interoperability.yaml`.

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

## Unsupported In Milestone 4

Milestone 4 intentionally applies through the public helper surface. The apply
result emits `OSI_IMPORT_120` warnings for lossless metadata that is preserved
in the plan but not fully applied by those helpers:

- exact semantic object column order.
- dimension and metric object-column ordinal/visibility metadata.
- hidden fact object-column membership.
- relationship description and path priority.
- full native metric metadata such as aggregation internals, measure
  expression, semantic filters, and display policy.

Lossless round-trip fidelity for those fields requires either expanded public
helpers or a narrow normalized batch apply helper in a later milestone.
