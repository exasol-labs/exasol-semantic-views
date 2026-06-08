#!/usr/bin/env python3
"""Lightweight tests for tools/osi.py without requiring Exasol."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OSI_PATH = ROOT / "tools/osi.py"

spec = importlib.util.spec_from_file_location("osi_tool", OSI_PATH)
osi = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
assert spec.loader is not None
sys.modules[spec.name] = osi
spec.loader.exec_module(osi)

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None


def load_fixture(path: Path) -> dict:
    if yaml is None:
        raise RuntimeError("PyYAML unavailable")
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def test_fixtures_validate() -> None:
    if yaml is None:
        document = {
            "version": "0.2.0.dev0",
            "semantic_model": [
                {
                    "name": "json_only",
                    "datasets": [{"name": "orders", "source": "MART.ORDERS"}],
                }
            ],
        }
        osi.validate_document(document)
        return
    for path in sorted((ROOT / "tests/fixtures/osi").glob("*.yaml")):
        document = load_fixture(path)
        osi.validate_document(document)


def test_invalid_version_fails() -> None:
    if yaml is None:
        document = {
            "version": "0.2.0.dev0",
            "semantic_model": [
                {
                    "name": "json_only",
                    "datasets": [{"name": "orders", "source": "MART.ORDERS"}],
                }
            ],
        }
    else:
        document = load_fixture(ROOT / "tests/fixtures/osi/minimal_model.yaml")
    document["version"] = "0.1.1"
    try:
        osi.validate_document(document)
    except osi.OsiValidationError as exc:
        assert any("$.version" in error for error in exc.errors)
    else:
        raise AssertionError("expected invalid version to fail")


def test_custom_extension_data_must_parse() -> None:
    if yaml is None:
        document = {
            "version": "0.2.0.dev0",
            "semantic_model": [
                {
                    "name": "json_only",
                    "datasets": [{"name": "orders", "source": "MART.ORDERS"}],
                    "custom_extensions": [{"vendor_name": "EXASOL", "data": "{}"}],
                }
            ],
        }
    else:
        document = load_fixture(ROOT / "tests/fixtures/osi/minimal_model.yaml")
    document["semantic_model"][0]["custom_extensions"][0]["data"] = "{not-json"
    try:
        osi.validate_document(document)
    except osi.OsiValidationError as exc:
        assert any("data must parse as JSON" in error for error in exc.errors)
    else:
        raise AssertionError("expected invalid extension JSON to fail")


def test_key_expression_column_extraction() -> None:
    expression = "CAST(ol.order_id AS VARCHAR(36)) || '-' || CAST(ol.line_id AS VARCHAR(36))"
    assert osi.simple_key_columns(expression, "ol") == ["order_id", "line_id"]
    assert osi.simple_key_columns("o.order_id", "o") == ["order_id"]


def test_relationship_parser() -> None:
    relationship = {
        "FROM_ENTITY_NAME": "order_line",
        "TO_ENTITY_NAME": "order",
        "JOIN_CONDITION": "ol.order_id = o.order_id AND ol.line_id = o.line_id",
    }
    entities = {
        "order_line": {"SOURCE_ALIAS": "ol"},
        "order": {"SOURCE_ALIAS": "o"},
    }
    assert osi.parse_relationship_columns(relationship, entities) == (
        ["order_id", "line_id"],
        ["order_id", "line_id"],
    )


def plan_document(
    document: dict[str, Any],
    *,
    strict: bool = False,
    profile: str = "auto",
    warnings_as_errors: bool = False,
) -> dict[str, Any]:
    return osi.plan_import(
        document,
        osi.ImportOptions(profile=profile, strict=strict, warnings_as_errors=warnings_as_errors, source="<test>"),
    )


def operation(plan: dict[str, Any], operation_name: str, object_name: str | None = None) -> dict[str, Any]:
    for item in plan["operations"]:
        if item["operation"] != operation_name:
            continue
        args = item["arguments"]
        if object_name is None or object_name in {
            args.get("relationship_name"),
            args.get("dimension_name"),
            args.get("fact_name"),
            args.get("metric_name"),
            args.get("entity_name"),
            args.get("object_name"),
        }:
            return item
    raise AssertionError(f"operation not found: {operation_name} {object_name}")


def diagnostic_codes(plan: dict[str, Any]) -> set[str]:
    return {item["code"] for item in plan["diagnostics"]}


def test_import_plan_json_core_without_yaml_dependency() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "json_only",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "primary_key": ["order_id"],
                        "fields": [
                            {
                                "name": "order_status",
                                "expression": {"dialects": [{"dialect": "ANSI_SQL", "expression": "orders.order_status"}]},
                                "dimension": {},
                            }
                        ],
                    }
                ],
                "metrics": [
                    {
                        "name": "order_count",
                        "expression": {"dialects": [{"dialect": "ANSI_SQL", "expression": "COUNT(order_status)"}]},
                    }
                ],
            }
        ],
    }
    plan = plan_document(document)
    assert plan["status"] == "ok"
    assert operation(plan, "create_model")["arguments"]["model_name"] == "json_only"
    assert operation(plan, "add_entity", "orders")["arguments"]["source_alias"] == "orders"
    assert operation(plan, "add_dimension", "order_status")["arguments"]["data_type"] == "VARCHAR(2000000)"
    assert {"OSI_IMPORT_020", "OSI_IMPORT_030"} <= diagnostic_codes(plan)


def test_import_plan_minimal_fixture() -> None:
    if yaml is None:
        return
    plan = plan_document(load_fixture(ROOT / "tests/fixtures/osi/minimal_model.yaml"), strict=True)
    assert plan["status"] == "ok"
    assert operation(plan, "create_model")["arguments"]["published_schema"] == "SEMANTIC_MINIMAL_SALES"
    assert operation(plan, "add_unique_key", "orders")["arguments"]["key_kind"] == "PRIMARY"
    assert operation(plan, "add_dimension", "order_status")["arguments"]["data_type"] == "VARCHAR(32)"
    metric = operation(plan, "add_metric", "order_count")
    assert metric["arguments"]["metric_type"] == "ADDITIVE"
    assert metric["metadata"]["metric_kind"] == "SIMPLE"


def test_import_plan_warnings_as_errors_blocks() -> None:
    if yaml is None:
        return
    plan = plan_document(
        load_fixture(ROOT / "tests/fixtures/osi/minimal_model.yaml"),
        warnings_as_errors=True,
    )
    assert plan["status"] == "blocked"
    assert ("OSI_IMPORT_120", "ERROR") in {(item["code"], item["severity"]) for item in plan["diagnostics"]}


def test_import_plan_missing_datatype_strict_blocks() -> None:
    if yaml is None:
        return
    plan = plan_document(load_fixture(ROOT / "tests/fixtures/osi/missing_datatype.yaml"), strict=True)
    assert plan["status"] == "blocked"
    errors = {item["code"] for item in plan["diagnostics"] if item["severity"] == "ERROR"}
    assert "OSI_IMPORT_030" in errors


def test_import_plan_complex_relationship_prefers_native_join_condition() -> None:
    if yaml is None:
        return
    plan = plan_document(load_fixture(ROOT / "tests/fixtures/osi/complex_relationship.yaml"), strict=True)
    assert plan["status"] == "ok"
    relationship = operation(plan, "add_relationship", "order_line_to_customer_history")
    assert relationship["arguments"]["join_condition"] == (
        "ol.customer_id = ch.customer_id AND ol.order_date >= ch.valid_from AND ol.order_date < ch.valid_to"
    )
    assert relationship["metadata"]["requires_native_join_condition"] is True


def test_import_plan_lossless_preserves_native_metadata() -> None:
    if yaml is None:
        return
    plan = plan_document(load_fixture(ROOT / "tests/fixtures/osi/sales_lossless.yaml"), strict=True)
    assert plan["status"] == "ok"
    assert plan["models"][0]["profile"] == "lossless"
    net_revenue = operation(plan, "add_fact", "net_revenue")
    assert net_revenue["metadata"]["object_columns"] == [{"object_name": "SALES", "ordinal": 5}]
    total_revenue = operation(plan, "add_metric", "total_revenue")
    assert total_revenue["metadata"]["native"]["metric_kind"] == "SIMPLE"
    assert "filter_expr" not in total_revenue["arguments"]


def test_invalid_exasol_extension_envelope_blocks_import_plan() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "bad_extension",
                "datasets": [{"name": "orders", "source": "MART.ORDERS"}],
                "custom_extensions": [
                    {
                        "vendor_name": "EXASOL",
                        "data": json.dumps({"published_schema": "SEMANTIC_BAD", "semantic_objects": {"bad": True}}),
                    }
                ],
            }
        ],
    }
    plan = plan_document(document, strict=True)
    assert plan["status"] == "blocked"
    assert "OSI_IMPORT_100" in diagnostic_codes(plan)


def main() -> int:
    test_fixtures_validate()
    test_invalid_version_fails()
    test_custom_extension_data_must_parse()
    test_key_expression_column_extraction()
    test_relationship_parser()
    test_import_plan_json_core_without_yaml_dependency()
    test_import_plan_minimal_fixture()
    test_import_plan_warnings_as_errors_blocks()
    test_import_plan_missing_datatype_strict_blocks()
    test_import_plan_complex_relationship_prefers_native_join_condition()
    test_import_plan_lossless_preserves_native_metadata()
    test_invalid_exasol_extension_envelope_blocks_import_plan()
    print("ok osi tool tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
