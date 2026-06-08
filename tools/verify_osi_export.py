#!/usr/bin/env python3
"""Verify OSI export support on Exasol Nano."""

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


def extension_data(extensions: list[dict[str, str]], vendor_name: str) -> list[dict[str, Any]]:
    result = []
    for extension in extensions:
        if extension["vendor_name"] == vendor_name:
            result.append(json.loads(extension["data"]))
    return result


def prepare_catalog(con) -> None:
    con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
        "'sales', 'order', 'order_order_id_key', 'PRIMARY', 'Order primary key', 'OSI')"
    ).fetchall()
    con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
        "'sales', 'order', 'order_order_id_key', 'order_id', NULL, 1)"
    ).fetchall()
    con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
        "'sales', 'ENTITY', 'order', 'PARTNER_VENDOR', '{\"opaque\":true}', 'OSI', 'roundtrip')"
    ).fetchall()


def dataset_by_name(document: dict[str, Any], name: str) -> dict[str, Any]:
    for dataset in document["semantic_model"][0]["datasets"]:
        if dataset["name"] == name:
            return dataset
    raise AssertionError(f"dataset not found: {name}")


def relationship_by_name(document: dict[str, Any], name: str) -> dict[str, Any]:
    for relationship in document["semantic_model"][0].get("relationships", []):
        if relationship["name"] == name:
            return relationship
    raise AssertionError(f"relationship not found: {name}")


def metric_by_name(document: dict[str, Any], name: str) -> dict[str, Any]:
    for metric in document["semantic_model"][0].get("metrics", []):
        if metric["name"] == name:
            return metric
    raise AssertionError(f"metric not found: {name}")


def main() -> int:
    con = connect()
    try:
        prepare_catalog(con)
        interop, interop_warnings = osi.export_model(
            con,
            osi.ExportOptions(model_name="sales", object_name="SALES", profile="interoperability"),
        )
        lossless, lossless_warnings = osi.export_model(
            con,
            osi.ExportOptions(model_name="sales", object_name=None, profile="lossless"),
        )
    finally:
        con.close()

    osi.validate_document(interop)
    osi.validate_document(lossless)
    assert_equal("interop version", interop["version"], "0.2.0.dev0")
    assert_equal("lossless version", lossless["version"], "0.2.0.dev0")
    assert_no_warnings("interop warnings", interop_warnings)
    assert_no_warnings("lossless warnings", lossless_warnings)

    order = dataset_by_name(interop, "order")
    assert_equal("order primary key", order.get("primary_key"), ["order_id"])
    partner_extensions = [ext for ext in order["custom_extensions"] if ext["vendor_name"] == "PARTNER_VENDOR"]
    assert_equal("non-Exasol extension count", len(partner_extensions), 1)
    assert_equal("non-Exasol extension data preserved", partner_extensions[0]["data"], '{"opaque":true}')

    order_line = dataset_by_name(interop, "order_line")
    assert_equal("composite primary key extraction", order_line.get("primary_key"), ["order_id", "line_id"])

    relationship = relationship_by_name(interop, "order_line_to_order")
    assert_equal("relationship from columns", relationship["from_columns"], ["order_id"])
    assert_equal("relationship to columns", relationship["to_columns"], ["order_id"])

    total_revenue = metric_by_name(interop, "total_revenue")
    assert_equal("metric synonym export", total_revenue["ai_context"]["synonyms"], ["revenue", "sales"])

    model_extensions = extension_data(lossless["semantic_model"][0]["custom_extensions"], "EXASOL")
    assert_true("lossless model extension", bool(model_extensions))
    semantic_objects = model_extensions[0].get("semantic_objects", [])
    assert_true("lossless semantic objects preserved", any(item["object_name"] == "SALES" for item in semantic_objects))

    json.loads(osi.dump_json(interop))
    try:
        yaml_text = osi.dump_yaml(interop)
    except osi.OsiError:
        print("ok yaml version quoted: skipped (PyYAML unavailable)")
    else:
        assert_true("yaml version quoted", yaml_text.startswith('version: "0.2.0.dev0"'))
    print("ok OSI export verifier")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
