<div align="center">

<h1>Exasol Semantic Views</h1>

<p><em>A database-native semantic layer for Exasol.<br>Governed metrics, deterministic compilation, and semantic fusion across heterogeneous sources — all in SQL.</em></p>

[![Exasol](https://img.shields.io/badge/Exasol-2025.1%2B-003865?logo=databricks&logoColor=white)](https://www.exasol.com)
[![Runtime](https://img.shields.io/badge/runtime-Lua%20%7C%20SQL-informational)](#installation)
[![Agent-first](https://img.shields.io/badge/agent--first-COMPILE__REQUEST__JSON-blueviolet)](#agent-first-by-design)
[![Semantic SQL](https://img.shields.io/badge/Semantic%20SQL-preprocessor-success)](#a-concrete-example)

**[Quickstart](#quickstart-with-exasol-personal) · [Docs](#project-docs) · [Agent Skills](#agent-first-by-design) · [Example](#a-concrete-example) · [Grain Safety](#grain-safety-you-can-see)**

</div>

---

Exasol Semantic Views is a database-native semantic layer for Exasol. It turns
business meaning into governed database metadata, then exposes that meaning to
SQL users, BI tools, and agents through one shared compiler. A logical entity
can be backed by one warehouse table or fused across local, federated, and
migrating representations without changing its business contract.

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
  -> physical representations, authority, coverage, and identity
  -> validation and compatibility rules
  -> SQL, BI, agent, introspection, and materialization surfaces
  -> ordinary Exasol SQL execution
```

The result is one governed contract. Modelers can author and review metrics with
SQL-native Semantic SQL. Humans can query governed metrics as columns. Agents
can call structured compiler scripts. BI tools can discover typed views through
ordinary JDBC/ODBC metadata once a model is published, and query them in
sessions that can activate the preprocessor
([what BI tools see](#what-bi-tools-see)). The generated SQL still runs inside
Exasol, under normal Exasol privileges.

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
- **Representations and fusion** map one logical entity to heterogeneous
  physical sources, with explicit bindings, temporal coverage, authority, and
  semantic identity controlling safe selection or reconciliation.
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

Fusion is proof-driven rather than best-effort: validation checks keys,
coverage, bindings, and identity before the compiler can partition or reconcile
sources. See the [architecture guide](docs/architecture.md#semantic-fusion-path)
for the supported fusion strategies and safety boundaries.

The installed admin APIs are Exasol Lua scripts, so callers must use
`EXECUTE SCRIPT SEMANTIC_ADMIN.<script>(...)`. Do not call them as scalar
functions with `SELECT SEMANTIC_ADMIN.<script>(...)`.

The official Exasol MCP Server can query published semantic views without a
custom adapter: enable its read-query tool, activate
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` with `set_exasol_preprocessor`, verify
the session setting, and run semantic SQL with `execute_exasol_query`. See
[Exasol MCP Server integration](docs/mcp-server-integration.md) for setup,
agent behavior, reconnect handling, and the structured-adapter boundary.

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
forms intended for bootstrap and deliberate resets. For day-to-day edits, use
`ADD OR REPLACE FACT` or `ADD OR REPLACE METRIC`, which upsert one definition
and leave the rest of the object alone. Failed Semantic SQL applies are
rejected and the previous catalog state is restored before returning the
validation error.

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
guard error instead of returning misleading placeholder data:

```text
SEMANTIC_SURFACE_001: semantic query requires the Lua SQL preprocessor.
Run EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL() for this session.
```

### What BI Tools See

`PUBLISH_MODEL` creates the published schema; loading a model does not. Until a
model is published, `SEMANTIC_SALES` does not exist at all — and Semantic SQL
still works, because the preprocessor rewrites from the catalog rather than
from the view, which makes a missing publish easy to overlook. Install the demo
published with:

```sh
python3 tools/install.py --example --publish
```

Once published, the schema holds ordinary Exasol views with typed columns and
column comments, so JDBC/ODBC metadata discovery works without any adapter:

```sql
SELECT COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE, COLUMN_COMMENT
FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = 'SEMANTIC_SALES';
--  SALES  TOTAL_REVENUE  DECIMAL(18,2)  Net recognized revenue excluding tax
```

What that metadata does *not* carry is the governance layer — synonyms,
certification, verified examples, and which metric/dimension pairs are valid.
Those live in `SEMANTIC_CATALOG` and `SEMANTIC_AGENT`, and a client that wants
them reads those views rather than `EXA_ALL_COLUMNS`. Published objects also
publish a `SEMANTIC_SALES.SEMANTIC_DISCOVERY` table naming the queries to use.

Discovery is therefore adapter-free; *querying* is not. A BI client must be
able to activate the preprocessor for its session, or the guard error above is
what it gets. `docs/virtual-schema-adapter.md` is candid that the adapter which
would remove that requirement does not exist yet.

The preprocessor can be enabled per session, through BI connection
initialization, or as a database-wide operator setting. See
[Admin setup for database-wide Semantic SQL](docs/admin-db-wide-setup.md) for
rollout and rollback guidance. The official Exasol MCP Server can activate the
same session preprocessor with `set_exasol_preprocessor`; tools without either
script execution or preprocessor controls need database-wide activation or a
semantic adapter.

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

## Grain Safety You Can See

The demo model is deliberately multi-grain, because that is what makes the
project's central property observable. `net_revenue`, `net_cost`, and
`quantity` are order-line measures in the `SALES` object. `freight_amount` is
charged once per order and lives in a second object, `ORDER_HEADER`, rooted at
`order`.

Order-grain freight groups fine along dimensions reachable without fan-out --
`ship_mode` on the order itself, `customer_segment` through the `MANY_TO_ONE`
`order_to_customer` edge:

```sql
SELECT ship_mode, total_freight
FROM SEMANTIC_SALES.ORDER_HEADER
GROUP BY ship_mode;
--  EXPRESS  58.75
--  GROUND   46.50
```

Putting that same metric in `SALES` would make it groupable by
`product_category`, and the only path from `order` to `product` runs backwards
through `order_line_to_order` -- one order row fanned out across its lines. The
model refuses it when the metric is *defined*, not when it is queried, and
restores the catalog:

```text
SEMANTIC_ADMIN_090: metric rejected; validation failed: SEMANTIC_MODEL_030:
Visible metric freight_in_sales cannot be grouped or filtered by dimension
product_category: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED via order_line_to_order
(rejected: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED) > order_line_to_product. No
relationship declaration makes a fanning traversal safe. Expose this metric only
alongside dimensions reachable from 'order' without fan-out, in this or a
separate semantic object, or remove one of the two from object 'SALES'.
```

The refusal is worth a real number: joining orders to lines by hand and summing
freight by product category reports 149.00 against 105.25 actually charged.

`SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX` publishes the same verdict for every
metric/dimension pair, so agents can see the boundary without hitting it. Run
`python3 tools/verify_fanout_guardrails.py` against an installed model to walk
through all of it live; it is part of the smoke suite.

## Fusion You Can See In The Number

Two of the failures data fusion prevents are arithmetic, not opinion. Both are
mistakes a hand-written query makes silently.

**A re-loaded boundary day.** A hot/cold split is the most ordinary warehouse
shape there is, and the most ordinary accident is the archive job loading the
cutover day into both tables. A hand-rolled `UNION ALL` counts it twice; F3
coverage predicates cannot, because each partition declares the half-open
interval it owns:

```
hand-rolled UNION ALL : 5762.75
declared F3 fusion    : 4972.00   <- the truth
```

**Revenue stranded in a NULL bucket.** A warehouse customer master has no
loyalty tier for customers onboarded after its last load. Grouping revenue by
that column reports them as `(null)` — a bucket nobody acts on. F4
reconciliation against the CRM, declared authoritative for that attribute,
recovers them:

```
warehouse only : {'(null)': 156253.44, 'Gold': 42000.00, 'Silver': 31500.00}
reconciled     : {'Bronze': 27400.25, 'Gold': 100250.75, 'Silver': 102102.44}
recovered      : 156253.44 — 68.0% of revenue, and the total is unchanged
```

Neither number is quoted from a slide: `tools/verify_fusion_value.py` builds
both landscapes, computes both comparisons, and asserts them, so these figures
cannot drift from what the product does. It is part of the smoke suite. See
[docs/data-fusion.md](docs/data-fusion.md) for the six fusion levels and the
declarations behind these two.

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

For agents using the official Exasol MCP Server, the default preprocessor tools
provide a direct semantic SQL path: list, set, and verify
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`, then query the published view with
`execute_exasol_query`. A dedicated adapter is needed only for structured
requests, plans, durable handles, explanations, or feedback. See the
[MCP integration guide](docs/mcp-server-integration.md) for the exact workflow
and reconnect and result-limit caveats.

The repository includes three agent skills:

- [**exasol-semantic-analyst**](skills/exasol-semantic-analyst/SKILL.md) — for
  agents answering business questions against an existing model. Covers
  discovery, compatibility checking, `COMPILE_REQUEST_JSON`, result execution,
  explanation, and feedback capture.
- [**exasol-semantic-modeler**](skills/exasol-semantic-modeler/SKILL.md) — for
  agents creating or maintaining a model. Covers schema inspection, entity and
  relationship modelling, fact and dimension authoring, SQL-native metric DDL,
  validation, publication, and governance configuration.
- [**exasol-semantic-reviewer**](skills/exasol-semantic-reviewer/SKILL.md) — for
  agents coordinating human review of proposed or published models. Covers
  evidence, technical and semantic approval gates, acceptance tests, semantic
  diffs, release handoffs, and post-publication feedback triage.

## Quickstart With Exasol Personal

Install the [Exasol Personal](https://github.com/exasol/exasol-personal)
launcher, then create a local deployment:

```sh
exasol install local
exasol status
```

Each deployment picks its own port, and only the first one gets 8563. Export it
so every tool in this repo reaches the right deployment:

```sh
export EXASOL_PORT=$(jq -r .connection.dbPort ~/.exasol/personal/deployments/default/deployment.json)
```

Create a Python environment, install the client dependency, and install ESV with its sales example:

```sh
python3 -m venv .venv
.venv/bin/pip install pyexasol
.venv/bin/python tools/install.py --example
```

Run a first semantic query through the SQL client. Enabling Semantic SQL and
querying in the same invocation keeps the preprocessor active for that session:

```sh
exasol connect -c "
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC;
"
```

Use `exasol stop` and `exasol start` to suspend and resume the deployment.

Every install records which build it applied, so a deployment can answer
"what am I running?" without comparing checkouts:

```sql
SELECT DISPLAY_VERSION, GIT_COMMIT, GIT_STATE, RUNTIME_CHECKSUM, INSTALLED_AT
FROM SEMANTIC_CATALOG.PRODUCT_VERSION;
--  0.1+dev  a5b6c64...  DIRTY  365e183d9000...  2026-08-23 09:14:02
```

See [Which build is installed](docs/semantic-catalog.md#which-build-is-installed)
for the full column set and the install history view.

## Testing

Run the fast database-free Lua runtime suite:

```sh
sh tools/run_lua_tests.sh
```

It executes the canonical compiler, validator, semantic-definition, agent, and
materialization Lua sources with in-memory catalog fixtures. The suite reports
and enforces per-runtime active-line coverage plus named decision-outcome
coverage. The full database-backed smoke workflow runs this lane first and then
verifies packaging, installation, compilation, generated SQL execution, concurrency,
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
with environment variables — `EXASOL_HOST`, `EXASOL_PORT`, `EXASOL_USER`,
`EXASOL_PASSWORD` — or with `--port`:

```sh
EXASOL_HOST=myhost EXASOL_PORT=60930 EXASOL_USER=admin EXASOL_PASSWORD=secret \
  python3 tools/install.py
```

On Exasol Personal only the *first* deployment gets 8563, so overriding the port
is the common case rather than the exception. Read the port back from the
deployment and export it once for every tool in this repo:

```sh
export EXASOL_PORT=$(jq -r .connection.dbPort ~/.exasol/personal/deployments/default/deployment.json)
```

Substitute the deployment name if you created it with `exasol install local -d <name>`.

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
  - [Exasol MCP Server integration](docs/mcp-server-integration.md)
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
  - [Reviewer skill](skills/exasol-semantic-reviewer/SKILL.md) — coordinating review and release approval

## License

This project is licensed under the [MIT License](LICENSE).
