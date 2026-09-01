#!/usr/bin/env python3
"""Verify normalized OSI batch import support on Exasol."""

from __future__ import annotations

import importlib.util
import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OSI_PATH = ROOT / "tools/osi.py"
TARGET_MODEL = "sales_osi_batch_import"

spec = importlib.util.spec_from_file_location("osi_tool", OSI_PATH)
osi = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
assert spec.loader is not None
sys.modules[spec.name] = osi
spec.loader.exec_module(osi)


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


def scalar(con, sql: str) -> int:
    rows = fetchall(con, sql)
    return int(rows[0][0])


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
        "generated_sql": row[4],
        "plan_json": row[5],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_true(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(f"{name}: expected true")
    print(f"ok {name}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected to find {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def make_plan(document: dict[str, Any]) -> dict[str, Any]:
    return osi.plan_import(
        document,
        osi.ImportOptions(
            profile="lossless",
            strict=True,
            warnings_as_errors=False,
            target_model=TARGET_MODEL,
            source="<live-sales-export>",
        ),
    )


def apply_batch(con, plan: dict[str, Any]) -> dict[str, Any]:
    return osi.apply_import_plan(
        con,
        plan,
        osi.ImportApplyOptions(
            collision_policy="replace_draft",
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=False,
            apply_mode="batch",
        ),
    )


def object_columns(con) -> list[tuple[str, str, int, bool]]:
    rows = fetchall(
        con,
        """
        SELECT oc.COLUMN_KIND, oc.COLUMN_NAME, oc.ORDINAL_POSITION, oc.IS_VISIBLE
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        JOIN SYS_SEMANTIC.MODELS m
          ON m.MODEL_ID = so.MODEL_ID
        WHERE m.MODEL_NAME = 'sales_osi_batch_import'
          AND so.OBJECT_NAME = 'SALES'
        ORDER BY oc.ORDINAL_POSITION
        """,
    )
    return [(row[0], row[1], int(row[2]), bool(row[3])) for row in rows]


# Presentation metadata the ADD_* scripts have no parameter for.
#
# osi.py has always *exported* format_hint, unit_hint, sensitivity_label and
# display_policy for both field kinds and listed them as importable native
# keys, but nothing applied them coming back in -- and nothing in the catalog
# could set them either, so every export carried them absent and the loss was
# invisible. A document authored elsewhere, by hand or by another
# implementation of the profile, lost them silently. Batch apply patches them
# in now; script apply still cannot, and says so with OSI_IMPORT_120. This
# injects real values into the exported document so the batch lane is checked
# against something, rather than against four NULLs that would match either way.
PRESENTATION_PROBE = {
    "FACT": {"format_hint": "#,##0.00", "unit_hint": "USD",
             "sensitivity_label": "INTERNAL", "display_policy": "SHOW"},
    "DIMENSION": {"format_hint": "@", "unit_hint": "text",
                  "sensitivity_label": "PII", "display_policy": "MASK"},
}


def inject_presentation_metadata(document: dict[str, Any]) -> dict[str, tuple[str, dict]]:
    """Stamp one dimension and one fact, and say which names were stamped."""
    stamped: dict[str, tuple[str, dict]] = {}
    for model in document.get("semantic_model", []):
        for dataset in model.get("datasets", []):
            for field in dataset.get("fields", []):
                for extension in field.get("custom_extensions", []):
                    if extension.get("vendor_name") != "EXASOL":
                        continue
                    data = json.loads(extension["data"])
                    kind = str(data.get("field_kind", "")).upper()
                    if kind not in PRESENTATION_PROBE or kind in stamped:
                        continue
                    data.update(PRESENTATION_PROBE[kind])
                    extension["data"] = json.dumps(data)
                    stamped[kind] = (str(field["name"]), PRESENTATION_PROBE[kind])
    return stamped


def main() -> int:
    con = connect()
    try:
        document, warnings = osi.export_model(
            con,
            osi.ExportOptions(model_name="sales", object_name=None, profile="lossless"),
        )
        # The sales model ships a materialization, which no Ossie profile can
        # carry. It does not block a lossless export -- losing one changes query
        # cost, not answers -- but it is reported, so this asserts the expected
        # warning rather than none. A second code here is a real regression.
        assert_equal("source export warning codes",
                     [item["code"] for item in warnings], ["OSI_EXPORT_050"])
        stamped = inject_presentation_metadata(document)
        assert_equal("presentation probe covers both field kinds",
                     sorted(stamped), ["DIMENSION", "FACT"])

        plan = make_plan(document)
        assert_equal("batch plan status", plan["status"], "ok")

        result = apply_batch(con, plan)
        assert_equal("batch apply status", result["status"], "ok")

        for kind, (field_name, expected) in sorted(stamped.items()):
            surface = "DIMENSIONS" if kind == "DIMENSION" else "FACTS"
            name_column = "DIMENSION_NAME" if kind == "DIMENSION" else "FACT_NAME"
            assert_equal(
                f"{kind.lower()} presentation metadata survives a batch import",
                fetchall(
                    con,
                    "SELECT FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY "
                    f"FROM SEMANTIC_CATALOG.{surface} "
                    f"WHERE MODEL_NAME = {sql_string(TARGET_MODEL)} "
                    f"AND {name_column} = {sql_string(field_name)}",
                ),
                [(expected["format_hint"], expected["unit_hint"],
                  expected["sensitivity_label"], expected["display_policy"])],
            )
        assert_equal("batch apply mode", result["apply_mode"], "batch")
        assert_true("batch rows returned", len(result["batch_rows"]) >= len(plan["operations"]))
        operation_row = result["batch_rows"][0]
        validation_row = result["batch_rows"][-1]
        for column in [
            "STATUS",
            "OPERATION_INDEX",
            "OPERATION_NAME",
            "TARGET",
            "SOURCE_PATH",
            "ROW_COUNT",
            "MESSAGE",
        ]:
            assert_true(f"batch operation row column {column}", column in operation_row)
        for column in [
            "STATUS",
            "OPERATION_NAME",
            "TARGET",
            "SOURCE_PATH",
            "WARNING_JSON",
            "VALIDATION_RUN_ID",
            "MESSAGE",
        ]:
            assert_true(f"batch validation row column {column}", column in validation_row)
        assert_equal("batch diagnostics", result["diagnostics"], [])
        assert_true("batch validation id", result["validation_run_id"] is not None)

        assert_equal(
            "batch object columns",
            object_columns(con),
            [
                ("DIMENSION", "customer_region", 1, True),
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
                ("METRIC", "completed_revenue", 12, True),
            ],
        )
        assert_equal(
            "relationship path priorities",
            scalar(
                con,
                """
                SELECT COUNT(*)
                FROM SYS_SEMANTIC.RELATIONSHIPS r
                JOIN SYS_SEMANTIC.MODELS m
                  ON m.MODEL_ID = r.MODEL_ID
                WHERE m.MODEL_NAME = 'sales_osi_batch_import'
                  AND r.PATH_PRIORITY = 100
                """,
            ),
            3,
        )
        assert_equal(
            "structured relationship key mappings",
            scalar(
                con,
                """
                SELECT COUNT(*)
                FROM SEMANTIC_CATALOG.RELATIONSHIP_KEY_MAPPINGS
                WHERE MODEL_NAME = 'sales_osi_batch_import'
                """,
            ),
            3,
        )
        metric_rows = fetchall(
            con,
            """
            SELECT mt.METRIC_KIND, mt.AGGREGATION_FUNCTION, mt.MEASURE_EXPR,
                   mt.SEMANTIC_FILTER_EXPR, mt.SQL_FILTER_EXPR
            FROM SYS_SEMANTIC.METRICS mt
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = mt.MODEL_ID
            WHERE m.MODEL_NAME = 'sales_osi_batch_import'
              AND mt.METRIC_NAME = 'completed_revenue'
            """,
        )
        assert_equal(
            "filtered metric native metadata",
            metric_rows,
            [("FILTERED", "SUM", "net_revenue", "order_status = 'COMPLETE'", "o.order_status = 'COMPLETE'")],
        )

        compiled = compile_request(
            con,
            {
                "model": TARGET_MODEL,
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "order_by": [{"field": "total_revenue", "direction": "desc"}],
                "limit": 2,
                "purpose": "osi_batch_import_smoke",
                "client": "verify_osi_batch_import",
            },
        )
        assert_equal("batch imported compile status", compiled["status"], "OK")
        assert_contains("batch imported compile SQL", compiled["generated_sql"], 'c.region AS "customer_region"')
        revenue_rows = fetchall(con, compiled["generated_sql"])
        assert_equal("batch imported query rows", revenue_rows, [("North", "3635"), ("West", "1500")])
    finally:
        con.close()
    print("ok OSI batch import verifier")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
