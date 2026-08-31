# Changelog

All notable changes to Exasol Semantic Views are documented here.

---

## [Unreleased]

### Added

#### `osi.py export --profile lossless` refuses to be quietly lossy

- Apache Ossie describes **one source**; the fusion layer describes **how several
  compose**, and `0.2.0.dev0` has no definition for a representation, a coverage
  window, an authority role, a semantic identity, an identity binding, a mapping
  relation, an attribute fusion policy or a materialization. Exporting a model
  that carried any of them produced a document, a `{"warnings": []}` file, and an
  imported copy that passed `VALIDATE_MODEL` with zero errors — a *different,
  valid* model that answers differently, with nothing on either side saying so.
- A `lossless` export now **refuses** when the model carries fusion metadata, names
  what it found, and points at `EXPORT_FUSION_DECLARATION` as the companion file
  a complete backup needs. `--profile interoperability` reports the same finding
  as an `OSI_EXPORT_050` warning, because dropping what the standard cannot
  express is what interchange means — doing it silently is not.
- The refusal is scoped by **consequence, not by tier**. Losing an authority
  declaration changes what the model *answers*, so it blocks. Losing a
  materialization changes only how *fast* it answers, so it warns and names
  `REGISTER_MATERIALIZATION`. The single `PRIMARY` representation `ADD_ENTITY`
  auto-creates is the F0 compatibility row, not a declaration, so an ordinary
  tier-1 model still exports clean.
- `--allow-lossy` exports the tier-1 half deliberately, downgrading the refusal
  to the same warning.
- `docs/osi-format.md` no longer recommends `lossless` for backups without
  qualification; it documents the scope boundary, the two-file backup, and the
  restore order.

### Changed

#### One JSON implementation instead of four

- `lua/semantic_layer/shared/json.lua` replaces a byte-identical 179-line codec
  in `compiler/request_json.lua` and `admin/semantic_definition.lua`, a third
  copy of the encoder half in `agent/runtime.lua`, and a fourth parser in
  `admin/validator.lua`. `admin/fusion_declaration.lua` no longer imports the
  4 600-line DDL parser to reach an encoder.
- The copies had already drifted where it was least visible. A decoded JSON
  `null` is a bare sentinel table whose only meaning is its *identity*, so a null
  produced by one module was an anonymous empty table to the others.
  `compiler/query_spec.lua` read `{"metrics": null}` as an empty list while
  `compiler/request_json.lua`'s own copy would have refused it, and
  `admin/fusion_declaration.lua` read an explicit `null` as a *present*
  declaration, rendering `table: 0x...` into the catalog. Both are fixed: a null
  array field is now explicitly an absent one, and a null where a declaration
  belongs is `SEMANTIC_FUSION_010`.
- `M.decode` and `M.is_valid` are one parser with one `strict` flag. Behaviour is
  unchanged on both sides — the decoder stays lenient because it re-reads
  payloads this runtime wrote, and validation stays strict because a model
  author's `data_json` should be refused at definition time.
- No behaviour change for callers otherwise; `COMPILER_RUNTIME` gives back one
  main-chunk local (189 → 188 of 200) and the generated SQL loses a duplicate.

### Fixed

- `tools/verify_osi_import.py`, `verify_osi_batch_import.py` and
  `verify_osi_roundtrip.py` asserted the sales export produced no warnings. It
  drops a materialization, so they now assert the exact warning and still fail on
  a new one.

### Testing

- `tests/lua/json_unit_test.lua` (4 tests, 100 % line coverage of the new module)
  pins the encoder's sorted-key determinism, every decoder form and refusal, the
  sentinel's identity, and each input `decode` and `is_valid` answer differently
  about.
- A fifth convention in `tests/test_conventions.py`: **a routine is written
  once.** A function body identical in two Lua modules is pinned in
  `DUPLICATED_LUA_BODIES` and may only shrink; a separate check forbids a private
  JSON codec or sentinel outside the owning module, and a third derives from the
  *generated* SQL that every runtime referencing `ESV_JSON` also embeds it. All
  three were verified by breaking them.
- Coverage raised rather than re-baselined where the extraction moved
  fully-covered lines out of a file: `semantic_definition.lua` 72.5 → 76.1 (the
  DDL rollback's snapshot/restore round trip, previously untested and the place a
  new catalog column silently stops being restored), `agent/runtime.lua`
  93.4 → 95.4 (instruction scope dispatch — four of six branches were uncovered,
  and a scope resolved against the wrong table attaches an instruction to
  whatever object shares that id), `request_json.lua` 87.1 → 88.2 (the HAVING
  predicate parser, whose identical WHERE twin was the only one tested),
  `query_spec.lua` 96.7 → 100, `tools/osi.py` 57.7 → 59.4.
- `tools/verify_osi_export.py` builds a model carrying an authority declaration
  and proves the refusal live, because the check is a query against catalog views
  that a unit test cannot keep honest.

### Documentation

- `CLAUDE.md`: **the 200-local ceiling applies to the sum, not to a file.** A
  generated runtime script is one Exasol chunk of concatenated sources, so
  splitting a file into two buys no headroom — only namespacing does. Records the
  cost table, why the `do` block in `request_json.lua` is load-bearing, and that
  every runtime using a shared module must embed it.

#### The fusion declaration document: tier 2 as one file

- Tier 1 — what one source says about itself — has had a document format for a
  while: Apache Ossie/OSI, one file per source. Tier 2, how those sources
  compose, had none, and on a *published* model it was not incrementally
  authorable at all: `ADD_ENTITY_REPRESENTATION`, `ADD_IDENTITY_BINDING`,
  `ADD_IDENTITY_MAPPING_RELATION` and `SET_REPRESENTATION_AUTHORITY` are each
  refused alone, because each alone leaves the model invalid.
- `SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION(MODEL_NAME, DECLARATION_JSON, DRY_RUN)`
  applies the whole tier-2 layer as one entity-keyed JSON document: ordered by
  dependency, atomic against a snapshot of the seven fusion tables, and
  dry-runnable — which matters most here because fusion validation runs *data*
  probes against possibly remote sources.
- `SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION(MODEL_NAME, ENTITY_NAME)` returns the
  same document back, one row, always naming its model. Re-applying an exported
  document reports `nothing to do` with `APPLIED_COUNT = 0`, so a CI job can read
  that as "no drift".
- It is an upsert, not a reconciliation: the document declares what it contains
  and leaves alone what it omits. Removal stays with the `REMOVE_*` scripts —
  deleting governance metadata because a JSON key is absent is not a mistake
  worth making convenient.
- A representation may carry its own `attribute_bindings`, which is what makes
  the canonical F4 shape reachable on a published model: a supplemental source
  narrower than the primary is invalid until those bindings land, and entity-level
  bindings arrive after the representation has already been validated. Refusals
  are `SEMANTIC_FUSION_011` (unknown key), `_014` (identity binding with no
  identity), `_015` (document names another model), `_017` (empty bindings array),
  `_018` (unknown entity), and `SEMANTIC_ADMIN_217` (unknown attribute).

#### `DIMENSION` in `ALTER SEMANTIC VIEW`

- Semantic DDL covered facts and metrics only, so the SQL-native surface could
  describe what an object measures but not what it can be grouped by. `REPLACE
  DIMENSIONS (...)` and `ADD OR REPLACE DIMENSION` complete an object's interior,
  reusing the fact clauses exactly — `ON ENTITY`, `AS`, `RETURNS`, `DISPLAY`,
  `COMMENT`, `FORMAT`, `CERTIFIED`, `PRIVATE`.
- One statement may carry `REPLACE DIMENSIONS`, `REPLACE FACTS` and `REPLACE
  METRICS` together: one validation pass, one rollback unit. That is also the
  only way to restore an object's column *order*, which OSI export carries into
  the imported model.
- New refusals `SEMANTIC_DDL_025`–`_029` and `_038`, and `SEMANTIC_DDL_012` now
  advertises all eight accepted forms.

#### `ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS`

- Authority × coverage × identity × bindings is a product, and the
  one-dimensional `_WITH_*` forms cover four points of it by hand; BUG-G04 was a
  report that one combination had no door. One call now takes a closed
  `DECLARATIONS_JSON` carrying any of `authority`, `coverage`, `identity` and
  `attribute_bindings`, atomically. Unknown keys are refused by name
  (`SEMANTIC_ADMIN_214`); `coverage` with `identity` is refused (`_215`) because
  `SEMANTIC_MODEL_047` rejects that pair anyway.

### Changed

- **Two authoring surfaces are now divided by job, not by preference.** Semantic
  DDL owns the interior of a semantic object; the `ADD_*`/`SET_*`/`REMOVE_*`
  scripts own the graph between objects; the fusion document owns how sources
  compose. The docs previously called one "preferred" and the others
  "compatibility APIs", which had to be either kept true or repeatedly corrected.
- `docs/data-fusion.md` gains a two-tier architecture diagram: one semantic layer
  per federated source at tier 1, semantic fusion above them at tier 2, and tier
  2 as the only surface agents and users see.
- `EXPORT_FUSION_DECLARATION` returns one row per call rather than one per entity,
  always emits `model`, and serialises an empty `entities` as `{}` — without
  which `SEMANTIC_FUSION_015` could never fire on an exported-then-reapplied
  file, the one workflow it exists for.
- `SOURCE_KIND` is cross-checked against `SYS.EXA_ALL_VIRTUAL_SCHEMAS`
  (`SEMANTIC_ADMIN_218`) instead of being free text, and the primary
  representation `ADD_ENTITY` creates now derives its kind — so a federated
  entity records `VIRTUAL_SCHEMA` rather than being mislabelled `RELATION`.
- Advisory codes `SEMANTIC_ADMIN_W060`/`W061` are renumbered `220`/`221`.
  Severity is carried by the channel — a raised error, or a `SEVERITY`/`WARNINGS`
  column — never by a code's spelling.
- `SEMANTIC_MODEL_038` now carries the recovery suffix its siblings have, so a
  key-cardinality difference says what to do about it instead of printing two row
  counts.

### Fixed

- **A metric based on one entity but aggregating another entity's fact compiled
  to invalid SQL** with `STATUS = OK`: the fact's expression was rendered against
  the base entity's `FROM` clause without joining its own, so
  `SUM((o.freight_amount)) FROM "MART"."ORDER_LINES" ol` failed at execution with
  `object O.FREIGHT_AMOUNT not found`. Both directions failed the same way.
  `SEMANTIC_MODEL_061` now refuses it at definition time.
- A visible metric aggregating at an entity coarser than its object's root is
  refused with `SEMANTIC_MODEL_059`, and a partitioned entity used as an
  intermediate join hop no longer silently drops partitions
  (`FUSION_PARTITION_JOIN_UNSUPPORTED`).
- `SEMANTIC_MODEL_060` splits "semantic identity has no binding for active
  representation" out of `SEMANTIC_MODEL_047`, so validation can promote the root
  cause to the head of the report by comparing a code instead of searching the
  message text.
- The F5 mapping-relation join is rendered from one shared module, fixing a
  case-sensitivity defect that existed independently in five places.
- SQL NULL reaching an Exasol Lua script as truthy `userdata` no longer defeats
  required-parameter checks: `REMOVE_RELATIONSHIP`, `REMOVE_UNIQUE_KEY`,
  `REMOVE_UNIQUE_KEY_WITH_COLUMNS`, `REMOVE_ATTRIBUTE_BINDING` and
  `RECERTIFY_MODEL_IF_PUBLISHED` reported an address instead of
  `SEMANTIC_ADMIN_001`, and `DESCRIBE_SEMANTIC_METRIC`/`EXPLAIN_SEMANTIC_METRIC`
  crashed concatenating it. `PUBLISH_MODEL` no longer writes
  `userdata: 0x...` into `SEMANTIC_DISCOVERY` for an undescribed object.
- `SEMANTIC_CATALOG_DISCOVERY.METRIC_DEFINITIONS_QUERY` selected `OBJECT_NAME`
  from a view that has no such column; it reads `METRIC_OVERVIEW` now, and every
  `SELECT` the discovery tables advertise is executed by
  `verify_catalog_introspection.py`.
- An attribute policy already matching the catalog is no longer re-applied, so a
  fusion document converges instead of reporting `APPLIED_COUNT = 1` forever.

#### Named admin calls and a published script signature

- Exasol checks parameter arity in the SQL layer, *before* a script body runs, so
  a miscount can only ever surface as `expected 5 script parameters but got 4` —
  no script name, no parameter name, and nothing a script can do about it.
- `SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS` publishes every `SEMANTIC_ADMIN`
  script's signature, generated from the install SQL itself so it cannot drift,
  with a ready-made `CALL_TEMPLATE`.
- `SEMANTIC_ADMIN.CALL_ADMIN_JSON(SCRIPT_NAME, ARGS_JSON)` calls any of them with
  named arguments, which removes the failure mode instead of describing it. An
  unknown parameter is refused by name against the published signature
  (`SEMANTIC_ADMIN_101`) and an unknown script with `SEMANTIC_ADMIN_100`.

#### `ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY`, and binding issues everywhere

- F4 needs a representation *and* its authority: the two-call sequence passes
  through a state that says something the modeller did not mean, and on a
  published model each call is validated separately. The compound call declares
  both as one candidate and unwinds the representation if the authority
  declaration is refused.
- `ADD_ENTITY_REPRESENTATION` now reports `GENERATED_BINDING_ISSUE_COUNT` and
  `GENERATED_BINDING_ISSUES` — the ergonomics that were unique to the F5 compound
  call — so a registration that will block the next authoring call says so
  immediately instead of at the next `VALIDATE_MODEL`.

#### Deployment identity on the agent surface

- Exasol Personal reassigns ports on restart, so a client pinned to a static DSN
  can reach a different database and answer confidently from the wrong catalog.
  Nothing on the agent surface let a caller notice.
- `SEMANTIC_AGENT.DEPLOYMENT_IDENTITY_FOR_AGENT` publishes the database name and
  version, the product version, the runtime checksum, the install timestamp and
  model count; `MODELS_FOR_AGENT` carries `DATABASE_NAME` and `RUNTIME_CHECKSUM`
  so an agent already reading that view can assert without a second query.
  `docs/mcp-server-integration.md` warns against a pinned `EXA_DSN`.

#### Per-request planner safeguards (`options.max_branches`, `options.max_bytes`)

- `docs/data-fusion.md` documented these as overridable while the closed request
  schema rejected the key outright.
- They are accepted now, and they **tighten only**: a request can ask the planner
  to fail earlier than the deployment's limit, never later, so a caller cannot
  talk the planner out of a safeguard. A value that is not a positive integer,
  or an unknown options key, is refused with `SEMANTIC_REQUEST_004`.

#### Fusion is discoverable (`FUSION_FOR_AGENT`, `FUSION_STRATEGY`, `SOURCE_COUNT`)

- Fusion changes the answer — a partitioned entity merges aggregate states
  across sources, a reconciled attribute takes its value from the authoritative
  one — and none of it was visible on the agent surface. An agent reading
  `FIELDS_FOR_AGENT` could not tell a single-source column from a reconciled one,
  and had no way to explain the number it reported.
- `SEMANTIC_AGENT.FUSION_FOR_AGENT` projects every fusion declaration as one row
  per entity: representations and their partition coverage (`FUSION_ASPECT` of
  `REPRESENTATION`/`PARTITION`, with predicate and interval), authority roles,
  attribute policies, and certified identity mappings.
- `OBJECTS_FOR_AGENT` and `FIELDS_FOR_AGENT` gained `SOURCE_COUNT` and
  `FUSION_STRATEGY` (`UNION`, `COALESCE`, `RECONCILE`, or `NONE`).
- `PUBLISH_MODEL` carries the same fact into the published column comment, so a
  BI user who never reads the catalog still sees it: *"Resolved customer name.
  Fused across 2 sources (RECONCILE)."*
- Listed in `SEMANTIC_AGENT_DISCOVERY.KEY_VIEWS` with a ready-made query.

#### Definition-time plannability gate (`SEMANTIC_MODEL_056`, `SEMANTIC_MODEL_057`)

- A metric the planner could never compile was accepted, validated, published,
  and reported `VALID` by every agent surface, failing only when someone queried
  it — and since `SELECT *` expands to every column of the object, one such
  metric took the whole object down with it. Two shapes did this: `COUNT(*)`,
  which has no fact input and therefore no input grain
  (`METRIC_INPUT_GRAIN_MISSING`), and a non-mergeable aggregate such as `AVG` on
  an F3-partitioned entity, whose partitions merge aggregate states.
- `VALIDATE_MODEL` now classifies every active metric with the planner's own
  code (`ESV_METRIC_PLAN.build_dag`, packaged into the validator runtime), so the
  gate cannot drift from what the compiler decides. `SEMANTIC_MODEL_056` reports
  a missing or ambiguous input grain; `SEMANTIC_MODEL_057` an aggregate with no
  mergeable state whose leaves force state merging.
- The `COUNT(*)` refusal names both supported row-count forms: `COUNT(<fact>)`
  over a non-null fact, and `FACT <name> AS 1` with `SUM(<name>)`.
- Non-mergeable aggregates stay valid where the single-branch renderer compiles
  them, so `AVG` on an unpartitioned single-fact entity is still accepted. The
  gate judges each metric alone: a metric that cannot be planned by itself can
  never be queried, while a combination that only fails together remains a
  request-time concern.
- Because every mutator revalidates, the reverse order is caught too:
  partitioning an entity that already carries a non-mergeable metric is refused
  by the mutation that would complete the partitioning.
- Regression: `tools/verify_metric_plannability.py`, in the smoke suite.

#### Quoted identifiers in Semantic DDL

- The demo model ships an entity named `order`, a reserved word, and
  `ON ENTITY "order"` was refused with `SEMANTIC_DDL_002` while unquoted `order`
  parsed. Quoted metric, fact, model, and object names were already accepted —
  the tokenizer decodes a quoted token — but `ON ENTITY` reads raw source text,
  so a single statement disagreed with itself about quoting.
- Every name position now accepts a double-quoted identifier. Quoting selects a
  name, it does not widen what a name may be: the quoted text still has to be a
  valid identifier, so `"order line"` is still refused, echoed as written.

#### Column introspection (`CATALOG_COLUMNS`, `COMPILE_RESULT_SCHEMA_FOR_AGENT`)

- The catalog is 40+ views whose column names are not guessable from the concept
  they expose (`CURRENT_VALIDATION_ISSUES` names the rule `RULE_CODE`, not
  `ISSUE_CODE`; `VALIDATION_RUNS` ends a run at `FINISHED_AT`, not
  `COMPLETED_AT`), and the only answer was to read the docs or guess.
- `SEMANTIC_CATALOG.CATALOG_COLUMNS` answers "what are the columns of X?" in one
  query, across `SEMANTIC_CATALOG` (`SURFACE_KIND = CATALOG`), `SEMANTIC_AGENT`
  (`AGENT`), `SYS_SEMANTIC` (`CORE`), and published model schemas
  (`PUBLISHED`). Derived from `EXA_ALL_COLUMNS`, so it cannot drift from the
  installed objects, and privilege-filtered per session: a reader granted
  `SEMANTIC_CATALOG` alone sees the catalog rows and nothing else.
- `SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT` publishes the compile result
  contract as data — nine columns per entrypoint with ordinal, zero-based index,
  type, null conditions, and meaning. It records the two details a positional
  reader gets wrong: `ORIGINAL_SQL` is present but always `NULL` for
  `COMPILE_REQUEST_JSON`, and the ninth column is `QUERY_LOG_ID` for
  `COMPILE_SQL_DEBUG` where the other two entrypoints have `AGENT_REQUEST_ID`.
  The three layouts share their first eight rows by construction.

#### Path-choice reporting (`SEMANTIC_MODEL_055`, `RELATIONSHIP_PATH_ALTERNATIVES`)

- Path proofs measured ambiguity as "more than one *shortest* safe path" and
  refused that outright. An alternative of a *different* length passed the same
  gate silently: the shortest path won, validation said nothing, and the plan
  reported `warnings: []` with an empty `candidate_paths`. Path length is a
  tie-break convention, not a statement about meaning — the longer path can
  attribute a fact row to a different dimension row and change the number.
- `VALIDATE_MODEL` now reports `SEMANTIC_MODEL_055` (warning) for a visible
  metric/dimension pair whose entities are connected by more than one safe
  path, naming the selected path and each path not selected.
- `PLAN_JSON.warnings` — declared since the first release and never populated —
  now carries `RELATIONSHIP_PATH_ALTERNATIVES` with the selected path, the
  alternatives, and `selection_reason = SHORTEST_SAFE_PATH`. The `LEGACY_JOIN`
  relationship proof carries the same candidate list that `STRICT_GRAIN`
  already emitted when refusing.
- Unchanged: a tie in length is still an authoring-time ERROR
  (`SEMANTIC_MODEL_030` / `AMBIGUOUS_RELATIONSHIP_PATH`), and `STRICT_GRAIN`
  still refuses an alternative of any length. The new code is a warning because
  a denormalized shortcut edge alongside the long way round is a common and
  harmless shape that the engine cannot distinguish from two genuinely
  different roles; it reports the choice instead of deciding quietly.
- Neither message offers `PATH_PRIORITY` as a remedy, because it does not
  select between candidate paths in either mode. Documented in
  `docs/validation-rules.md#path-ambiguity` with the full mode matrix.
- The alternative enumeration is bounded by path length, candidate count, and
  work done, and reports truncation rather than a false "no alternative".
- Regression: `tools/verify_path_ambiguity.py`, in the smoke suite.

#### `ADD OR REPLACE FACT`

- Semantic SQL had `ADD OR REPLACE METRIC` but no fact equivalent, so adding
  one fact meant restating every fact in the object through `REPLACE FACTS`.
  Facts are the primitive metrics compose from, which made it the wrong
  operation to omit.
- `ALTER SEMANTIC VIEW <model>.<object> ADD OR REPLACE FACT <name> ON ENTITY
  <entity> AS <expr> RETURNS <type> ...` now upserts one fact and leaves the
  object's other facts in place.
- Fixed while validating: a statement carrying only `REPLACE FACTS` was
  rejected with `SEMANTIC_DDL_012` — whose message listed `REPLACE FACTS` as an
  accepted form. Fact-only statements now parse.
- The two single forms each consume the rest of the statement, so combining
  them with each other or with a `REPLACE` block is refused explicitly
  (`SEMANTIC_DDL_037`) instead of silently absorbing the tail.
- Fact *removal* still has no DDL form; that waits until dependent-metric
  rewrites are transactional, and the docs now say so where the forms are
  listed.

#### Build provenance in the catalog

- The database recorded nothing about the product build serving it: the only
  version-ish catalog objects described semantic model versions, and
  `install.py` never mentioned a version at all. Diagnosing "identical
  catalogs, different behaviour" meant comparing schemas by hand and guessing
  from install timestamps.
- `tools/install.py` now records one row per run in
  `SYS_SEMANTIC.PRODUCT_INSTALLATIONS`: version from `CHANGELOG.md`, release
  state (`RELEASED`/`DEVELOPMENT`), git commit and clean/dirty state, a
  SHA-256 over the install SQL as executed, and who installed it when.
- `SEMANTIC_CATALOG.PRODUCT_VERSION` answers "which build is this?" in one
  query, with `DISPLAY_VERSION` folding in the release state (`0.1+dev`).
  `SEMANTIC_CATALOG.PRODUCT_INSTALL_HISTORY` keeps every install recorded
  against the database, so a runtime upgrade stays visible afterwards.
- The installer prints the same line on completion.
- `RUNTIME_CHECKSUM` is the discriminator that survives a tarball, a vendored
  copy, or uncommitted edits, where git provenance does not. `verify_milestone1`
  asserts the recorded checksum matches the install SQL on disk.

#### `SET_RELATIONSHIP`

- Relationships were add-only. Re-adding was refused as a duplicate
  (`SEMANTIC_ADMIN_016`) and removing was refused while key mappings existed
  (`SEMANTIC_ADMIN_066`), so correcting a cardinality or a fanout policy meant
  a four-step sequence: remove the mappings in descending ordinal order, remove
  the relationship, add it back, re-add the mappings. That is the operation the
  fan-out reason codes push modelers toward.
- `SEMANTIC_ADMIN.SET_RELATIONSHIP(MODEL_NAME, RELATIONSHIP_NAME,
  JOIN_CONDITION, CARDINALITY, JOIN_TYPE, FANOUT_POLICY)` edits one
  relationship in place. Any argument left `NULL` keeps its stored value,
  `FANOUT_POLICY = 'NONE'` clears the column, and key mappings survive the
  edit.
- Endpoints are deliberately not editable: changing them makes it a different
  relationship whose key mappings no longer describe it.
- On a PUBLISHED model the change validates prospectively and is restored on
  error (`SEMANTIC_ADMIN_098`), matching `REMOVE_RELATIONSHIP`'s
  `SEMANTIC_ADMIN_094`. On a draft the change applies and validation runs go
  stale; compilation is gated on validation status, so nothing can query the
  model until it is revalidated.
- Regression: `tools/verify_set_relationship.py`, in the smoke suite.

### Fixed
#### `--reset` could not remove an orphaned published schema

- Published schemas were discovered only from the catalog, so one whose model row
  was already gone survived every future `--reset` — a fully typed,
  BI-discoverable surface with no model behind it. Worse, an unreadable catalog
  was silently treated as "nothing was published", which is exactly the case that
  manufactures orphans.
- Discovery now also scans for the `SEMANTIC_DISCOVERY` table `PUBLISH_MODEL`
  always creates, which is the physical evidence of a published schema. A failure
  to read either source is reported rather than swallowed, and if *neither* can
  be read the reset refuses instead of dropping only the managed schemas.

#### `CLARIFICATION_JSON` was never populated for an unknown field

- The column is part of the published nine-column contract and documented as the
  agent's disambiguation channel, but only ambiguity ever filled it — the most
  common agent mistake, an unknown field, returned a dead end.
- An unknown field now returns `NEEDS_CLARIFICATION` with near-miss candidates
  from the same object, or names the semantic view the field actually belongs to,
  both in the message and in `CLARIFICATION_JSON`.
- **Contract note:** the status of an unknown-field refusal changes from `ERROR`
  to `NEEDS_CLARIFICATION` *only when there is something to clarify*. With no
  near-miss and no other view, the field is simply wrong and the status stays
  `ERROR`, so a consumer keying on `ERROR` sees a change only where the compiler
  now has an answer to offer.

#### `SEMANTIC_ADMIN_019` did not say who owned the name

- Dimension names are unique per *model*, not per semantic view. "duplicate
  dimension: ship_mode" gave no hint that another view owned it, nor that there
  is no operation to share one dimension between views. The refusal now names the
  owning entity and views and states the rule; `docs/creating-metrics.md`
  documents the scoping.
- A view that ends up with metrics and no dimensions — the visible symptom of
  dimensions refused during authoring — is now reported by validation
  (`SEMANTIC_MODEL_058`) instead of publishing a single grand-total column
  quietly.

#### F3 coverage on a shared entity silently broke another object's dimensions

- Orders are commonly both the grain of one object's metrics and the join hop
  another object's dimensions hang off. Declaring F3 coverage on such an entity
  was accepted with no validation error, and every dimension the *other* object
  exposed from it became permanently unqueryable (`SEMANTIC_REQUEST_074`) while
  the published contract still advertised the columns.
- The metric/dimension matrix now marks those pairs invalid with
  `FUSION_PARTITION_DIMENSION_UNSUPPORTED`, so `VALIDATE_MODEL` names every
  affected pair (`SEMANTIC_MODEL_030`) with the remedy, `PUBLISH_MODEL` refuses,
  and on a published model the coverage declaration itself is rejected and
  restored. Pairs whose metric *is* based on the partitioned entity stay valid —
  that is what F3 supports.
- Regression: `tools/verify_metric_plannability.py`.

#### Agent surfaces reported unqueryable metrics as valid and ready

- `VALID_COMBINATIONS_FOR_AGENT`, `FIELDS_FOR_AGENT`, and `MODELS_FOR_AGENT` all
  agreed that a metric the compiler always refuses was valid, certified, and
  ready. This is the historical BUG-003 class, reached through metric
  plannability rather than path divergence.
- Closed from both ends: an unplannable metric can no longer validate at all
  (`SEMANTIC_MODEL_056`/`_057`), and the matrix now reflects F3 joined-dimension
  reachability, so the agent views inherit the correct answer.
  `docs/known-issues.md` records the reproduction and the general lesson — pair
  every new compiler refusal with an authoring-time rule.

#### The preprocessor guard told you to enable an already-enabled preprocessor

- Querying an orphaned published schema — one whose model was dropped or reset
  away — fell through to the view's own guard, which could only advise running
  `ENABLE_SEMANTIC_SQL()`: the thing the user had just done.
- The preprocessor now recognises a schema that carries the `SEMANTIC_DISCOVERY`
  table `PUBLISH_MODEL` creates but that no active model claims, and refuses with
  `SEMANTIC_QUERY_005` naming it as an orphaned publication and giving both ways
  out. Ordinary non-semantic queries still pass through untouched.

#### `SEMANTIC_MODEL_042` did not say a `TIMESTAMP` literal is required

- Hot/cold splits are usually written on a `DATE` column, so `DATE '2026-07-01'`
  is the natural bound to type — and the canonical-form message read as though
  the interval did not match, when it did.
- The message now names the near-miss: *"Found DATE '2026-07-01': a coverage
  bound must be a TIMESTAMP literal, so write TIMESTAMP '2026-07-01 00:00:00'"*.

#### F4 contributor joins emitted non-executable SQL for a lower-case key column

- Attribute Reconciliation rendered the entity's declared
  `UNIQUE_KEY_COLUMN.COLUMN_NAME` inside double quotes verbatim. Exasol resolves
  a quoted identifier exactly, so a key declared `customer_id` — the case the
  shipped demo model itself uses — produced `f4_rep_27."customer_id"` against a
  physical `CUSTOMER_ID`. Validation reported zero errors, compilation returned
  `STATUS = OK` with correct fusion provenance, and the SQL then failed at
  execution. F4 worked only where keys happened to be declared upper case, which
  is why the five shipped fusion verifiers were green.
- The validator's conflict probe had always resolved declared names against
  `EXA_ALL_COLUMNS`; the compiler had not. That resolution now lives in one
  shared module (`lua/semantic_layer/shared/source_columns.lua`, embedded in both
  runtimes), so what the validator probes and what the compiler renders cannot
  disagree. Each side of the join resolves against its own source.
- Where the metadata cannot answer — a source outside `EXA_ALL_COLUMNS` — the
  declared spelling is used, exactly as before. The validator's conflict probe
  remains the gate that refuses a key column no source exposes, and it runs for
  precisely the two strategies that build this join.
- Regression: `tools/verify_fusion_f4.py` now declares its key in lower case, as
  a modeller would, and asserts the rendered join resolved it.

#### `SET_ATTRIBUTE_FUSION_POLICY` and `SET_REPRESENTATION_AUTHORITY` were not prospective

- Both persisted the change and returned successfully even when the candidate
  left a **published** model failing validation, so one accepted call took a live
  model offline for every consumer (`SEMANTIC_QUERY_010`) until someone worked
  out which change to undo. The same gap let `RECONCILE` land on an attribute
  whose bindings could not support it.
- Both now follow the candidate-validate-restore path the representation
  mutators already used: on a published model an invalid candidate is rejected
  and the prior policy or authority restored (`SEMANTIC_ADMIN_094`). Drafts keep
  the contract every other draft mutator has — applied and marked stale, because
  compilation is gated on validation status and reverting would block the repair
  in progress.
- Deliberately *not* done: rejecting `COALESCE`/`RECONCILE` on a `FACT` outright.
  The compiler refuses reconciled facts only in a multi-fact plan
  (`SEMANTIC_REQUEST_074`); single-branch fact reconciliation is supported,
  documented, and exact, so a blanket rejection would have removed a working
  capability. The prospective validation is what prevents the broken state.
- Regression: `tools/verify_fusion_governance.py`, in the smoke suite.

#### Diagnostics did not name the alternate representation that blocks authoring

- Registering an alternate representation on a draft is accepted and leaves the
  model invalid until the declaration is completed. Every later authoring call
  then failed on the representation rather than on what was attempted, and the
  recovery — `REMOVE_ENTITY_REPRESENTATION` — appeared in no message.
- Representation-scoped validation messages now name the blocking representation
  and both ways out: complete the declaration (F3 coverage, attribute bindings,
  or a certified F5 identity), or remove it. The suffix is added only when every
  named representation is an `ALTERNATE`, since a `PRIMARY` cannot be removed.
  `SEMANTIC_ADMIN_091`/`_092` inherit it, because they quote the validator.

#### The documented F3 bootstrap order could not work

- The bootstrap sequence put `SET_REPRESENTATION_COVERAGE_BATCH` after facts and
  dimensions, and a second passage said to add all representations and attribute
  bindings first. Both fail: until coverage exists the alternate is validated as
  an F1 *equivalent*, and hot/cold key sets are disjoint by construction
  (`SEMANTIC_MODEL_038`).
- `SKILL.md`, `references/authoring-workflows.md`, and `docs/data-fusion.md` now
  give the rule: declare the partition and its coverage as one candidate with
  `ADD_ENTITY_REPRESENTATION_WITH_COVERAGE` — verified to work on a draft whose
  object already has dimensions, facts, and metrics — or, when registering
  separately on a draft, call `SET_REPRESENTATION_COVERAGE_BATCH` immediately
  afterwards, before adding any attribute to that entity.

#### The legacy entity key expression was a silent trap

- `SEMANTIC_CATALOG.ENTITIES.PRIMARY_KEY_EXPR` reads as *the* entity key. It is
  not: grain proofs, path safety, and relationship key matching all use
  `UNIQUE_KEYS`/`UNIQUE_KEY_COLUMNS`, and the expression is consumed only by
  `SUGGEST_GRAIN_METADATA` and OSI export, only when it is exactly
  `alias.column`. The validator's own messages already called it "Legacy
  primary-key expression".
- The catalog view now exposes it as `LEGACY_PRIMARY_KEY_EXPR` — the vocabulary
  the runtime already used. **Breaking for readers of that view column**;
  `SYS_SEMANTIC.ENTITIES.PRIMARY_KEY_EXPR` is unchanged, and the OSI document
  field keeps its spec name `primary_key_expr`.
- New `SEMANTIC_MODEL_054` (warning): the expression does not reference every
  column of the entity's declared primary key, naming the columns it misses, so
  an expression that is not unique at the entity's grain no longer sits in the
  catalog unremarked. A warning, not an error, because nothing proves against
  the expression.


#### The installer claimed a publish it never performed

- `install.py --example` printed "Sales model published at
  SEMANTIC_SALES.SALES" while leaving the model `DRAFT`. Loading a model does
  not create its published schema — `PUBLISH_MODEL` does — so `SEMANTIC_SALES`
  did not exist at all, and a BI client reading JDBC/ODBC metadata found
  nothing. Semantic SQL worked anyway, because the preprocessor rewrites from
  the catalog rather than from the view, which is what made the missing publish
  easy to miss.
- The summary now says what actually happened: `loaded (DRAFT — no published
  schema yet)` with the one command to publish, or `published at
  SEMANTIC_SALES.SALES (typed views, BI-discoverable)`.
- New `--publish` flag (implies `--example`) validates and publishes the demo,
  so a BI-discoverable install is one command:
  `python3 tools/install.py --example --publish`.
- Left opt-in rather than publishing the demo by default: a published model is
  a governed contract, where authoring requires compound declarations and every
  candidate state is validated prospectively. That is correct for production and
  friction for a model people poke at while learning — including this repo's own
  validation suite, which works by deliberately breaking the demo model.
- README gains a **What BI Tools See** section: discovery through
  `EXA_ALL_COLUMNS` is adapter-free once published, the governance layer lives
  in `SEMANTIC_CATALOG`/`SEMANTIC_AGENT` rather than in JDBC metadata, and
  querying still needs a session that can activate the preprocessor. The
  headline claim now says so instead of "BI tools can discover typed views".

#### `FANOUT_POLICY` was undocumented free text

- The column accepted any string (`'banana'` was stored verbatim and validated
  clean). It is now a closed set — `REFERENCE_ONLY`, `DEDUPLICATE`, `ALLOCATE`
  — matched case-insensitively and stored upper-case.
- `ADD_RELATIONSHIP` refuses an unrecognized value on write with
  `SEMANTIC_ADMIN_003`, the same way it already refused an unrecognized
  cardinality or join type. Semantic DDL and OSI import write through that
  script, so they inherit the check; importing a legacy model whose policy is
  outside the set now fails loudly there.
- New `SEMANTIC_MODEL_053` (**warning**, not error, so stored models keep
  validating) fires for a value that predates the write-path check, and for a
  policy declared on a cardinality where it has no meaning.
- Documented in `docs/validation-rules.md#fanout-policy`: what the column is,
  how to set it, what each value means, and that **no value authorizes
  traversal** — the values record intent for a technique a planner may one day
  prove. `docs/creating-metrics.md` no longer tells readers to "check the
  fanout policy" when a metric/dimension pair is rejected.

#### Fan-out refusals named a remedy that does not exist

- The reverse of a `MANY_TO_ONE` (and the forward direction of a
  `ONE_TO_MANY`) was reported as `FANOUT_REQUIRES_POLICY`, but
  `FANOUT_POLICY` was never consulted for those directions: declaring one
  changed nothing, so the message sent modelers after a remedy that could not
  work. Verified against a `MANY_TO_ONE` carrying `FANOUT_POLICY = 'ALLOCATE'`,
  which was still refused with the same "requires policy" reason.
- Those edges now report `ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED`, the code the
  strict lane already used for the identical situation, so both lanes share one
  vocabulary and no reason code names a remedy. With many-to-many traversal
  also refused, no reason code implies a policy would help — because none
  would.
- `SEMANTIC_MODEL_030` now states the remedy that does exist for a fanning
  pair: expose the metric only alongside dimensions reachable from its base
  entity without fan-out, or drop one of the two from the object.
- Callers reading `REASON_CODE` from `METRIC_DIMENSION_MATRIX` or
  `VALID_COMBINATIONS_FOR_AGENT` see the new value; there is no compatibility
  alias, since the old one was actively misleading.

#### Many-to-many traversal silently double counted

- A `MANY_TO_MANY` relationship with any non-empty `FANOUT_POLICY` was treated
  as a safe edge by the legacy join lane and compiled to a flat join with no
  de-duplication, so a measure whose row matched several partners was counted
  once per partner. `plans/architecture-decisions/001-grain-aware-result-semantics.md`
  had always specified the opposite ("a fanout policy is not an allocation
  proof"), and `STRICT_GRAIN` already refused it.
- The shared grain graph now marks many-to-many edges unsafe in both
  directions with reason `MANY_TO_MANY_UNSUPPORTED`, so validation rejects a
  visible metric/dimension pair that needs one (`SEMANTIC_MODEL_030`) and the
  compiler refuses the request (`SEMANTIC_REQUEST_042`).
- `SEMANTIC_REQUEST_042` now names the blocking relationship and reason instead
  of only reporting that no safe path exists. Path rejection text moved from
  the validator into the shared graph so both runtimes phrase it identically.
- A declared `FANOUT_POLICY` still satisfies `SEMANTIC_MODEL_010`; the rule
  message now says a policy declares intent and does not authorize traversal.
- Regression: `tools/verify_many_to_many_refusal.py`, in the smoke suite.
- **Upgrade note:** a model that relied on many-to-many traversal changes from
  returning inflated numbers to failing validation on its next `VALIDATE_MODEL`
  (`SEMANTIC_MODEL_030`), which gates every compile for that model. Remove the
  offending metric or dimension from the object, or root a separate semantic
  object on the other side of the bridge.

### Changed

#### `SEMANTIC_DDL_080` names which state blocked a metric lookup

- A dropped metric is deactivated, not deleted: it stays in
  `SEMANTIC_CATALOG.METRIC_OVERVIEW` as an `INACTIVE` row whose `OBJECT_NAME` is
  `NULL` once its last membership is gone. `DROP METRIC` answering "metric not
  found" for a metric the reader can still see read as a contradiction.
- `DROP METRIC` and `RENAME METRIC` now distinguish the three states: already
  dropped (naming the `INACTIVE` row and how to re-add it), active but a column
  of a different semantic view (naming that view), and genuinely absent (the
  original wording, now naming the view searched).
- `docs/creating-metrics.md` documents the deactivate-not-delete lifecycle and
  the `STATUS = 'ACTIVE'` filter for the live surface.

#### Compile results are read by column name

- `EXECUTE SCRIPT` result sets are named — `RETURNS TABLE` carries the names over
  the wire — so nothing needs to know which index `GENERATED_SQL` sits at.
  Positional reads are what turned one wrong column layout in the docs into
  consumers silently reading `NULL`.
- `tools/semantic_client.py` now maps compile results by the result set's own
  column names. `CLAUDE.md` documents that pattern instead of a hardcoded index
  map, and points at the queryable contract.
- Regressions: `tools/verify_catalog_introspection.py` (in the smoke suite)
  asserts every published contract row against each script's live result set and
  `CATALOG_COLUMNS` against `EXA_ALL_COLUMNS`; `tests/test_semantic_client.py`
  asserts the same contract against the install SQL without a database, and that
  the client never indexes a result row positionally.

#### `EXASOL_PORT` is documented where the other connection variables are

- The README listed `EXASOL_HOST`, `EXASOL_USER`, and `EXASOL_PASSWORD` but not
  the port, which `install.py --help` documented all along. On Exasol Personal
  only the first deployment gets 8563, so overriding the port is the common
  case; the README now shows the variable, the `--port` flag, and how to read
  the port back out of a deployment.

#### The sales demo model is multi-grain, so fan-out protection is demonstrable

- `MART.ORDERS` gained `FREIGHT_AMOUNT` and `SHIP_MODE`; `MART.CUSTOMERS` gained
  `SEGMENT`.
- A second semantic object, `ORDER_HEADER` (rooted at `order`), exposes
  `total_freight` over `ship_mode` and `customer_segment`. Every fact in the
  previous demo sat at the `order_line` leaf and every relationship pointed
  outward from it, so fan-out was structurally impossible and the model's
  central safety property could not be observed from the shipped example.
- `tools/verify_fanout_guardrails.py` walks through and asserts the guarantee:
  safe traversals match hand-written SQL, the same order-grain metric is
  refused in the line-grain `SALES` object with `SEMANTIC_MODEL_030` /
  `ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED` and a rolled-back catalog, and the
  overstated number the refusal prevents is printed. It runs as part of
  `tools/run_smoke.sh`.

## [0.1] - 2026-08-19

### Added

#### Fusion Phase F3: temporal partition unions

- Representations can declare certified coverage predicates and half-open
  validity intervals through `SET_REPRESENTATION_COVERAGE`.
- The compiler expands partitioned metric leaves into representation-specific
  aggregate-state branches, combines them with `UNION ALL`, and records source,
  coverage, validity, and binding provenance in `PLAN_JSON`.
- Validation requires complete, contiguous, non-overlapping, open-ended
  coverage and proves key uniqueness per partition without requiring disjoint
  partitions to contain identical key sets.
- F3 supports mergeable `SUM` and `COUNT` states. Partitioned joined dimensions
  and materialization substitution remain fail-closed for later phases.

### Fixed

#### Unusable F3 partition declarations

- Once a model has active metrics, `VALIDATE_MODEL` now rejects coverage on an
  entity that is the base of none of them, because F3 cannot fuse an entity used
  only as a joined dimension. Empty-model authoring remains repairable while
  its first metric is created.
- `SEMANTIC_MODEL_043` names the entity and blocks publication before existing
  dimension queries can regress to `SEMANTIC_QUERY_074`.

#### F3 fail-closed diagnostics

- F3 typed-planning errors now name the unsupported metric and aggregate, the
  partitioned entity, or the joined dimension/filter that caused refusal.
- Incomplete partition bindings now name the missing attribute and partition
  and prescribe `ADD_ATTRIBUTE_BINDING` instead of reporting only the entity.

#### F3 coverage predicate certification

- `VALIDATE_MODEL` now requires every F3 runtime predicate to exactly encode
  its declared half-open validity interval over one qualified temporal column.
- Mismatched, overlapping, gapped, or free-form predicates fail
  `SEMANTIC_MODEL_042` before publication instead of invalidating the interval
  proof and silently changing `UNION ALL` results.

#### Multi-representation probe timeout

- `VALIDATE_MODEL` now refuses every multi-representation F1/F3 key probe unless
  the caller configured session `QUERY_TIMEOUT` between 1 and 60 seconds.
- The guard no longer classifies source schemas, so declared `RELATION` sources,
  normalization views over Virtual Schemas, and deeper dependency chains cannot
  bypass it.
- The bounded timeout applies to the complete Exasol script, turning an
  intermittently stuck federated probe into a database timeout instead of an
  unbounded validation session.

#### Primary representation selection

- F2 complete-candidate ranking now prefers the representation currently marked
  `PRIMARY` before representation priority and ID, so promotion is effective
  when retained defaults and explicit bindings otherwise rank equally.
- Binding role and binding priority remain authoritative ahead of the primary
  tie-breaker, preserving intentional attribute fallback.

#### Remote representation validation cost

- `VALIDATE_MODEL` now defers F1 source probes until local catalog validation is
  clean, so invalid authoring states do not scan federated representations.
- Each representation's distinct-key cardinality is probed once per declared
  key instead of rescanning the primary for every alternate; exact
  bidirectional key-set proofs remain unchanged.

#### Attribute-binding repair ordering

- `ADD_ATTRIBUTE_BINDING` now compares validation before and after the
  candidate mutation, allowing bindings to repair multi-column representation
  mismatches sequentially while still rolling back newly introduced errors.
- Intermediate representation errors continue to block publication until all
  required bindings are present and validation succeeds.

#### Representation identity scope diagnostics

- The modeler workflow now requires exact preflight checks for physical key and
  join-column names before registering an alternate representation.
- Identity-related validation errors now explain that F2 binds dimensions and
  facts only, recommend a canonicalizing source view, and identify native
  representation identity binding as a Phase F5 capability.

#### Representation promotion binding safety

- `SET_PRIMARY_REPRESENTATION` no longer moves a compatibility default onto an
  incoming representation that already has an explicit binding for the same
  attribute.
- Promotion detects and repairs stale default/explicit collisions created by
  older F2 installs before enforcing the clean-validation gate, restoring a
  supported rollback route for affected models.

#### Unary null predicates

- Structured filters and `having`, plus Semantic SQL `WHERE` and `HAVING`, now
  support unary `IS NULL` and `IS NOT NULL` predicates without a value.
- The machine-readable agent contract now exposes explicit entries for both
  operators, matching the runtime compiler.

#### Strict structured-request keys

- `COMPILE_REQUEST_JSON` now rejects unknown top-level keys with
  `SEMANTIC_REQUEST_004` instead of silently dropping them during `QuerySpec`
  normalization.
- `COMPILE_REQUEST_SCHEMA_FOR_AGENT` exposes all 12 accepted top-level keys so
  autonomous callers can validate capability assumptions before compiling.
- Regression coverage includes nested-output requests, deterministic unknown-key
  diagnostics, request logging, and the live database contract.

### Added

#### Semantic fusion Phase F2

- Dimensions and facts now support representation-specific expressions through
  governed `ATTRIBUTE_BINDINGS` with deterministic `PREFER` and `FALLBACK`
  source selection.
- The compiler selects one complete representation per entity, records binding
  provenance in plan version 9, and fails with `SEMANTIC_REQUEST_080` rather
  than combining partial sources.
- Legacy attributes receive compatibility-default bindings automatically;
  primary representation promotion moves only those defaults and leaves
  explicit F2 bindings unchanged.
- Added binding lifecycle scripts, catalog visibility, validation rules
  `SEMANTIC_MODEL_039`/`040`, cache invalidation, rollback coverage, and
  modeler-skill guidance.

#### Official Exasol MCP Server integration

- Added a user and autonomous-agent workflow for discovering, activating, and
  verifying `SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` through the official MCP
  server before executing governed semantic SQL.
- Documented server settings, reconnect behavior, view-discovery fallbacks, and
  the requirement to put `LIMIT` in semantic SQL instead of using MCP
  `row_limit`.
- Published MCP guidance with each semantic model and updated the semantic
  analyst skill to distinguish the direct MCP path from the optional structured
  semantic adapter.

#### Grain-aware aggregation Phase D2

- Plan version 7 / physical-plan version 4 can replace one complete proven
  multi-fact leaf with an aggregate materialization while leaving other leaves
  on their base sources.
- Branch candidates must provide every required dimension and mergeable state
  with a matching `SUM` rollup policy. Selection prefers the least excess
  dimensionality and then the stable materialization ID.
- Private aggregate-state producers are eligible without becoming public
  object columns. Partial, filtered-state, finalized-only, inactive, and unsafe
  candidates produce deterministic diagnostics and whole-leaf base fallback.
- The maintained live lane compares all-base, hybrid, and fully materialized
  results, including sparse states, ratios, filters, `HAVING`, grand totals,
  cache determinism, and metamorphic branch isolation.

#### Grain-aware aggregation Phase D1

- Multi-branch physical plans now identify every branch's physical source as a
  deterministic base-source contract and expose measured branch-count and SQL
  size safeguards under plan version 6 / physical-plan version 3.
- Successful compiler calls record planner runtime in the existing
  `AGENT_REQUEST_LOG.RUNTIME_MS` and `QUERY_LOG.RUNTIME_MS` fields without
  putting nondeterministic timing into cached plan JSON.
- The maintained live multi-fact lane now covers differential and metamorphic
  correctness before materialized branch substitution is introduced.
- Leaf-local metric predicates no longer create a false conformance proof
  requirement, while legacy single-branch non-mergeable aggregates retain
  their compatibility renderer and strict or multi-branch plans reject them.

#### Grain-aware aggregation Phase C3

- Plan-version 5 multi-fact requests now finalize mergeable states after the
  cross-branch rollup, compute derived metrics in dependency-ordered CTEs, and
  return executable SQL through both structured JSON and Semantic SQL.
- Final `COUNT` states use zero for groups supplied only by another branch;
  `SUM` states retain SQL nullability. `HAVING`, output ordering, and limits are
  applied only after scalar finalization.
- Successful multi-branch compiles now use the normal versioned compile cache.
  Existing single-branch SQL continues to use the legacy-compatible renderer.
- Private metrics now remain hidden in semantic-object column metadata. They can
  therefore serve as transitive state dependencies without expanding the
  object's public compatibility surface.

#### Grain-aware aggregation Phase C2

- Plan-version 4 multi-fact requests now include a typed
  `PhysicalMultiBranchPlan` with one base-source branch per leaf entity,
  deterministic state columns, conditional metric-local aggregates, proven
  joins, typed sparse-state placeholders, and a `UNION ALL` merged-state
  pipeline.
- The multi-branch renderer is protected by fixed branch-count and
  generated-SQL-size safeguards.
- Physical binding failures return `_075` with a stable plan-level reason.

#### Grain-aware aggregation Phase C1

- Multi-fact additive requests lower to a `MULTI_BRANCH`
  logical plan with normalized fact/state/finalizer nodes, bound filter scopes,
  strict branch-to-dimension proofs, and stable requirement/proof/rejection
  identifiers. C1 initially kept valid plans behind `_073`; path-specific proof
  failures return `_074`.
- Single-branch SQL generation remains on the existing renderer.

#### Databricks Unity Catalog Metric View compatibility

- **Databricks UCMV import** — added
  `SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW`, which translates a supported
  Databricks metric-view YAML subset into native semantic catalog metadata and
  can optionally apply, validate, and publish the model. Unsupported constructs
  return `DBX_IMPORT_*` diagnostics.
- **Databricks SQL surface compatibility** — semantic SQL now accepts
  `MEASURE(metric)`, the `agg(metric)` synonym, and `GROUP BY ALL` against
  published semantic objects. The wrappers are supported in `SELECT`, `HAVING`,
  and `ORDER BY`; `MEASURE()` of a dimension returns `SEMANTIC_QUERY_006`.
- `tools/import_databricks.py`, `tools/verify_databricks_import.py`,
  `tools/verify_databricks_sql_compat.py`, and
  `sql/examples/sales_databricks_metric_view.yaml` cover host-side file import,
  end-to-end import verification, SQL-surface verification, and a runnable demo
  fixture.

#### Semantic SQL: optional GROUP BY

- **GROUP BY is now optional** — a semantic SQL query that selects dimensions without a `GROUP BY` clause (e.g. `SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES`) now compiles by inferring `GROUP BY` from the selected dimensions, instead of returning `SEMANTIC_QUERY_007`. The emitted SQL is identical to the explicit-`GROUP BY` form (`build_sql` already builds `GROUP BY` from the selected dimensions). When a `GROUP BY` *is* supplied it must still exactly cover the selected dimensions, otherwise `SEMANTIC_QUERY_008` is returned. `SELECT *` and metric-only queries are unaffected. Backward-compatible: previously valid queries still compile unchanged.
- `tools/verify_group_by_inference.py` — focused integration test covering inference, inferred-equals-explicit results, multi-dimension inference, rejection of a non-covering `GROUP BY`, and composition with WHERE/ORDER BY/LIMIT.

#### Semantic SQL: Phase 2 subset improvements

- **HAVING clause** — `HAVING total_revenue > 1000`, `HAVING total_revenue BETWEEN 100 AND 1600`, and multi-predicate `HAVING p1 AND p2` forms are now accepted in semantic SQL. The HAVING clause enforces metric-only predicates; dimension fields in HAVING return `SEMANTIC_QUERY_040`. BETWEEN in HAVING reuses the same `after_between` flag logic as WHERE.
- **`WHERE metric > N` auto-routing** — metric predicates written in the WHERE clause (e.g. `WHERE total_revenue > 0`) are silently routed to HAVING at parse time. Dimension predicates remain in WHERE. Mixed `WHERE dim_filter AND metric_filter` clauses are split correctly.
- **`having` key in `COMPILE_REQUEST_JSON`** — the structured request model now accepts an optional `having` array with the same filter-object shape as `filters`. Each entry must reference a metric field. `COMPILE_REQUEST_SCHEMA_FOR_AGENT` documents the new key.
- **Materialization bypass** — queries with any HAVING predicate skip materialization selection and always use the full physical SQL path (required because materialized column names cannot be referenced in HAVING expressions).
- `tools/verify_semantic_sql_phase2.py` — 93-assertion integration test script covering HAVING, auto-routing, `COMPILE_REQUEST_JSON having`, materialization bypass, preprocessor path, and Phase 1+2 regressions.

#### Semantic SQL: Phase 1 subset improvements

- **ORDER BY ordinals** — `ORDER BY 1 DESC`, `ORDER BY 2, 1 ASC`, and mixed ordinal/name forms are now accepted in semantic SQL. Resolves ordinals against the SELECT list exactly as GROUP BY already did. Out-of-range ordinals return `SEMANTIC_QUERY_060`.
- **BETWEEN in WHERE** — `WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'` now compiles correctly. The AND-splitting loop in `parse_where_filters` uses an `after_between` flag to distinguish the BETWEEN value separator from a conjunction boundary. Works in any position within a multi-predicate WHERE clause including between other AND-joined predicates. New error codes: `SEMANTIC_QUERY_034` (missing AND separator), `SEMANTIC_QUERY_035` (non-literal values).
- `tools/verify_semantic_sql_phase1.py` — 67-assertion integration test script covering both new features and full regressions.

### Changed

- Databricks UCMV nested join path resolution now registers both absolute and
  relative snowflake paths and binds expressions to the deepest matching join
  entity, so fields such as `customer.nation.n_name` resolve to the nested
  `nation` entity instead of the parent join.
- `lua/semantic_layer/compiler/request_json.lua` — `parse_semantic_sql` no longer requires a `GROUP BY` clause when dimensions are selected; the `GROUP BY` coverage validation now runs only when a `GROUP BY` is supplied (`SEMANTIC_QUERY_007` removed). `tools/verify_milestone4.py` updated to assert the inferred-GROUP BY query now succeeds.
- `lua/semantic_layer/compiler/request_json.lua` — `find_top_level_clauses`, `clause_end`, `build_sql`, `compile_request_table`, and `parse_semantic_sql` updated for Phase 2; `parse_having_filters` added (~95 lines total). `parse_where_filters` and `parse_order_by` updated for Phase 1. Source file is the canonical implementation; `sql/install/003_create_semantic_admin_scripts.sql` is generated by `python3 tools/package_lua_scripts.py`.
- `sql/install/006_create_semantic_agent_views.sql` — `COMPILE_REQUEST_SCHEMA_FOR_AGENT` view updated with `HAVING_KEYS` documentation row.

### Removed

- `skills/exasol-semantic-views-agent/` — replaced by the two focused skills above.

---

## Notes on versioning

Version 0.1 is the first tagged release. Items above are tracked against the
development baseline established by the user-study simulations run on
2026-05-13. Phase 1 and Phase 2 are complete. The next planned milestone is
Phase 3 (subqueries/CTE rewriting and CAST in SELECT — deferred pending demand).
