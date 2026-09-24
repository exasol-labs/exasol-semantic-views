# Changelog

All notable changes to Exasol Semantic Views are documented here.

---

## [Unreleased]

Two capabilities that were planned separately and shipped as one, because they
turned out to be the same problem: **BI tools could not use this layer**, and
**the layer could not tell you what it was protecting**. The BI work makes a
semantic object usable from ordinary SQL, which immediately widens what a caller
can reach; the governance work is what makes that safe to offer. Neither is
useful alone.

**Upgrading is not transparent.** Five changes alter behaviour for an existing
deployment — the policy columns now refuse, callers are granted a new schema
instead of `SYS_SEMANTIC`, a statement that joins a published object to
another table is refused by default, `METRIC_COMPATIBLE_DIMENSIONS` no
longer returns refused pairs, and a semantic DDL clause the parser used to
ignore is now refused. Each is called out below.

### Added

#### BI tools work, without asking every user to run a setup statement

- **A statement that *wraps* a semantic object now compiles.** Previously only a
  bare `SELECT … FROM SEMANTIC_X.OBJ` did, and a BI tool almost never emits
  that — it emits the object inside a TopN wrapper, a CTE, a subquery, a union, a
  window, arithmetic in the select list, `COUNT(*)`. Those are accepted by a
  second path that replaces the *reference* with a derived table rather than
  compiling the statement around it, leaving everything outside to Exasol.
  Of the 16 shapes exercised by `tools/verify_reference_expansion.py`, 13 now
  compile, 2 are refused as composition and 1 because no column of the object is
  named — and the values of every accepted shape are checked against the model
  rather than merely checked for not raising.
- **What expansion costs, per shape.** The single figure this entry used to
  quote — "+0.9 ms on a compile" — was measured on the shape where expansion does
  the least work, and is about 30× low for the shapes a BI tool actually emits.
  Measured interleaved, 40 rounds, all cache-warm, median:

  | shape | outcome | median | × bare |
  |---|---|---|---|
  | bare `SELECT a, b FROM obj` | OK | 162.6 ms | — |
  | aliased `SELECT t0.a, t0.b FROM obj t0` | OK | 157.9 ms | 0.97× |
  | TopN `… ORDER BY 2 DESC LIMIT 5` | OK | 161.8 ms | 0.99× |
  | subquery `SELECT x.a FROM (…) x` | OK | 234.5 ms | **1.44×** |
  | CTE `WITH z AS (…) SELECT …` | OK | 228.7 ms | **1.41×** |
  | arithmetic in the select list, **bare** | OK | 719.3 ms | **4.42×** |
  | the same, wrapped in a subquery | OK | 260.8 ms | 1.60× |
  | `ORDER BY` a non-selected field, **bare** | OK | 779.0 ms | **4.79×** |
  | the same, wrapped in a subquery | OK | 245.3 ms | 1.51× |
  | a composed statement, refused | `SEMANTIC_QUERY_012` | 272.5 ms | **1.68×** |
  | the same wrapped, refused | `SEMANTIC_QUERY_012` | 219.1 ms | 1.35× |

  The two bare/wrapped pairs are the constructs the single-lane change above made
  compile bare, and they are the expensive ones — which nothing measured at the
  time. The cause is not expansion. It is that the whole-statement path has to
  *fail* first, and a late failure has already read the catalog and resolved
  every field; wrapping the object makes that path decline immediately instead,
  which is the whole of the 4.4×–4.8× → 1.5×–1.6× difference. Nothing caches the outcome
  either: the compile cache stores successes only, and the *expanded* statement
  is never stored under its own text — only the inner compile it wraps — so the
  failed attempt is repeated on every execution. Caching the expansion outcome
  would remove both halves. It touches the cache-integrity boundary, so it is not
  a change to make without its own verifier, and it is not in this release.
- **A refusal is not a shortcut**, which this table previously claimed. The
  composed row was published at 0.73× bare on the reasoning that it is "refused
  before any of that". It is not, and an external re-measurement of the same
  commit put it above bare. Before expansion can refuse a statement for joining
  the object to something else it has to resolve the model and the object's
  columns — that is how it knows the reference is a semantic object rather than
  an ordinary table to leave alone — so a refusal costs strictly more than a
  cache-warm compile, and the bare form pays the whole-statement lane's late
  failure on top. The wrapped composed row is now printed beside it, because the
  gap between the two is the evidence.
- Measured on Exasol `2026.2.0-nano.3` (Exasol Personal, single node) on an Apple
  M3 Pro, 11 cores, 36 GB, macOS 26.6.1. The earlier `+0.9 ms` named no hardware
  at all, which is part of why it survived being wrong — and naming it was still
  not enough, because a reader on another build found every absolute at 0.71–0.82×
  of the published ones. The table now carries `× bare`, which is what actually
  reproduced. `tools/measure_expansion_cost.py` regenerates it, so the next person
  to doubt it does not have to write a script first, and it now prints the
  *outcome* of each shape beside its median — a refused row that quietly started
  compiling would otherwise keep printing a number meaning something else.
- **The two SQL paths are one path, so the shape of a statement is never the
  reason it works.** Whatever the whole-statement path cannot compile is now
  handed to reference expansion, instead of only a short list of refusal codes
  being retried. Before this, a redundant subquery was the difference between a
  working report and a refusal: `SELECT region FROM obj ORDER BY revenue DESC`
  was refused while `SELECT * FROM (<the same query>) x` ran, and no surface said
  so, which made the workaround undiscoverable rather than merely undocumented.
  Constructs that were refused bare now work bare: `ORDER BY` a non-selected
  field, `OFFSET`, `SELECT DISTINCT`, arithmetic and `CASE` in the select list,
  `IN (subquery)`, correlated `EXISTS`, `CAST`, window functions, set operators
  and CTEs. `tools/verify_sql_lane_parity.py` runs the bare and
  wrapped form of each construct and requires the same rows or the same refusal
  code.
- The generated derived-table alias is quoted. `__esv_ref_1` is not a legal
  Exasol identifier unquoted, so every expanded statement that did not already
  carry an alias produced SQL that could not be parsed.
- **A refusal now comes from whichever path has more to say about the statement.**
  Expansion may turn a refusal into a success, but not into a vaguer refusal:
  `SELECT bogus FROM obj` keeps `Unknown semantic field: bogus. Did you mean: …?`
  rather than being re-described as a statement whose columns could not be
  inferred. Expansion reaches that same refusal itself (`SEMANTIC_QUERY_020`) for
  the wrapped form, which the whole-statement path never reads — so the two
  forms agree there too.
- **Grouping a published object in its own query block is refused
  (`SEMANTIC_QUERY_015`).** An object is already aggregated to the grain its
  fields imply, so `SELECT region, COUNT(*) FROM obj GROUP BY region` groups a
  grouped result. Joining the two paths made this reachable for the first time:
  expansion turns it into valid SQL over the derived table and it returned `1`
  per region — a count of groups, and the most dangerous shape of wrong, because
  the figure a reviewer checks first looks sane. Aggregating in an *outer* block
  is unaffected and remains the supported way to count a semantic result, because
  there the caller has named the grain. The refusal sits behind the same
  `SET_MODEL_DERIVED_COMPOSITION` opt-in as the join guard: that setting says the
  model accepts ordinary-SQL semantics, and re-aggregation is ordinary-SQL
  semantics, so gating only one of the two hazards would make the opt-in mean
  different things depending on which one a statement reached.
- **Every SQL entry point now answers the same way.** The fallthrough above
  originally reached only the preprocessor, so `COMPILE_SQL`, `COMPILE_SQL_DEBUG`
  and `EXPLAIN_COMPILED_SQL` still refused every construct it had just made work
  — the same statement ran through one door and was refused at another, and the
  surfaces an author reaches for to find out *why* a query behaved a certain way
  were the ones that disagreed with the query. The decision is now one shared
  routine that all three call.
- **A failing statement is reported at a line the author actually wrote.** The
  compiled SQL spliced into a statement runs to eight or so lines, so everything
  after the reference moved down by that many: a one-line query that Exasol
  rejected came back as `syntax error … [line 10, column 3]`, pointing into text
  the author had never seen. That was the second half of B09 and it outlived the
  first. The derived table is now emitted on one line
  (`sql_text.flatten_lines`), so line numbers survive the rewrite. The column
  still counts the spliced characters, which inline rewriting cannot avoid, and
  both the docs and `QUERY_CAPABILITIES` now say to read the line and ignore the
  column. Newlines inside string literals are not folded, and a statement
  carrying a line comment is left alone rather than having the rest of it
  commented out.
- **A valid statement is never reported by a parser.**
  `tools/verify_no_raw_parse_errors.py` runs a corpus of statement shapes — not
  the three that were reported — and requires each to answer or carry a rule
  code, then requires every position in the malformed corpus to name a real line.
- When reference expansion *breaks* rather than refuses, the whole-statement
  lane's refusal is kept if it had one. Returning `reference expansion failed`
  in place of `COUNT(*) over a semantic object is refused` hid a good reason
  behind a bad one.
- **The preprocessor lane records what it did.** `QUERY_LOG` was written by
  `COMPILE_SQL_DEBUG` and nothing else, so after a day of dashboards it held no
  rows from the lane BI tools actually use: `SEMANTIC_SOURCE.MY_QUERY_LOG` was
  permanently empty, and `EXPLAIN_COMPILED_SQL('QUERY_LOG', …)` had no handle to
  explain — the remedy this project's own docs offer for "why is my number
  different from my colleague's". `SEMANTIC_USER` was granted `INSERT` on the
  table for a writer that never ran. Every statement the preprocessor rewrites is
  now recorded; statements it leaves alone are not, which matters because a
  database-wide preprocessor sees every statement in every session.
  `CLIENT_NAME` distinguishes the two paths, `PREPROCESSOR` and
  `PREPROCESSOR:EXPANSION`.
- **The row carries the plan, so it can be explained.** Everything
  `EXPLAIN_COMPILED_SQL` reports — the governance prose, the materialization,
  which fields were asked for — is read back out of `PLAN_JSON`, and reference
  expansion used to discard the inner compile's plan. A lane that logged
  diligently without one would have satisfied the letter of the fix and left the
  story exactly as unreachable.
- **`EXPLAIN_COMPILED_SQL` works for a non-`SYS` caller.** It read
  `SYS_SEMANTIC.QUERY_LOG` and `SYS_SEMANTIC.AGENT_REQUEST_LOG` directly, and
  the script runs with the caller's rights, so a BI user reaching for the answer
  got `insufficient privileges: SELECT on table QUERY_LOG`. It now reads the
  principal-scoped views. A handle belonging to another principal reports as not
  found rather than as forbidden — the existence of someone else's query is not
  ours to confirm.
- **The governance prose no longer misattributes a cached plan.** A compile is
  served to anyone inside the same trust boundary, so the plan carries whoever
  compiled it first; the prose told the person who had just run a query that SYS
  compiled it. It now names both when they differ, and says that the rows were
  still resolved with the runner's own rights.
- Cost: about **20–30 ms** per rewritten statement on the reference deployment,
  measured A/B. It is the single-row `INSERT` itself and not the payload —
  logging with `PLAN_JSON` omitted was no faster — so there is no cheaper version
  of this that still explains anything. The agent lane has always paid the same.
- `tools/verify_sql_lane_logging.py` runs as a scoped principal rather than as
  `SYS`, because `SYS` has SELECT on everything and would not have noticed any of
  the three defects above.
- **`QUERY_CAPABILITIES` names the code each lane actually emits.** The view is
  cited from `docs/bi-tools.md`, a BI-facing document, and carried only the
  structured lane's `SEMANTIC_REQUEST_*` spellings — so an integrator sending SQL
  and matching the published code never matched, because that lane emits
  `SEMANTIC_QUERY_*`. `REFUSAL_CODE` is replaced by `SQL_REFUSAL_CODE` and
  `REQUEST_REFUSAL_CODE`, and a row names both only where both lanes reach the
  condition.
- **The drift test runs the shapes instead of grepping for the codes.** It used
  to search the Lua sources for each published code and pass if the string
  appeared anywhere, which it always did — both spellings exist in the source, so
  the view could publish the wrong one and nothing failed. A spell-checker is not
  a contract. `tools/verify_query_capabilities_contract.py` now executes a
  statement for every published shape, in the lane the row names, and compares
  the code that comes back. Rows and demonstrations are keyed on the view's own
  `SHAPE` text, so neither can outlive the other: a row nobody demonstrates fails,
  and a demonstration whose row has gone fails too.
- Added the shapes the view was missing: `SEMANTIC_QUERY_007` (an aggregate the
  metric does not declare), `_005` (a SELECT list naming no field), `_026`
  (HAVING with no metric) and `_028` (reading a relation the model does not vouch
  for). The report also listed `_033`, `_050` and `_061` as missing; those shapes
  now *work* rather than refuse, so they are published as supported instead.
- Corrected two rows that named codes nobody receives, both of them added earlier
  in this release: a statement naming no column of the object reports `_005`, not
  `_011` — `_011` is what a *wrapper* gets, where the whole-statement path has no
  opinion — and re-aggregation reports `_015` only where that path cannot read the
  statement, such as a CTE; where it can, it says something sharper (`_008`,
  `_010`, `_026`). Both were found by running the shapes rather than by reading.
- One row of the report is stale: an `IS_PRIVATE` metric is refused as withheld
  (`_027`) in both lanes, not reported as an unknown field. That was fixed by the
  policy-column work earlier in this release.
- **`DISPLAY_POLICY` and `SENSITIVITY_LABEL` have a writer.**
  `SEMANTIC_ADMIN.SET_FIELD_POLICY(model, object, field, display_policy,
  sensitivity_label)` sets both on a dimension or a metric, and `NULL` clears
  one. `docs/governance.md` has presented these two as a control table and
  `docs/validation-rules.md` has documented `SEMANTIC_MODEL_069` for a bad value,
  while the only thing in the product that wrote either was a private helper
  inside the OSI document importer — so the documented route to `MASK` was a
  direct `UPDATE` on `SYS_SEMANTIC`, which the same page tells stewards never to
  do and which this release stopped granting them. The gap was never enforcement;
  enforcement worked, and the study set the columns by hand to prove it. Nothing
  in the product would set them.
- A script rather than a DDL clause beside `PRIVATE`, and the split is the point:
  `PRIVATE` says what a field *is* — an invisible one — and belongs with its
  definition; these two say how a *visible* field must be handled, which is a
  decision made about a model that already exists, usually by someone who did not
  write it. That is the shape of `SET_MODEL_GOVERNANCE_MODE`, and this is its
  field-level member. `docs/governance.md` now documents all four columns
  together with the surface each uses and why; the preprocessor page keeps only
  the `PRIVATE` grammar and points at it.
- The value is not judged at write time. `VALIDATE_MODEL` owns the
  `DISPLAY_POLICY` vocabulary and reports `SEMANTIC_MODEL_069` against it, so
  checking it in the script too would put the list in two places and let them
  disagree — the script says to validate instead, which is the idiom
  `SET_MODEL_GOVERNANCE_MODE` already states.
- Naming a fact is refused rather than written: neither column has a reader for
  one, because a fact is never returned to a caller, and the refusal says the
  policy belongs on the metric built from it. Setting a policy clears the model's
  compile cache, or a statement compiled under the old policy would go on being
  served under the new one.
- `tools/verify_field_policy_writer.py` holds the whole path rather than the
  writer alone — set, refused in both lanes, cleared, allowed again — because
  each half already existed and what was missing was that they were never joined.
  A writer that wrote without being enforced would pass half of it.
- **A representation-scoped `coverage` in a fusion document can be applied.**
  `docs/data-fusion.md` presents it as one of three ways to complete an
  alternate, and it could never be used. The reported cause was one missing
  assignment — the constructed batch entry did not name the representation it was
  about, so every such declaration came back asking for
  `COVERAGE_JSON[1].representation_name`, a field the document schema does not
  have. Fixing that alone was not enough, and the rest only showed up once the
  route got far enough to fail differently:
  - `SET_REPRESENTATION_COVERAGE_BATCH` is all-or-nothing by design — a
    partitioned set cannot be initialized one representation at a time — so a
    per-representation call could never succeed however it was spelled. Coverage
    is now collected across the entity and applied in one call.
  - Coverage declared on a representation that already existed was dropped in
    silence: that path carried authority and identity, ignored coverage, and
    reported `OK` having done nothing. That is the worse half of the same defect,
    because the other half at least raised.
  - The batch now runs after the document's attribute bindings, because coverage
    turns the set into a partition and a partition is validated attribute by
    attribute (`SEMANTIC_MODEL_052`). Run first, it was rejected for a binding
    the same document was about to add.
- **`SEMANTIC_MODEL_038` says what is actually wrong.** It offered the same three
  completions as every other incomplete-representation error — temporal coverage,
  attribute bindings, or a certified semantic identity — for a failure none of
  them settles: the alternate resolves to a different *set of keys*. Attribute
  bindings declare where a column comes from and say nothing about which rows
  exist; a semantic identity is checked against the same key set and refuses on
  its own terms (`SEMANTIC_MODEL_049`); temporal coverage describes a source that
  covers a time range, not one that is incomplete. The message now says it is a
  difference in rows rather than columns and names the route that works —
  presenting the source over the full key set, LEFT JOINed onto the primary's
  keys, with the attributes it does not carry left NULL.
- `docs/data-fusion.md` said the null-cast `FALLBACK` binding exists to replace
  that widened view. True for a source narrower in columns, and the sentence was
  being read as covering both — it now says which case each settles.
- `tools/measure_expansion_cost.py` is new and deliberately not a verifier: it
  measures rather than asserts, and a threshold on a wall-clock median would be
  flaky on a laptop. It prints the table above, with the database version and the
  machine, so the figure cannot go stale unnoticed again.
- **A statement naming a field of a *different* semantic view is refused, not
  half-compiled.** `SELECT CUSTOMER_REGION, TOTAL_FREIGHT FROM …ORDER_HEADER`
  resolved the metric, found no dimension of that name on that view, and built
  the derived table from the half that resolved — leaving the outer statement
  selecting a column the derived table did not have. Exasol answered `object
  CUSTOMER_REGION not found`, which is true of the generated text and useless
  about the query. Silently dropping a requested column is the dangerous half:
  it is how a statement comes back answering a question nobody asked. The
  projection check now runs whether or not anything else resolved, so the
  refusal is the one the whole-statement path already had — *"Unknown semantic
  field: CUSTOMER_REGION. It is a column of semantic view SALES, not of
  ORDER_HEADER."* An `x AS name` output alias is a declaration rather than a
  reference and is not reported as an unknown field.
- **The cost of splitting a model by grain is written down once.**
  `SEMANTIC_MODEL_059` forces a coarser metric into its own semantic view;
  `SEMANTIC_ADMIN_019` then refuses to share a dimension name between the two,
  `SEMANTIC_QUERY_020` refuses a field of one on the other, and
  `SEMANTIC_QUERY_012` refuses to join the published views back together. Each
  rule was clear on its own and the consequence was only discoverable by meeting
  all four. `docs/creating-metrics.md` now sets out what to decide up front, and
  `tools/verify_fanout_guardrails.py` asserts all four steps so the section
  cannot drift from the behaviour.
- **`SEMANTIC_ADMIN.REMOVE_SEMANTIC_OBJECT(model, object)`** — a semantic view
  can be taken out of a model. `ADD_SEMANTIC_OBJECT` had no counterpart: the DDL
  edits an object's *interior* and cannot remove the object, no apply path
  reconciles a model by deleting one, and `DROP_MODEL` takes the entities,
  relationships, published views, grants and frozen-view records with it.
  That was not a tidiness problem. `PUBLISH_MODEL` refuses an object with no
  visible columns (`SEMANTIC_SURFACE_014`), so a single mistyped
  `ADD_SEMANTIC_OBJECT` left a model that **could not be published and could not
  be repaired** — and filling the object in instead was no escape, because its
  dimensions would need new names (`SEMANTIC_ADMIN_019`), making the typo
  permanent in a different form.
- It removes the view and the dimensions and metrics it exposes, so their names
  are free again, and drops the published view — `PUBLISH_MODEL` only ever issues
  `CREATE OR REPLACE VIEW` and would never notice the object was gone, leaving a
  view answering from the SQL it was compiled with, which is the frozen-view
  hazard arrived at by accident. It clears the model's compile cache for the same
  reason.
- It keeps facts and entities. A fact is declared on an *entity*, not on a view,
  and may feed metrics in other views; an entity is the model's graph. `ADD_ENTITY`
  still has no counterpart, which is now the only `ADD_*` that has none.
- It refuses when another view's metric is built on one of the metrics it would
  take (`SEMANTIC_ADMIN_099`), rather than cascading and leaving that metric
  naming something that is gone. The dependency is read from
  `METRIC_DEPENDENCIES`, which `VALIDATE_MODEL` derives — not `METRIC_INPUTS`,
  which records what an admin call declared and stays empty for a metric whose
  *expression* names another metric. The cost of that is staleness: a dependency
  added since the last validation is not seen here, and the next `VALIDATE_MODEL`
  reports the broken metric instead.
- The dependent tables were taken from `SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS`
  rather than from grepping for a column called `OBJECT_ID`. Two of the five
  references reach a semantic object through `SCOPE_ID`, and the grep would have
  missed both.
- The gap was deliberate, not an oversight: `tests/test_install.py` pinned
  `ADD_SEMANTIC_OBJECT` as intentionally having no removal, with the reason
  *"semantic objects are part of the published contract and currently require
  model rebuild"*, and failed the moment a `REMOVE_` appeared — telling us to
  retire the exception. The reason did not cover the case that makes it an
  obstacle: a view with no columns cannot be published, so the deferral left a
  model that could not be repaired at all. The exception is now removed, and
  `ADD_ENTITY` is the only `ADD_*` with no counterpart and a reason that still
  holds.
- **`docs/bi-tools.md` says who needs what**, measured by granting one privilege
  at a time and recording what starts working. The row that matters: a role
  granted the model but not the physical sources browses every field, compiles
  every query and **retrieves nothing** — the compiler runs as the caller, which
  is what makes row-level security in the sources the real control.
- **`CREATE VIEW` over a semantic object is marked as not a BI capability.** It
  was listed among the statements a BI tool emits, and it compiles — but it needs
  `CREATE VIEW` (or `CREATE ANY VIEW` outside a schema the author owns), which a
  reporting role should not hold, and what it produces is readable by anyone
  granted the view with no rights on the sources and no preprocessor. Two further
  facts are now written down because they were measured: the author cannot pass
  the view on without *grantable* rights on every relation its compiled SQL
  reads, and the reader needs nothing but `SELECT` on the view.
- **`SEMANTIC_QUERY_080` no longer reports an authorization outcome as a
  modelling defect.** A caller who cannot read a physical source gets an empty
  source-column probe, and the planner concluded from that that no representation
  could traverse the relationship. This is the same shape that was fixed for an
  unauthorized *model* — where the comment records that it "sent modellers
  looking for a bug that did not exist" — one level down, for the sources. The
  message now names the privilege possibility without asserting it, because the
  code fires for genuine modelling defects too.
- **`SELECT COUNT(*)` on a published object without the preprocessor is refused.**
  The guard raises from every column, and a statement that selects no column
  never evaluated one: `COUNT(*)` counted the guard view's own single row and
  returned **1** — a plausible number for a question the view exists to refuse.
  The guard is now in the `WHERE` clause as well, which a row has to pass to be
  counted. The `WHERE 1 = 0` driver metadata probe still returns the column shape
  with no rows.
- **`VALIDATE_MODEL` says when a model has frozen views (`SEMANTIC_MODEL_067`).**
  A view compiled from a semantic object stores physical SQL, which is what lets
  it answer with no preprocessor — and also why it goes on answering with the
  model as it was when it was made. It does not fail, it does not warn, and the
  number still looks right. Nothing asked, and `CHECK_FROZEN_VIEWS` existed but
  ran only when somebody remembered.
- The notice says what the catalog knows and no more. Whether a frozen view still
  matches what the model would compile **cannot** be answered there: the version
  never changes, `MODELS.UPDATED_AT` does not move on authoring, and `METRICS`,
  `DIMENSIONS` and `FACTS` carry no timestamps at all — so "was this edited since
  the view was frozen" has no signal to key on. Comparing the frozen column list
  would catch a rename and miss the case that matters, an expression changed
  under the same name. So the rule counts the views and names
  `CHECK_FROZEN_VIEWS`, which recompiles each one and answers exactly.
- It is a standing condition, not permanent noise: dropping the view retires the
  warning with it, and a record whose view is already gone is not reported at all.
- Making `VALIDATE_MODEL` prove staleness itself was considered and rejected. It
  would mean the validator calling the compiler, and the compiler binds to the
  latest *successful* validation run — inverting a dependency the architecture
  keeps deliberately one-way.
- `docs/admin-db-wide-setup.md` schedules the check: run it wherever model
  changes land, act on `STALE` by re-creating or dropping the view, and leave
  `DROPPED` alone.
- **A representation promotion is verified end to end, and F17 is closed.** It
  had been carried forward as an open finding through two studies: after
  promoting a representation, the one *named* `primary` holds role `ALTERNATE`.
  No promotion had ever completed — both studies were refused first by
  `SEMANTIC_ADMIN_045` and then by `SEMANTIC_ADMIN_058` — so what they observed
  afterwards described a promotion that had not happened.
- It is not a defect. With a fixture that gets past those gates the roles swap,
  exactly one representation holds `PRIMARY`, the entity's source moves, the
  model still validates, and a query returns rows from the promoted source. What
  is left is a representation *called* `primary` whose role is `ALTERNATE` —
  correct, because a name is a label and the role is what the layer reads — and
  the promotion already reports it (`SEMANTIC_ADMIN_221`) and hands back the
  `RENAME_ENTITY_REPRESENTATION` call that settles it, which this now checks
  works.
- Reaching the promotion needs a single-column unique key, both sources exposing
  that column, and a bare `DIRECT` identity binding on it. A third gate is worth
  naming because it is easy to misread: multi-representation key probes need a
  session `QUERY_TIMEOUT`, and without one `VALIDATE_MODEL` returns
  `PRECONDITION` (`SEMANTIC_MODEL_041`). That is not an error, so a caller
  counting only errors reads it as a clean run and the promotion is refused later
  by `SEMANTIC_ADMIN_048` for what looks like an unrelated reason.
- **The declared-aggregation guard is a property of the request, not of which
  lane read it.** `SEMANTIC_QUERY_007` was raised by the whole-statement path and
  then discarded whenever reference expansion rewrote the statement
  successfully — so the guard held for `SELECT region, MAX(revenue) … GROUP BY
  region` and not for the same statement without the `GROUP BY`, which is the
  form `docs/bi-tools.md` teaches ("there is no `GROUP BY` to write — it is
  inferred"). Where Exasol objected to the rewritten text the caller got `not a
  single-group group function`; where it had nothing to object to,
  `SELECT SUM(gross_margin_pct) FROM obj` returned the ratio itself — a number
  under a label that lies about how it was computed, which is what the guard's
  own comment exists to prevent. `COUNT(total_revenue)` returned `1`, counting
  the derived table's single row.
- Wrapping reached the wrong number too: inside a subquery, a CTE or one arm of a
  union, all four returned the ratio. So the check now runs in reference
  expansion as well, through **one routine** both lanes call
  (`aggregate_wrapper_refusal`) — the two lanes disagreeing about which
  aggregates a metric accepts is precisely how the guard was lost.
- The same fix closes two raw-error leaks found alongside it:
  `MEASURE(customer_region)` reported `function or script MEASURE not found`, and
  `SUM(customer_region)` leaked a **data value** into the message
  (`invalid character value for cast; Value: 'South'`). Both are
  `SEMANTIC_QUERY_006` now.
- A protective set of "lane refusals expansion may not override" was written for
  this and then removed. With expansion raising the refusal itself it could not
  be made to fire: reverting the expansion-side guard fails five parity checks,
  reverting the protective set failed none. A rule that cannot fire reads like
  coverage.
- **An implicit column alias is no longer reported as an unknown field.**
  `SELECT z.r FROM (SELECT t0.CUSTOMER_REGION r FROM obj t0) z` — the same
  declaration as `AS r` with the keyword left out — was refused
  `SEMANTIC_QUERY_020`. Two operands cannot sit side by side in a select list, so
  the second is a label; the keyword list decides which of the two is which,
  because `SELECT` is a word too and reading it as an operand made every first
  column look like an alias.
- `tools/verify_query_capabilities_contract.py` demonstrates this row with the
  form the documentation teaches rather than the one with an explicit `GROUP BY`.
  The old probe passed throughout: a contract verified against the shape the
  implementation happens to handle is testing the implementation. Reported by the
  2026-09-21 evaluation, which also suggested taking shapes from `docs/`
  verbatim — worth doing, and not done here.
- **The composition guard follows the derived table out of its block.**
  `bi_expansion.composed_in_from` stopped scanning at the edge of the reference's
  own parenthesised block, so putting the object in a subquery and joining *that*
  was invisible to it — and expansion puts the semantic result exactly where the
  reference was, so the join fans out either way. With
  `ALLOW_DERIVED_COMPOSITION = FALSE` the wrapped form was accepted and returned
  **North 7270 against a truth of 3635**, which is the literal pair
  `docs/bi-tools.md` prints to justify the refusal; `CROSS JOIN` after wrapping
  reached 14540, and the CTE form behaved the same. Block scoping stays correct
  for the sibling guard `reaggregated_in_block`, because aggregating in an outer
  block is supported — there the caller has named the grain. A join is not: it
  fans out wherever it sits.
- Two things had to be got right for the walk outward. A closing paren carries
  the depth it *returns to* rather than the one it closes, so keying the step on
  seeing `)` at the inner depth never fired and the scan never left the first
  block. And after leaving a block the scan is only inside a `FROM` clause if
  that block was a relation in one: for a CTE body what follows the close is the
  main query's select list, whose commas separate expressions — reading those as
  relation separators refused `WITH q AS (…) SELECT a, b FROM q`, which contains
  no join at all. The scan now waits for that block's own `FROM`, which is also
  what catches the CTE consumer's join.
- A unit assertion had encoded the defect as intended, reasoning that a join
  outside the block "is not this reference's composition: the derived table is
  already closed by then". The derived table is what the join is joining.
- `tools/verify_sql_lane_parity.py` holds four composition shapes bare against
  wrapped, which is the invariant the reporter suggested and the one that would
  have caught this.
- Known boundary: a statement the layer rewrites but Exasol then rejects — a
  syntax error, `DISTINCT ON`, `LIMIT -1`, `ORDER BY` an unknown column — now
  comes back with Exasol's message instead of a `SEMANTIC_QUERY_*` code. Exasol
  names the specific problem in each case, so none is a wrong answer, but nine
  statements that the layer used to recognise it no longer does. They are pinned
  as a ratchet in `tools/verify_sql_lane_parity.py`, which may shrink and may not
  grow. Widening the field scan into `WHERE` and `ORDER BY` would recover two of
  them at the cost of a keyword list whose every omission refuses a *valid*
  query, so the fix belongs with routing all refusals through a rule code.
- **Which columns get compiled is inferred and, when it cannot be, refused.**
  `alias.column` references, unqualified names matching a published column, and
  `*` — where a bare `*` counts only in the reference's own query block, so the
  star in `SELECT * FROM (SELECT t0.A FROM obj t0) x` means the subquery's
  columns. Reading it otherwise compiled nine columns where two were named,
  which changed the grain and returned 0 for a region worth 3635 with no error.
- **`CREATE VIEW` over a semantic object now works**, and the stored text is
  compiled physical SQL, so the view answers with no preprocessor at all.
- **Database-wide activation is documented as the supported BI deployment mode**
  rather than an advanced option. A BI tool opens its own pooled connections and
  gives you nowhere to run a per-session statement, so session activation is not
  something a Tableau or Power BI deployment can use.

#### A governance layer, without Virtual Schemas

- **`SYS_SEMANTIC.SOURCE_TRUST`** classifies every physical relation the planner
  may emit — representations *and* materializations — by one derivation:
  resolve transitive base relations through `EXA_ALL_DEPENDENCIES`. Two objects
  that were checked on their own terms and never compared are now one property.
  This closes a demonstrated defect in which a rollup built over the raw mart
  voided a representation's row-level security: a restricted principal saw one
  region before the rollup was registered and every region after it, with no
  error, no warning and no plan diagnostic.
- **`SEMANTIC_SOURCE`, a fifth managed schema**: one thin, principal-scoped view
  per `SYS_SEMANTIC` table the compiler reads, filtered to the models the caller
  is authorized for. `MODEL_ROLE_GRANTS` existed and nothing read it; it does
  now, and it counts **inherited** roles, which the previous
  `IN (CURRENT_USER, 'PUBLIC')` matching could not see.
- **`SYS_SEMANTIC.FROZEN_VIEWS`** records each view compiled from a semantic
  object with the relations it froze, and `SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS`
  recompiles and compares, because such a view keeps answering after the model
  changes — with the old answer and no error.
- **A compile-cache entry is checked before it is served.** `COMPILE_CACHE` is an
  ordinary table, and whoever can `UPDATE` it chooses the text a published view
  then runs with the view owner's rights. A cached statement may now only read
  relations the model declares, and must read at least one — `SELECT 'PWNED'`
  reads none.

#### The controls explain themselves

- **`SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL`** — one row per model with a
  `SUMMARY` sentence: what mode it is in, what it can vouch for, what it cannot.
- **`SEMANTIC_CATALOG.QUERY_CAPABILITIES`** — one row per SQL shape, supported or
  refused, with the refusal code. A tool integrator should not discover the
  boundary by hitting it.
- **`PLAN_JSON` carries a `governance` block** — the principal who compiled it,
  the mode in force, and every relation the SQL reads with its trust class — and
  **`EXPLAIN_COMPILED_SQL` renders it in prose**, naming the *consequence* rather
  than the classification: *"a principal entitled to fewer rows may still see all
  of them here."*
- **New admin scripts:** `SET_MODEL_GOVERNANCE_MODE`,
  `SET_MODEL_DERIVED_COMPOSITION`, `CHECK_FROZEN_VIEWS`.

### Changed

#### The policy columns do what their names say — **breaking**

- `IS_PRIVATE` on a metric and `IS_HIDDEN` on a dimension removed the field from
  discovery and **not** from queries, so anyone who knew the name got the data.
  They now refuse wherever the field is named — **filters included**, or the
  filter lane becomes the way around a field you cannot discover
  (`SEMANTIC_REQUEST_027`).
- `DISPLAY_POLICY = 'MASK'` withholds the value from results
  (`SEMANTIC_REQUEST_024`) while **filtering on it still works**. It refuses the
  projection rather than substituting a redacted value: ESV groups by every
  selected dimension, so a placeholder would either collapse every row into one
  group or sit beside real counts, and both silently change what the number
  means. Any other value in the column is reported as a policy nobody applies
  (`SEMANTIC_MODEL_069`).
- `SENSITIVITY_LABEL` is documented as what it is — a label, free text, enforced
  by nothing. **None of this substitutes for source policy**: the compiler runs
  with the caller's rights and the caller can read the physical sources directly.

#### Callers are granted `SEMANTIC_SOURCE`, not `SYS_SEMANTIC` — **breaking**

- The compiler runs as the caller, so a non-`SYS` principal needed `SELECT` on
  `SYS_SEMANTIC` — every other model's metric definitions, every other user's
  logged requests, and a map of the physical estate. The new `SEMANTIC_USER`
  role names the baseline a caller actually needs, and `GRANT_MODEL_ROLE` grants
  it. An unauthorized model now resolves to *not found* instead of
  `SEMANTIC_REQUEST_080` "no active representation can traverse relationship …",
  which reported an authorization outcome as a modelling defect.
- Cost, measured: **+48% on a cold compile**, and the warm path — what BI tools
  and repeat queries pay — is free.

#### Joining a published object to another relation is refused by default — **breaking**

- Expansion makes the semantic result a derived table, and a join can repeat its
  rows: the same query across a join re-aggregates North to **7270** against a
  truth of **3635**. Refused with `SEMANTIC_QUERY_012`; opt in per model with
  `SET_MODEL_DERIVED_COMPOSITION`.

#### Faster

- **The preprocessor lane**: per nested query 77.75 ms → 6.75 ms. The runtimes
  are imported only when the statement could possibly need them, the Semantic SQL
  lane consults the compile cache before loading the catalog rather than after,
  and the cache key now carries a build id hashed from the sources that decide
  compiler output — so a parser or renderer change can no longer serve SQL
  compiled by the previous runtime.
- **`VALIDATE_MODEL`: 2.08 s → 0.90 s**, which is ~4 minutes off a full smoke run
  (219 validations). It probed `SYS.EXA_ALL_COLUMNS` once per declared column —
  48 times for a four-entity model, 43% of a validation — and now reads each
  relation's column list once. Its catalog writes are batched into one statement
  per table rather than one per row. Re-measured on the hardware named above it
  is **1.06 s** for the demo model (median of 5, preprocessor off): the direction
  and the size of the win hold, the absolute figure does not travel between
  machines, and the original quoted none.

### Fixed

#### An outer `AVG` over a non-additive metric was 47.5 % wrong (BUG-26)

- The docs call aggregating a semantic object in an outer block supported,
  because the caller has named the grain. That is exact for a metric that adds
  up, and wrong for one that does not. `SELECT AVG(t.avg_resolution_h) FROM
  (SELECT sla_bucket, avg_resolution_h FROM …) t` averaged two bucket averages,
  weighting 19 tickets the same as 1,181. It answered 71.59 where the truth was
  48.52, with `STATUS = OK`. On `sales`, `SUM` over per-region
  `gross_margin_pct` answers a 120 % margin.
- Reference expansion now refuses an outer `SUM` or `AVG` over such a metric
  (`SEMANTIC_QUERY_016`), in a derived table or a CTE, however deeply nested in
  an expression. The message names the aggregate, the metric and the grain.
- **"Adds up" is judged from what the metric computes, not from its label.** A
  DDL metric `AS AVG(x)` is stored with `METRIC_TYPE = 'ADDITIVE'`. A single
  `SUM`/`COUNT` adds up, and so does a linear combination of such metrics
  (`gross_margin = total_revenue - total_cost` still sums exactly).
- **The grain comes from what expansion compiles, not from what the subquery
  selects.** A dimension the subquery only filters on is part of it, so
  `… (SELECT gross_margin_pct FROM obj WHERE customer_region IN (…)) t` is
  refused too.
- Still accepted, and exact or self-describing:
  - `MIN`, `MAX` and `COUNT` of the per-group values;
  - window aggregates;
  - an outer block that groups by the whole grain, including by ordinal or by an
    inner alias.
  `SET_MODEL_DERIVED_COMPOSITION` opts out, like `SEMANTIC_QUERY_015`.
  `tools/verify_outer_reaggregation.py` checks refusals, exact values and the
  opt-out live.

#### An unknown DDL clause was absorbed into the previous clause (BUG-25)

- The DDL parser finds a clause by its keyword, and the value runs to the next
  keyword. So an unrecognised keyword became part of the previous value:
  `RETURNS DECIMAL(18,2) UNIT 'kg'` stored the type `DECIMAL(18,2) UNIT 'kg'`,
  and so did the typo `FORMATT 'currency'` and the nonsense `WOMBAT 'purple'`.
  All three passed a dry run and validation; only `PUBLISH_MODEL` refused, with
  `SEMANTIC_SURFACE_005: unsafe data type`. Words before the first clause were
  dropped, and a clause another kind uses (`WINDOW` on a dimension) was parsed
  and then ignored.
- Each entry kind now has a fixed clause set, and each clause's value has a
  fixed shape: a name, a literal, a list, a type, or a flag with no value. The
  parser refuses:
  - an unrecognised word, by name (`SEMANTIC_DDL_039`, listing the accepted
    clauses);
  - a clause from another kind (`SEMANTIC_DDL_043`);
  - a repeated clause (`SEMANTIC_DDL_044`; the second one used to be absorbed
    too).
  Expression-valued clauses are checked for a trailing `WORD 'literal'` pair.
- **`UNIT` is now a metric clause.** It writes `UNIT_HINT`, and export emits it.
  `SEMANTIC_MODEL_022` had been recommending a unit that the grammar had no way
  to set.
- New rule `SEMANTIC_MODEL_073` (error) casts every declared data type, so a
  malformed type written through `ADD_METRIC` or an older catalog is refused by
  `VALIDATE_MODEL`, not by `PUBLISH_MODEL`. `SEMANTIC_SURFACE_005` now names
  the column and the clause to correct.
- **Behaviour change:** a definition that relied on a clause being ignored now
  fails. That covers `FORMAT` on a `FACT`, which the grammar never stored.
  `tools/verify_semantic_ddl_clauses.py` covers the report end-to-end.

#### `METRIC_COMPATIBLE_DIMENSIONS` listed incompatible dimensions (BUG-24)

- The view returned every metric × dimension pair, including the fan-out and
  no-path pairs that `COMPILE_SQL` refuses. An agent that asked it for
  `DIMENSION_NAME … WHERE METRIC_NAME = ?`, the obvious query, got exactly the
  combinations that are blocked everywhere else.
- It now returns only `IS_VALID = TRUE` rows, with the same columns. The
  unfiltered rows, with `REASON_CODE` and `REASON_MESSAGE` for each refusal, are
  in the new `SEMANTIC_CATALOG.METRIC_DIMENSION_COMPATIBILITY`, which
  `SHOW ALL SEMANTIC DIMENSIONS FOR METRIC` now reads.
- **Behaviour change:** a caller that read refused pairs from
  `METRIC_COMPATIBLE_DIMENSIONS` must switch to
  `METRIC_DIMENSION_COMPATIBILITY`.
- `SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT` is unchanged. Its refused rows
  and reason codes are part of the documented agent contract.

#### A dimension expression that cannot execute compiled to `STATUS = OK` (BUG-23)

- `CASE WHEN tk.RESOLVED THEN resolved ELSE open END`, where the literals are
  missing their quotes and `OPEN` is reserved, passed `ADD_DIMENSION`,
  `VALIDATE_MODEL`, `PUBLISH_MODEL` and `COMPILE_SQL`. It failed only when the
  generated SQL ran, with `syntax error, unexpected OPEN_`. The static checks see
  only qualified `alias.column` references, so a bare word was invisible to all
  of them.
- New rule `SEMANTIC_MODEL_072` (error) binds each dimension, fact and
  attribute-binding expression against the relation it is rendered over, with
  `SELECT <expression> FROM <source> <alias> WHERE FALSE`. The probe reads no
  rows. A clean model pays one query per representation; the probe splits into
  one query per expression only when the combined one fails. The message quotes
  the expression and the database's error.
- `ADD_DIMENSION`, `ADD_FACT` and the semantic DDL already validate before
  committing, so the expression is now refused at authoring time
  (`SEMANTIC_ADMIN_091` / `SEMANTIC_DDL_090` carrying `SEMANTIC_MODEL_072`) and
  rolled back. A catalog that already holds such an expression fails
  `VALIDATE_MODEL`.
- Virtual-schema tables are probed too (BUG-23b). The first version skipped
  them, because even `WHERE FALSE` on a virtual table goes through the adapter's
  pushdown. That left the original failure intact for federated sources: the
  report's `CASE WHEN ri.MODE THEN foo ELSE bar END` over `LAKE.SHIPMENTS` was
  accepted, published and compiled to `STATUS = OK`. The expression is now bound
  against a local stand-in with the table's column names and types from
  `EXA_ALL_COLUMNS`, `(SELECT CAST(NULL AS <type>) AS "<col>", …) <alias>`. That
  takes about 3 ms; a pushdown probe took about 420 ms, and the stand-in works
  while the remote is down. A stand-in that cannot be built, or does not bind on
  its own, is never blamed on the expression. Wrapping the virtual table in a
  view, the workaround from the report, is no longer needed.
- Not probed: metric expressions, filters and identity expressions.
  `tools/verify_expression_binding.py` covers all three authoring paths for a
  relation; the unit tests cover the virtual-schema stand-in.

#### The join the docs print was refused with a different code than the docs print

- `docs/bi-tools.md` §4 printed a statement beside `SEMANTIC_QUERY_012`, and
  `QUERY_CAPABILITIES` published the same code for the same shape. Run verbatim
  it returned `SEMANTIC_QUERY_003` — "FROM must reference one published semantic
  object", which is not true of a statement that references exactly one, and
  which names neither the double-counting hazard nor
  `SET_MODEL_DERIVED_COMPOSITION`. `_012` is what the docs tell integrators to
  match on.
- The cause was guard *order*, not arbitration. A statement that joins the
  object and also groups it reaches both guards in reference expansion, and
  re-aggregation was asked first. Its code, `SEMANTIC_QUERY_015`, deliberately
  only wins when the other lane had no opinion — so the other lane's
  parse-shape complaint outranked it. The composition guard is asked first now.
- That ordering is also the better answer on its own terms: `_015` tells the
  author to wrap the object in a subquery and aggregate that, which is sound for
  a statement that only re-groups and **wrong** for one that also joins —
  wrapping first and joining the wrapper is the shape that inflates 30×.
- The contract verifier missed it because it demonstrated the join *without* the
  aggregation, and the aggregation is what changed the answer. It now uses the
  documented form.

#### Documented examples are now run, and one was stale

- `tools/verify_documented_examples.py` extracts every fenced SQL block in
  `docs/` that is followed by a `-- SEMANTIC_..._NNN` comment, runs it verbatim
  in the lane its first word implies, and requires every code the comment names.
  Nothing is transcribed into the verifier, so editing the statement in the doc
  edits the test.
- It immediately found a second drift: `docs/examples.md` printed the fan-out
  refusal as `SEMANTIC_MODEL_030` with the pre-split message about a
  metric/dimension pair. The rule has been `SEMANTIC_MODEL_059` — a metric
  aggregating *coarser* than its object's root — since that code was split out.
  The example now prints what the layer actually says.

#### A published model with two faults could not be repaired, only dropped

- Every mutator on a published model revalidates the candidate and reverts
  itself with `SEMANTIC_ADMIN_094` if it fails. Measured against *zero* errors,
  that is a trap rather than a guard: a model holding two independent errors
  cannot be repaired, because each single step removes one and leaves the other,
  so every step is refused and rolled back. `PUBLISH_MODEL` refuses too, queries
  against the published schema return `SEMANTIC_QUERY_010`, and the only thing
  that succeeds is `DROP_MODEL` — which takes the entities, relationships,
  published views and grants with it. It is the same dead end
  `REMOVE_SEMANTIC_OBJECT` was added to solve one level up.
- No admin call is needed to reach it. `ALTER TABLE … DROP COLUMN` on a column
  two bindings read leaves the published model holding two `SEMANTIC_MODEL_040`
  errors the next time anyone validates it.
- The guard now refuses what a change *introduces*. `NEW_VALIDATION_ERRORS`
  revalidates and reports only the errors that were not in the model's previous
  validation run — keyed on severity, object type, object name and rule code,
  not on the message, because several rules print counts that move while the
  fault stays the same. The 15 mutators that raised `SEMANTIC_ADMIN_094` from
  their own `VALIDATE_MODEL` call consult it instead, and
  `RECERTIFY_MODEL_IF_PUBLISHED`, which the rest consult, answers
  `ERROR_PRE_EXISTING` where it used to answer `ERROR`.
- **The protection is unchanged.** A step that breaks something new is still
  refused and still reverted; `tools/verify_published_repair_path.py` asserts
  both halves, because a guard that stops refusing is not a fix.
- One documented limit, pinned by the same verifier: the baseline is the
  model's *previous* validation run, so before anyone revalidates a model that
  has just broken, every error still reads as new and the guard refuses as it
  always did. `VALIDATE_MODEL` is the remedy, and it is only ever one call — a
  refused mutator revalidates on its way out.

#### Two `SEMANTIC_MODEL_044` conditions contradicted the catalog

- Both printed only their requirement. A steward could read
  `SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS` and `REPRESENTATION_AUTHORITIES`, see
  that both conditions were satisfied, and have no way to act on the error —
  because the validator counts only bindings whose `STATUS` is `ACTIVE`, on the
  model's active version, naming a representation that is itself `ACTIVE`, and
  the catalog shows more than that.
- They are now `SEMANTIC_MODEL_070` (fewer than two contributors) and
  `SEMANTIC_MODEL_071` (not exactly one bound `AUTHORITATIVE` representation),
  and each names what it counted and against which scope. `_071` also says the
  thing that was never written down: an `AUTHORITATIVE` representation carrying
  no binding for that attribute does not count.
- `_071` also counted *bindings* where it meant representations, so two bindings
  on one authoritative representation read as two authorities — a conflict
  between a thing and itself. Both counts are over representations now.

#### A SQL client got the wrong data in the right-looking columns

- Three defects with one cause and one fix: the planner's column *order* was
  returned instead of the caller's, so a client binding by position got the wrong
  data silently; `AS "c11"` was discarded; and an unaliased column came back
  lower-case where the published view advertises it upper-case.

#### BI SQL was refused for things that were not wrong with it

- An aggregate wrapper is honoured when the metric declares it and refused when
  it does not — `SUM()` around a ratio returns the ratio otherwise.
- `COUNT(*)` over a semantic object is refused rather than guessed, because its
  answer depends on a grain the caller never named.
- The `WHERE 1 = 0` and `LIMIT 0` driver probes return the correct shape with no
  rows. `LIMIT 0` required relaxing `limit >= 1` to `limit >= 0` in the shared
  validation — a deliberate contract change, since having the two lanes disagree
  about what a limit means would be worse.
- A parenthesised `WHERE` predicate leaked its closing paren into the generated
  SQL. Latent, and reachable only once `SUM()` wrapping stopped being refused
  earlier.

#### The catalog and agent surfaces showed every model to every caller

- `SEMANTIC_SOURCE` was scoped correctly, but `SEMANTIC_USER` also grants
  `SELECT` on `SEMANTIC_CATALOG` and `SEMANTIC_AGENT`, and **every view in them
  read the tables directly**. So the disclosure came back through the surface
  beside the one that had been fixed: `GOVERNANCE_FOR_MODEL` reported a model as
  not visible while `SEMANTIC_CATALOG.METRICS` next to it returned that model's
  metric expressions, and `FIELDS_FOR_AGENT` — the surface an agent boots from —
  listed fields of a model it would be refused on.
- Both surfaces now read the **already-filtered `SEMANTIC_SOURCE` views** rather
  than the tables: 227 base reads repointed, so the scoping is inherited rather
  than restated in 59 places, and a view added later inherits it by
  construction. The generated set grew from 32 to 43 scoped views to cover what
  the catalog reads and the compiler does not.
- `PRODUCT_INSTALLATIONS` is deliberately left unscoped: deployment identity is a
  property of the installation, not of any model.
- The source views now install directly after the catalog tables
  (`001b_create_semantic_source_views.sql`), because the catalog views read them.

#### `GOVERNED` mode reported the error and served the data anyway

- The trust boundary's whole purpose is the rollup that substitutes for a proven
  branch and drops the row policy its representations carry. The detection
  shipped and worked — `SEMANTIC_MODEL_065`, a trust class, a prose explanation,
  a plan block — but **`GOVERNED` mode was consulted in exactly one place**, the
  guard that refuses to freeze a view. An ordinary query against the same model
  compiled and returned every region to a principal entitled to one, while
  `GOVERNANCE_FOR_MODEL.SUMMARY` said *"it will refuse to compile or to freeze a
  view"*. That is the specific failure `docs/governance.md` opens by warning
  against.
- An ordinary compile in `GOVERNED` mode is now refused when the SQL it produced
  reads a relation the model does not vouch for
  (`SEMANTIC_REQUEST_028` / `SEMANTIC_QUERY_028`). `RAW` is deliberately not
  refused: a materialization built *from* the governed views is a table, so it
  classifies `RAW` while carrying their policy, and refusing it would make the
  mode unusable with any pre-aggregate.
- **`PLAN_JSON` reported `OPEN` for a `GOVERNED` model.** `load_model` never
  selected `GOVERNANCE_MODE`, and `model.governance_mode or "OPEN"` in two
  consumers turned the missing column into a confident wrong answer rather than
  an absent one — which is also why the `CREATE VIEW` path refused correctly and
  the compile path did not: the other loader selected it.

#### Database-wide activation denied service to everyone else

- `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT` — the deployment mode this release
  documents as the supported one for BI tools — made **every statement fail for
  every principal without `SEMANTIC_USER`**, including principals with no
  relationship to this layer: `SELECT 1` returned `insufficient privileges for
  executing a script`. Exasol runs the preprocessor as the caller, so a script
  they cannot execute is a script that stops them executing anything.
- The installer now grants `EXECUTE` on `SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`
  to `PUBLIC`, which is safe because that script only decides whether a statement
  is semantic. And a caller who may run it but may *not* run the compiler
  runtimes now has their SQL **passed through unchanged** rather than refused —
  the preprocessor rewrites semantic statements, and one it cannot rewrite
  belongs to the database as written.
- The rest of the suite activates per session, which is exactly the configuration
  in which this cannot appear, so it shipped past a green run.
  `tools/verify_database_wide_activation.py` now covers the documented mode.

#### Ordering faults that only a clean install finds

- `GRANT_MODEL_ROLE` raised *"object SEMANTIC_X does not exist"* **after** writing
  the grant row when the model was not yet published, leaving the caller an error
  and the catalog a grant. Harmless while nothing read `MODEL_ROLE_GRANTS`;
  with authorization reading it, a half-applied grant silently made a model
  private. The schema grant is now conditional, and `PUBLISH_MODEL` catches up
  every role already holding the model.
- Registering or retiring a materialization left `SOURCE_TRUST` describing a
  relation set that no longer existed. Both mutators clear it.


## [0.2] - 2026-09-02

### Changed

#### One word for one concept in the catalog

- **`AGENT_SUGGESTIONS` / `AGENT_SUGGESTION_REVIEWS` / `AGENT_SUGGESTION_TARGETS`
  are now `MODEL_EVOLUTION_SUGGESTIONS` / `_REVIEWS` / `_TARGETS`.** The thing was
  called a *suggestion* where it was stored and an *evolution* where it was read
  (`SEMANTIC_CATALOG.MODEL_EVOLUTION_*`) and written (`PROPOSE_MODEL_EVOLUTION`,
  `REVIEW_MODEL_EVOLUTION`), so a caller who used the script and then looked for
  the table found nothing. The rename also restores the convention every other
  table follows: the catalog view and the core table it exposes share a name.
- Their seven foreign keys were renamed with them, so a constraint's name no
  longer disagrees with the table it sits on.
- **Upgrading carries the data.** `SYS_SEMANTIC` has no schema-version column and
  every table is created with `CREATE TABLE IF NOT EXISTS`, so a bare rename
  would have left an existing deployment holding its rows in the old table and a
  new empty one beside it. `tools/install.py` now renames in place before running
  the SQL, guarded on both sides so it is a no-op on a fresh install and on a
  re-install. `RENAME TABLE` rather than create-and-copy, because it carries the
  identity counter: inserting explicit ids into an IDENTITY column does not
  advance the generator — verified against Exasol — so a copy migration would
  hand out ids colliding with the ones it had just restored. 001 also drops the
  predecessor constraint names, or an upgraded catalog would keep both.

#### Refusals name the fusion level instead of numbering it

- Nineteen runtime messages carried a bare `F0`–`F5` label — *"F5 semantic
  identity cannot be combined with F3 representation coverage on the same
  entity"* — while the catalog used the numbers **zero** times and the only
  decode table lived in one document. They now read *"a semantic identity cannot
  be combined with temporal representation coverage"*. Same for partition fusion,
  attribute bindings, representation role and source kind, and fact
  reconciliation.
- The reference docs keep the labels — `semantic-catalog.md` heads sections `F3`,
  `F4`, `F5` — and `docs/glossary.md` decodes them. A reader still meets a number;
  just not while being refused.

#### `field` is the canonical name for a queryable thing

- `docs/agent-contract.md` now says so where a caller reads it: `field` is a
  dimension or a metric and never a fact; `dimension`, `column` and `name` are
  tolerated aliases; and `attribute` is a *different* collective noun covering
  dimensions and facts, used only on the binding surfaces. `docs/data-fusion.md`
  says the same where it uses the word.

### Fixed

#### VP-020 — `BINDINGS_JSON` made you guess its vocabulary, one round trip at a time

- Each refusal was precise about the fault and silent about the accepted
  vocabulary, and they arrived one per attempt: `representation` was *silently
  ignored*, so the first message said `representation_name is required`; then
  `binding_role is required`; then the primary rule; then `binding_role must be
  PREFER or FALLBACK`. Five attempts to write one dimension, each buying a
  single fact.
- `BINDINGS_JSON` is now a closed contract like `DECLARATIONS_JSON`: an
  unrecognised key is **refused with a suggestion** (`unknown key
  "representation" (did you mean "representation_name"?)`) rather than dropped,
  every fault in one binding object is reported **together**, and the refusal
  carries the accepted shape plus this entity's actual alternate names and the
  primary's role-only rule. The first attempt now returns everything the five
  attempts used to.
- The unknown-representation and unbound-alternate refusals name the alternates
  that exist, instead of only the name that does not.

#### VP-002 — a fused dimension resolved to NULL on a validated, published model

- **The canonical fusion case returned `NULL` for every row.** Surfacing an
  attribute only a supplemental representation carries is what fusion is for,
  and it was unreachable: `ADD_DIMENSION_WITH_BINDINGS` takes the primary's
  binding from `EXPRESSION`, so "the primary has no such column" has to be
  written `CAST(NULL AS VARCHAR(10))` — and the script pinned that placeholder
  at `PREFER` priority 1 while *refusing* to let the caller say otherwise
  (`SEMANTIC_ADMIN_213: BINDINGS_JSON must not bind the primary representation`).
  The compiler picks one representation per entity and prefers the candidate
  needing the fewest `FALLBACK` bindings, so the placeholder beat the CRM
  binding that had the data. `VALIDATE_MODEL` reported 0 errors, `PUBLISH_MODEL`
  succeeded, and the query answered `STATUS = OK` with a single `NULL` row.
- **`BINDINGS_JSON` now accepts a `primary` entry carrying `binding_role` and
  `binding_priority`.** The expression still comes from `EXPRESSION` — a primary
  entry that supplies one is refused, because two places to write it is two
  places to disagree. The shape the bug report needed is now one call, and
  `ADD_FACT_WITH_BINDINGS` gets it too, from the same script.
- **`SEMANTIC_MODEL_063`** refuses the state however it was reached, including
  on models built before this change: a binding whose expression is a literal
  `NULL` may not be `PREFER` while another representation binds real data. The
  message hands back the `REPLACE_ATTRIBUTE_BINDING` call that repairs it. An
  attribute whose bindings are *all* placeholders is a stub, not a wrong answer,
  and is left alone. `shared/sql_text.lua` owns what counts as a literal NULL,
  and matches only `NULL` and `CAST(NULL AS <type>)` — under-matching costs a
  diagnostic, over-matching would cost someone a valid model.

#### The request log keeps the question it was given

- **`natural_language_text` reaches its own column.**
  `COMPILE_REQUEST_SCHEMA_FOR_AGENT` tells an agent the key is *"retained as
  request metadata"*, and `AGENT_REQUEST_LOG.NATURAL_LANGUAGE_TEXT` exists to
  hold it — but the `INSERT` omitted the column, so the promise was kept only
  accidentally, by `REQUEST_JSON` storing the request whole. Anything reading the
  dedicated column got `NULL`.

#### An OSI batch import keeps a field's presentation metadata

- `osi.py` has always **exported** `format_hint`, `unit_hint`,
  `sensitivity_label` and `display_policy` for dimensions and facts, and listed
  them as importable native keys — but nothing applied them coming back in.
  `APPLY_NORMALIZED_OSI_IMPORT` now patches them in after the `ADD_*` script
  runs, the way it already did for metrics, so a batch import is lossless for
  them. `is_hidden` rides along: `ADD_DIMENSION` has no parameter for it, so an
  imported hidden dimension used to come back visible.
- **Script-mode apply still cannot**, and now says which keys it is dropping,
  per field kind — `ADD_DIMENSION` does carry `format_hint`, and `FACTS` has no
  `IS_HIDDEN`, so naming those would send a reader chasing a loss that did not
  happen. The metric warning gained the same "apply in batch mode to keep it".

### Added

#### `RENAME_ENTITY_REPRESENTATION` — the remedy an advisory already named

- `ADD_ENTITY` mints the name `primary` for an entity's first representation and
  `REPRESENTATION_ROLE` is a separate column, so **the first promotion anyone
  performs leaves a row named `primary` holding role `ALTERNATE`.**
  `SET_PRIMARY_REPRESENTATION` reported this as `SEMANTIC_ADMIN_221` and told the
  caller to "rename either representation" — and no rename existed anywhere in
  the product. A warning whose remedy is not implemented is worse than no
  warning: it says the state is fixable and then strands the reader in it, since
  the name could not be changed by any script. Reported open by three
  consecutive fusion evaluations.
- The new script is a **pure relabel**, and the catalog is what makes that safe:
  `REPRESENTATION_NAME` occurs in exactly one column of one table, and
  `ATTRIBUTE_BINDINGS`, `IDENTITY_BINDINGS` and `REPRESENTATION_AUTHORITIES` all
  reference a representation by `REPRESENTATION_ID`. Nothing points at the name,
  so bindings, authorities, coverage, priority and role are untouched and there is
  nothing to roll back. It clears the compile cache (cached `PLAN_JSON` carries
  the old label in its provenance) and deliberately does *not* mark validation
  runs stale — a relabel cannot change a verdict, and marking stale would drop a
  published model to `NEEDS_VALIDATION` over a cosmetic fix.
- `SEMANTIC_ADMIN_221` now hands back a ready-to-run call with the model, entity
  and current name already filled in. Promotion still never renames on your
  behalf: the name is what authoring scripts and fusion documents address a
  representation by, so moving it silently under a caller would be worse than the
  divergence it fixes.

#### One check for an invariant 29 tables depend on

- **`SEMANTIC_MODEL_062`** — a catalog row whose `MODEL_ID` disagrees with the
  model its `VERSION_ID` belongs to. `MODEL_ID` is denormalised onto 29 tables
  because almost every read filters by model; the join to `MODEL_VERSIONS` would
  otherwise be on every one of them. That trade is worth making, but it leaves
  the invariant held up entirely by every writer passing both columns
  consistently — Exasol's foreign keys are declared `DISABLE` by design and
  cannot catch a disagreement, and a row filed under the wrong model is read by
  neither. The rule derives its table list from `EXA_ALL_COLUMNS`, so a new
  catalog table carrying both columns is checked from the day it is added.

### Removed

- **`SEMANTIC_CATALOG.SEMANTIC_DEFINITION_SOURCE`** — a second name for
  `SEMANTIC_DEFINITION_SOURCES`, one letter apart, returning the same fourteen
  columns and the same rows. Two views for one thing is a trap for whoever finds
  the wrong one first.
- **`SYS_SEMANTIC.CALCULATION_GROUPS` and `CALCULATION_ITEMS`** — declared for a
  calculation-item feature that was never built. Nothing wrote them, nothing read
  them, and compilation never consulted them; they were documented as "persisted
  but not currently consumed". Two nouns and three foreign keys standing for
  behaviour that does not exist. Dropped rather than kept as a promise. They were
  always empty, so an upgrade loses nothing.
- **`SYS_SEMANTIC.OBJECT_PRIVILEGES`** — an object-level ACL nothing could
  populate: eight of its ten columns had no writer anywhere in the product, and
  no `GRANT` script reached it. `OBJECTS_FOR_AGENT` did read it, which made it
  look live — but the filter was *deny only if a grant exists*, and since no
  grant could exist it always evaluated to allow. Two dozen lines of SQL
  enforcing nothing, plus a governance promise in a catalog an admin browses.
  Access control that does work is Exasol's own: `PUBLISH_MODEL` grants on the
  published schema and `MODEL_ROLE_GRANTS` records it.
- **Three columns no code path could set**, each promising behaviour the product
  does not have: `MODEL_VERSIONS.CATALOG_HASH` (nothing computed it) and
  `AGENT_FEEDBACK.REVIEWED_AT` / `REVIEWED_BY` (a review workflow copied from
  `MODEL_EVOLUTION_SUGGESTIONS`, where `REVIEW_MODEL_EVOLUTION` writes both, and
  never built for feedback — which has no review queue and no reviewer script).
  `CREATE TABLE IF NOT EXISTS` is a no-op on an existing catalog, so 001 carries
  an idempotent `DROP COLUMN IF EXISTS` block; the columns were always `NULL`.
- Net: the catalog is 45 → 42 core tables, 46 → 44 catalog views, 475 → 462
  columns and 106 → 101 declared foreign keys.

### Testing

- `RenamedTableMigrationTest` covers all four states the migration can meet: a
  fresh install (no-op), an existing catalog (renamed in place, never copied), a
  re-install (no-op), and a run interrupted between the rename and the drop
  (resolves forward). A fifth check reads `001_create_semantic_catalog.sql` and
  requires every rename target to still be declared and no rename source to be —
  so a stale pair cannot rename into nothing.
- Verified live end to end: a catalog staged in the pre-rename shape with rows in
  all three tables was upgraded with `install.py` (no `--reset`); the rows
  survived, the old names were gone, and the next `PROPOSE_MODEL_EVOLUTION` got a
  fresh id rather than colliding.
- `tools/osi.py`'s own concept labels — rendered into the `lossless` export
  refusal — are checked for bare level numbers where they are declared. They were
  the half of item 5 that a `lua/` grep could not see, and the live smoke run
  found them.
- The convention that every `F`-label the runtime emits must be decodable
  **inverted**: the runtime now emits none, so the check is that no refusal
  carries a bare label, plus a second check that every label the *documentation*
  still uses has a row in the glossary's decode table. Both verified by breaking
  them.

### Documentation

#### `docs/glossary.md` — every term, defined once

- **`grain` was used 130 times across the documentation and defined nowhere.** It
  is the property every correctness rule in this layer is ultimately about —
  fan-out refusals, metric plannability, the object-root check, `STRICT_GRAIN`
  proof mode, half of `validation-rules.md` — and a modeller met it in their
  *second* call, as `ADD_ENTITY`'s `GRAIN_DESCRIPTION`. It now has a definition,
  an example with a number attached, and the distinction between the prose
  `GRAIN_DESCRIPTION` and the machine-readable `UNIQUE_KEYS` that grain proofs
  actually use.
- The only Vocabulary section that existed — in `docs/data-fusion.md` — defined
  nine terms, every one an advanced fusion concept. The glossary was inverted:
  the hard parts had one and the first steps did not. That section is now
  **lifted** into the glossary rather than copied, so a term has one definition.
- 31 terms, in the order a reader meets them: grain first, then the nine a first
  model needs, then the collective nouns, then fusion, then governance.
- **`field`, `attribute` and `column` are explained.** They group dimensions,
  facts and metrics into three different overlapping sets, neither `field` nor
  `attribute` was defined anywhere, and the split is not arbitrary — a *field* is
  what a caller can name in a query (so no facts), an *attribute* is what must be
  bound to an expression per source (so no metrics).
- **`F0`–`F5` can be decoded.** Those labels appear in 19 runtime refusal
  messages and nowhere in the catalog, and `docs/data-fusion.md` names the levels
  differently than `docs/semantic-catalog.md` numbers them. The glossary carries
  one table mapping each label to what it means, and says the two enumerations
  differ.
- Reading the catalog: that `STATUS` means lifecycle on most tables and something
  else on the rest, and that six `*_ID` columns are discriminated rather than
  foreign keys.

#### Recovered content and repaired links

- `docs/architecture-decisions/001-grain-aware-result-semantics.md` was deleted
  as a stale doc on 2026-08-22 and three links to it were left behind — including
  `architecture.md` saying *"ADR 001 defines the grain-aware result contract"*,
  the only place that promised to define grain at all.
- The distinction it carried — **entity grain**, **requested dimensionality** and
  **merge identity**, and why a multi-fact request aggregates each branch before
  merging rather than joining facts first — survived nowhere else. It is now in
  the glossary, and the three links point there.

#### Which query lane

- `docs/semantic-compiler.md` opens with a table of the six ways to get an answer
  out of a published model and who each is for. The authoring surfaces have had a
  documented boundary since `CLAUDE.md`'s "Two Authoring Surfaces"; the query
  surfaces had none.

### Testing

- A seventh convention in `tests/test_conventions.py`: **a term is defined once,
  in the glossary, and the glossary stays complete.** Five checks, all verified by
  breaking them:
  - a pinned set of terms a reader needs before their first model must stay
    defined, and no term may be defined twice;
  - `grain` must be *defined*, not merely named;
  - `data-fusion.md` must keep pointing at the glossary rather than defining
    terms again — the section was lifted, not copied;
  - every `F0`–`F5` label the **runtime** emits in a user-facing message must have
    a row in the glossary's decode table, derived from the Lua sources so a new
    fusion level cannot reach a refusal without reaching the glossary;
  - every documentation link resolves, file and heading anchor — which is how the
    nine-day-old dangling ADR links were found.

### Changed

#### Reading a driver row has one implementation: `shared/rows.lua`

- `missing`, `row_value`, `null_if_missing` and `scalar` opened six runtimes, and
  the copies had drifted where it mattered: `row[name] or row[lower] or
  row[position]` treats a boolean `FALSE` as absent and falls through to an
  ordinal that is usually nil, so a `FALSE` read out of a row could arrive as
  `NULL`. `shared/catalog_rollback.lua` got an explicit nil test when it was
  extracted; the other six modules kept the `or` chain. Now none of them do.
- **A mistyped column name is an error in test mode instead of a wrong value.**
  763 call sites carry a hand-counted ordinal alongside a column name. Exasol
  returns named rows so production reads by name; the offline harness stubs
  positional arrays so tests read by ordinal — both branches covered, their
  *agreement* not. Under `ESV_TEST_MODE`, a row that carries names but not the
  one asked for, *while something sits at the ordinal*, is now an error: that is
  exactly the case that returns a different column's value and hides it. A named
  row missing both is still nil, so a partially-populated fixture stays legal.
- Measured rather than assumed: 554 reads in the offline suite go against named
  rows, 20 of them miss the name (all legal partial fixtures), and **none**
  currently returns a wrong value. So this found no existing defect — what it
  buys is that a renamed catalog column or a typo now fails in any test using a
  named row, where before it would have returned a neighbouring column.
- The helpers keep their own names in each module (`row_value(...)`, not
  `rows.row_value(...)`): 763 call sites read better that way, a `rows` alias
  would be shadowed by the many local `rows` variables these files declare, and
  four bound names cost the chunk exactly what the four definitions they replace
  did. `shared/rows.lua` itself sits behind a `do` block so it costs one
  main-chunk local instead of five.

#### `physical_unique_key` and `physical_fusion_key` were one function

- Byte-identical bodies under two names in `compiler/request_json.lua` and
  `admin/validator.lua` — which is how the compiler and the validator came to
  describe the same key check differently. Now `grain_graph.physical_unique_key`,
  beside the key matching that module already owns.

#### Verifiers share their host-side plumbing

- `tools/verify_support.py` owns `connect()`, `sql_string()`, reading a script
  result **by column name**, and calling an admin script by keyword through
  `CALL_ADMIN_JSON`. 59 verifiers each defined their own `connect()`, 29
  character-for-character, and 26 their own `sql_string()`; exactly one imported
  the tested `semantic_client.py` that already read results by name. Six are
  converted and `PRIVATE_CONNECT` pins the remaining 53, shrink-only.

#### Every verifier is named for the invariant it protects

- The 24-name grandfather list is **empty**. Eighteen needed only the ticket
  prefix removed — the rest of `verify_bug26_published_f3_batch` was already the
  invariant — and the six `verify_milestoneN` files are now
  `verify_catalog_and_seed`, `verify_model_validation`,
  `verify_structured_request_compiler`, `verify_sql_compiler_and_surfaces`,
  `verify_agent_context_and_feedback` and `verify_materialization_selection`.
- Their docstrings were the same defect one layer down — every one still opened
  *"Verify Milestone 4 …"* — and were rewritten to say what the file protects.
  `verify_materialization_selection` now also records that it is order-dependent
  on `sql/examples/sales_materializations.sql` being loaded immediately before it,
  which had never been written down anywhere.
- What made this safe was removing its risk first. The 2026-08-25 review declined
  the rename because it "carries real risk of silently dropping a verifier from
  the suite" — a file renamed but not renamed in `run_smoke.sh` simply stops
  running. That is checkable, so it is now checked in both directions: every
  verifier must be wired into `run_smoke.sh`, and `run_smoke.sh` must name no
  verifier that is gone.

### Testing

- `tests/lua/rows_unit_test.lua` (5 tests, 100 % of the module) pins the FALSE
  case, the positional fallback, the strict mismatch and its deliberate
  narrowness, and why `scalar` is exempt — `SELECT MAX(x)` names its column after
  the expression, so a missing name there is normal rather than a defect.
- `admin/fusion_declaration.lua` gained a full export test built from **named**
  rows, which under the new strict reader is simultaneously a check that every
  column name and hand-counted ordinal in the export path agrees with the SELECT
  above it.
- `admin/semantic_definition.lua` gained metric metadata coverage for a filtered,
  owned, private metric — the branches the existing fixture skipped by leaving
  `SEMANTIC_FILTER_EXPR`, `FILTER_EXPR` and `OWNER_ROLE` nil.
- **`DUPLICATED_LUA_BODIES` is empty.** Seven bodies at the start of the week,
  four after `sql_text.lua`, one after `rows.lua`, none after
  `grain_graph.physical_unique_key`. An empty pin is the strongest form of the
  rule: the next copy fails immediately instead of being grandfathered.

### Documentation

- `CLAUDE.md` gains a sixth convention (verifiers share their plumbing), records
  that two ratchets drained to empty, and lists `shared/rows.lua` in the module
  table.

### Changed

#### SQL text has one owner: `shared/sql_text.lua`

- `quote_ident`, `quote_qualified`, `sql_string`, `sql_literal`,
  `replace_qualified_alias`, `strip_string_literals`, `token_upper`,
  `decode_quoted_identifier` and the dialect lexer had between two and five
  copies across `compiler/request_json.lua`, `admin/validator.lua`,
  `admin/semantic_definition.lua`, `compiler/physical_plan.lua`,
  `compiler/grain_sql.lua` and `shared/identity_join.lua`.
- Two of them mattered. `replace_qualified_alias` rewrites a table alias inside
  an expression while respecting string literals — it is how a representation's
  expression is re-pointed at a different source — and `strip_string_literals`
  backs the alias analysis the validator proves expressions with. They were
  byte-identical in the validator and the compiler, so the validator proved an
  expression safe with one copy while the compiler emitted SQL from the other. A
  divergence there is not a crash; it is SQL that is wrong and validates.
- `shared/identity_join.lua`'s header had named this module as the thing it
  could not yet call ("a shared SQL module is a bigger change than this one
  earns"). It calls it now.
- **One lexer, two flags.** `compiler/request_json.lua`'s `sql_tokens` and
  `admin/semantic_definition.lua`'s `tokenize` were the same ~95 lines with two
  real differences, and both are now named options rather than two files:
  `operators` fuses `>=`/`<=`/`<>`/`!=` (semantic SQL compares whole operators;
  the DDL parser slices by byte offset and has always seen two symbols), and
  `upper_identifiers` folds a quoted identifier's decoded value (the DDL parser
  reads names out of quoted tokens; the semantic-SQL parser must not, or a
  column quoted as `"AND"` would parse as a conjunction). Every token now carries
  `start_pos`, `end_pos` and `depth`; the semantic-SQL parser ignores them.
- Verified byte-equivalent to both originals before landing: a differential
  harness ran the pre-change lexers and the merged one over a hand-built corpus
  and 4 000 random inputs, comparing every field of every token. Zero
  differences.

#### `WHERE` and `HAVING` are parsed once

- `parse_where_filters` and `parse_having_filters` were two ~110-line functions
  whose diff was 72 lines of 123, almost all of it the clause noun in three
  messages. Everything else — the top-level `AND` split that skips `BETWEEN`'s
  own `AND`, the operator scan, `IS NULL` / `IN` / `BETWEEN`, the
  literal-or-raw-SQL fallback — was written twice, so a predicate form added to
  one and forgotten in the other passed every test.
- One `parse_predicates`, with `WHERE_CLAUSE` and `HAVING_CLAUSE` carrying the
  only two real differences: HAVING resolves the field and refuses a non-metric
  (`SEMANTIC_QUERY_040`), and stores the resolved name where WHERE stores what
  the author typed. Each clause's three messages sit together in its table.
- `SEMANTIC_QUERY_030`, `_031` and `_033` left the overloaded-code pin as a
  result: their extra "meanings" were the same condition written once per clause.

#### The two apply paths share one rollback

- `APPLY_SEMANTIC_DEFINITION` and `APPLY_FUSION_DECLARATION` both snapshot a
  slice of `SYS_SEMANTIC`, apply, validate and restore on refusal.
  `admin/fusion_declaration.lua` did it in 45 lines by reading column lists from
  `EXA_ALL_COLUMNS`; `admin/semantic_definition.lua` did it in 335 lines with
  every column written out four times per table — snapshot `SELECT`, restore
  `INSERT` list, `VALUES` list, and a parameter map carrying ordinals that had to
  stay in step with the first. Nothing checked that the four agreed, and
  `METRICS` grew five columns after it was written.
- Both now use `shared/catalog_rollback.lua`. A table is declared once, parent to
  child; deletes run in reverse and inserts forward from that one order.

### Fixed

- **A restored boolean `FALSE` came back as `NULL`.** Both rollbacks read a
  captured value with `row[name] or row[lower] or row[position]`, which treats
  `false` as absent and falls through to an ordinal that is usually nil — so
  `ATTRIBUTE_BINDINGS.IS_DEFAULT` and `OBJECT_COLUMNS.IS_VISIBLE` could be
  restored as NULL. The shared reader tests for nil explicitly.
- **The DDL rollback cleared two tables it never restored.**
  `METRIC_DEPENDENCIES` and `METRIC_DIMENSION_MATRIX` were in the delete list and
  not the snapshot. One list per table makes that unexpressible. Both are
  validator output that the `VALIDATE_MODEL` run following a restore rewrites, so
  this closes a window rather than changing an outcome.

### Testing

- `tests/lua/sql_text_unit_test.lua` (6 tests, 99.4 % of the module — the one
  uncovered line is the `end` of a `while` loop that this interpreter never
  reports, traced rather than assumed). It pins the alias rewriter's literal
  handling, the offset-preserving literal strip, and *exactly* the two ways the
  lexer's modes differ, so the difference is a contract instead of a fork.
- `admin/semantic_definition.lua` 76.1 → 78.5: `batch_call`, the 176-line
  dispatch that is the third place an admin script's parameter list is written
  down, is now driven for all thirteen targets with every placeholder required to
  be bound from its own key. Exasol checks arity, not names, so a mistyped
  binding there arrives as NULL and imports a row with a field missing.
- `admin/fusion_declaration.lua` 67.0 → 74.1: the apply path end to end —
  validation refusing an already-written document and the catalog being restored
  (including the compile cache, which the dispatched scripts cannot clear for
  it), a dispatched script refusing mid-sequence, a dry run that validates and
  commits nothing, and a malformed document reported in `STATUS` rather than
  raised.
- `shared/catalog_rollback.lua` at 100 %, including the refusal when a table's
  columns cannot be read — deriving from an empty answer would capture nothing,
  restore nothing, and report success.
- The `DUPLICATED_LUA_BODIES` ratchet drained from seven bodies to four, and a
  second ownership rule now guards `shared/sql_text.lua` the way one already
  guarded `shared/json.lua`: a *reworded* copy would pass the body check and
  still let the validator prove an expression the compiler renders differently.

### Documentation

- `CLAUDE.md`: the grain-graph invariant now has a sibling for SQL text. Quoting,
  literal rendering, alias rewriting, literal stripping and lexing delegate to
  `shared/sql_text.lua`; the F5 mapping join to `shared/identity_join.lua`.

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
  copy, or uncommitted edits, where git provenance does not. `verify_catalog_and_seed`
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
- `lua/semantic_layer/compiler/request_json.lua` — `parse_semantic_sql` no longer requires a `GROUP BY` clause when dimensions are selected; the `GROUP BY` coverage validation now runs only when a `GROUP BY` is supplied (`SEMANTIC_QUERY_007` removed). `tools/verify_sql_compiler_and_surfaces.py` updated to assert the inferred-GROUP BY query now succeeds.
- `lua/semantic_layer/compiler/request_json.lua` — `find_top_level_clauses`, `clause_end`, `build_sql`, `compile_request_table`, and `parse_semantic_sql` updated for Phase 2; `parse_having_filters` added (~95 lines total). `parse_where_filters` and `parse_order_by` updated for Phase 1. Source file is the canonical implementation; `sql/install/003_create_semantic_admin_scripts.sql` is generated by `python3 tools/package_lua_scripts.py`.
- `sql/install/006_create_semantic_agent_views.sql` — `COMPILE_REQUEST_SCHEMA_FOR_AGENT` view updated with `HAVING_KEYS` documentation row.

### Removed

- `skills/exasol-semantic-views-agent/` — replaced by the two focused skills above.

---

## Notes on versioning

Version 0.2 is the second tagged release. Items above are tracked against the
development baseline established by the user-study simulations run on
2026-05-13. Phase 1 and Phase 2 are complete. The next planned milestone is
Phase 3 (subqueries/CTE rewriting and CAST in SELECT — deferred pending demand).
