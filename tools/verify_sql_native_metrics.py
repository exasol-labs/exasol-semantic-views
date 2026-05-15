#!/usr/bin/env python3
"""Verify SQL-native metric definition and introspection flows on Exasol Nano."""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any


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


COMPOUND_AGGREGATE_METRIC = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC avg_order_value_probe
  AS SUM(net_revenue) / NULLIF(COUNT(DISTINCT order_id), 0)
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
                "'DESCRIBE_SEMANTIC_METRIC', 'EXPLAIN_SEMANTIC_METRIC', "
                "'EXPORT_SEMANTIC_DEFINITION', 'ENABLE_SEMANTIC_SQL', 'DISABLE_SEMANTIC_SQL')",
            ),
            7,
        )

        dry_run = apply_definition(con, SEMANTIC_DEFINITION, True)
        assert_equal("dry run status", dry_run["status"], "DRY_RUN")
        assert_equal("dry run operation count", int(dry_run["operation_count"]), 8)
        assert_contains("dry run normalized semantic filter", dry_run["normalized_json"], '"semantic_filter_expr":"order_status =')

        compound_dry_run = apply_definition(con, COMPOUND_AGGREGATE_METRIC, True)
        compound_json = json.loads(compound_dry_run["normalized_json"])
        assert_equal("compound aggregate function", compound_json["metrics"][0]["aggregation_function"], "SUM")
        assert_equal("compound aggregate measure expr", compound_json["metrics"][0]["measure_expr"], "net_revenue")

        applied = apply_definition(con, SEMANTIC_DEFINITION, False)
        assert_status_ok("semantic definition apply", applied)
        reapplied = apply_definition(con, SEMANTIC_DEFINITION, False)
        assert_status_ok("semantic definition idempotent apply", reapplied)

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

        invalid_validation = apply_definition(
            con,
            """ALTER SEMANTIC VIEW sales.SALES
REPLACE METRICS (
  METRIC bad_replaced_metric
    AS SUM(missing_fact)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Bad Replaced Metric'
    COMMENT 'Should be rejected atomically'
    ADDITIVE PUBLIC CERTIFIED
)""",
            False,
        )
        assert_equal("invalid validation apply status", invalid_validation["status"], "ERROR")
        assert_equal("invalid validation apply error", invalid_validation["error_code"], "SEMANTIC_DDL_090")
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
            exported = fetchall(con, "EXPORT SEMANTIC METRIC sales.SALES.total_revenue")
            assert_equal("export metric kind", exported[0][0], "METRIC")
            exported_dry_run = apply_definition(con, exported[0][2], True)
            assert_equal("exported metric dry run", exported_dry_run["status"], "DRY_RUN")
            assert_equal("export semantic view rows", len(fetchall(con, "EXPORT SEMANTIC VIEW sales.SALES")), 9)
            assert_equal("export semantic model rows", len(fetchall(con, "EXPORT SEMANTIC MODEL sales")), 19)
            dimension_filter = fetchall(
                con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'DIMENSION')",
            )
            assert_equal("export semantic dimensions rows", len(dimension_filter), 4)
            assert_equal("export semantic dimensions kind", {row[0] for row in dimension_filter}, {"DIMENSION"})
        finally:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

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
