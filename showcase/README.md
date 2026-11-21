# Databricks UCMV on Exasol — Showcase

**The story in one line:** define a metric once in a Databricks Unity Catalog Metric View (UCMV),
import the YAML into Exasol unchanged, and query it with the *same* `MEASURE(...)` / `GROUP BY ALL`
SQL. No re-modeling, no external services — the translation runs inside the database.

The whole showcase is **pure SQL** and runs with **no Python**: Docker for the database and
[`exapump`](https://github.com/exasol-labs/exapump) (a single-binary SQL CLI) to run it.

## Run it

```sh
# from the repo root
sh showcase/run.sh             # boots Exasol (nano), installs, imports, runs the demo
sh showcase/run.sh --down      # stop the database and remove the temp connection profile
```

Prereqs: **Docker** and **exapump** on your PATH. Nothing else.

### Runs on a Mac (Apple Silicon)
The database image is `exasol/nano`, which is **multi-arch** (`linux/arm64` + `linux/amd64`). On an
Apple Silicon Mac, Docker pulls the native `arm64` build automatically — the same `run.sh` and
`docker-compose.yml` work unchanged. No `--privileged`, no Rosetta.

### What each step shows (for narrating live)
1. Start Exasol nano in Docker.
2. Connect (a throwaway `ucmv-showcase` exapump profile; nano uses a self-signed cert).
3. Install the semantic layer + demo `MART` tables by running the committed `sql/install/*.sql` and
   `sql/examples/sales_*.sql` through exapump.
4. Print the input UCMV YAML — exactly what you'd export from Databricks.
5. Point at `showcase/demo.sql` — the pure-SQL demo.
6. Run `showcase/demo.sql` in one session: it imports the UCMV (inline YAML →
   `SEMANTIC_SALES_DBX.SALES_DBX`), enables the Databricks query surface, and runs the queries.

## The pasteable artifact: `showcase/demo.sql`

`demo.sql` is self-contained — paste it into any SQL client (exapump, DbVisualizer, DBeaver) and run
it as **one session** (`ENABLE_SEMANTIC_SQL()` is session-scoped, so the queries must share the
connection that enables it). It does three things:

```sql
-- 1) import the UCMV (YAML inlined) — creates, validates, publishes SEMANTIC_SALES_DBX.SALES_DBX
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW('<yaml>', 'sales_dbx', 'SEMANTIC_SALES_DBX', TRUE);
-- 2) turn on the Databricks query surface
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
-- 3) query it the Databricks way
SELECT customer_region, MEASURE(total_revenue) AS total_revenue, MEASURE(order_count) AS order_count
FROM SEMANTIC_SALES_DBX.SALES_DBX GROUP BY ALL ORDER BY total_revenue DESC;
```

## How the UCMV maps onto Exasol

| Databricks UCMV | Exasol semantic object |
|---|---|
| `source: catalog.schema.table` | root **entity** |
| `joins[]` (incl. nested/snowflake) | one **entity** per join + a **relationship** (`many_to_one` → MANY_TO_ONE) |
| `fields[]` (`name`/`expr`) | **dimensions** (column refs qualified by entity) |
| `measures[]` `SUM/AVG/MIN/MAX(expr)` | private **fact** (the inner expr) + aggregate **metric** |
| `measures[]` `COUNT(1)` / `COUNT(DISTINCT col)` | **fact** + `COUNT` / `COUNT(DISTINCT)` **metric** |
| `measures[]` `expr FILTER (WHERE pred)` | **filtered metric** |
| `measures[]` `MEASURE(a)/MEASURE(b)` | **ratio metric** `a / NULLIF(b,0)` |

## Talking points

- **Translation runs in the database** (Lua) — only the YAML text is passed in. No external service,
  no LLM in the data path.
- **Deterministic, governed SQL** — the import publishes a guarded semantic view; the preprocessor
  compiles `MEASURE()` / `GROUP BY ALL` to plain physical SQL. BI tools, agents, and SQL authors all
  hit the same governed definition.
- **Migration without rewrites** — the metric YAML *and* the query idioms carry over.

## Be honest about the edges (see `docs/databricks-metric-views.md`)

- Expressions are **translated, not dialect-converted** — Databricks-only functions (e.g.
  `QUARTER()`) won't run on Exasol; use portable SQL in the metric expressions.
- `window:` measures are **skipped** on import (`DBX_IMPORT_410`).
- An inline-query `source:` (`SELECT ...`) is **unsupported** (`DBX_IMPORT_210`) — wrap it in a view
  and import that.

## Files

| File | Role |
|---|---|
| `run.sh` | One command: boots nano, installs via exapump, runs `demo.sql`. `--down` tears down. |
| `demo.sql` | The pure-SQL demo: inline UCMV import + `ENABLE_SEMANTIC_SQL` + the queries. |
| `docker-compose.yml` | `exasol/nano` (multi-arch) on `127.0.0.1:8563`, ephemeral. |
