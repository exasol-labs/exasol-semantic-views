-- Thresholds begin at an honest baseline and are enforced independently so a
-- well-tested small module cannot conceal an untested compiler or validator.
-- Raise a threshold whenever coverage increases; do not lower one to merge.
--
-- Values are floored to the nearest 0.1 pp below the actual observed
-- percentage so display-rounded floats (e.g. `hit/active × 100` == 70.8986
-- displaying as `70.90`) don't trip the gate on unchanged code. Ratcheted
-- 2026-08-22 after adding cache-key sensitivity + deterministic
-- fixed-length property tests, again after moving path-rejection
-- diagnostics out of the validator into the shared grain graph, and again
-- 2026-08-24 after reporting safe-path alternatives instead of selecting
-- silently between them, again after accepting quoted identifiers and naming
-- which state blocked a metric drop, and again after the fusion-study fixes
-- (plannability gate, request options, unknown-field clarification), and again
-- 2026-08-25 after closing F13/F17/F18 -- the verified-query request scope in
-- the agent runtime, and the metric-grain proof against the object root in the
-- validator -- and again the same day for BUG-G01, which added the
-- partitioned-join-hop refusal to the matrix, the logical planner, and the
-- physical renderer's backstop, and again for BUG-G03, which routed the F5
-- identity mapping columns through the shared resolver and covered the
-- previously untested mapped-base rendering.
--
-- admin/fusion_declaration.lua joined the gate 2026-08-26. Its end-to-end
-- claims -- one document on a published model, dry run, round-trip -- are
-- proven live in tools/verify_fusion_declaration.py, which this gate cannot
-- see; the unit tests cover the contract refusals, the operation order and
-- the rollback's column discovery.
--
-- shared/identity_join.lua joined the gate when it was extracted 2026-08-25:
-- one join that had been written out five times, and had already carried one bug
-- in all five. It is fully covered, so the floor is 100.
--
-- shared/source_columns.lua joined the gate with that change. It was loaded and
-- measured but ungated, which is a poor place for a blind spot: both runtimes
-- embed it, and it is the single point where a declared column name becomes the
-- physical one.
--
-- shared/rows.lua joined the gate 2026-08-31, at 100. It took the row-reading
-- prelude out of six modules, which moved covered lines out of their
-- denominators: admin/semantic_definition.lua measures 78.48 against the 78.53 it
-- reached before the extraction. That is one line of 2 277, all of it accounted
-- for -- 13 covered and 2 uncovered lines left the file and the 13 are now gated
-- at 100 here. Recorded rather than papered over, because a floor that drops
-- with no explanation is how a real regression gets through.
--
-- shared/sql_text.lua joined the gate 2026-08-31 with the same change, at 99.4
-- rather than 100 for one line the interpreter never reports: the `end` of the
-- line-comment `while` loop in the lexer is listed as an active line and no line
-- event ever fires for it, because the jump back to the test is attributed to
-- the `while`. Verified by tracing it directly rather than assumed.
--
-- shared/json.lua joined the gate 2026-08-31, when four private JSON codecs
-- became one. Floored at 100: a codec with an untested branch is a decoder that
-- accepts something no test has ever looked at, and the module is 75 active
-- lines. Ratcheted the same day after the extraction moved fully-covered lines
-- out of four files -- which lowers a percentage without lowering coverage, so
-- each of those was re-measured *after* adding tests that put it back above its
-- old floor rather than by lowering the floor. Net: semantic_definition.lua
-- 72.5 -> 76.1 (the DDL rollback's snapshot/restore round trip, previously
-- untested), agent/runtime.lua 93.4 -> 95.4 (instruction scope dispatch, four
-- of six branches previously uncovered), request_json.lua 87.1 -> 88.2 (the
-- HAVING predicate parser, whose WHERE twin was the only one tested),
-- query_spec.lua 96.7 -> 100.
--
-- request_json.lua 88.8 -> 88.9 on 2026-09-19, when the Semantic SQL lane
-- stopped loading the catalog before consulting the compile cache and stopped
-- loading it twice on a miss. The new tests assert the *statement* count, not
-- just the result: a cache hit that still loaded the catalog would return the
-- right SQL and cost 17 round trips, which is exactly the regression a
-- result-only test cannot see. See plans/preprocessor-latency.md.
-- sql_text.lua 99.5 -> 99.54 on 2026-09-20, when flatten_lines was added so a
-- spliced statement keeps the author's line numbers. The tests are worth more
-- than the ratchet here: the two cases that must not fold -- a newline inside a
-- string literal, and a line comment whose newline ends it -- are the ones that
-- would corrupt data or comment out the rest of a statement, and neither shows
-- up in the happy path this function was written for.
-- sql_text.lua 99.4 -> 99.5 on 2026-09-19, when output projection was added so
-- a SQL client gets its own select list back. Three defects shared one cause and
-- one fix: the planner's column order was returned instead of the caller's
-- (binding by position put the wrong data in each column, silently), `AS "c11"`
-- was discarded, and an unaliased column came back lower-case where the
-- published view advertises it upper-case. See plans/bi-and-generic-interface-support.md.
-- request_json.lua 88.9 -> 89.9 on 2026-09-19, when BI-generated SQL started
-- being accepted on its own terms: an aggregate wrapper is honoured only when
-- the metric declares it (SUM of a ratio refuses rather than returning the
-- ratio), COUNT(*) is refused because its answer depends on a grain the caller
-- never named, and the `WHERE 1 = 0` / `LIMIT 0` driver probes return a shape
-- instead of an error. Ratcheted again the same day to 90.0 for the latent bug
-- that work exposed: a parenthesised WHERE predicate leaked its closing paren
-- into the generated SQL, which stayed hidden only because those queries were
-- refused earlier for wrapping a metric in SUM().
-- See plans/bi-and-generic-interface-support.md.
-- request_json.lua 90.0 -> 90.1 on 2026-09-19, when a cache entry stopped being
-- trusted merely because the compiler is what usually writes it. COMPILE_CACHE
-- is a table: whoever can UPDATE it picks the text a published guarded view then
-- runs with the view owner's rights, with no compile in between. The read now
-- checks the statement against the relations the model declares, and the tests
-- cover both halves of that -- an entry reading an undeclared relation, and
-- `SELECT 'PWNED'`, which reads none and which a containment-only check would
-- wave through. See plans/combined-bi-and-governance-plan.md, C3.
-- validator.lua 94.2 -> 94.4 on 2026-09-19, when representations and
-- materializations stopped being governed by two sets of rules and got one
-- derived trust class. That split is how a materialization over the raw mart
-- could void a representation's row-level security: each was checked on its own
-- terms, neither was compared with the other. The tests drive the derivation
-- directly rather than through a full validate_model mock, so the classification
-- and both governance modes are exercised without a 200-line SQL fixture.
-- validator.lua 95.0 -> 95.1 and semantic_definition.lua 78.8 -> 79.1 on
-- 2026-09-24, when the DDL parser began refusing unrecognised clauses by name
-- and SEMANTIC_MODEL_073 began casting every declared data type (BUG-25).
-- validator.lua 94.9 -> 95.0 on 2026-09-24, when SEMANTIC_MODEL_072 began
-- binding dimension, fact and binding expressions against their relation.
-- validator.lua 94.8 -> 94.9 on 2026-09-22 (2678/2819 displays as 95.00%), when the two contributor-counting
-- conditions of SEMANTIC_MODEL_044 became SEMANTIC_MODEL_070 and _071 and
-- started naming what they counted. The unit test asserts the counts and the
-- names, not that an error fired: the old messages printed only their
-- requirement, and both were observably satisfied in the catalog when they
-- fired, so a rule that merely fires is exactly the thing that failed here.
--
-- agent/runtime.lua 95.5 -> 95.5 on 2026-09-20, when the governance block got a
-- prose rendering. The test asserts what the sentence has to *say*, not that a
-- sentence exists: it names the principal, the mode, each relation with its
-- trust class, and -- the part that matters -- the consequence, so a reader who
-- does not know what DIVERGENT means still learns what it costs them. A plan
-- from before this existed says nothing rather than guessing.
--
-- request_json.lua 90.3 -> 90.3 and validator.lua 94.8 -> 94.8 on 2026-09-20,
-- when the policy columns stopped being decorative. IS_PRIVATE / IS_HIDDEN now
-- refuse wherever the field is named -- filters included, or the filter lane
-- becomes the way around a field you cannot discover -- and DISPLAY_POLICY =
-- MASK refuses the projection while permitting the filter. The live behaviour
-- is proven in tools/verify_policy_columns.py, which this gate cannot see; the
-- unit test covers the resolver refusal, which is the one place every lane goes
-- through.
--
-- validator.lua 94.4 -> 94.8 on 2026-09-19, when a view compiled from a semantic
-- object started being tracked. Such a view is the one object here that can be
-- right when it is made and wrong later with nothing in it changing, so the
-- tests cover both ways that happens and the difference between them: a
-- superseded version is old and rebuildable, while a relation the model no
-- longer vouches for is a policy hole that has already opened -- an error in a
-- model that promised to be governed, a warning otherwise.
--
-- request_json.lua 90.1 -> 90.3 on 2026-09-19, when a statement that *wraps* a
-- semantic object started compiling instead of being refused. The tests cover
-- the two things that decide whether the answer is right rather than merely
-- produced: which columns get compiled, and whether the reference is composed
-- with another relation. The star case is there because it was a live defect --
-- an outer `SELECT *` over a subquery was read as "every column of the object",
-- which changed the grain and returned 0 for a region worth 3635, with no error.
-- See plans/combined-bi-and-governance-plan.md, step 7.
--
-- No threshold moved for the principal-scoped catalog (2026-09-19). The change
-- is a schema qualifier on 27 catalog reads plus one view in place of a
-- three-branch union, so it moves no branch: what it changes is which
-- privileges the caller needs, and that is provable only against a live
-- database with a real role hierarchy. tools/verify_effective_principal.py is
-- where it is proven; this gate cannot see it.
return {
    lines = {
        ["lua/semantic_layer/shared/json.lua"] = 100,
        ["lua/semantic_layer/shared/rows.lua"] = 100,
        ["lua/semantic_layer/shared/sql_text.lua"] = 99.54,
        ["lua/semantic_layer/shared/catalog_rollback.lua"] = 100,
        ["lua/semantic_layer/shared/grain_graph.lua"] = 95.7,
        ["lua/semantic_layer/shared/source_columns.lua"] = 92.5,
        ["lua/semantic_layer/shared/identity_join.lua"] = 100,
        ["lua/semantic_layer/compiler/query_spec.lua"] = 100,
        ["lua/semantic_layer/compiler/catalog_snapshot.lua"] = 100,
        ["lua/semantic_layer/compiler/metric_plan.lua"] = 94.0,
        ["lua/semantic_layer/compiler/physical_plan.lua"] = 86.6,
        ["lua/semantic_layer/compiler/grain_sql.lua"] = 98.5,
        ["lua/semantic_layer/compiler/request_json.lua"] = 90.39,
        ["lua/semantic_layer/admin/validator.lua"] = 95.1,
        ["lua/semantic_layer/compiler/materializations.lua"] = 92.2,
        ["lua/semantic_layer/admin/semantic_definition.lua"] = 79.1,
        ["lua/semantic_layer/admin/fusion_declaration.lua"] = 81.58,
        ["lua/semantic_layer/agent/runtime.lua"] = 95.78,
    },
    branches = 100,
}
