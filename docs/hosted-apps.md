# Hosted Dashboards and Applications

This page is for an application that queries a semantic model from its own
code: a dashboard framework, a notebook served as an app, a reporting service.
Unlike a BI tool, it usually has no connect hook to paste a statement into. It
runs fixed SQL through a driver or a result-set helper, and its sessions come
from a pool that it does not fully control.

The short version: **query the model live on every request, never store the
SQL it compiles to, and make every session the app uses set itself up again.**

---

## 1. Never persist `GENERATED_SQL`

`COMPILE_SQL` and `COMPILE_REQUEST_JSON` return `GENERATED_SQL`, which runs on
any session with no setup. That makes it tempting to save it in the app's SQL
file. **Don't.** The text is the model as it was at that moment:

- **A certified metric fix does not reach it.** When `total_revenue` was
  corrected to exclude cancelled orders, the live dashboards moved to the new
  figure and the one with saved SQL kept showing the old one.
- **On a fused model it also freezes fusion.** The text contains the coverage
  boundary timestamps, the `COALESCE` authority order and the identity mapping
  join. After a routine roll-forward moved rows from the hot partition to the
  archive and the boundary with them, the saved SQL returned a third of the
  live answer.
- **Nothing can find it afterwards.** `COMPILE_SQL` writes no log row and no
  `FROZEN_VIEWS` entry, so `CHECK_FROZEN_VIEWS` cannot see text an app stored.
  Rolling such an app back one revision silently restores the old number, with
  every check green.

Compile per request instead (section 3), or query the published view live. If
a frozen statement is genuinely what you want, make it a database view with
`CREATE VIEW` through the preprocessor: that is registered, and
`CHECK_FROZEN_VIEWS` reports when it goes `STALE`
([BI tools: Creating views on top](bi-tools.md#creating-views-on-top)).

## 2. Session setup

The preprocessor is a session setting. An app's pool opens new sessions on
start, after a reconnect, when it replaces a connection, and after any error
that makes the driver discard one. **Each of those needs the setup again**, so
run it wherever the app obtains a connection, not once at start-up.

Which statement depends on what the app's helper expects back:

| the helper that runs setup | use | why |
|---|---|---|
| expects no result set (a plain `execute`) | `ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` | returns nothing |
| requires a result set (a `query_rows()`-style helper) | `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()` | same effect, plus one status row: `STATUS`, `ACTIVATION_SCOPE`, `PREPROCESSOR_SCRIPT`, `MESSAGE` |

`MODELS_FOR_AGENT.SESSION_SETUP_SQL` carries the statement for each model, so an
app can read it rather than hard-code it. A session without the preprocessor
is easy to recognise: a plain statement fails with `SEMANTIC_SURFACE_001` from
the published view's guard, which says what to run, and a `GROUP BY` statement
fails earlier, in Exasol's parser, with `not a valid GROUP BY expression`. Treat
either as "set the session up again", then retry once.

Semantic DDL through the preprocessor returns a result set too, so a client
that insists on a row count for DDL (such as `exapump sql`) reports `Expected
row count, got result set`. Author from a client that accepts result sets.

## 3. Choosing a lane

| lane | when it fits | what it costs |
|---|---|---|
| **Live Semantic SQL** against `SEMANTIC_<MODEL>.<OBJECT>` | the app already writes SQL; one statement per panel | needs the session setup above on every session |
| **Per-request compile**: `COMPILE_REQUEST_JSON`, then run `GENERATED_SQL` straight away | the app builds requests from data; no session setup is possible | two round trips per query |

Both see the model as it is now. The per-request lane also identifies the app:
put a `client` in the request (`"client": "sales-dashboard"`) and every call,
refusals included, is attributed in `REQUEST_HISTORY_FOR_AGENT`. The live lane
logs as `PREPROCESSOR` under the session's database user, so give each app its
own user if you need to tell them apart.

`COMPILE_SQL` is for checking a statement, not for serving it: it logs nothing.
`COMPILE_SQL_DEBUG(statement, client_name)` compiles the same way and records
the call in `QUERY_LOG` with your client name.

**Column names differ by lane.** Semantic SQL returns columns as SQL names them,
upper-case unless aliased (`TOTAL_REVENUE`). A structured request returns them
under the canonical field name (`total_revenue`), or under a synonym as
written when it asked for one. Read results by name, and pick one lane per
panel. `COMPILE_RESULT_SCHEMA_FOR_AGENT` states this per entrypoint.

## 4. Governed presentation

Labels, formats and certification are part of the model. Join results to
`SEMANTIC_AGENT.FIELDS_FOR_AGENT` instead of hard-coding them, so a renamed or
corrected metric keeps its certified label:

```sql
SELECT SQL_COLUMN_NAME, FIELD_NAME, DISPLAY_NAME, DESCRIPTION,
       FORMAT_HINT, UNIT_HINT, IS_CERTIFIED, SOURCE_COUNT, FUSION_STRATEGY
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES';
```

Match a Semantic SQL column on `SQL_COLUMN_NAME` and a structured-request column
on `FIELD_NAME`. A `percentage` value is a fraction (`0.25` is 25%), and a
`currency` value names its currency in `UNIT_HINT`; see
[Creating metrics](creating-metrics.md).

## 5. A minimal provenance panel

Three things are worth showing next to a number:

- **Is the model sound?** `MODELS_FOR_AGENT.VALIDATION_STATUS`. `WARNING` is
  not `VALID`; the warnings themselves are in
  `SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES`.
- **Is this field fused?** `FIELDS_FOR_AGENT.SOURCE_COUNT` and
  `FUSION_STRATEGY` answer it without compiling anything.
- **How was this answer assembled?** From a per-request compile's `PLAN_JSON`:
  `logical_plan.physical_plan.fusion_plan` for the fusion decisions, and
  `selected_representations[].selected_bindings[].fusion_contributors` for which
  sources fed a fused field.

## 6. Grants

The app's database user needs the model granted with `GRANT_MODEL_ROLE` and
`SELECT` on the physical sources: the compiled SQL reads them with the caller's
rights. Broad privileges such as `SELECT ANY TABLE` let the user set the
preprocessor but not run a semantic query. The full table is in
[BI tools: Who needs what](bi-tools.md#who-needs-what).

## 7. Recording what a panel was built against

Store each field's definition hash with the panel that uses it, and compare
on deploy, on rollback and in a health check:

```sql
SELECT FIELD_KIND, FIELD_NAME, DEFINITION_HASH
FROM SEMANTIC_AGENT.DEFINITION_HASHES_FOR_AGENT
WHERE MODEL_NAME = 'sales';
```

A field's hash moves when what it computes does: its expression or filter,
anything it is built from, or its entity's sources, coverage or authority. It
does not move for a validation run, a republish, a new label, or a rename. A
compile per request gets the same values for its fields in
`PLAN_JSON.definition_hashes`. A rollback that restores old SQL and a stored
hash that no longer matches is the "every check green, wrong number" case
this exists to catch.

## 8. Noticing a breaking change

When a metric is dropped or renamed, the history shows who is now failing.
`REQUEST_HISTORY_FOR_AGENT` shows each user their own requests, and `SYS` all
of them, so run this as `SYS` to see every app, or as the app's user to see
its own:

```sql
SELECT CLIENT_NAME, USER_NAME, ERROR_CODE, COUNT(*)
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
WHERE MODEL_NAME = 'sales' AND STATUS <> 'OK'
GROUP BY 1, 2, 3;
```

A renamed metric keeps its old name as a synonym, and a query that still uses
it gets its column back under the name it used, so reading by name keeps
working until the app moves to the new one.
