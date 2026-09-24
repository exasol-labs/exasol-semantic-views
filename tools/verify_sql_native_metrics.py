#!/usr/bin/env python3
"""Verify SQL-native metric definition and introspection flows on Exasol."""

from __future__ import annotations

import json
import os
import re
import ssl
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


SEMANTIC_DEFINITION = """ALTER SEMANTIC VIEW sales.SALES
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
    PUBLIC CERTIFIED,

  FACT quantity
    ON ENTITY order_line
    AS ol.quantity
    RETURNS DECIMAL(18,0)
    ADDITIVE
    DISPLAY 'Quantity'
    COMMENT 'Number of units on the order line'
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
    COMMENT 'Cost recognized for sold units'
    ADDITIVE PUBLIC CERTIFIED,

  METRIC gross_margin
    AS total_revenue - total_cost
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Gross Margin'
    COMMENT 'Total revenue minus total cost'
    DERIVED PUBLIC CERTIFIED,

  METRIC gross_margin_pct
    AS gross_margin / NULLIF(total_revenue, 0)
    ON ENTITY order_line
    RETURNS DECIMAL(18,6)
    FORMAT 'percentage'
    DISPLAY 'Gross Margin %'
    COMMENT 'Gross margin as a percentage of revenue'
    RATIO PUBLIC CERTIFIED,

  METRIC completed_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FILTER (WHERE order_status = 'COMPLETE')
    FORMAT 'currency'
    DISPLAY 'Completed Revenue'
    COMMENT 'Net revenue for completed orders only'
    ADDITIVE PUBLIC CERTIFIED
)"""


ADD_OR_REPLACE_TOTAL_REVENUE = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT 'currency'
  DISPLAY 'Total Revenue'
  COMMENT 'Net recognized revenue excluding tax'
  SYNONYMS ('revenue', 'sales')
  ADDITIVE PUBLIC CERTIFIED"""


INVALID_RATIO = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC bad_ratio
  AS total_revenue / 10
  ON ENTITY order_line
  RETURNS DECIMAL(18,6)
  RATIO PUBLIC"""


INLINE_AGGREGATE_RATIO = """ALTER SEMANTIC VIEW sales.SALES
REPLACE METRICS (
  METRIC avg_line_value
    AS SUM(net_revenue) / SUM(quantity)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Average Line Value'
    RATIO PUBLIC CERTIFIED
)"""


COMPOUND_AGGREGATE_METRIC = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC avg_order_value_probe
  AS SUM(net_revenue) / NULLIF(COUNT(DISTINCT ol.order_id), 0)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC"""


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    host = os.environ.get("EXASOL_HOST", "localhost")
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"{host}:{port}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def fetchall(con, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def scalar(con, sql: str) -> Any:
    rows = fetchall(con, sql)
    return rows[0][0]


def cleanup_metrics(con, metric_names: list[str]) -> None:
    quoted = ", ".join(sql_string(name) for name in metric_names)
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID IN ("
        "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME IN (" + quoted + "))"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID IN ("
        "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME IN (" + quoted + "))"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES WHERE METRIC_ID IN ("
        "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME IN (" + quoted + "))"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_KIND = 'METRIC' "
        "AND COLUMN_NAME IN (" + quoted + ")"
    )
    con.execute("DELETE FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME IN (" + quoted + ")")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")


def cleanup_dimensions(con, dimension_names: list[str]) -> None:
    """Remove probe dimensions so this file re-runs against a dirty model."""
    quoted = ", ".join(sql_string(name) for name in dimension_names)
    con.execute(
        "DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_TYPE = 'DIMENSION' "
        "AND ATTRIBUTE_ID IN (SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS "
        "WHERE DIMENSION_NAME IN (" + quoted + "))"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES WHERE ATTRIBUTE_TYPE = 'DIMENSION' "
        "AND ATTRIBUTE_ID IN (SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS "
        "WHERE DIMENSION_NAME IN (" + quoted + "))"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_KIND = 'DIMENSION' "
        "AND COLUMN_NAME IN (" + quoted + ")"
    )
    con.execute("DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE DIMENSION_NAME IN (" + quoted + ")")


def apply_definition(con, definition_sql: str, dry_run: bool) -> dict[str, Any]:
    rows = fetchall(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{sql_string(definition_sql)}, {'TRUE' if dry_run else 'FALSE'})",
    )
    if len(rows) != 1:
        raise AssertionError(f"expected one apply row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "message": row[2],
        "normalized_json": row[3],
        "operation_count": row[4],
        "validation_run_id": row[5],
    }


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})")
    if len(rows) != 1:
        raise AssertionError(f"expected one compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "original_sql": row[3],
        "generated_sql": row[4],
        "plan_json": row[5],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def assert_fails_with(con, name: str, sql: str, expected: str) -> None:
    try:
        con.execute(sql).fetchall()
    except Exception as exc:
        assert_contains(name, str(exc), expected)
        return
    raise AssertionError(f"{name}: expected failure containing {expected!r}")


def assert_status_ok(name: str, result: dict[str, Any]) -> None:
    if result["status"] != "OK":
        raise AssertionError(f"{name}: expected OK, got {result}")
    print(f"ok {name}: OK")


def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

        assert_equal(
            "sql native scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                "AND SCRIPT_NAME IN ("
                "'SEMANTIC_DEFINITION_RUNTIME', 'APPLY_SEMANTIC_DEFINITION', "
                "'APPLY_SEMANTIC_DEFINITION_OR_FAIL', "
                "'DESCRIBE_SEMANTIC_METRIC', 'EXPLAIN_SEMANTIC_METRIC', "
                "'EXPORT_SEMANTIC_DEFINITION', 'ENABLE_SEMANTIC_SQL', 'DISABLE_SEMANTIC_SQL')",
            ),
            8,
        )

        dry_run = apply_definition(con, SEMANTIC_DEFINITION, True)
        assert_equal("dry run status", dry_run["status"], "DRY_RUN")
        assert_equal("dry run operation count", int(dry_run["operation_count"]), 8)
        assert_contains("dry run normalized semantic filter", dry_run["normalized_json"], '"semantic_filter_expr":"order_status =')

        compound_dry_run = apply_definition(con, COMPOUND_AGGREGATE_METRIC, True)
        assert_equal("single metric dry run status", compound_dry_run["status"], "DRY_RUN")
        compound_json = json.loads(compound_dry_run["normalized_json"])
        assert_equal("compound aggregate function", compound_json["metrics"][0]["aggregation_function"], "SUM")
        assert_equal("compound aggregate measure expr", compound_json["metrics"][0]["measure_expr"], "net_revenue")

        applied = apply_definition(con, SEMANTIC_DEFINITION, False)
        assert_status_ok("semantic definition apply", applied)
        reapplied = apply_definition(con, SEMANTIC_DEFINITION, False)
        assert_status_ok("semantic definition idempotent apply", reapplied)

        inline_ratio = apply_definition(con, INLINE_AGGREGATE_RATIO, False)
        assert_status_ok("inline aggregate ratio apply", inline_ratio)
        assert_equal(
            "inline aggregate ratio lineage",
            fetchall(
                con,
                "SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_NAME "
                "FROM SEMANTIC_CATALOG.METRIC_LINEAGE "
                "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'avg_line_value' "
                "ORDER BY ORDINAL_POSITION",
            ),
            [("NUMERATOR", "FACT", "net_revenue"), ("DENOMINATOR", "FACT", "quantity")],
        )
        cleanup_metrics(con, ["avg_line_value"])
        restored = apply_definition(con, SEMANTIC_DEFINITION, False)
        assert_status_ok("restore semantic definition after inline ratio", restored)

        assert_equal(
            "object fact and metric columns",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.OBJECT_COLUMNS "
                "WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES' "
                "AND COLUMN_KIND IN ('FACT', 'METRIC')",
            ),
            8,
        )
        assert_equal(
            "completed semantic filter",
            fetchall(
                con,
                "SELECT METRIC_KIND, SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR "
                "FROM SEMANTIC_CATALOG.METRICS "
                "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'completed_revenue'",
            ),
            [("FILTERED", "order_status = 'COMPLETE'", "o.order_status = 'COMPLETE'")],
        )
        assert_equal(
            "metric filter dimension",
            fetchall(
                con,
                "SELECT FILTER_KIND, REQUIRED_DIMENSION_NAME "
                "FROM SEMANTIC_CATALOG.METRIC_FILTER_OVERVIEW "
                "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'completed_revenue'",
            ),
            [("SEMANTIC_SQL", "order_status")],
        )
        assert_equal(
            "ratio lineage roles",
            fetchall(
                con,
                "SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_NAME "
                "FROM SEMANTIC_CATALOG.METRIC_LINEAGE "
                "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'gross_margin_pct' "
                "ORDER BY ORDINAL_POSITION",
            ),
            [("NUMERATOR", "METRIC", "gross_margin"), ("DENOMINATOR", "METRIC", "total_revenue")],
        )

        compiled = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["completed_revenue"],
                "dimensions": ["customer_region"],
                "client": "verify_sql_native_metrics",
            },
        )
        assert_status_ok("compiled semantic-filtered metric", compiled)
        assert_contains("compiled semantic filter SQL", compiled["generated_sql"], "o.order_status = 'COMPLETE'")

        ratio = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["gross_margin_pct"],
                "dimensions": ["customer_region"],
                "client": "verify_sql_native_metrics",
            },
        )
        assert_status_ok("compiled ratio metric", ratio)
        plan = json.loads(ratio["plan_json"])
        assert_equal("plan metric kind", plan["metric_details"][0]["metric_kind"], "RATIO")
        assert_equal(
            "plan ratio roles",
            [item["role"] for item in plan["metric_details"][0]["input_roles"]],
            ["NUMERATOR", "DENOMINATOR"],
        )

        invalid = apply_definition(con, INVALID_RATIO, False)
        assert_equal("invalid ratio status", invalid["status"], "ERROR")
        assert_equal("invalid ratio error", invalid["error_code"], "SEMANTIC_DDL_070")
        assert_equal(
            "invalid ratio did not mutate catalog",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'bad_ratio'"),
            0,
        )

        invalid_definition = """ALTER SEMANTIC VIEW sales.SALES
REPLACE METRICS (
  METRIC bad_replaced_metric
    AS SUM(missing_fact)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Bad Replaced Metric'
    COMMENT 'Should be rejected atomically'
    ADDITIVE PUBLIC CERTIFIED
)"""
        metric_count_before_dry_run = scalar(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales'",
        )
        invalid_dry_run = apply_definition(con, invalid_definition, True)
        assert_equal("invalid dry run status", invalid_dry_run["status"], "ERROR")
        assert_equal("invalid dry run error", invalid_dry_run["error_code"], "SEMANTIC_DDL_090")
        assert_contains(
            "invalid dry run identifies rule and field",
            invalid_dry_run["message"],
            "SEMANTIC_MODEL_011 [METRIC bad_replaced_metric]",
        )
        assert_equal(
            "invalid dry run restored catalog",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales'"),
            metric_count_before_dry_run,
        )

        invalid_validation = apply_definition(con, invalid_definition, False)
        assert_equal("invalid validation apply status", invalid_validation["status"], "ERROR")
        assert_equal("invalid validation apply error", invalid_validation["error_code"], "SEMANTIC_DDL_090")
        assert_contains(
            "invalid validation identifies rule and field",
            invalid_validation["message"],
            "SEMANTIC_MODEL_011 [METRIC bad_replaced_metric]",
        )
        assert_equal(
            "invalid validation restored metrics",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.OBJECT_COLUMNS "
                "WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES' "
                "AND COLUMN_KIND = 'METRIC'",
            ),
            5,
        )
        assert_equal(
            "invalid validation no bad metric",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'bad_replaced_metric'"),
            0,
        )

        synonym_handoff = SEMANTIC_DEFINITION.replace(
            "    SYNONYMS ('revenue', 'sales')\n", "", 1
        ).replace(
            "    COMMENT 'Net revenue for completed orders only'\n",
            "    COMMENT 'Net revenue for completed orders only'\n"
            "    SYNONYMS ('revenue', 'sales')\n",
            1,
        )
        assert_equal(
            "replace metrics synonym handoff",
            apply_definition(con, synonym_handoff, False)["status"],
            "OK",
        )
        assert_equal(
            "synonym moved to target metric",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.SYNONYMS s "
                "JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = s.OBJECT_ID "
                "WHERE s.OBJECT_TYPE = 'METRIC' "
                "AND mt.METRIC_NAME = 'completed_revenue' "
                "AND UPPER(s.SYNONYM) = 'REVENUE'",
            ),
            1,
        )
        assert_equal(
            "restore original synonym owner",
            apply_definition(con, SEMANTIC_DEFINITION, False)["status"],
            "OK",
        )

        duplicate_synonym = SEMANTIC_DEFINITION.replace(
            "    COMMENT 'Net revenue for completed orders only'\n",
            "    COMMENT 'Net revenue for completed orders only'\n"
            "    SYNONYMS ('revenue')\n",
            1,
        )
        duplicate_result = apply_definition(con, duplicate_synonym, False)
        assert_equal("duplicate synonym rejected", duplicate_result["status"], "ERROR")
        assert_equal("duplicate synonym error", duplicate_result["error_code"], "SEMANTIC_DDL_090")
        assert_contains(
            "duplicate synonym identifies rule and field",
            duplicate_result["message"],
            "SEMANTIC_MODEL_021 [SYNONYM REVENUE]",
        )

        assert_fails_with(
            con,
            "add metric invalid validation rollback",
            """EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales', 'SALES', 'invalid_metric_probe',
  'SUM(missing_fact)', NULL, 'ADDITIVE', 'order_line', 'DECIMAL(18,2)',
  'Invalid Metric Probe', 'Invalid metric for regression testing',
  'currency', FALSE, TRUE
)""",
            "SEMANTIC_ADMIN_090",
        )
        validation_rows = fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        assert_equal("invalid add metric no validation errors", len(validation_rows), 0)
        assert_equal(
            "invalid add metric no orphan metric",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'invalid_metric_probe'"),
            0,
        )
        assert_equal(
            "invalid add metric no orphan object column",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.OBJECT_COLUMNS "
                "WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES' "
                "AND COLUMN_KIND = 'METRIC' AND COLUMN_NAME = 'invalid_metric_probe'",
            ),
            0,
        )

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        try:
            assert_fails_with(
                con,
                "preprocessed semantic DDL surfaces apply errors",
                INVALID_RATIO,
                "SEMANTIC_DDL_070",
            )
            assert_equal(
                "preprocessor works after rejected add metric",
                len(fetchall(
                    con,
                    "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES "
                    "GROUP BY customer_region",
                )),
                3,
            )
        finally:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

        assert_fails_with(
            con,
            "add metric duplicate object column preflight",
            """EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales', 'SALES', 'customer_region',
  'SUM(net_revenue)', NULL, 'ADDITIVE', 'order_line', 'DECIMAL(18,2)',
  'Customer Region Collision', 'Should fail before insert',
  'currency', FALSE, TRUE
)""",
            "SEMANTIC_ADMIN_018",
        )
        assert_equal(
            "add metric duplicate did not orphan metric",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS WHERE METRIC_NAME = 'customer_region'"),
            0,
        )

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        try:
            con.execute(ADD_OR_REPLACE_TOTAL_REVENUE)
            wildcard_rows = fetchall(con, "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")
            assert_equal("semantic select star returns one row", len(wildcard_rows), 1)
            singular_show = fetchall(con, "SHOW SEMANTIC VIEW sales.SALES")
            assert_contains("show semantic view singular", repr(singular_show), "total_revenue")
            dynamic_filter = fetchall(
                con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL("
                + sql_string(
                    "SELECT order_month, total_revenue FROM SEMANTIC_SALES.SALES "
                    "WHERE order_month = ADD_MONTHS(TRUNC(CURRENT_DATE, 'MM'), -1) "
                    "GROUP BY order_month"
                )
                + ")",
            )
            assert_equal("semantic sql dynamic filter status", dynamic_filter[0][0], "OK")
            assert_contains("semantic sql dynamic filter SQL", dynamic_filter[0][4], "ADD_MONTHS")
            lower_filter = compile_request(
                con,
                {
                    "model": "sales",
                    "object": "SALES",
                    "metrics": ["total_revenue"],
                    "dimensions": ["order_status"],
                    "filters": [{"field": "order_status", "op": "=", "value": "complete"}],
                },
            )
            assert_status_ok("case-insensitive string filter compile", lower_filter)
            assert_contains("case-insensitive string filter SQL", lower_filter["generated_sql"], "UPPER(o.order_status)")
            assert_equal(
                "case-insensitive string filter rows",
                scalar(con, "SELECT COUNT(*) FROM (" + lower_filter["generated_sql"] + ")"),
                1,
            )
            assert_equal(
                "show semantic metrics",
                fetchall(con, "SHOW SEMANTIC METRICS IN sales.SALES LIKE 'revenue'"),
                [
                    (
                        "completed_revenue",
                        "Completed Revenue",
                        "FILTERED",
                        "order_line",
                        "currency",
                        True,
                        False,
                        None,
                        "Net revenue for completed orders only",
                        None,
                    ),
                    (
                        "total_revenue",
                        "Total Revenue",
                        "SIMPLE",
                        "order_line",
                        "currency",
                        True,
                        False,
                        None,
                        "Net recognized revenue excluding tax",
                        "revenue, sales",
                    ),
                ],
            )
            describe = fetchall(con, "DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue")
            assert_contains("describe metric", repr(describe), "Total Revenue")
            explain = fetchall(con, "EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct")
            assert_contains("explain metric lineage", repr(explain), "NUMERATOR:METRIC")
            dimensions = fetchall(con, "SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue")
            assert_contains("show compatible dimensions", repr(dimensions), "customer_region")
            # BUG-24: the view named for compatible dimensions returned every
            # pair, including the fan-out pairs COMPILE_SQL refuses. It is now
            # filtered; the unfiltered pairs and reasons have their own view.
            assert_equal(
                "compatible dimensions exclude refused pairs",
                fetchall(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS "
                              "WHERE IS_VALID = FALSE")[0][0],
                0,
            )
            assert_equal(
                "compatibility view keeps refused pairs",
                fetchall(con, "SELECT REASON_CODE FROM SEMANTIC_CATALOG.METRIC_DIMENSION_COMPATIBILITY "
                              "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'total_freight' "
                              "AND DIMENSION_NAME = 'product_category'"),
                [("ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED",)],
            )
            shown_all = fetchall(con, "SHOW ALL SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue")
            assert_equal("show all includes every shown dimension",
                         {row[0] for row in dimensions} <= {row[0] for row in shown_all}, True)
            exported = fetchall(con, "EXPORT SEMANTIC METRIC sales.SALES.total_revenue")
            assert_equal("export metric kind", exported[0][0], "METRIC")
            exported_dry_run = apply_definition(con, exported[0][2], True)
            assert_equal("exported metric dry run", exported_dry_run["status"], "DRY_RUN")
            assert_equal("export semantic view rows", len(fetchall(con, "EXPORT SEMANTIC VIEW sales.SALES")), 9)
            # 19 for SALES + freight_amount, total_freight, ship_mode, customer_segment.
            assert_equal("export semantic model rows", len(fetchall(con, "EXPORT SEMANTIC MODEL sales")), 23)
            dimension_filter = fetchall(
                con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'DIMENSION')",
            )
            assert_equal("export semantic dimensions rows", len(dimension_filter), 4)
            assert_equal("export semantic dimensions kind", {row[0] for row in dimension_filter}, {"DIMENSION"})
        finally:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

        original_metric_id = scalar(
            con,
            "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS "
            "WHERE METRIC_NAME = 'total_revenue' AND STATUS = 'ACTIVE'",
        )
        fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY("
            "'sales', 'SALES', 'rename_compatibility', 'Revenue before rename', "
            "'{\"model\":\"sales\",\"object\":\"SALES\",\"metrics\":[\"total_revenue\"]}', "
            "NULL, FALSE)",
        )
        rename_ddl = (
            "ALTER SEMANTIC VIEW sales.SALES "
            "RENAME METRIC total_revenue TO gross_merchandise_value"
        )
        assert_equal("rename metric dry run", apply_definition(con, rename_ddl, True)["status"], "DRY_RUN")
        assert_equal("rename metric apply", apply_definition(con, rename_ddl, False)["status"], "OK")
        assert_equal(
            "renamed metric validates with verified query using old synonym",
            len(fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")),
            0,
        )
        assert_equal(
            "rename preserves metric id",
            scalar(
                con,
                "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS "
                "WHERE METRIC_NAME = 'gross_merchandise_value' AND STATUS = 'ACTIVE'",
            ),
            original_metric_id,
        )
        assert_equal(
            "rename keeps old name synonym",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.SYNONYMS "
                "WHERE OBJECT_TYPE = 'METRIC' AND OBJECT_ID = " + str(original_metric_id)
                + " AND UPPER(SYNONYM) = 'TOTAL_REVENUE'",
            ),
            1,
        )
        assert_contains(
            "rename rewrites dependent expression",
            scalar(
                con,
                "SELECT EXPRESSION FROM SYS_SEMANTIC.METRICS "
                "WHERE METRIC_NAME = 'gross_margin_pct'",
            ),
            "gross_merchandise_value",
        )
        assert_status_ok(
            "old metric synonym remains compilable",
            compile_request(
                con,
                {"model": "sales", "object": "SALES", "metrics": ["total_revenue"]},
            ),
        )
        rename_back = (
            "ALTER SEMANTIC VIEW sales.SALES "
            "RENAME METRIC gross_merchandise_value TO total_revenue"
        )
        assert_equal("rename metric back", apply_definition(con, rename_back, False)["status"], "OK")

        # Each RENAME METRIC keeps the previous name as a synonym; the round-trip above
        # therefore accumulates 'gross_merchandise_value' on total_revenue. Reset the
        # synonym list to the canonical seed values so later smoke tests see clean state.
        reset_synonyms = (
            "ALTER SEMANTIC VIEW sales.SALES "
            "ADD OR REPLACE METRIC total_revenue "
            "  AS SUM(net_revenue) "
            "  ON ENTITY order_line "
            "  RETURNS DECIMAL(18,2) "
            "  FORMAT 'currency' "
            "  DISPLAY 'Total Revenue' "
            "  COMMENT 'Net recognized revenue excluding tax' "
            "  SYNONYMS ('revenue', 'sales') "
            "  ADDITIVE PUBLIC CERTIFIED"
        )
        assert_status_ok("reset total_revenue synonyms", apply_definition(con, reset_synonyms, False))

        # ADD OR REPLACE FACT: adding one fact must not require restating every
        # fact in the object, which REPLACE FACTS does.
        facts_before = fetchall(
            con,
            "SELECT FACT_NAME FROM SEMANTIC_CATALOG.FACTS "
            "WHERE MODEL_NAME = 'sales' ORDER BY FACT_NAME",
        )
        add_fact_ddl = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE FACT gross_line_amount
  ON ENTITY order_line
  AS ol.quantity * ol.net_unit_price
  RETURNS DECIMAL(18,2)
  ADDITIVE
  DISPLAY 'Gross Line Amount'
  COMMENT 'Line amount before discounts'
  PUBLIC CERTIFIED"""
        assert_status_ok("add or replace fact", apply_definition(con, add_fact_ddl, False))
        facts_after = fetchall(
            con,
            "SELECT FACT_NAME FROM SEMANTIC_CATALOG.FACTS "
            "WHERE MODEL_NAME = 'sales' ORDER BY FACT_NAME",
        )
        assert_equal(
            "single fact upsert preserves the other facts",
            facts_after,
            sorted(facts_before + [("gross_line_amount",)]),
        )
        assert_equal(
            "fact registered as an object column",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.OBJECT_COLUMNS "
                "WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES' "
                "AND COLUMN_KIND = 'FACT' AND COLUMN_NAME = 'gross_line_amount'",
            ),
            1,
        )
        update_fact_ddl = add_fact_ddl.replace(
            "DISPLAY 'Gross Line Amount'", "DISPLAY 'Gross Line Amount v2'"
        )
        assert_status_ok("replace existing fact", apply_definition(con, update_fact_ddl, False))
        assert_equal(
            "fact display name updated in place",
            fetchall(
                con,
                "SELECT DISPLAY_NAME FROM SEMANTIC_CATALOG.FACTS "
                "WHERE MODEL_NAME = 'sales' AND FACT_NAME = 'gross_line_amount'",
            ),
            [("Gross Line Amount v2",)],
        )
        combined = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES "
            "ADD OR REPLACE FACT combo_probe ON ENTITY order_line AS ol.quantity "
            "RETURNS DECIMAL(18,0) PUBLIC "
            "ADD OR REPLACE METRIC combo_metric AS SUM(combo_probe) ON ENTITY order_line "
            "RETURNS DECIMAL(18,0) PUBLIC",
            False,
        )
        assert_equal("combined single forms rejected", combined["status"], "ERROR")
        assert_equal("combined single forms code", combined["error_code"], "SEMANTIC_DDL_037")

        # A fact-only REPLACE block is a valid statement on its own; it used to
        # be refused as SEMANTIC_DDL_012 despite being listed as accepted.
        facts_only = """ALTER SEMANTIC VIEW sales.ORDER_HEADER
REPLACE FACTS (
  FACT freight_amount
    ON ENTITY order
    AS o.freight_amount
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Freight Amount'
    COMMENT 'Freight charged on the order header'
    PUBLIC CERTIFIED
)"""
        assert_status_ok("fact-only replacement block", apply_definition(con, facts_only, False))

        # Fact removal has no DDL or admin form yet (dependent-metric rewrites
        # are not transactional), so retire the probe fact by hand rather than
        # leaving it in the shipped model for every later smoke step. Mirrors
        # ADD_FACT's own rollback order.
        con.execute("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_KIND = 'FACT' "
                     "AND OBJECT_REF_ID IN (SELECT FACT_ID FROM SYS_SEMANTIC.FACTS "
                     "WHERE FACT_NAME = 'gross_line_amount')")
        con.execute("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES "
                     "WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID IN ("
                     "SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'gross_line_amount')")
        con.execute("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS "
                     "WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID IN ("
                     "SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'gross_line_amount')")
        con.execute("DELETE FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'gross_line_amount'")
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        assert_equal(
            "probe fact retired",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.FACTS "
                "WHERE MODEL_NAME = 'sales' AND FACT_NAME = 'gross_line_amount'",
            ),
            0,
        )

        drop_dependency = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES DROP METRIC total_revenue",
            False,
        )
        assert_equal("drop depended-on metric rejected", drop_dependency["status"], "ERROR")
        assert_equal("drop depended-on metric rollback", drop_dependency["error_code"], "SEMANTIC_DDL_090")
        assert_equal(
            "drop rollback keeps metric active",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS "
                "WHERE METRIC_NAME = 'total_revenue' AND STATUS = 'ACTIVE'",
            ),
            1,
        )

        obsolete_ddl = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC obsolete_metric
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC"""
        assert_equal("add obsolete metric", apply_definition(con, obsolete_ddl, False)["status"], "OK")
        assert_equal(
            "drop obsolete metric",
            apply_definition(
                con,
                "ALTER SEMANTIC VIEW sales.SALES DROP METRIC obsolete_metric",
                False,
            )["status"],
            "OK",
        )
        assert_equal(
            "dropped metric inactive",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS "
                "WHERE METRIC_NAME = 'obsolete_metric' AND STATUS = 'INACTIVE'",
            ),
            1,
        )

        # A dropped metric stays visible as an INACTIVE row with no object
        # membership, so "metric not found" read as a contradiction. Each of
        # the three states a lookup can fail in gets named.
        dropped_again = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES DROP METRIC obsolete_metric",
            False,
        )
        assert_equal("re-drop refused", dropped_again["status"], "ERROR")
        assert_equal("re-drop code", dropped_again["error_code"], "SEMANTIC_DDL_080")
        assert_contains("re-drop names the state", dropped_again["message"],
                        "was already dropped")
        assert_contains("re-drop explains the visible row", dropped_again["message"],
                        "STATUS = 'INACTIVE'")
        assert_equal(
            "the explained row is really there",
            fetchall(
                con,
                "SELECT OBJECT_NAME, STATUS FROM SEMANTIC_CATALOG.METRIC_OVERVIEW "
                "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'obsolete_metric'",
            ),
            [(None, "INACTIVE")],
        )

        wrong_object = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES DROP METRIC total_freight",
            False,
        )
        assert_equal("drop from the wrong view refused", wrong_object["status"], "ERROR")
        assert_contains("wrong view names the owning view", wrong_object["message"],
                        "it is exposed by: ORDER_HEADER")

        absent = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES DROP METRIC never_defined_metric",
            False,
        )
        assert_equal("absent metric refused", absent["status"], "ERROR")
        assert_contains("absent metric wording", absent["message"],
                        "metric not found in semantic view SALES")

        # The demo ships an entity named `order`, a reserved word. Quoted names
        # were accepted for metrics, facts, models, and objects but not after
        # ON ENTITY, so one statement disagreed with itself.
        quoted = apply_definition(
            con,
            'ALTER SEMANTIC VIEW "sales"."ORDER_HEADER" '
            'ADD OR REPLACE FACT "quoted_probe" ON ENTITY "order" '
            "AS o.freight_amount RETURNS DECIMAL(18,2) ADDITIVE PUBLIC",
            False,
        )
        assert_status_ok("quoted identifiers in every name position", quoted)
        assert_equal(
            "quoted entity resolved to the unquoted entity",
            fetchall(
                con,
                "SELECT ENTITY_NAME FROM SEMANTIC_CATALOG.FACTS "
                "WHERE MODEL_NAME = 'sales' AND FACT_NAME = 'quoted_probe'",
            ),
            [("order",)],
        )
        bad_quoted = apply_definition(
            con,
            "ALTER SEMANTIC VIEW sales.SALES "
            'ADD OR REPLACE FACT bad_probe ON ENTITY "order line" '
            "AS ol.quantity RETURNS DECIMAL(18,0) ADDITIVE PUBLIC",
            False,
        )
        assert_equal("quoting is not an escape hatch", bad_quoted["status"], "ERROR")
        assert_equal("invalid quoted name code", bad_quoted["error_code"], "SEMANTIC_DDL_002")
        assert_contains("invalid quoted name is echoed as written",
                        bad_quoted["message"], '"order line"')

        # Retire the probe fact the same way this suite retires the other one.
        con.execute("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_KIND = 'FACT' "
                     "AND OBJECT_REF_ID IN (SELECT FACT_ID FROM SYS_SEMANTIC.FACTS "
                     "WHERE FACT_NAME = 'quoted_probe')")
        con.execute("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES "
                     "WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID IN ("
                     "SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'quoted_probe')")
        con.execute("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS "
                     "WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID IN ("
                     "SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'quoted_probe')")
        con.execute("DELETE FROM SYS_SEMANTIC.FACTS WHERE FACT_NAME = 'quoted_probe'")
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")

        # ---- DIMENSION in ALTER SEMANTIC VIEW -------------------------------
        #
        # Until now the DDL covered facts and metrics only, and `DIMENSION` was
        # refused with SEMANTIC_DDL_012 -- so the documented "SQL-native" surface
        # could describe what an object measures but not what it can be grouped
        # by, and the one clause a modeller most often edits had to go through
        # ADD_DIMENSION's ten positional parameters.
        #
        # A dimension is a fact's shape (an expression on an entity, with a type
        # and presentation metadata), so it reuses the fact clauses and adds no
        # keyword. What differs is where it lands: DIMENSIONS spells visibility
        # IS_HIDDEN rather than IS_PRIVATE, carries FORMAT_HINT rather than an
        # additive policy, and a dimension is a *visible* object column because
        # it is something a caller groups by.
        cleanup_dimensions(con, ["freight_band", "bad_column_dim"])
        dim_dry = apply_definition(
            con,
            'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION freight_band'
            ' ON ENTITY "order"'
            " AS CASE WHEN o.freight_amount > 20 THEN 'HIGH' ELSE 'LOW' END"
            " RETURNS VARCHAR(10) DISPLAY 'Freight Band' COMMENT 'Bucketed freight'"
            " FORMAT 'text' CERTIFIED",
            True)
        assert_equal("dimension dry run status", dim_dry["status"], "DRY_RUN")
        assert_equal("dimension dry run counts one operation", dim_dry["operation_count"], 1)
        assert_equal(
            "dimension dry run committed nothing",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.DIMENSIONS"
                        " WHERE DIMENSION_NAME = 'freight_band'"),
            0,
        )

        dim_applied = apply_definition(
            con,
            'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION freight_band'
            ' ON ENTITY "order"'
            " AS CASE WHEN o.freight_amount > 20 THEN 'HIGH' ELSE 'LOW' END"
            " RETURNS VARCHAR(10) DISPLAY 'Freight Band' COMMENT 'Bucketed freight'"
            " FORMAT 'text' CERTIFIED",
            False)
        assert_status_ok("dimension apply", dim_applied)
        dim_row = fetchall(
            con,
            "SELECT DATA_TYPE, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, IS_HIDDEN,"
            " IS_CERTIFIED FROM SEMANTIC_CATALOG.DIMENSIONS"
            " WHERE MODEL_NAME = 'sales' AND DIMENSION_NAME = 'freight_band'")
        assert_equal("dimension catalog row", list(dim_row[0]),
                     ["VARCHAR(10)", "Freight Band", "Bucketed freight", "text", False, True])
        assert_equal(
            "dimension is a visible object column",
            scalar(con,
                   "SELECT oc.IS_VISIBLE FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
                   " JOIN SYS_SEMANTIC.DIMENSIONS d ON d.DIMENSION_ID = oc.OBJECT_REF_ID"
                   " WHERE oc.COLUMN_KIND = 'DIMENSION' AND d.DIMENSION_NAME = 'freight_band'"),
            True,
        )
        assert_equal(
            "dimension got its default attribute binding",
            scalar(con,
                   "SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab"
                   " JOIN SYS_SEMANTIC.DIMENSIONS d ON d.DIMENSION_ID = ab.ATTRIBUTE_ID"
                   " WHERE ab.ATTRIBUTE_TYPE = 'DIMENSION' AND ab.IS_DEFAULT = TRUE"
                   " AND ab.STATUS = 'ACTIVE' AND d.DIMENSION_NAME = 'freight_band'"),
            1,
        )

        # The point of authoring it: it has to answer a query, with the numbers a
        # hand-written join gives.
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
        compiled = compile_request(con, {"model": "sales", "object": "SALES",
                                         "metrics": ["total_revenue"],
                                         "dimensions": ["freight_band"]})
        assert_equal("compile grouped by the new dimension", compiled["status"], "OK")
        got = {str(row[0]): row[1] for row in fetchall(con, compiled["generated_sql"])}
        truth = {str(row[0]): row[1] for row in fetchall(
            con,
            "SELECT CASE WHEN o.FREIGHT_AMOUNT > 20 THEN 'HIGH' ELSE 'LOW' END,"
            " SUM(ol.QUANTITY * ol.NET_UNIT_PRICE)"
            " FROM MART.ORDER_LINES ol JOIN MART.ORDERS o ON o.ORDER_ID = ol.ORDER_ID"
            " GROUP BY 1")}
        assert_equal("DDL-authored dimension returns the truth", got, truth)

        # REPLACE DIMENSIONS is a set replacement, exactly as REPLACE FACTS is:
        # it decides the object's dimension membership, and the ones left out
        # leave the object.
        before = scalar(con,
            "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
            " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
            " WHERE so.OBJECT_NAME = 'SALES' AND oc.COLUMN_KIND = 'DIMENSION'")
        if int(before) < 2:
            raise AssertionError(f"fixture needs several dimensions on SALES, has {before}")
        combined = apply_definition(
            con,
            'ALTER SEMANTIC VIEW sales.SALES'
            ' REPLACE DIMENSIONS ('
            '   DIMENSION ship_mode ON ENTITY "order" AS o.ship_mode RETURNS VARCHAR(20)'
            "     DISPLAY 'Ship Mode' CERTIFIED,"
            '   DIMENSION order_status ON ENTITY "order" AS o.order_status'
            "     RETURNS VARCHAR(20) DISPLAY 'Order Status' CERTIFIED)"
            ' REPLACE METRICS ('
            '   METRIC total_revenue AS SUM(net_revenue) ON ENTITY order_line'
            "     RETURNS DECIMAL(18,2) FORMAT 'currency' ADDITIVE PUBLIC CERTIFIED)",
            False)
        assert_status_ok("dimensions and metrics in one statement", combined)
        assert_equal("one statement counted three operations",
                     combined["operation_count"], 3)
        assert_equal(
            "REPLACE DIMENSIONS decided the object's dimension set",
            scalar(con,
                   "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
                   " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
                   " WHERE so.OBJECT_NAME = 'SALES' AND oc.COLUMN_KIND = 'DIMENSION'"),
            2,
        )

        # Refusals. The message must list the new forms, or a caller reading it
        # concludes dimensions are still unsupported.
        for label, statement, expected in (
            ("block entry must be a DIMENSION",
             'ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS'
             ' (FACT x ON ENTITY "order" AS o.ship_mode RETURNS VARCHAR(20))',
             "SEMANTIC_DDL_025"),
            ("dimension requires AS",
             'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d'
             ' ON ENTITY "order" RETURNS VARCHAR(20)', "SEMANTIC_DDL_026"),
            ("dimension requires RETURNS",
             'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d'
             ' ON ENTITY "order" AS o.ship_mode', "SEMANTIC_DDL_027"),
            ("REPLACE DIMENSIONS needs a block",
             'ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS DIMENSION d',
             "SEMANTIC_DDL_028"),
            ("unterminated DIMENSIONS block",
             'ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS (DIMENSION d',
             "SEMANTIC_DDL_029"),
            ("single dimension form cannot share a statement",
             'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d'
             ' ON ENTITY "order" AS o.ship_mode RETURNS VARCHAR(20)'
             ' REPLACE METRICS (METRIC m AS SUM(net_revenue) ON ENTITY order_line'
             ' RETURNS DECIMAL(18,2))', "SEMANTIC_DDL_038"),
        ):
            refused = apply_definition(con, statement, True)
            if refused["status"] != "ERROR":
                raise AssertionError(f"{label}: expected ERROR, got {refused}")
            assert_contains(label, str(refused["error_code"]) + " " + str(refused["message"]),
                            expected)
        # The two surfaces must agree. `sales_model_seed.sql` builds the four
        # SALES dimensions with ADD_DIMENSION; the DDL block in
        # `sales_metrics_semantic_definition.sql` claims to be its declarative
        # equivalent. Replay that block and require the four rows to carry the
        # seed's exact values -- otherwise the example's claim quietly stops
        # being true. Stated as literals rather than as a before/after snapshot,
        # because earlier checks in this file deliberately edit these same
        # dimensions and a snapshot would just compare them to themselves.
        SEEDED_SALES_DIMENSIONS = [
            ("customer_region", "customer", "c.region", "VARCHAR(100)",
             "Customer Region", "Commercial region assigned to the customer",
             None, False, True),
            ("order_month", "order", "DATE_TRUNC('month', o.order_date)", "DATE",
             "Order Month", "Calendar month of the order date", "month", False, True),
            ("order_status", "order", "o.order_status", "VARCHAR(32)",
             "Order Status", "Lifecycle status of the order", None, False, True),
            ("product_category", "product", "p.category", "VARCHAR(100)",
             "Product Category", "Commercial product category", None, False, True),
        ]
        seeded_names = tuple(row[0] for row in SEEDED_SALES_DIMENSIONS)
        dimension_columns = (
            "SELECT DIMENSION_NAME, ENTITY_NAME, EXPRESSION, DATA_TYPE, DISPLAY_NAME,"
            " DESCRIPTION, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED"
            " FROM SEMANTIC_CATALOG.DIMENSIONS WHERE MODEL_NAME = 'sales'"
            f" AND DIMENSION_NAME IN {seeded_names} ORDER BY DIMENSION_NAME")
        example = (ROOT / "sql/examples/sales_metrics_semantic_definition.sql").read_text(
            encoding="utf-8")
        block = re.search(
            r"(ALTER SEMANTIC VIEW sales\.SALES\s*\nREPLACE DIMENSIONS \(.*?\n\);)",
            example, re.S)
        if block is None:
            raise AssertionError(
                "the example no longer carries a REPLACE DIMENSIONS block")
        statement = block.group(1).rstrip(";")
        replayed = apply_definition(con, statement, False)
        assert_status_ok("example dimension block replays", replayed)
        assert_equal("DDL block reproduces the ADD_DIMENSION seed exactly",
                     fetchall(con, dimension_columns),
                     [tuple(row) for row in SEEDED_SALES_DIMENSIONS])
        # Applying it again must be a no-op, which is what makes the file safe to
        # keep in source control and re-run.
        again = apply_definition(con, statement, False)
        assert_status_ok("example dimension block is idempotent", again)
        assert_equal("second apply changed nothing",
                     fetchall(con, dimension_columns),
                     [tuple(row) for row in SEEDED_SALES_DIMENSIONS])

        # A *failed* apply must roll the dimension back, not just a dry run.
        # Both paths restore the same snapshot, and that snapshot did not cover
        # SYS_SEMANTIC.DIMENSIONS until dimensions became authorable here.
        rejected = apply_definition(
            con,
            'ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION bad_column_dim'
            ' ON ENTITY "order" AS o.no_such_column_xyz RETURNS VARCHAR(20)',
            False)
        if rejected["status"] != "ERROR":
            raise AssertionError(f"invalid dimension was accepted: {rejected}")
        assert_contains("failed apply names the unknown column",
                        str(rejected["message"]), "SEMANTIC_MODEL_017")
        assert_equal(
            "failed apply left no dimension row behind",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.DIMENSIONS"
                        " WHERE DIMENSION_NAME = 'bad_column_dim'"),
            0,
        )
        assert_equal(
            "failed apply left no orphan binding behind",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab"
                        " WHERE ab.ATTRIBUTE_TYPE = 'DIMENSION' AND NOT EXISTS ("
                        " SELECT 1 FROM SYS_SEMANTIC.DIMENSIONS d"
                        " WHERE d.DIMENSION_ID = ab.ATTRIBUTE_ID)"),
            0,
        )

        unsupported = apply_definition(con, "ALTER SEMANTIC VIEW sales.SALES REPLACE NOTHING (x)", True)
        for form in ("REPLACE DIMENSIONS", "ADD OR REPLACE DIMENSION"):
            assert_contains("SEMANTIC_DDL_012 advertises " + form,
                            str(unsupported["message"]), form)

        # Put the model back the way this file found it -- content *and* column
        # order. The probes above used REPLACE blocks, which are set
        # replacements: they drop what they leave out, and verifiers later in
        # tools/run_smoke.sh depend on this object. verify_osi_batch_import.py
        # pins OBJECT_COLUMNS exactly, ordinals included, because OSI export
        # carries them to the imported model.
        #
        # Restoring in one statement is what makes the ordinals come back as
        # 1..12: all three REPLACE blocks delete first, then the apply re-adds
        # dimensions, facts and metrics in that order, each taking MAX+1. Two
        # separate statements would interleave -- dimensions landing after the
        # surviving facts and metrics -- and renumber the object.
        cleanup_dimensions(con, ["freight_band", "bad_column_dim"])
        restore_statement = (
            statement.rstrip()
            + "\n"
            + SEMANTIC_DEFINITION.split("ALTER SEMANTIC VIEW sales.SALES", 1)[1].strip()
        )
        assert_status_ok("model restored after the probes",
                         apply_definition(con, restore_statement, False))
        assert_equal(
            "object columns restored, ordinals included",
            fetchall(con,
                     "SELECT oc.COLUMN_KIND, oc.COLUMN_NAME, oc.ORDINAL_POSITION,"
                     " oc.IS_VISIBLE FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
                     " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
                     " WHERE so.OBJECT_NAME = 'SALES' ORDER BY oc.ORDINAL_POSITION"),
            [("DIMENSION", "customer_region", 1, True),
             ("DIMENSION", "order_month", 2, True),
             ("DIMENSION", "order_status", 3, True),
             ("DIMENSION", "product_category", 4, True),
             ("FACT", "net_revenue", 5, False),
             ("FACT", "net_cost", 6, False),
             ("FACT", "quantity", 7, False),
             ("METRIC", "total_revenue", 8, True),
             ("METRIC", "total_cost", 9, True),
             ("METRIC", "gross_margin", 10, True),
             ("METRIC", "gross_margin_pct", 11, True),
             ("METRIC", "completed_revenue", 12, True)],
        )
        for restored in ("gross_margin_pct", "completed_revenue"):
            assert_equal(
                f"{restored} is back on the object",
                scalar(con,
                       "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
                       " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
                       " WHERE so.OBJECT_NAME = 'SALES' AND oc.COLUMN_KIND = 'METRIC'"
                       f" AND oc.COLUMN_NAME = {sql_string(restored)}"),
                1,
            )

        add_replace_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION("
            "'sales', 'SALES', 'order', 'order_year', "
            "'YEAR(o.order_date)', 'DECIMAL(4,0)', "
            "'Order Year', 'Calendar year of order', NULL, FALSE)",
        )
        assert_equal("add_or_replace new dimension was_update", add_replace_rows[0][4], False)
        assert_equal("add_or_replace new dimension object_column_registered", add_replace_rows[0][6], True)

        replace_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION("
            "'sales', 'SALES', 'order', 'order_year', "
            "'YEAR(o.order_date)', 'DECIMAL(4,0)', "
            "'Order Year Updated', 'Updated description', NULL, FALSE)",
        )
        assert_equal("add_or_replace updated dimension was_update", replace_rows[0][4], True)
        assert_equal(
            "add_or_replace no duplicate",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.DIMENSIONS d "
                "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = d.MODEL_ID "
                "WHERE m.MODEL_NAME = 'sales' AND d.DIMENSION_NAME = 'order_year' AND d.STATUS = 'ACTIVE'",
            ),
            1,
        )

        remove_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_DIMENSION('sales', 'SALES', 'order_year')",
        )
        assert_equal("remove dimension status", remove_rows[0][0], "OK")
        assert_equal("remove dimension name confirmed", remove_rows[0][3], "order_year")
        assert_equal(
            "remove dimension not visible",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.DIMENSIONS d "
                "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = d.MODEL_ID "
                "WHERE m.MODEL_NAME = 'sales' AND d.DIMENSION_NAME = 'order_year'",
            ),
            0,
        )
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        finally:
            con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
