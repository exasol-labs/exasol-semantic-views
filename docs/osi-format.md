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

## Profiles

Two profiles are planned.

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

`sql/examples/sales_osi.yaml` mirrors the sales interoperability fixture as a
human-facing example next to the existing sales SQL examples.

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

## Unsupported In Milestone 0

Milestone 0 does not implement the converter. It only pins the schema,
documents the support policy, and adds fixtures for later implementation and
tests.
