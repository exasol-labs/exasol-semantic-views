#!/usr/bin/env python3
"""Verify Databricks UCMV import on Exasol Nano (end-to-end).

Imports sql/examples/sales_databricks_metric_view.yaml into a fresh model over
the demo MART tables, asserts the translated catalog shape, and confirms the
imported model compiles and answers a Databricks-style query.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "sql/examples/sales_databricks_metric_view.yaml"
TARGET_MODEL = "sales_dbx"
TARGET_SCHEMA = "SEMANTIC_SALES_DBX"

failures = 0


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


def ok(name: str, detail: str = "") -> None:
    print(f"ok  {name}{': ' + detail if detail else ''}")


def fail(name: str, detail: str) -> None:
    global failures
    failures += 1
    print(f"FAIL {name}: {detail}")


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual == expected:
        ok(name, repr(actual))
    else:
        fail(name, f"expected {expected!r}, got {actual!r}")


def cleanup(con) -> None:
    """Best-effort removal of a prior import so the test is re-runnable."""
    try:
        con.execute(f"DROP SCHEMA IF EXISTS {TARGET_SCHEMA} CASCADE")
    except Exception:
        pass
    ids = fetchall(con, f"SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER({sql_string(TARGET_MODEL)})")
    if not ids:
        return
    model_id = ids[0][0]
    tables = [
        r[0]
        for r in fetchall(
            con,
            "SELECT COLUMN_TABLE FROM SYS.EXA_ALL_COLUMNS "
            "WHERE COLUMN_SCHEMA = 'SYS_SEMANTIC' AND COLUMN_NAME = 'MODEL_ID'",
        )
    ]
    # FK children before parents: retry until all delete cleanly.
    for _ in range(6):
        remaining = []
        for table in tables:
            try:
                con.execute(f"DELETE FROM SYS_SEMANTIC.{table} WHERE MODEL_ID = {model_id}")
            except Exception:
                remaining.append(table)
        con.commit()
        if not remaining:
            break
        tables = remaining


def import_view(con, apply: bool) -> dict[str, Any]:
    yaml_text = FIXTURE.read_text(encoding="utf-8")
    sql = (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW("
        f"{sql_string(yaml_text)}, {sql_string(TARGET_MODEL)}, {sql_string(TARGET_SCHEMA)}, {'TRUE' if apply else 'FALSE'})"
    )
    row = fetchall(con, sql)[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "model_name": row[3],
        "generated_ddl": row[4],
        "diagnostics": json.loads(row[5]) if row[5] else [],
        "validation_run_id": row[6],
    }


def main() -> int:
    con = connect()
    try:
        cleanup(con)

        # Dry-run translation (no apply): DDL emitted, nothing created.
        dry = import_view(con, apply=False)
        assert_equal("dry_run/status", dry["status"], "OK")
        if dry["generated_ddl"] and "ALTER SEMANTIC VIEW" in dry["generated_ddl"]:
            ok("dry_run/ddl_emitted", "ALTER SEMANTIC VIEW present")
        else:
            fail("dry_run/ddl_emitted", "generated DDL missing ALTER SEMANTIC VIEW")
        count = fetchall(con, f"SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME)=UPPER({sql_string(TARGET_MODEL)})")[0][0]
        assert_equal("dry_run/not_applied", int(count), 0)

        # Apply translation.
        res = import_view(con, apply=True)
        if res["status"] != "OK":
            fail("apply/status", f"{res['error_code']}: {res['error_message']}")
            return 1
        ok("apply/status", "OK")
        if res["validation_run_id"] is None:
            fail("apply/validation_run", "no validation run id returned")
        else:
            ok("apply/validation_run", str(res["validation_run_id"]))
        for diag in res["diagnostics"]:
            if diag.get("severity") == "ERROR":
                fail("apply/diagnostics", f"unexpected ERROR diagnostic: {diag}")

        # Catalog shape: 4 entities, 3 relationships, 4 dimensions, 5 facts, 6 metrics, synonyms present.
        def model_count(table: str) -> int:
            return int(
                fetchall(con, f"SELECT COUNT(*) FROM SEMANTIC_CATALOG.{table} WHERE UPPER(MODEL_NAME)=UPPER({sql_string(TARGET_MODEL)})")[0][0]
            )

        assert_equal("catalog/entities", model_count("ENTITIES"), 4)
        assert_equal("catalog/relationships", model_count("RELATIONSHIPS"), 3)
        assert_equal("catalog/dimensions", model_count("DIMENSIONS"), 4)
        assert_equal("catalog/facts", model_count("FACTS"), 5)
        assert_equal("catalog/metrics", model_count("METRICS"), 6)

        # Metric kinds inferred from the Databricks measure shapes.
        kinds = {
            r[0]: r[1]
            for r in fetchall(
                con,
                "SELECT METRIC_NAME, METRIC_KIND FROM SEMANTIC_CATALOG.METRICS "
                f"WHERE UPPER(MODEL_NAME)=UPPER({sql_string(TARGET_MODEL)})",
            )
        }
        assert_equal("kind/avg_order_value", kinds.get("avg_order_value"), "RATIO")
        assert_equal("kind/completed_revenue", kinds.get("completed_revenue"), "FILTERED")
        assert_equal("kind/total_revenue", kinds.get("total_revenue"), "SIMPLE")

        # Imported model compiles and answers a Databricks-style query.
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        rows = fetchall(
            con,
            "SELECT customer_region, MEASURE(total_revenue) AS total_revenue, MEASURE(avg_order_value) AS aov "
            f"FROM {TARGET_SCHEMA}.SALES_DBX GROUP BY ALL ORDER BY total_revenue DESC",
        )
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        if rows and len(rows) == 3:
            ok("query/rows", f"{len(rows)} region rows")
        else:
            fail("query/rows", f"expected 3 region rows, got {rows!r}")

        if failures:
            print(f"\nFAILED: {failures} assertion(s) failed")
            return 1
        print("\nPASSED: Databricks UCMV import verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
