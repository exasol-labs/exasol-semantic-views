#!/usr/bin/env python3
"""Lightweight tests for tools/osi.py without requiring Exasol."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


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


def main() -> int:
    test_fixtures_validate()
    test_invalid_version_fails()
    test_custom_extension_data_must_parse()
    test_key_expression_column_extraction()
    test_relationship_parser()
    print("ok osi tool tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
