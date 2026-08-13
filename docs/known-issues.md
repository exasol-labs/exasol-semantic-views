# Known Issues

This file tracks known issues and their **verified status per Exasol version**. Unlike the
previously-referenced `reports/bug-log.md` (which lives in a git-ignored working directory and is
not part of a fresh checkout), this document is checked in and is the authoritative list.

Last full verification: **Exasol 2026.1.0** (`exasol/docker-db:latest-2026.1`), 2026-06-15, against
a clean `python3 tools/install.py --example --reset` install.

Documentation and implementation-boundary audit: **2026-08-13**. This audit
checked the current Lua, install SQL, and maintained verifier inventory; it does
not replace the dated live-runtime verification above.

## Resolved / documentation fixes

### `COMPILE_REQUEST_JSON` column layout (fixed)

`COMPILE_REQUEST_JSON` returns the **same 9-column** result set as `COMPILE_SQL`
(`STATUS, ERROR_CODE, ERROR_MESSAGE, ORIGINAL_SQL, GENERATED_SQL, PLAN_JSON, CLARIFICATION_JSON,
VALIDATION_RUN_ID, AGENT_REQUEST_ID`), with `GENERATED_SQL` at **index 4**. `ORIGINAL_SQL` (index 3)
is `NULL` for JSON requests but the column is present, so positional indices align with `COMPILE_SQL`.

Earlier docs claimed an 8-column layout (`GENERATED_SQL` at index 3); a consumer following that read
`NULL`. The docs and the one stale test (`tools/verify_semantic_sql_phase1.py`) have been corrected.
The rest of the tooling (`tools/semantic_client.py`, `verify_milestone3.py`,
`verify_dimension_discovery.py`, `verify_claude_study_issues.py`) already used the correct mapping.

## Historical bugs — status on Exasol 2026.1.0

These were tracked in the old git-ignored `reports/bug-log.md`. None reproduce on a clean install of
Exasol 2026.1.0:

### BUG-001 — concurrent `COMPILE_REQUEST_JSON` transaction collisions

- **Symptom (historical):** concurrent compiles raised `SEMANTIC_REQUEST_999` / `_100`.
- **Status on 2026.1.0:** **Not reproduced.** `tools/verify_concurrent_compile.py` ran 48 compiles
  across 6 threads — all `STATUS=OK`, no `SEMANTIC_REQUEST_100`/`_999` leakage.

### BUG-002 — `order_quarter` dimension uses `QUARTER()` (not an Exasol function)

- **Symptom (historical):** the `order_quarter` dimension compiled but failed at execution because
  `QUARTER()` is not a valid Exasol function.
- **Status on 2026.1.0:** **Not present in the clean example.** `sql/examples/sales_model_seed.sql`
  does not define `order_quarter`; it only appears in the optional one-off
  `sql/examples/sales_model_fixup.sql`, where the expression is already corrected to
  `CEIL(MONTH(o.order_date) / 3.0)`. A clean `--reset` install seeds only `customer_region`,
  `order_month`, `order_status`, `product_category`.
- **Guidance:** expression validation uses a static function allowlist but does
  not compile SQL (see CLAUDE.md). Use documented Exasol functions and execute
  each dimension/fact expression against its source entity before registration.

### BUG-003 — `VALID_COMBINATIONS_FOR_AGENT` over-reports validity

- **Symptom (historical):** the agent view reported `IS_VALID=True` for some metric/dimension
  combinations the compiler rejected with `SEMANTIC_REQUEST_042`, caused by `find_path` diverging
  between `validator.lua` and the compiler.
- **Status on 2026.1.0:** **No mismatch on the clean demo.** All 20 metric × dimension combinations
  report `IS_VALID=True` and the compiler accepts them. The original report was tied to user-study
  artifacts not present in the clean seed.
- **Current safeguard:** validator and compiler path decisions delegate to the
  packaged `lua/semantic_layer/shared/grain_graph.lua`. Keep proof behavior in
  that shared module rather than adding planner-specific path rules.

## Deferred / not yet implemented (by design)

- Semantic SQL subqueries / CTEs and arbitrary `CAST` expressions in `SELECT`.
- A project-owned Virtual Schema adapter. Existing Virtual Schema relations can
  already be registered as entity representations.
- General `SEMI_ADDITIVE` and `WINDOW` metric execution. The catalog can
  represent them, but the typed planner has no state/finalization contract.
- Cross-branch exact distinct aggregation. Ordinary single-branch
  `COUNT(DISTINCT ...)` can use the legacy renderer; scalar partial distinct
  counts are not mergeable.
