<div align="center">

<h1>Exasol Semantic Views</h1>

<p><em>A database-native semantic layer for Exasol.<br>Governed metrics, deterministic compilation, and a structured agent contract — all in SQL.</em></p>

[![Exasol](https://img.shields.io/badge/Exasol-2025.1%2B-003865?logo=databricks&logoColor=white)](https://www.exasol.com)
[![Runtime](https://img.shields.io/badge/runtime-Lua%20%7C%20SQL-informational)](#installation)
[![Agent-first](https://img.shields.io/badge/agent--first-COMPILE__REQUEST__JSON-blueviolet)](#agent-first-by-design)
[![Semantic SQL](https://img.shields.io/badge/Semantic%20SQL-preprocessor-success)](#a-concrete-example)

**[Quickstart](#quickstart-with-exasol-nano) · [Docs](#project-docs) · [Agent Skills](#agent-first-by-design) · [Example](#a-concrete-example)**

</div>

---

Exasol Semantic Views is a database-native semantic layer for Exasol. It turns
business meaning into governed database metadata, then exposes that meaning to
SQL users, BI tools, and agents through one shared compiler.

The project is built around a simple idea: the semantic layer should live where
the data runs. Definitions, validation results, agent context, materialization
metadata, and generated SQL explanations are stored in Exasol and served
through SQL.

## The Concept

Most analytics systems already have a semantic layer, but it is often scattered
across dashboard formulas, copied SQL, spreadsheet conventions, notebooks, and
agent prompts. Exasol Semantic Views moves that contract into Exasol itself:

```text
Business model
  -> entities, grain, relationships
  -> dimensions, facts, metrics defined with Semantic SQL
  -> validation and compatibility rules
  -> SQL, BI, agent, introspection, and materialization surfaces
  -> ordinary Exasol SQL execution
```

The result is one governed contract. Modelers can author and review metrics with
SQL-native Semantic SQL. Humans can query governed metrics as columns. Agents
can call structured compiler scripts. BI tools can discover typed views. The
generated SQL still runs inside Exasol, under normal Exasol privileges.

## Semantic Model At A Glance

The semantic layer is not just a list of metric formulas. It captures the
business shape of the model and uses that shape when compiling queries:

- **Entities and grain** describe business objects such as `order_line`,
  `order`, `customer`, and `product`, including their physical tables and key
  expressions.
- **Relationships** describe how entities join and whether those joins preserve
  metric correctness.
- **Dimensions** are the fields users group, filter, and explain by, such as
  `customer_region`, `order_month`, and `product_category`.
- **Facts** are reusable row-level expressions at an entity grain, such as
  `net_revenue = ol.quantity * ol.net_unit_price`.
- **Metrics** compose facts and other metrics into governed aggregate answers.
- **Validation** records dependency graphs, fanout checks, and the
  metric/dimension compatibility matrix.
- **Governance and agent context** add visibility, certification, synonyms,
  verified examples, glossary text, feedback, and role-scoped discovery.
- **Optimization metadata** lets the compiler choose registered
  materializations when they are valid for the request.

Metrics are composed from lower-level pieces rather than repeated physical SQL:

```text
fact net_revenue
  -> metric total_revenue = SUM(net_revenue)
  -> metric completed_revenue = SUM(net_revenue)
       FILTER (WHERE order_status = 'COMPLETE')

fact net_cost
  -> metric total_cost = SUM(net_cost)

metric gross_margin = total_revenue - total_cost
metric gross_margin_pct = gross_margin / NULLIF(total_revenue, 0)
```

The compiler uses the same metadata for all access paths: published semantic
views with the Lua SQL preprocessor, deterministic agent requests through
`COMPILE_REQUEST_JSON`, SQL tooling through `COMPILE_SQL`, and model review
through `SHOW`, `DESCRIBE`, `EXPLAIN`, and `EXPORT`.

The installed admin APIs are Exasol Lua scripts, so callers must use
`EXECUTE SCRIPT SEMANTIC_ADMIN.<script>(...)`. Do not call them as scalar
functions with `SELECT SEMANTIC_ADMIN.<script>(...)`.

## A Concrete Example

The included sales model starts with the physical sales tables already modeled
as entities, relationships, and dimensions. From there, the user defines the
metric layer in one SQL-native Semantic SQL block:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

ALTER SEMANTIC VIEW sales.SALES
REPLACE FACTS (
  FACT net_revenue
    ON ENTITY order_line
    AS ol.quantity * ol.net_unit_price
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Net Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    PUBLIC CERTIFIED,

  FACT net_cost
    ON ENTITY order_line
    AS ol.quantity * ol.unit_cost
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Net Cost'
    COMMENT 'Cost recognized for sold units'
    PUBLIC CERTIFIED
)
REPLACE METRICS (
  METRIC total_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Total Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    SYNONYMS ('revenue', 'sales')
    ADDITIVE PUBLIC CERTIFIED,

  METRIC total_cost
    AS SUM(net_cost)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Total Cost'
    ADDITIVE PUBLIC CERTIFIED,

  METRIC gross_margin
    AS total_revenue - total_cost
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Gross Margin'
    DERIVED PUBLIC CERTIFIED,

  METRIC gross_margin_pct
    AS gross_margin / NULLIF(total_revenue, 0)
    ON ENTITY order_line
    RETURNS DECIMAL(18,6)
    FORMAT 'percentage'
    DISPLAY 'Gross Margin %'
    RATIO PUBLIC CERTIFIED,

  METRIC completed_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FILTER (WHERE order_status = 'COMPLETE')
    FORMAT 'currency'
    DISPLAY 'Completed Revenue'
    ADDITIVE PUBLIC CERTIFIED
);
```

The preprocessor lowers that statement to
`SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION`, where Lua parses, validates, and
persists catalog metadata. For bootstrap or CI sessions where preprocessing is
disabled, call that script directly with the Semantic SQL text and a `DRY_RUN`
flag.

`REPLACE FACTS` and `REPLACE METRICS` are full object-membership replacement
forms intended for bootstrap and deliberate resets. For day-to-day metric
edits, use `ADD OR REPLACE METRIC`. Failed Semantic SQL applies are rejected
and the previous catalog state is restored before returning the validation
error.

A SQL user can ask for a governed metric as if it were a column:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC
LIMIT 2;
```

`SELECT * FROM SEMANTIC_SALES.SALES` is also supported after the preprocessor
is enabled; it expands to the visible semantic dimensions and metrics.

The Lua SQL preprocessor rewrites that semantic query into valid physical
Exasol SQL over the `MART` tables. In the included sales example, the result is:

```text
CUSTOMER_REGION  TOTAL_REVENUE
North            3635
West             1500
```

Without the preprocessor, the published view fails loudly with an actionable
guard error instead of returning misleading placeholder data.

The preprocessor can be enabled per session, through BI connection
initialization, or as a database-wide operator setting. See
[Admin setup for database-wide Semantic SQL](docs/admin-db-wide-setup.md) for
rollout and rollback guidance. Tools that cannot run `EXECUTE SCRIPT` should
call `COMPILE_SQL` or `COMPILE_REQUEST_JSON` through a semantic adapter instead
of querying the guarded view directly.

Modelers can inspect the same definitions without leaving SQL:

```sql
SHOW SEMANTIC VIEWS;

SHOW SEMANTIC METRICS IN sales.SALES;

DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;

SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue;

EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;

EXPORT SEMANTIC METRIC sales.SALES.total_revenue;

EXPORT SEMANTIC VIEW sales.SALES;

EXPORT SEMANTIC MODEL sales;
```

`SHOW` helps users discover metrics. `DESCRIBE` shows business meaning and
governance. `EXPLAIN` shows lineage, compatible dimensions, and validation
context. `EXPORT` returns canonical Semantic SQL that can be reviewed or
reapplied.

`ALTER SEMANTIC VIEW` supports metric authoring and fact/metric replacement.
Dimension maintenance uses the `SEMANTIC_ADMIN.ADD_DIMENSION` script; unsupported
authoring forms fail loudly during preprocessing.

## Agent-First By Design

Agents should not have to remember SQL snippets, join conditions, or aggregate
rules. They should ask for governed metrics and dimensions:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["total_revenue"],
    "dimensions": ["customer_region"],
    "order_by": [{"field": "total_revenue", "direction": "desc"}],
    "limit": 2,
    "client": "readme"
  }'
);
```

The compiler validates the model, checks metric/dimension compatibility, plans
the required joins, expands the metric expression, and returns generated SQL
plus plan metadata. The caller then executes the generated SQL under normal
Exasol privileges.

Structured filters accept `field`, `dimension`, `column`, or `name` for the
field key and `op` or `operator` for the operator key. Supported operators are
listed in `SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT`.

For SQL-oriented tools, `COMPILE_SQL` provides the same deterministic compiler
path without relying on session preprocessor state:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  'SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   GROUP BY customer_region
   ORDER BY total_revenue DESC
   LIMIT 2'
);
```

`COMPILE_SQL_DEBUG` is available when you explicitly want SQL compile logging in
`SYS_SEMANTIC.QUERY_LOG`; the normal preprocessor path avoids hot-path logging.

For agents connected through MCP or another tool layer, the adapter must expose
semantic operations that can execute the database scripts. A generic
SELECT-only SQL tool can still read `SEMANTIC_AGENT` and `SEMANTIC_CATALOG`
views, but it cannot compile structured requests or enable the SQL
preprocessor by itself. Database-wide preprocessor activation can mitigate that
for simple generic MCP `SELECT` queries against published semantic views, but it
does not fix MCP metadata listing gaps or add script execution support.

The repository includes two Codex-compatible agent skills:

- [**exasol-semantic-analyst**](skills/exasol-semantic-analyst/SKILL.md) — for
  agents answering business questions against an existing model. Covers
  discovery, compatibility checking, `COMPILE_REQUEST_JSON`, result execution,
  explanation, and feedback capture.
- [**exasol-semantic-modeler**](skills/exasol-semantic-modeler/SKILL.md) — for
  agents creating or maintaining a model. Covers schema inspection, entity and
  relationship modelling, fact and dimension authoring, SQL-native metric DDL,
  validation, publication, and governance configuration.

## Quickstart With Exasol Nano

Start or check Nano from the parent workspace:

```sh
../nano/exanano status
```

Run the full local smoke test:

```sh
sh tools/run_nano_smoke.sh
```

The smoke test packages the Lua runtime into install SQL, resets the development
schemas, installs the extension, creates the sales example with SQL-native
metric definitions, validates the model, publishes `SEMANTIC_SALES.SALES`,
verifies semantic SQL execution, checks the agent context and feedback surface,
tests materialization selection, and verifies Semantic SQL authoring,
introspection, export, and Databricks UCMV compatibility.

If your default Python does not have `pyexasol`, point `PYTHON_BIN` at a
virtualenv Python that does:

```sh
PYTHON_BIN=../exasol-json-tables/.venv/bin/python sh tools/run_nano_smoke.sh
```

After the smoke test, try the semantic SQL example above in a session after
enabling semantic SQL.

## Testing

Run the fast database-free Lua runtime suite:

```sh
sh tools/run_lua_tests.sh
```

It executes the canonical compiler, validator, semantic-definition, agent, and
materialization Lua sources with in-memory catalog fixtures. The suite reports
and enforces per-runtime active-line coverage plus named decision-outcome
coverage. The full Nano smoke workflow runs this lane first and then verifies
packaging, installation, compilation, generated SQL execution, concurrency,
host-side regressions, extended Semantic SQL, SQL fixtures, non-SYS model-role
grant/revoke and raw-source isolation, and integrations against Exasol. The
database-free lane and packaging consistency are enforced by the checked-in
GitHub Actions workflow.

For explicit cold/warm latency, deployed-model breadth, and dimension
cardinality measurements, run:

```sh
python3 tools/verify_runtime_performance.py
```

See [Runtime testing](docs/runtime-testing.md) for coverage scope, thresholds,
and large/high-cardinality CI configuration.

## Installation

Point the installer at a running Exasol instance and run:

```sh
python3 tools/install.py
```

This packages the Lua runtime into install SQL and runs all seven install scripts
in order. Connection defaults to `localhost:8563` with user `sys`/`exasol`. Override
with environment variables:

```sh
EXASOL_HOST=myhost EXASOL_USER=admin EXASOL_PASSWORD=secret python3 tools/install.py
```

To also load the bundled sales demo model:

```sh
python3 tools/install.py --example
```

`pyexasol` must be available (`pip install pyexasol`). If your default Python does
not have it, prefix with your virtualenv Python:

```sh
PYTHON_BIN=.venv/bin/python $PYTHON_BIN tools/install.py --example
```

Pass `--skip-package` to skip the Lua packaging step and use the already-generated
`sql/install/` files — useful in CI after a prior packaging run.

## Project Docs

- Usage
  - [Creating metrics](docs/creating-metrics.md)
  - [Admin setup for database-wide Semantic SQL](docs/admin-db-wide-setup.md)
  - [Databricks metric views](docs/databricks-metric-views.md)
  - [Apache Ossie / OSI import/export](docs/osi-format.md)
  - [Examples](docs/examples.md)
- Design
  - [Architecture](docs/architecture.md)
  - [Semantic compiler](docs/semantic-compiler.md)
  - [Semantic SQL preprocessor](docs/semantic-sql-preprocessor.md)
  - [Semantic catalog](docs/semantic-catalog.md)
  - [Runtime testing](docs/runtime-testing.md)
- Agents
  - [Agent contract](docs/agent-contract.md)
  - [Analyst skill](skills/exasol-semantic-analyst/SKILL.md) — answering business questions
  - [Modeler skill](skills/exasol-semantic-modeler/SKILL.md) — creating and maintaining models

## License

This project is licensed under the [MIT License](LICENSE).
