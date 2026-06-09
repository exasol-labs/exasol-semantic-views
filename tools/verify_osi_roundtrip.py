#!/usr/bin/env python3
"""Verify OSI lossless round-trip fidelity on Exasol Nano."""

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
SOURCE_MODEL = "sales"
TARGET_MODEL = "sales_osi_roundtrip"
FAILURE_MODEL = "sales_osi_roundtrip_failure"
PATCH_FAILURE_MODEL = "sales_osi_roundtrip_patch_failure"
PARTNER_VENDOR = "PARTNER_VENDOR"

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


def sql_value(value: str | None) -> str:
    if value is None:
        return "NULL"
    return sql_string(value)


def fetchall(con, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def scalar(con, sql: str) -> int:
    rows = fetchall(con, sql)
    return int(rows[0][0])


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_true(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(f"{name}: expected true")
    print(f"ok {name}")


def assert_no_warnings(name: str, warnings: list[dict[str, Any]]) -> None:
    if warnings:
        raise AssertionError(f"{name}: expected no warnings, got {warnings!r}")
    print(f"ok {name}: no warnings")


def diagnostic_codes(result: dict[str, Any]) -> set[str]:
    return {item["code"] for item in result.get("diagnostics", [])}


def partner_payload(scope_type: str, scope_name: str | None) -> str:
    return json.dumps(
        {"marker": "osi-roundtrip", "scope": scope_type, "scope_name": scope_name},
        separators=(",", ":"),
        sort_keys=True,
    )


PARTNER_FIXTURES = [
    ("MODEL", None, "roundtrip_model"),
    ("SEMANTIC_OBJECT", "SALES", "roundtrip_semantic_object"),
    ("ENTITY", "order", "roundtrip_entity"),
    ("RELATIONSHIP", "order_line_to_order", "roundtrip_relationship"),
    ("DIMENSION", "customer_region", "roundtrip_dimension"),
    ("FACT", "net_revenue", "roundtrip_fact"),
    ("METRIC", "total_revenue", "roundtrip_metric"),
]
EXPECTED_PARTNER_PAYLOADS = {partner_payload(scope_type, scope_name) for scope_type, scope_name, _ in PARTNER_FIXTURES}
PRIMARY_KEY_FIXTURES = [
    ("order_line", "order_line_primary_key", ["order_id", "line_id"]),
    ("order", "order_primary_key", ["order_id"]),
    ("customer", "customer_primary_key", ["customer_id"]),
    ("product", "product_primary_key", ["product_id"]),
]


def ensure_primary_key(con, entity_name: str, key_name: str, columns: list[str]) -> None:
    existing = scalar(
        con,
        "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEYS "
        f"WHERE MODEL_NAME = {sql_string(SOURCE_MODEL)} "
        f"AND ENTITY_NAME = {sql_string(entity_name)} "
        "AND KEY_KIND = 'PRIMARY' "
        "AND STATUS = 'ACTIVE'",
    )
    if existing > 0:
        return
    con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
        f"{sql_string(SOURCE_MODEL)}, {sql_string(entity_name)}, {sql_string(key_name)}, "
        "'PRIMARY', 'Imported from OSI primary_key.', 'OSI')",
    ).fetchall()
    for ordinal, column in enumerate(columns, start=1):
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
            f"{sql_string(SOURCE_MODEL)}, {sql_string(entity_name)}, {sql_string(key_name)}, "
            f"{sql_string(column)}, NULL, {ordinal})",
        ).fetchall()


def prepare_roundtrip_catalog(con) -> None:
    for entity_name, key_name, columns in PRIMARY_KEY_FIXTURES:
        ensure_primary_key(con, entity_name, key_name, columns)
    for scope_type, scope_name, extension_name in PARTNER_FIXTURES:
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
            f"{sql_string(SOURCE_MODEL)}, {sql_string(scope_type)}, {sql_value(scope_name)}, "
            f"{sql_string(PARTNER_VENDOR)}, {sql_string(partner_payload(scope_type, scope_name))}, "
            f"'OSI', {sql_string(extension_name)})",
        ).fetchall()
    con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION("
        "'sales', 'METRIC', 'total_revenue', 'DEFINITION', "
        "'Use total_revenue for recognized net revenue analysis.', NULL, 10)",
    ).fetchall()


def export_lossless(con, model_name: str) -> dict[str, Any]:
    document, warnings = osi.export_model(
        con,
        osi.ExportOptions(model_name=model_name, object_name=None, profile="lossless"),
    )
    osi.validate_document(document)
    assert_no_warnings(f"{model_name} lossless export warnings", warnings)
    return document


def make_plan(document: dict[str, Any], target_model: str) -> dict[str, Any]:
    return osi.plan_import(
        document,
        osi.ImportOptions(
            profile="lossless",
            strict=True,
            warnings_as_errors=False,
            target_model=target_model,
            source="<roundtrip-lossless-export>",
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


def collect_partner_extension_data(value: Any) -> set[str]:
    result: set[str] = set()

    def visit(item: Any) -> None:
        if isinstance(item, dict):
            extensions = item.get("custom_extensions")
            if isinstance(extensions, list):
                for extension in extensions:
                    if not isinstance(extension, dict):
                        continue
                    data = extension.get("data")
                    if extension.get("vendor_name") == PARTNER_VENDOR and isinstance(data, str):
                        result.add(data)
                    if isinstance(data, str):
                        try:
                            visit(json.loads(data))
                        except json.JSONDecodeError:
                            pass
            for nested in item.values():
                visit(nested)
        elif isinstance(item, list):
            for nested in item:
                visit(nested)

    visit(value)
    return result


def fetch_snapshot_rows(con, sql: str, canonical_model_name: str) -> list[dict[str, Any]]:
    rows = osi.fetch_dicts(con, sql)
    for row in rows:
        if "MODEL_NAME" in row:
            row["MODEL_NAME"] = canonical_model_name
        if row.get("SCOPE_TYPE") == "MODEL" and "SCOPE_NAME" in row:
            row["SCOPE_NAME"] = canonical_model_name
        if (row.get("VENDOR_NAME") != "EXASOL" or row.get("SCOPE_TYPE") == "SEMANTIC_OBJECT") and "EXTENSION_NAME" in row:
            row["EXTENSION_NAME"] = None
    return rows


def semantic_snapshot(con, model_name: str, canonical_model_name: str) -> dict[str, Any]:
    model = sql_string(model_name)
    return {
        "models": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, OWNER_ROLE, SURFACE_TYPE "
            f"FROM SEMANTIC_CATALOG.MODELS WHERE UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "entities": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, "
            "PRIMARY_KEY_EXPR, GRAIN_DESCRIPTION, DESCRIPTION "
            f"FROM SEMANTIC_CATALOG.ENTITIES WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "semantic_objects": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, OBJECT_NAME, ROOT_ENTITY_NAME, DESCRIPTION "
            f"FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "relationships": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, RELATIONSHIP_NAME, FROM_ENTITY_NAME, TO_ENTITY_NAME, JOIN_CONDITION, "
            "RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY, PATH_PRIORITY, DESCRIPTION "
            f"FROM SEMANTIC_CATALOG.RELATIONSHIPS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "dimensions": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, ENTITY_NAME, DIMENSION_NAME, EXPRESSION, DATA_TYPE, DISPLAY_NAME, "
            "DESCRIPTION, FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_HIDDEN, IS_CERTIFIED "
            f"FROM SEMANTIC_CATALOG.DIMENSIONS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "facts": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, ENTITY_NAME, FACT_NAME, EXPRESSION, DATA_TYPE, ADDITIVE_POLICY, "
            "DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, IS_CERTIFIED "
            f"FROM SEMANTIC_CATALOG.FACTS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "metrics": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, BASE_ENTITY_NAME, METRIC_NAME, EXPRESSION, FILTER_EXPR, METRIC_TYPE, DATA_TYPE, "
            "DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, "
            "IS_CERTIFIED, OWNER_ROLE, METRIC_KIND, AGGREGATION_FUNCTION, MEASURE_EXPR, SEMANTIC_FILTER_EXPR, "
            "SQL_FILTER_EXPR, DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_NAME, WINDOW_SPEC_JSON, TYPE_PARAMS_JSON "
            f"FROM SEMANTIC_CATALOG.METRICS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "object_columns": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, OBJECT_NAME, COLUMN_KIND, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE "
            f"FROM SEMANTIC_CATALOG.OBJECT_COLUMNS WHERE UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "unique_keys": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, ENTITY_NAME, KEY_NAME, KEY_KIND, DESCRIPTION, SOURCE_FORMAT "
            f"FROM SEMANTIC_CATALOG.UNIQUE_KEYS WHERE STATUS = 'ACTIVE' AND UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "unique_key_columns": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, ENTITY_NAME, KEY_NAME, KEY_KIND, ORDINAL_POSITION, COLUMN_NAME, EXPRESSION "
            f"FROM SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS WHERE UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "custom_extensions": fetch_snapshot_rows(
            con,
            "SELECT MODEL_NAME, SCOPE_TYPE, SCOPE_NAME, VENDOR_NAME, EXTENSION_NAME, SOURCE_FORMAT, DATA_JSON "
            f"FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS WHERE UPPER(MODEL_NAME) = UPPER({model})",
            canonical_model_name,
        ),
        "synonyms": fetch_snapshot_rows(
            con,
            """
            SELECT m.MODEL_NAME, s.OBJECT_TYPE,
                   CASE
                     WHEN s.OBJECT_TYPE = 'MODEL' THEN m.MODEL_NAME
                     WHEN s.OBJECT_TYPE = 'SEMANTIC_OBJECT' THEN so.OBJECT_NAME
                     WHEN s.OBJECT_TYPE = 'ENTITY' THEN e.ENTITY_NAME
                     WHEN s.OBJECT_TYPE = 'RELATIONSHIP' THEN r.RELATIONSHIP_NAME
                     WHEN s.OBJECT_TYPE = 'DIMENSION' THEN d.DIMENSION_NAME
                     WHEN s.OBJECT_TYPE = 'FACT' THEN f.FACT_NAME
                     WHEN s.OBJECT_TYPE = 'METRIC' THEN mt.METRIC_NAME
                     ELSE NULL
                   END AS OBJECT_NAME,
                   s.SYNONYM, s.SYNONYM_SOURCE
            FROM SYS_SEMANTIC.SYNONYMS s
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = s.MODEL_ID
             AND m.ACTIVE_VERSION_ID = s.VERSION_ID
            LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON s.OBJECT_TYPE = 'SEMANTIC_OBJECT' AND so.OBJECT_ID = s.OBJECT_ID
            LEFT JOIN SYS_SEMANTIC.ENTITIES e
              ON s.OBJECT_TYPE = 'ENTITY' AND e.ENTITY_ID = s.OBJECT_ID
            LEFT JOIN SYS_SEMANTIC.RELATIONSHIPS r
              ON s.OBJECT_TYPE = 'RELATIONSHIP' AND r.RELATIONSHIP_ID = s.OBJECT_ID
            LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
              ON s.OBJECT_TYPE = 'DIMENSION' AND d.DIMENSION_ID = s.OBJECT_ID
            LEFT JOIN SYS_SEMANTIC.FACTS f
              ON s.OBJECT_TYPE = 'FACT' AND f.FACT_ID = s.OBJECT_ID
            LEFT JOIN SYS_SEMANTIC.METRICS mt
              ON s.OBJECT_TYPE = 'METRIC' AND mt.METRIC_ID = s.OBJECT_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER({model})
            """.format(model=model),
            canonical_model_name,
        ),
        "instructions": fetch_snapshot_rows(
            con,
            """
            SELECT m.MODEL_NAME, ai.SCOPE_TYPE,
                   CASE
                     WHEN ai.SCOPE_TYPE = 'MODEL' THEN m.MODEL_NAME
                     WHEN ai.SCOPE_TYPE = 'SEMANTIC_OBJECT' THEN so.OBJECT_NAME
                     WHEN ai.SCOPE_TYPE = 'ENTITY' THEN e.ENTITY_NAME
                     WHEN ai.SCOPE_TYPE = 'DIMENSION' THEN d.DIMENSION_NAME
                     WHEN ai.SCOPE_TYPE = 'FACT' THEN f.FACT_NAME
                     WHEN ai.SCOPE_TYPE = 'METRIC' THEN mt.METRIC_NAME
                     ELSE NULL
                   END AS SCOPE_NAME,
                   ai.INSTRUCTION_KIND, ai.INSTRUCTION_TEXT, ai.APPLIES_TO_ROLE, ai.PRIORITY
            FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS ai
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = ai.MODEL_ID
             AND m.ACTIVE_VERSION_ID = ai.VERSION_ID
            LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON ai.SCOPE_TYPE = 'SEMANTIC_OBJECT' AND so.OBJECT_ID = ai.SCOPE_ID
            LEFT JOIN SYS_SEMANTIC.ENTITIES e
              ON ai.SCOPE_TYPE = 'ENTITY' AND e.ENTITY_ID = ai.SCOPE_ID
            LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
              ON ai.SCOPE_TYPE = 'DIMENSION' AND d.DIMENSION_ID = ai.SCOPE_ID
            LEFT JOIN SYS_SEMANTIC.FACTS f
              ON ai.SCOPE_TYPE = 'FACT' AND f.FACT_ID = ai.SCOPE_ID
            LEFT JOIN SYS_SEMANTIC.METRICS mt
              ON ai.SCOPE_TYPE = 'METRIC' AND mt.METRIC_ID = ai.SCOPE_ID
            WHERE ai.STATUS = 'ACTIVE'
              AND UPPER(m.MODEL_NAME) = UPPER({model})
            """.format(model=model),
            canonical_model_name,
        ),
    }


def compare_or_fail(name: str, expected: Any, actual: Any) -> None:
    diffs = osi.diff_json_values(expected, actual, f"$.{name}")
    if diffs:
        print(json.dumps({"diffs": diffs[:10]}, indent=2), file=sys.stderr)
        raise AssertionError(f"{name}: found {len(diffs)} normalized difference(s)")
    print(f"ok {name}: equivalent")


def strip_example_text(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.startswith("Example: "))


def document_for_supported_roundtrip_compare(document: dict[str, Any]) -> dict[str, Any]:
    prepared = json.loads(json.dumps(document))

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            ai_context = value.get("ai_context")
            if isinstance(ai_context, dict):
                ai_context.pop("examples", None)
                instructions = ai_context.get("instructions")
                if isinstance(instructions, str):
                    stripped = strip_example_text(instructions)
                    if stripped:
                        ai_context["instructions"] = stripped
                    else:
                        ai_context.pop("instructions", None)
                if not ai_context:
                    value.pop("ai_context", None)
            for nested in value.values():
                visit(nested)
        elif isinstance(value, list):
            for nested in value:
                visit(nested)

    visit(prepared)
    return prepared


def snapshot_for_supported_roundtrip_compare(snapshot: dict[str, Any]) -> dict[str, Any]:
    prepared = json.loads(json.dumps(snapshot))
    instructions = []
    for row in prepared.get("instructions", []):
        instruction_text = row.get("INSTRUCTION_TEXT")
        if isinstance(instruction_text, str) and instruction_text.startswith("Example: "):
            continue
        instructions.append(
            {
                "MODEL_NAME": row.get("MODEL_NAME"),
                "SCOPE_TYPE": row.get("SCOPE_TYPE"),
                "SCOPE_NAME": row.get("SCOPE_NAME"),
                "INSTRUCTION_TEXT": row.get("INSTRUCTION_TEXT"),
            }
        )
    prepared["instructions"] = instructions
    prepared["synonyms"] = [
        {
            "MODEL_NAME": row.get("MODEL_NAME"),
            "OBJECT_TYPE": row.get("OBJECT_TYPE"),
            "OBJECT_NAME": row.get("OBJECT_NAME"),
            "SYNONYM": row.get("SYNONYM"),
        }
        for row in prepared.get("synonyms", [])
    ]
    return prepared


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


def compile_equivalent(con, name: str, request: dict[str, Any]) -> None:
    source = dict(request, model=SOURCE_MODEL)
    target = dict(request, model=TARGET_MODEL)
    source_result = compile_request(con, source)
    target_result = compile_request(con, target)
    assert_equal(f"{name} source compile status", source_result["status"], "OK")
    assert_equal(f"{name} target compile status", target_result["status"], "OK")
    assert_equal(f"{name} generated SQL", target_result["generated_sql"], source_result["generated_sql"])
    assert_equal(f"{name} result rows", fetchall(con, target_result["generated_sql"]), fetchall(con, source_result["generated_sql"]))


def assert_batch_rollback(con, name: str, plan: dict[str, Any], model_name: str) -> None:
    osi.cleanup_imported_model(con, model_name)
    result = apply_batch(con, plan)
    assert_equal(f"{name} rollback status", result["status"], "rolled_back")
    assert_true(f"{name} diagnostic", "OSI_APPLY_040" in diagnostic_codes(result))
    assert_equal(
        f"{name} target model rows",
        scalar(con, f"SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER({sql_string(model_name)})"),
        0,
    )


def unsupported_target_failure_plan() -> dict[str, Any]:
    return {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "ok",
        "source": "<roundtrip-failure>",
        "models": [{"model_name": FAILURE_MODEL}],
        "diagnostics": [],
        "operations": [
            {
                "operation": "create_model",
                "target": "SEMANTIC_ADMIN.CREATE_MODEL",
                "source_path": "$.failure.model",
                "arguments": {
                    "model_name": FAILURE_MODEL,
                    "published_schema": "SEMANTIC_OSI_FAILURE",
                    "description": "rollback failure probe",
                },
            },
            {
                "operation": "unsupported",
                "target": "SEMANTIC_ADMIN.NO_SUCH_HELPER",
                "source_path": "$.failure.unsupported",
                "arguments": {"model_name": FAILURE_MODEL},
            },
        ],
    }


def metadata_patch_failure_plan() -> dict[str, Any]:
    return {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "ok",
        "source": "<roundtrip-patch-failure>",
        "models": [{"model_name": PATCH_FAILURE_MODEL}],
        "diagnostics": [],
        "operations": [
            {
                "operation": "create_model",
                "target": "SEMANTIC_ADMIN.CREATE_MODEL",
                "source_path": "$.failure.model",
                "arguments": {
                    "model_name": PATCH_FAILURE_MODEL,
                    "published_schema": "SEMANTIC_OSI_PATCH_FAILURE",
                    "description": "rollback patch failure probe",
                },
            },
            {
                "operation": "add_entity",
                "target": "SEMANTIC_ADMIN.ADD_ENTITY",
                "source_path": "$.failure.dataset",
                "arguments": {
                    "model_name": PATCH_FAILURE_MODEL,
                    "entity_name": "order_line",
                    "source_schema": "MART",
                    "source_object": "ORDER_LINES",
                    "source_alias": "ol",
                    "primary_key_expr": "ol.order_id",
                },
            },
            {
                "operation": "add_semantic_object",
                "target": "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT",
                "source_path": "$.failure.semantic_object",
                "arguments": {
                    "model_name": PATCH_FAILURE_MODEL,
                    "object_name": "SALES",
                    "root_entity_name": "order_line",
                    "description": "patch failure object",
                },
                "metadata": {
                    "columns": [
                        {"kind": "DIMENSION", "name": "missing_dimension", "ordinal": 1},
                    ]
                },
            },
        ],
    }


def main() -> int:
    con = connect()
    try:
        prepare_roundtrip_catalog(con)
        osi.cleanup_imported_model(con, TARGET_MODEL)

        source_document = export_lossless(con, SOURCE_MODEL)
        source_partner_payloads = collect_partner_extension_data(source_document)
        assert_true("source partner extension scopes", EXPECTED_PARTNER_PAYLOADS <= source_partner_payloads)

        source_snapshot = osi.normalize_roundtrip_value(
            snapshot_for_supported_roundtrip_compare(semantic_snapshot(con, SOURCE_MODEL, SOURCE_MODEL))
        )
        plan = make_plan(source_document, TARGET_MODEL)
        assert_equal("round-trip import plan status", plan["status"], "ok")
        assert_equal("round-trip import plan diagnostics", plan["diagnostics"], [])

        script_mode = osi.apply_import_plan(
            None,
            plan,
            osi.ImportApplyOptions(
                collision_policy="replace_draft",
                rollback_on_failure=True,
                validate_after_apply=True,
                warnings_as_errors=True,
                apply_mode="script",
            ),
        )
        assert_equal("script-mode compatibility status", script_mode["status"], "blocked")
        assert_true("script-mode expected loss diagnostics", "OSI_IMPORT_120" in diagnostic_codes(script_mode))

        result = apply_batch(con, plan)
        assert_equal("round-trip batch apply status", result["status"], "ok")
        assert_equal("round-trip batch diagnostics", result["diagnostics"], [])
        assert_true("round-trip batch validation id", result["validation_run_id"] is not None)

        imported_document = export_lossless(con, TARGET_MODEL)
        imported_partner_payloads = collect_partner_extension_data(imported_document)
        assert_equal("partner extension data round-trip", imported_partner_payloads, source_partner_payloads)

        source_normalized = osi.normalize_osi_roundtrip_document(
            document_for_supported_roundtrip_compare(source_document),
            SOURCE_MODEL,
        )
        imported_normalized = osi.normalize_osi_roundtrip_document(
            document_for_supported_roundtrip_compare(imported_document),
            SOURCE_MODEL,
        )
        compare_or_fail("osi_document", source_normalized, imported_normalized)

        imported_snapshot = osi.normalize_roundtrip_value(
            snapshot_for_supported_roundtrip_compare(semantic_snapshot(con, TARGET_MODEL, SOURCE_MODEL))
        )
        compare_or_fail("semantic_snapshot", source_snapshot, imported_snapshot)

        compile_equivalent(
            con,
            "completed revenue by region",
            {
                "object": "SALES",
                "metrics": ["completed_revenue"],
                "dimensions": ["customer_region"],
                "order_by": [{"field": "completed_revenue", "direction": "desc"}],
                "limit": 2,
                "purpose": "osi_roundtrip_completed_revenue",
                "client": "verify_osi_roundtrip",
            },
        )
        compile_equivalent(
            con,
            "revenue by product category",
            {
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["product_category"],
                "order_by": [{"field": "total_revenue", "direction": "desc"}],
                "limit": 2,
                "purpose": "osi_roundtrip_product_revenue",
                "client": "verify_osi_roundtrip",
            },
        )

        assert_batch_rollback(con, "unsupported target", unsupported_target_failure_plan(), FAILURE_MODEL)
        assert_batch_rollback(con, "metadata patch failure", metadata_patch_failure_plan(), PATCH_FAILURE_MODEL)
    finally:
        con.close()
    print("ok OSI round-trip verifier")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
