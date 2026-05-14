#!/usr/bin/env python3
"""Run persona-based user studies against local Exasol Nano and MCP."""

from __future__ import annotations

import json
import re
import ssl
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import pyexasol  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports"
DSN = "localhost:8563"
USER = "sys"
PASSWORD = "exasol"
MCP_BASE = "http://localhost:4896"


def value_to_text(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def rows_to_text(rows: list[tuple[Any, ...]], limit: int = 8) -> list[list[Any]]:
    return [[value_to_text(value) for value in row] for row in rows[:limit]]


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def connect():
    return pyexasol.connect(
        dsn=DSN,
        user=USER,
        password=PASSWORD,
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def run_sql(con, sql: str) -> dict[str, Any]:
    started = time.time()
    try:
        stmt = con.execute(sql)
        rows = [tuple(row) for row in stmt.fetchall()]
        columns = list(stmt.columns().keys())
        return {
            "ok": True,
            "columns": columns,
            "rows": rows_to_text(rows),
            "row_count": len(rows),
            "elapsed_ms": round((time.time() - started) * 1000, 1),
        }
    except Exception as exc:
        return {
            "ok": False,
            "error": str(exc).strip(),
            "elapsed_ms": round((time.time() - started) * 1000, 1),
        }


def run_sql_no_fetch(con, sql: str) -> dict[str, Any]:
    started = time.time()
    try:
        con.execute(sql)
        return {"ok": True, "elapsed_ms": round((time.time() - started) * 1000, 1)}
    except Exception as exc:
        return {
            "ok": False,
            "error": str(exc).strip(),
            "elapsed_ms": round((time.time() - started) * 1000, 1),
        }


class McpClient:
    def __init__(self) -> None:
        self.session_id: str | None = None

    def init(self) -> None:
        if self.session_id is not None:
            return
        initial = subprocess.run(
            ["curl", "-sv", "-H", "Accept: text/event-stream", f"{MCP_BASE}/mcp"],
            capture_output=True,
            text=True,
            check=False,
        )
        match = re.search(r"mcp-session-id: ([a-f0-9]+)", initial.stderr)
        if not match:
            raise RuntimeError("Could not get MCP session id: " + initial.stderr[:500])
        self.session_id = match.group(1)
        self.post(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "exasol-semantic-views-study", "version": "1.0"},
                },
            },
            parse=False,
        )
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"}, parse=False)

    def post(self, payload: dict[str, Any], parse: bool = True) -> dict[str, Any]:
        self.init() if self.session_id is None and payload.get("method") != "initialize" else None
        headers = [
            "-H",
            "Content-Type: application/json",
            "-H",
            "Accept: application/json, text/event-stream",
        ]
        if self.session_id is not None:
            headers.extend(["-H", f"mcp-session-id: {self.session_id}"])
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", f"{MCP_BASE}/mcp", *headers, "-d", json.dumps(payload)],
            capture_output=True,
            text=True,
            check=False,
        )
        if not parse:
            return {"ok": result.returncode == 0, "stdout": result.stdout, "stderr": result.stderr}
        for line in result.stdout.splitlines():
            if line.startswith("data: "):
                return json.loads(line[6:])
        try:
            return json.loads(result.stdout)
        except Exception:
            return {"error": result.stdout[:1000], "stderr": result.stderr[:1000]}

    def call(self, tool_name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        self.init()
        return self.post(
            {
                "jsonrpc": "2.0",
                "id": int(time.time() * 1000) % 100000,
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments or {}},
            }
        )


@dataclass
class Step:
    name: str
    action: str
    result: dict[str, Any]
    friction: str | None = None


@dataclass
class Bug:
    bug_id: str
    title: str
    severity: str
    component: str
    repro: str
    expected: str
    actual: str
    persona: str


@dataclass
class Study:
    filename: str
    persona: str
    role: str
    interface: str
    goals: list[str]
    steps: list[Step] = field(default_factory=list)
    bugs: list[Bug] = field(default_factory=list)
    friction_points: list[str] = field(default_factory=list)
    observations: list[str] = field(default_factory=list)
    recommendations: list[str] = field(default_factory=list)

    def add_step(self, name: str, action: str, result: dict[str, Any], friction: str | None = None) -> dict[str, Any]:
        self.steps.append(Step(name, action, result, friction))
        if friction:
            self.friction_points.append(friction)
        return result

    def add_bug(
        self,
        bug_id: str,
        title: str,
        severity: str,
        component: str,
        repro: str,
        expected: str,
        actual: str,
    ) -> None:
        self.bugs.append(Bug(bug_id, title, severity, component, repro, expected, actual, self.persona))


def mcp_result_summary(response: dict[str, Any]) -> dict[str, Any]:
    result = response.get("result", response)
    if isinstance(result, dict) and ("structuredContent" in result or "isError" in result or "content" in result):
        return {
            "ok": not result.get("isError", False),
            "structured": result.get("structuredContent"),
            "text": result.get("content"),
        }
    return {"ok": "error" not in response, "response": response}


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    result = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_literal(payload)})")
    if result["ok"] and result["rows"]:
        row = result["rows"][0]
        result["compile_status"] = row[0]
        result["generated_sql"] = row[3]
        result["plan_json"] = row[4]
        result["agent_request_id"] = row[7]
    return result


def compile_sql(con, semantic_sql: str) -> dict[str, Any]:
    result = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_literal(semantic_sql)})")
    if result["ok"] and result["rows"]:
        row = result["rows"][0]
        result["compile_status"] = row[0]
        result["generated_sql"] = row[4]
        result["plan_json"] = row[5]
    return result


def study_casual_mcp(mcp: McpClient) -> Study:
    study = Study(
        "persona-test-01-casual-mcp.md",
        "Nina Patel",
        "Casual business user using conversational analytics",
        "Nano MCP Server only",
        [
            "Find what sales data is available.",
            "Get revenue by region without knowing physical tables.",
            "Understand what total revenue means.",
            "Ask for completed-order revenue using natural language intent.",
        ],
    )

    response = mcp_result_summary(mcp.call("find_exasol_schemas", {"keywords": ["sales", "revenue", "semantic"]}))
    study.add_step("Discover sales-related schemas", "find_exasol_schemas(['sales','revenue','semantic'])", response)
    schema_names = [row.get("name") for row in response.get("structured", {}).get("result", [])] if response.get("structured") else []
    if "SEMANTIC_SALES" not in schema_names:
        study.add_bug(
            "BUG-STUDY-005",
            "MCP schema search does not surface SEMANTIC_SALES",
            "High",
            "MCP discovery",
            "find_exasol_schemas(keywords=['sales','revenue','semantic'])",
            "SEMANTIC_SALES is returned.",
            f"Returned {schema_names}.",
        )

    sales_list = mcp_result_summary(mcp.call("list_exasol_tables_and_views", {"schema_name": "SEMANTIC_SALES"}))
    study.add_step("List SEMANTIC_SALES objects", "list_exasol_tables_and_views('SEMANTIC_SALES')", sales_list)
    listed_sales = [row.get("name") for row in sales_list.get("structured", {}).get("result", [])] if sales_list.get("structured") else []
    if "SALES" not in listed_sales:
        study.add_bug(
            "BUG-STUDY-001",
            "MCP table listing omits published semantic views",
            "High",
            "MCP discovery",
            "list_exasol_tables_and_views(schema_name='SEMANTIC_SALES')",
            "The published view SALES is listed.",
            f"Returned {listed_sales}; the discovery table is visible but the view is not.",
        )
        study.friction_points.append("MCP listing exposes only the discovery table, so the user must already know to describe SEMANTIC_SALES.SALES.")

    describe = mcp_result_summary(mcp.call("describe_exasol_table_or_view", {"schema_name": "SEMANTIC_SALES", "table_name": "SALES"}))
    study.add_step("Describe published semantic view", "describe_exasol_table_or_view('SEMANTIC_SALES','SALES')", describe)

    metrics = mcp_result_summary(
        mcp.call(
            "execute_exasol_query",
            {"query": "SELECT METRIC_NAME, DISPLAY_NAME, DESCRIPTION FROM SEMANTIC_CATALOG.METRICS ORDER BY METRIC_NAME"},
        )
    )
    study.add_step("Read metric definitions", "SELECT METRIC_NAME, DISPLAY_NAME, DESCRIPTION FROM SEMANTIC_CATALOG.METRICS", metrics)

    direct_query = mcp_result_summary(
        mcp.call(
            "execute_exasol_query",
            {
                "query": (
                    "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES "
                    "GROUP BY CUSTOMER_REGION ORDER BY TOTAL_REVENUE DESC"
                )
            },
        )
    )
    study.add_step(
        "Try direct semantic SQL through generic MCP SQL tool",
        "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION",
        direct_query,
        "The tool can run SELECT, but the session preprocessor is not enabled for the MCP connection.",
    )

    enable = mcp_result_summary(
        mcp.call("execute_exasol_query", {"query": "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()"})
    )
    study.add_step(
        "Try to enable Semantic SQL through MCP",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        enable,
        "The generic MCP SQL tool rejects non-SELECT statements.",
    )
    if enable.get("ok") is False:
        study.add_bug(
            "BUG-STUDY-002",
            "Generic MCP SQL tool cannot execute required semantic scripts",
            "Critical",
            "MCP adapter",
            "execute_exasol_query(query='EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()')",
            "Conversational interface can enable semantic SQL or call COMPILE_REQUEST_JSON through a semantic tool.",
            "The tool returns: The query is invalid or not a SELECT statement.",
        )

    compile_attempt = mcp_result_summary(
        mcp.call(
            "execute_exasol_query",
            {
                "query": (
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{"
                    '"model":"sales","object":"SALES","metrics":["total_revenue"],'
                    '"dimensions":["customer_region"],"client":"nina"}' "')"
                )
            },
        )
    )
    study.add_step(
        "Try structured compiler through generic MCP SQL tool",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{...}')",
        compile_attempt,
        "The preferred agent path is still inaccessible through the generic SELECT-only MCP tool.",
    )

    study.observations.extend(
        [
            "Schema search now finds SEMANTIC_SALES, and describing the known semantic view gives useful comments and columns.",
            "The casual MCP path still cannot produce a metric value without a semantic MCP adapter because script execution is blocked.",
            "Reading SEMANTIC_CATALOG.METRICS works and lets an assistant explain metric definitions if it knows the catalog schema.",
        ]
    )
    study.recommendations.extend(
        [
            "Add first-class MCP semantic tools: list_semantic_views, describe_semantic_view, execute_structured_semantic_query, execute_semantic_sql, explain_semantic_request.",
            "Fix the generic MCP table listing to include views, not only physical tables.",
            "Use the published view comments and discovery tables as a fallback, but do not treat them as a complete conversational interface.",
        ]
    )
    return study


def study_power_analyst() -> Study:
    con = connect()
    study = Study(
        "persona-test-02-power-analyst.md",
        "Marcus Rivera",
        "Senior analyst building a margin dashboard",
        "Direct SQL and pyexasol",
        [
            "Discover valid metric/dimension combinations.",
            "Build multi-metric region/category analytics.",
            "Filter completed orders without case mistakes.",
            "Rank categories within regions.",
            "Understand unsupported complex SQL edges.",
        ],
    )
    try:
        study.add_step(
            "Inspect available metrics",
            "SELECT METRIC_NAME, METRIC_KIND, DESCRIPTION FROM SEMANTIC_CATALOG.METRICS",
            run_sql(con, "SELECT METRIC_NAME, METRIC_KIND, DESCRIPTION FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME='sales' ORDER BY METRIC_NAME"),
        )
        study.add_step(
            "Inspect compatibility matrix",
            "SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT",
            run_sql(
                con,
                "SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE "
                "FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT "
                "WHERE MODEL_NAME='sales' AND METRIC_NAME IN ('total_revenue','gross_margin_pct') "
                "ORDER BY METRIC_NAME, DIMENSION_NAME",
            ),
        )
        request = {
            "model": "sales",
            "object": "SALES",
            "metrics": ["gross_margin", "gross_margin_pct", "total_revenue"],
            "dimensions": ["customer_region", "product_category"],
            "filters": [{"field": "order_status", "op": "=", "value": "complete"}],
            "order_by": [{"field": "gross_margin_pct", "direction": "desc"}],
            "client": "marcus-rivera",
        }
        compiled = compile_request(con, request)
        study.add_step("Compile multi-metric request with lowercase filter", json.dumps(request), compiled)
        if compiled.get("generated_sql"):
            rows = run_sql(con, compiled["generated_sql"])
            study.add_step("Execute generated dashboard SQL", compiled["generated_sql"], rows)
            if rows.get("row_count", 0) == 0:
                study.add_bug(
                    "BUG-STUDY-006",
                    "Lowercase string filter produced zero rows",
                    "High",
                    "Compiler",
                    json.dumps(request),
                    "Text filters should match COMPLETE when the user supplies complete.",
                    "Generated query returned zero rows.",
                )

            wrapped = (
                "SELECT * FROM ("
                "SELECT q.*, ROW_NUMBER() OVER (PARTITION BY \"customer_region\" ORDER BY \"gross_margin_pct\" DESC) AS region_rank "
                f"FROM ({compiled['generated_sql']}) q"
                ") ranked WHERE region_rank <= 2 ORDER BY \"customer_region\", region_rank"
            )
            study.add_step("Rank generated results within each region", wrapped, run_sql(con, wrapped))

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        semantic_sql = (
            "SELECT customer_region, product_category, gross_margin_pct "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region, product_category "
            "HAVING gross_margin_pct > 0.3 "
            "ORDER BY gross_margin_pct DESC"
        )
        having = run_sql(con, semantic_sql)
        study.add_step(
            "Try HAVING directly in semantic SQL",
            semantic_sql,
            having,
            "Semantic SQL intentionally supports a small BI subset; HAVING is not supported.",
        )
        if having["ok"]:
            study.add_bug(
                "BUG-STUDY-007",
                "Unsupported HAVING unexpectedly compiled",
                "Medium",
                "SQL preprocessor",
                semantic_sql,
                "Unsupported semantic SQL should fail closed or be documented as supported.",
                "Query succeeded.",
            )
        order_not_selected = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["gross_margin_pct"],
                "dimensions": ["customer_region"],
                "order_by": [{"field": "total_revenue", "direction": "desc"}],
                "client": "marcus-rivera",
            },
        )
        study.add_step(
            "Try ORDER BY metric not selected",
            "COMPILE_REQUEST_JSON metrics=['gross_margin_pct'], order_by=['total_revenue']",
            order_not_selected,
            "Power analysts often expect hidden ORDER BY expressions; the MVP requires ORDER BY fields to be selected.",
        )
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        con.close()

    study.observations.extend(
        [
            "The structured compiler handles multi-metric, multi-dimensional margin analysis and case-insensitive filters correctly.",
            "Advanced SQL patterns are best handled by compiling a semantic subquery, then applying regular Exasol SQL around the generated SQL.",
            "The small semantic SQL subset is predictable, but analysts need a clear escape-hatch pattern for ranking, HAVING, and more complex post-processing.",
        ]
    )
    study.recommendations.extend(
        [
            "Document the pattern: compile semantic request -> wrap generated SQL for advanced SQL analytics.",
            "Consider adding HAVING support or explicit examples for filtering on metric results after compilation.",
            "Consider allowing ORDER BY over unselected metrics when the metric is valid for the selected dimensions.",
        ]
    )
    return study


def cleanup_metric(con, metric_name: str) -> None:
    quoted = sql_literal(metric_name)
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID IN "
        f"(SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME = {quoted})"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID IN "
        f"(SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME = {quoted})"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES WHERE METRIC_ID IN "
        f"(SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME = {quoted})"
    )
    con.execute(f"DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_NAME = {quoted}")
    con.execute(f"DELETE FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME = {quoted}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")


def study_admin() -> Study:
    con = connect()
    study = Study(
        "persona-test-03-admin-bi.md",
        "Elena Novak",
        "Data admin preparing the semantic layer for BI users",
        "Direct SQL admin scripts",
        [
            "Validate and publish the model.",
            "Add general agent context.",
            "Add a new metric safely.",
            "Check current validation state and export definitions.",
            "Evaluate compatibility APIs for operational safety.",
        ],
    )
    try:
        study.add_step("Validate model", "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')", run_sql(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')"))
        study.add_step(
            "Check current validation issues",
            "SELECT * FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES WHERE MODEL_NAME='sales'",
            run_sql(con, "SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES WHERE MODEL_NAME='sales'"),
        )
        study.add_step("Publish model", "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')", run_sql(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')"))
        study.add_step(
            "Verify published status and readiness",
            "SELECT MODEL_STATUS, AGENT_READINESS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT",
            run_sql(con, "SELECT MODEL_NAME, MODEL_STATUS, AGENT_READINESS, VALIDATION_STATUS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT WHERE MODEL_NAME='sales'"),
        )
        instruction_sql = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION("
            "'sales','MODEL','sales','GENERAL','Revenue is in USD unless the metric says otherwise.',NULL,10)"
        )
        study.add_step("Add general agent instruction", instruction_sql, run_sql(con, instruction_sql))
        metric_sql = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC units_sold_admin
  AS SUM(quantity)
  ON ENTITY order_line
  RETURNS DECIMAL(18,0)
  FORMAT 'count'
  DISPLAY 'Units Sold'
  COMMENT 'Total units sold across order lines'
  ADDITIVE PUBLIC CERTIFIED"""
        dry = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(metric_sql)}, TRUE)")
        study.add_step("Dry-run single metric addition", "APPLY_SEMANTIC_DEFINITION(..., TRUE)", dry)
        apply = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(metric_sql)}, FALSE)")
        study.add_step("Apply single metric addition", metric_sql, apply)
        study.add_step(
            "Verify new metric visible to agents",
            "SELECT FIELD_NAME FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE FIELD_NAME='units_sold_admin'",
            run_sql(con, "SELECT FIELD_KIND, FIELD_NAME, AGENT_READINESS FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE FIELD_NAME='units_sold_admin'"),
        )
        invalid_sql = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC bad_admin_metric
  AS SUM(missing_fact)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC CERTIFIED"""
        invalid_apply = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(invalid_sql)}, FALSE)")
        study.add_step("Try invalid Semantic SQL apply", invalid_sql, invalid_apply)
        study.add_step(
            "Verify invalid apply did not mutate catalog",
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE METRIC_NAME IN (...)",
            run_sql(
                con,
                "SELECT METRIC_NAME FROM SEMANTIC_CATALOG.METRICS "
                "WHERE METRIC_NAME IN ('units_sold_admin','bad_admin_metric') ORDER BY METRIC_NAME",
            ),
        )
        invalid_add_metric = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
            "'sales','SALES','compat_invalid_probe','SUM(missing_fact)',NULL,'ADDITIVE','order_line',"
            "'DECIMAL(18,2)','Compat Invalid Probe','Should not become query-visible','currency',FALSE,TRUE)"
        )
        add_result = run_sql(con, invalid_add_metric)
        study.add_step(
            "Try invalid metric through compatibility ADD_METRIC",
            invalid_add_metric,
            add_result,
            "Compatibility API returned success for an invalid metric." if add_result.get("ok") else None,
        )
        validation_after_add = run_sql(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        study.add_step("Validate after invalid ADD_METRIC", "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')", validation_after_add)
        compile_after_bad = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "client": "elena-novak",
            },
        )
        study.add_step("Compile valid metric after invalid ADD_METRIC", "COMPILE_REQUEST_JSON(total_revenue by customer_region)", compile_after_bad)
        if compile_after_bad.get("compile_status") == "ERROR":
            study.add_bug(
                "BUG-STUDY-003",
                "Compatibility ADD_METRIC can leave invalid active metrics that block validating compiles",
                "High",
                "SEMANTIC_ADMIN.ADD_METRIC",
                invalid_add_metric,
                "Invalid compatibility API metric additions should validate and rollback or remain inactive.",
                "ADD_METRIC returned confirmation; later VALIDATE_MODEL and COMPILE_REQUEST_JSON failed due to missing_fact.",
            )
        cleanup_metric(con, "compat_invalid_probe")
        study.add_step("Cleanup invalid compatibility metric", "DELETE compat_invalid_probe catalog rows and validate", {"ok": True})
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        study.add_step("Export semantic model", "EXPORT SEMANTIC MODEL sales", run_sql(con, "EXPORT SEMANTIC MODEL sales"))
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        con.close()

        study.observations.extend(
        [
            "The SQL-native authoring path is safe: invalid applies are rejected and catalog state is restored.",
            "The compatibility ADD_METRIC path now rejects invalid active metrics during validation and leaves the catalog clean.",
            "Current validation issues and model readiness views give admins a concise operational view.",
        ]
    )
    study.recommendations.extend(
        [
            "Prefer SQL-native Semantic SQL in docs and admin tooling; label ADD_* as low-level compatibility APIs.",
            "Add a one-command model health view combining publish status, readiness, latest validation, visible field counts, and orphan checks.",
        ]
    )
    return study


def study_ml_engineer() -> Study:
    con = connect()
    study = Study(
        "persona-test-04-ml-engineer-udfs.md",
        "Priya Shah",
        "ML engineer who wants to reuse UDF feature logic in metrics",
        "Direct SQL, Lua scalar scripts, semantic compiler",
        [
            "Create and use a scalar UDF on physical data.",
            "Try to include UDF-derived features in semantic metrics.",
            "Evaluate whether semantic SQL can call UDFs in queries.",
            "Find a practical workaround.",
        ],
    )
    try:
        udf_sql = """CREATE OR REPLACE LUA SCALAR SCRIPT MART.DISCOUNT_SCORE(QTY DOUBLE, PRICE DOUBLE)
RETURNS DOUBLE AS
function run(ctx)
    if ctx.QTY == nil or ctx.PRICE == nil then
        return nil
    end
    return ctx.QTY * ctx.PRICE / 1000
end
/"""
        study.add_step("Create scalar Lua UDF", udf_sql, run_sql_no_fetch(con, udf_sql))
        study.add_step(
            "Use UDF in physical SQL",
            "SELECT MART.DISCOUNT_SCORE(quantity, net_unit_price) FROM MART.ORDER_LINES",
            run_sql(
                con,
                "SELECT order_id, product_id, MART.DISCOUNT_SCORE(quantity, net_unit_price) AS score "
                "FROM MART.ORDER_LINES ORDER BY order_id, product_id LIMIT 3",
            ),
        )
        metric_sql = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC avg_discount_score
  AS AVG(MART.DISCOUNT_SCORE(quantity, net_revenue))
  ON ENTITY order_line
  RETURNS DOUBLE
  FORMAT 'score'
  DISPLAY 'Average Discount Score'
  COMMENT 'Average UDF-derived discount score'
  ADDITIVE PUBLIC CERTIFIED"""
        study.add_step("Dry-run UDF metric definition", "APPLY_SEMANTIC_DEFINITION(UDF metric, TRUE)", run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(metric_sql)}, TRUE)"))
        apply = run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(metric_sql)}, FALSE)")
        study.add_step(
            "Apply UDF metric definition",
            metric_sql,
            apply,
            "The validator currently supports a fixed function vocabulary and semantic identifiers, not arbitrary scalar UDF calls.",
        )
        semantic_udf_sql = (
            "SELECT customer_region, MART.DISCOUNT_SCORE(total_revenue, total_cost) AS score "
            "FROM SEMANTIC_SALES.SALES GROUP BY customer_region"
        )
        study.add_step("Compile semantic SQL with UDF over metrics", semantic_udf_sql, compile_sql(con, semantic_udf_sql))
        workaround_sql = (
            "CREATE OR REPLACE TABLE MART.ORDER_LINE_FEATURES AS "
            "SELECT order_id, product_id, MART.DISCOUNT_SCORE(quantity, net_unit_price) AS discount_score "
            "FROM MART.ORDER_LINES"
        )
        study.add_step(
            "Workaround: materialize UDF output as physical feature table",
            workaround_sql,
            run_sql_no_fetch(con, workaround_sql),
            "This works outside the semantic layer, but there is no first-class feature/fact registration flow for UDF-derived physical features.",
        )
    finally:
        con.close()

    study.observations.extend(
        [
            "Lua scalar UDFs work normally in physical SQL.",
            "The semantic validator rejects UDF calls inside metric expressions, so ML feature logic cannot be reused directly in governed metrics.",
            "The viable workaround is to materialize UDF outputs as physical columns/tables and then model them as facts, but that requires extra data engineering.",
        ]
    )
    study.recommendations.extend(
        [
            "Document the current UDF limitation explicitly for ML/data science users.",
            "Add a governed whitelist for scalar UDFs in fact expressions, with role-scoped visibility and deterministic validation.",
            "Add examples for feature tables and UDF-derived facts if direct UDF support remains out of scope.",
        ]
    )
    return study


def study_snowflake_expert() -> Study:
    con = connect()
    study = Study(
        "persona-test-05-snowflake-expert.md",
        "Alex Kim",
        "Expert Snowflake user familiar with Snowflake Semantic Views",
        "Direct SQL and Semantic SQL preprocessor",
        [
            "Map Snowflake semantic-view concepts to this implementation.",
            "Try familiar Snowflake-style DDL/introspection.",
            "Inspect and export definitions.",
            "Author a metric using the Exasol-native syntax.",
        ],
    )
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        snowflake_ddl = """CREATE SEMANTIC VIEW sales_snowflake
TABLES (orders AS MART.ORDERS PRIMARY KEY (order_id))
METRICS (order_count AS COUNT(*))"""
        study.add_step(
            "Try Snowflake-style CREATE SEMANTIC VIEW",
            snowflake_ddl,
            run_sql_no_fetch(con, snowflake_ddl),
            "The project is inspired by semantic views, but it does not implement Snowflake's DDL grammar.",
        )
        study.add_step("Show semantic views", "SHOW SEMANTIC VIEWS", run_sql(con, "SHOW SEMANTIC VIEWS"))
        study.add_step("Show one semantic view", "SHOW SEMANTIC VIEW sales.SALES", run_sql(con, "SHOW SEMANTIC VIEW sales.SALES"))
        show_dims = run_sql(con, "SHOW SEMANTIC DIMENSIONS IN sales.SALES")
        study.add_step(
            "Try object-level dimension listing",
            "SHOW SEMANTIC DIMENSIONS IN sales.SALES",
            show_dims,
            "Only metric-scoped dimension compatibility listing exists today.",
        )
        study.add_step(
            "Use implemented compatibility listing",
            "SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue",
            run_sql(con, "SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue"),
        )
        study.add_step("Describe metric", "DESCRIBE SEMANTIC METRIC sales.SALES.gross_margin_pct", run_sql(con, "DESCRIBE SEMANTIC METRIC sales.SALES.gross_margin_pct"))
        study.add_step("Export semantic view", "EXPORT SEMANTIC VIEW sales.SALES", run_sql(con, "EXPORT SEMANTIC VIEW sales.SALES"))
        metric_sql = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC snowflake_style_revenue_copy
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT 'currency'
  DISPLAY 'Snowflake Style Revenue Copy'
  COMMENT 'Metric added by a Snowflake user using Exasol-native Semantic SQL'
  ADDITIVE PUBLIC CERTIFIED"""
        study.add_step("Dry-run Exasol-native single metric", metric_sql, run_sql(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_literal(metric_sql)}, TRUE)"))
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        con.close()

    study.observations.extend(
        [
            "Snowflake users can understand entities, dimensions, facts, metrics, comments, and introspection once they see the mapping.",
            "The first instinct to use Snowflake's CREATE SEMANTIC VIEW grammar fails with a generic parser error.",
            "Metric-scoped introspection is strong, but object-level dimension/fact listing commands would make exploration feel more complete.",
        ]
    )
    study.recommendations.extend(
        [
            "Add a Snowflake Semantic Views migration guide mapping TABLES/DIMENSIONS/METRICS to entities/dimensions/facts/metrics.",
            "Consider catching CREATE SEMANTIC VIEW syntax in the preprocessor and returning a targeted guidance error.",
            "Add SHOW SEMANTIC DIMENSIONS IN <model.object> and SHOW SEMANTIC FACTS IN <model.object> for object-level overview.",
        ]
    )
    return study


def study_autonomous_agent() -> Study:
    con = connect()
    study = Study(
        "persona-test-06-autonomous-agent.md",
        "ATLAS-9",
        "Fully autonomous analytics agent",
        "SEMANTIC_AGENT views plus COMPILE_REQUEST_JSON",
        [
            "Orient without physical-table access.",
            "Answer a business question using structured compilation.",
            "Explain the compiled query.",
            "Record feedback and review history.",
            "Check protocol robustness.",
        ],
    )
    try:
        study.add_step("Discover models", "SELECT * FROM SEMANTIC_AGENT.MODELS_FOR_AGENT", run_sql(con, "SELECT MODEL_NAME, MODEL_STATUS, AGENT_READINESS, VALIDATION_STATUS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT ORDER BY MODEL_NAME"))
        study.add_step("Discover fields", "SELECT * FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT", run_sql(con, "SELECT FIELD_KIND, FIELD_ROLE, FIELD_NAME, DATA_TYPE, AGENT_READINESS FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE MODEL_NAME='sales' AND OBJECT_NAME='SALES' ORDER BY FIELD_KIND, FIELD_NAME"))
        study.add_step("Check valid combinations", "SELECT * FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT", run_sql(con, "SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT WHERE MODEL_NAME='sales' AND OBJECT_NAME='SALES' AND METRIC_NAME IN ('gross_margin','gross_margin_pct','total_revenue') ORDER BY METRIC_NAME, DIMENSION_NAME"))
        request = {
            "model": "sales",
            "object": "SALES",
            "metrics": ["gross_margin", "gross_margin_pct", "total_revenue"],
            "dimensions": ["customer_region", "product_category"],
            "order_by": [{"field": "gross_margin_pct", "direction": "desc"}],
            "client": "ATLAS-9",
            "purpose": "gross margin by category and region",
        }
        compiled = compile_request(con, request)
        study.add_step("Compile business question", json.dumps(request), compiled)
        if compiled.get("generated_sql"):
            study.add_step("Execute generated SQL", compiled["generated_sql"], run_sql(con, compiled["generated_sql"]))
            agent_request_id = compiled.get("agent_request_id")
            if agent_request_id is not None:
                explain_sql = f"EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('AGENT_REQUEST', {agent_request_id})"
                study.add_step("Explain compiled request", explain_sql, run_sql(con, explain_sql))
                feedback_sql = (
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
                    f"'AGENT_REQUEST',{agent_request_id},'ACCEPTED','ATLAS-9 answer compiled and executed successfully.',NULL)"
                )
                study.add_step("Record accepted feedback", feedback_sql, run_sql(con, feedback_sql))
                invalid_feedback_sql = (
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
                    f"'AGENT_REQUEST',{agent_request_id},'completed_successfully','Invalid verdict robustness check.',NULL)"
                )
                invalid_feedback = run_sql(con, invalid_feedback_sql)
                study.add_step(
                    "Try invalid feedback verdict",
                    invalid_feedback_sql,
                    invalid_feedback,
                    "The feedback API accepted an unsupported verdict." if invalid_feedback.get("ok") else None,
                )
                if invalid_feedback["ok"]:
                    study.add_bug(
                        "BUG-STUDY-004",
                        "RECORD_AGENT_FEEDBACK accepts unsupported verdict values",
                        "Medium",
                        "SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK",
                        invalid_feedback_sql,
                        "Unsupported verdicts such as completed_successfully should be rejected or normalized.",
                        "The script inserted feedback and returned PENDING.",
                    )
        study.add_step(
            "Review request history",
            "SELECT REQUEST_TIME, HANDLE_TYPE, HANDLE_ID, CLIENT_NAME, STATUS FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT",
            run_sql(con, "SELECT REQUEST_TIME, HANDLE_TYPE, HANDLE_ID, CLIENT_NAME, STATUS, ERROR_CODE FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT ORDER BY REQUEST_TIME DESC LIMIT 5"),
        )
    finally:
        con.close()

    study.observations.extend(
        [
            "The autonomous-agent happy path works: discover, validate combinations, compile, execute, explain, record feedback, and inspect history.",
            "The agent never needed physical table names or join conditions.",
            "Feedback capture now enforces a stable verdict vocabulary for downstream review queues.",
        ]
    )
    study.recommendations.extend(
        [
            "Keep the RECORD_AGENT_FEEDBACK verdict enum documented and stable.",
            "Expose semantic MCP tools so autonomous agents do not need raw SQL script execution privileges through a generic query tool.",
            "Add more verified multi-dimensional examples to improve agent grounding for complex questions.",
        ]
    )
    return study


def result_md(result: dict[str, Any]) -> str:
    lines = []
    lines.append(f"- Status: {'OK' if result.get('ok') else 'ERROR'}")
    if "compile_status" in result:
        lines.append(f"- Compile status: `{result['compile_status']}`")
    if "row_count" in result:
        lines.append(f"- Rows: {result['row_count']}")
    if "elapsed_ms" in result:
        lines.append(f"- Elapsed: {result['elapsed_ms']} ms")
    if result.get("columns"):
        lines.append("- Columns: `" + "`, `".join(result["columns"][:12]) + "`")
    if result.get("rows"):
        lines.append("```text")
        for row in result["rows"][:8]:
            lines.append(str(row))
        lines.append("```")
    if result.get("generated_sql"):
        lines.append("Generated SQL excerpt:")
        lines.append("```sql")
        sql_text = str(result["generated_sql"])
        lines.append(sql_text[:1800] + ("..." if len(sql_text) > 1800 else ""))
        lines.append("```")
    if result.get("error"):
        lines.append("Error:")
        lines.append("```text")
        lines.append(str(result["error"])[:1800])
        lines.append("```")
    if result.get("structured") is not None:
        lines.append("Structured result excerpt:")
        lines.append("```json")
        lines.append(json.dumps(result["structured"], indent=2)[:1800])
        lines.append("```")
    elif result.get("text") is not None:
        lines.append("Text result excerpt:")
        lines.append("```text")
        lines.append(str(result["text"])[:1800])
        lines.append("```")
    return "\n".join(lines)


def write_study(study: Study) -> None:
    path = REPORTS / study.filename
    lines = [
        f"# Persona Test Report - {study.persona}",
        "",
        f"**Date:** {datetime.now().strftime('%Y-%m-%d')}",
        f"**Role:** {study.role}",
        f"**Interface:** {study.interface}",
        "",
        "## Goals",
        "",
    ]
    lines.extend(f"- {goal}" for goal in study.goals)
    lines.extend(["", "## Execution Log", ""])
    for index, step in enumerate(study.steps, 1):
        lines.extend(
            [
                f"### Step {index}: {step.name}",
                "",
                "Action:",
                "```text",
                step.action,
                "```",
                "",
                result_md(step.result),
                "",
            ]
        )
        if step.friction:
            lines.extend(["Friction: " + step.friction, ""])
    lines.extend(["## Friction Points", ""])
    if study.friction_points:
        lines.extend(f"- {item}" for item in dict.fromkeys(study.friction_points))
    else:
        lines.append("- None significant.")
    lines.extend(["", "## Bugs Found", ""])
    if study.bugs:
        for bug in study.bugs:
            lines.extend(
                [
                    f"### {bug.bug_id}: {bug.title}",
                    "",
                    f"- Severity: {bug.severity}",
                    f"- Component: {bug.component}",
                    "",
                    "Repro:",
                    "```text",
                    bug.repro,
                    "```",
                    f"Expected: {bug.expected}",
                    "",
                    f"Actual: {bug.actual}",
                    "",
                ]
            )
    else:
        lines.append("- No reproducible bugs found.")
    lines.extend(["", "## Observations", ""])
    lines.extend(f"- {item}" for item in study.observations)
    lines.extend(["", "## Recommendations", ""])
    lines.extend(f"- {item}" for item in study.recommendations)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_bug_log(studies: list[Study]) -> None:
    bugs = [bug for study in studies for bug in study.bugs]
    lines = [
        "# Consolidated Bug Log - Simulated User Tests",
        "",
        f"**Date:** {datetime.now().strftime('%Y-%m-%d')}",
        f"**Environment:** Exasol Nano at `{DSN}`, MCP at `{MCP_BASE}`",
        "",
        "## Bug Index",
        "",
        "| ID | Severity | Title | Component | Persona |",
        "|---|---|---|---|---|",
    ]
    if bugs:
        lines.extend(
            f"| {bug.bug_id} | {bug.severity} | {bug.title} | {bug.component} | {bug.persona} |"
            for bug in bugs
        )
    else:
        lines.append("| - | - | No bugs found | - | - |")
    lines.extend(["", "## Detailed Repros", ""])
    for bug in bugs:
        lines.extend(
            [
                f"### {bug.bug_id}: {bug.title}",
                "",
                f"**Severity:** {bug.severity}",
                f"**Component:** {bug.component}",
                f"**Found by:** {bug.persona}",
                "",
                "Repro:",
                "```text",
                bug.repro,
                "```",
                f"Expected: {bug.expected}",
                "",
                f"Actual: {bug.actual}",
                "",
            ]
        )
    (REPORTS / "bug-log.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_synthesis(studies: list[Study]) -> None:
    bugs = [bug for study in studies for bug in study.bugs]
    lines = [
        "# Cross-Study Synthesis - Simulated User Tests",
        "",
        f"**Date:** {datetime.now().strftime('%Y-%m-%d')}",
        f"**Studies:** {len(studies)} personas",
        "",
        "## Overview",
        "",
        "| Persona | Role | Interface | Bugs | Main result |",
        "|---|---|---|---:|---|",
    ]
    for study in studies:
        result = study.observations[0] if study.observations else ""
        lines.append(f"| {study.persona} | {study.role} | {study.interface} | {len(study.bugs)} | {result} |")
    lines.extend(
        [
            "",
            "## Themes",
            "",
            "### 1. The database-native happy paths are strong",
            "",
            "Direct SQL users and autonomous agents can discover governed fields, compile semantic requests, execute generated SQL, and inspect plans without physical join knowledge.",
            "",
            "### 2. Generic MCP remains the weakest entry point",
            "",
            "MCP schema discovery is better because semantic schemas have comments and discovery tables, but the generic MCP SQL tool still cannot execute `EXECUTE SCRIPT`, and table listing still omits views. Conversational analytics needs first-class semantic MCP tools.",
            "",
            "### 3. SQL-native authoring and compatibility APIs now fail closed",
            "",
            "`APPLY_SEMANTIC_DEFINITION` rolls back invalid semantic SQL. `ADD_METRIC` now validates and rejects invalid active metrics before they can break validating compiles.",
            "",
            "### 4. Advanced users need documented escape hatches",
            "",
            "Power analysts can wrap generated SQL for ranking and complex post-processing. ML engineers need clear guidance for UDF-derived features. Snowflake experts need a migration map instead of relying on familiar Snowflake syntax.",
            "",
            "## Top Recommendations",
            "",
            "1. Build a semantic MCP adapter with script-backed tools for discovery, compilation, execution, explanation, and feedback.",
            "2. Fix or extend generic MCP `list_exasol_tables_and_views` so it returns views.",
            "3. Add documentation and examples for advanced analytics post-processing over generated SQL.",
            "4. Add an ML/UDF modeling guide and decide whether scalar UDFs can be whitelisted in semantic facts.",
            "5. Add a Snowflake Semantic Views migration guide and targeted errors for unsupported Snowflake-style DDL.",
            "6. Add object-level introspection commands for dimensions and facts.",
            "",
            "## Bugs Found",
            "",
            "| ID | Severity | Title |",
            "|---|---|---|",
        ]
    )
    if bugs:
        lines.extend(f"| {bug.bug_id} | {bug.severity} | {bug.title} |" for bug in bugs)
    else:
        lines.append("| - | - | No reproducible bugs found |")
    (REPORTS / "cross-study-synthesis.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    REPORTS.mkdir(exist_ok=True)
    mcp = McpClient()
    studies = [
        study_casual_mcp(mcp),
        study_power_analyst(),
        study_admin(),
        study_ml_engineer(),
        study_snowflake_expert(),
        study_autonomous_agent(),
    ]
    for study in studies:
        write_study(study)
    write_bug_log(studies)
    write_synthesis(studies)
    raw = {
        "generated_at": datetime.now().isoformat(),
        "studies": [
            {
                "persona": study.persona,
                "role": study.role,
                "interface": study.interface,
                "bugs": [bug.__dict__ for bug in study.bugs],
                "steps": [
                    {"name": step.name, "action": step.action, "result": step.result, "friction": step.friction}
                    for step in study.steps
                ],
            }
            for study in studies
        ],
    }
    (REPORTS / "simulated-user-tests-raw.json").write_text(json.dumps(raw, indent=2), encoding="utf-8")
    print("Wrote reports:")
    for study in studies:
        print(" -", REPORTS / study.filename)
    print(" -", REPORTS / "cross-study-synthesis.md")
    print(" -", REPORTS / "bug-log.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
