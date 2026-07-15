#!/usr/bin/env python3
"""Lightweight tests for tools/osi.py without requiring Exasol."""

from __future__ import annotations

import builtins
import importlib.util
import json
import sys
import tempfile
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


def test_sales_osi_example_matches_interoperability_fixture() -> None:
    example = (ROOT / "sql/examples/sales_osi.yaml").read_text(encoding="utf-8")
    fixture = (ROOT / "tests/fixtures/osi/sales_interoperability.yaml").read_text(encoding="utf-8")
    assert example == fixture


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


def test_allowed_dialects_come_from_schema() -> None:
    schema = json.loads(osi.OSI_SCHEMA.read_text(encoding="utf-8"))
    schema_dialects = set(schema["$defs"]["Dialect"]["enum"])
    assert "BIGQUERY" in schema_dialects
    assert osi.allowed_osi_dialects() == schema_dialects


def test_bigquery_dialect_validates() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "bigquery_model",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "fields": [
                            {
                                "name": "order_status",
                                "expression": {"dialects": [{"dialect": "BIGQUERY", "expression": "order_status"}]},
                            }
                        ],
                    }
                ],
            }
        ],
    }
    osi.validate_document(document)


def test_json_load_works_when_pyyaml_unavailable() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [{"name": "json_only", "datasets": [{"name": "orders", "source": "MART.ORDERS"}]}],
    }
    real_import = builtins.__import__

    def fake_import(name: str, *args: Any, **kwargs: Any) -> Any:
        if name == "yaml":
            raise ImportError("blocked by test")
        return real_import(name, *args, **kwargs)

    with tempfile.TemporaryDirectory() as directory:
        json_path = Path(directory) / "model.json"
        yaml_path = Path(directory) / "model.yaml"
        json_path.write_text(json.dumps(document), encoding="utf-8")
        yaml_path.write_text("version: 0.2.0.dev0\nsemantic_model: []\n", encoding="utf-8")
        builtins.__import__ = fake_import
        try:
            assert osi.load_document(json_path) == document
            try:
                osi.load_document(yaml_path)
            except osi.OsiError as exc:
                assert "PyYAML is required" in str(exc)
            else:
                raise AssertionError("expected YAML load to require PyYAML")
            try:
                osi.dump_yaml(document)
            except osi.OsiError as exc:
                assert "PyYAML is required" in str(exc)
            else:
                raise AssertionError("expected YAML dump to require PyYAML")
        finally:
            builtins.__import__ = real_import


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


def test_rich_yaml_fixtures_have_json_planning_parity() -> None:
    if yaml is None:
        return
    for fixture_name in [
        "minimal_model.yaml",
        "sales_lossless.yaml",
        "complex_relationship.yaml",
        "missing_datatype.yaml",
        "invalid_relationship.yaml",
    ]:
        yaml_document = load_fixture(ROOT / f"tests/fixtures/osi/{fixture_name}")
        json_document = json.loads(json.dumps(yaml_document))
        assert plan_document(json_document, strict=True) == plan_document(yaml_document, strict=True)


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


def test_import_plan_invalid_relationship_fixture_fails_stably() -> None:
    if yaml is None:
        return
    plan = plan_document(load_fixture(ROOT / "tests/fixtures/osi/invalid_relationship.yaml"), strict=True)
    assert plan["status"] == "blocked"
    errors = {(item["code"], item["path"]) for item in plan["diagnostics"] if item["severity"] == "ERROR"}
    assert ("OSI_IMPORT_060", "$.semantic_model[0].relationships[0]") in errors


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


def test_import_plan_bigquery_dialect_fallback_warns_and_strict_blocks() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "dialect_model",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "custom_extensions": [
                            {
                                "vendor_name": "EXASOL",
                                "data": json.dumps(
                                    {
                                        "entity_name": "orders",
                                        "source_schema": "MART",
                                        "source_object": "ORDERS",
                                        "source_alias": "o",
                                    }
                                ),
                            }
                        ],
                        "fields": [
                            {
                                "name": "order_status",
                                "expression": {"dialects": [{"dialect": "BIGQUERY", "expression": "o.order_status"}]},
                                "dimension": {},
                                "custom_extensions": [
                                    {
                                        "vendor_name": "EXASOL",
                                        "data": json.dumps(
                                            {
                                                "field_kind": "DIMENSION",
                                                "entity_name": "orders",
                                                "data_type": "VARCHAR(32)",
                                            }
                                        ),
                                    }
                                ],
                            }
                        ],
                    }
                ],
            }
        ],
    }
    plan = plan_document(document, strict=False)
    assert plan["status"] == "ok"
    assert ("OSI_IMPORT_070", "WARNING") in {(item["code"], item["severity"]) for item in plan["diagnostics"]}
    assert operation(plan, "add_dimension", "order_status")["arguments"]["expression"] == "o.order_status"

    strict_plan = plan_document(document, strict=True)
    assert strict_plan["status"] == "blocked"
    assert ("OSI_IMPORT_070", "ERROR") in {(item["code"], item["severity"]) for item in strict_plan["diagnostics"]}


def test_import_plan_native_key_extension_precedes_core_keys() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "native_key_model",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "primary_key": ["core_order_id"],
                        "custom_extensions": [
                            {
                                "vendor_name": "EXASOL",
                                "data": json.dumps(
                                    {
                                        "entity_name": "orders",
                                        "source_schema": "MART",
                                        "source_object": "ORDERS",
                                        "source_alias": "o",
                                        "unique_keys": [
                                            {
                                                "key_name": "native_orders_key",
                                                "key_kind": "PRIMARY",
                                                "source_format": "OSI",
                                                "columns": [
                                                    {
                                                        "ordinal": 1,
                                                        "expression": "CAST(o.order_id AS VARCHAR(36))",
                                                    }
                                                ],
                                            }
                                        ],
                                    }
                                ),
                            }
                        ],
                    }
                ],
            }
        ],
    }
    plan = plan_document(document, strict=True)
    assert plan["status"] == "ok"
    key_operations = [item for item in plan["operations"] if item["operation"] == "add_unique_key"]
    assert [item["arguments"]["key_name"] for item in key_operations] == ["native_orders_key"]
    key_column = operation(plan, "add_unique_key_column")["arguments"]
    assert key_column["key_name"] == "native_orders_key"
    assert key_column.get("column_name") is None
    assert key_column["expression"] == "CAST(o.order_id AS VARCHAR(36))"


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


def test_import_plan_assigns_distinct_names_to_repeated_non_exasol_extensions() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "extension_model",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "custom_extensions": [
                            {
                                "vendor_name": "EXASOL",
                                "data": json.dumps(
                                    {
                                        "entity_name": "orders",
                                        "source_schema": "MART",
                                        "source_object": "ORDERS",
                                        "source_alias": "o",
                                    }
                                ),
                            },
                            {"vendor_name": "PARTNER_VENDOR", "data": '{"first":true}'},
                            {"vendor_name": "PARTNER_VENDOR", "data": '{"second":true}'},
                        ],
                    }
                ],
            }
        ],
    }
    plan = plan_document(document, strict=True)
    extension_names = [
        item["arguments"]["extension_name"]
        for item in plan["operations"]
        if item["operation"] == "add_custom_extension" and item["arguments"]["vendor_name"] == "PARTNER_VENDOR"
    ]
    assert extension_names == ["osi_2", "osi_3"]


def test_import_plan_preserves_raw_semantic_object_extensions() -> None:
    document = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "semantic_object_extension_model",
                "datasets": [
                    {
                        "name": "orders",
                        "source": "MART.ORDERS",
                        "custom_extensions": [
                            {
                                "vendor_name": "EXASOL",
                                "data": json.dumps(
                                    {
                                        "entity_name": "orders",
                                        "source_schema": "MART",
                                        "source_object": "ORDERS",
                                        "source_alias": "o",
                                    }
                                ),
                            }
                        ],
                    }
                ],
                "custom_extensions": [
                    {
                        "vendor_name": "EXASOL",
                        "data": json.dumps(
                            {
                                "semantic_objects": [
                                    {
                                        "object_name": "ORDERS",
                                        "root_entity": "orders",
                                        "custom_extensions": [
                                            {"vendor_name": "EXASOL", "data": '{"scope":"semantic_object"}'},
                                            {"vendor_name": "PARTNER_VENDOR", "data": '{"opaque":true}'},
                                        ],
                                    }
                                ]
                            }
                        ),
                    }
                ],
            }
        ],
    }
    plan = plan_document(document, strict=True)
    extensions = [
        item["arguments"]
        for item in plan["operations"]
        if item["operation"] == "add_custom_extension" and item["arguments"]["scope_type"] == "SEMANTIC_OBJECT"
    ]
    assert extensions == [
        {
            "model_name": "semantic_object_extension_model",
            "scope_type": "SEMANTIC_OBJECT",
            "scope_name": "ORDERS",
            "vendor_name": "EXASOL",
            "data_json": '{"scope":"semantic_object"}',
            "source_format": "OSI",
            "extension_name": "osi_1",
        },
        {
            "model_name": "semantic_object_extension_model",
            "scope_type": "SEMANTIC_OBJECT",
            "scope_name": "ORDERS",
            "vendor_name": "PARTNER_VENDOR",
            "data_json": '{"opaque":true}',
            "source_format": "OSI",
            "extension_name": "osi_2",
        },
    ]


def minimal_export_catalog() -> dict[str, Any]:
    return {
        "model": {
            "MODEL_ID": 1,
            "MODEL_NAME": "warning_model",
            "DESCRIPTION": "Warning model",
            "PUBLISHED_SCHEMA": "SEMANTIC_WARNING_MODEL",
            "OWNER_ROLE": None,
        },
        "entities": [
            {
                "ENTITY_ID": 10,
                "ENTITY_NAME": "orders",
                "SOURCE_SCHEMA": "MART",
                "SOURCE_OBJECT": "ORDERS",
                "SOURCE_ALIAS": "o",
                "PRIMARY_KEY_EXPR": None,
                "GRAIN_DESCRIPTION": None,
                "DESCRIPTION": "Orders",
            },
            {
                "ENTITY_ID": 11,
                "ENTITY_NAME": "customers",
                "SOURCE_SCHEMA": "MART",
                "SOURCE_OBJECT": "CUSTOMERS",
                "SOURCE_ALIAS": "c",
                "PRIMARY_KEY_EXPR": "c.customer_id",
                "GRAIN_DESCRIPTION": None,
                "DESCRIPTION": "Customers",
            },
        ],
        "relationships": [
            {
                "RELATIONSHIP_ID": 20,
                "RELATIONSHIP_NAME": "orders_to_customers_complex",
                "FROM_ENTITY_NAME": "orders",
                "TO_ENTITY_NAME": "customers",
                "JOIN_CONDITION": "o.customer_id = c.customer_id AND o.order_date >= c.valid_from",
                "RELATIONSHIP_CARDINALITY": "MANY_TO_ONE",
                "JOIN_TYPE": "LEFT",
                "FANOUT_POLICY": None,
                "PATH_PRIORITY": 100,
                "DESCRIPTION": None,
            }
        ],
        "dimensions": [],
        "facts": [
            {
                "FACT_ID": 30,
                "FACT_NAME": "private_amount",
                "ENTITY_NAME": "orders",
                "EXPRESSION": "o.amount",
                "DATA_TYPE": "DECIMAL(18,2)",
                "ADDITIVE_POLICY": "ADDITIVE",
                "DISPLAY_NAME": None,
                "FORMAT_HINT": None,
                "UNIT_HINT": None,
                "SENSITIVITY_LABEL": None,
                "DISPLAY_POLICY": None,
                "IS_PRIVATE": True,
                "IS_CERTIFIED": False,
                "DESCRIPTION": None,
            }
        ],
        "metrics": [
            {
                "METRIC_ID": 40,
                "METRIC_NAME": "private_revenue",
                "BASE_ENTITY_NAME": "orders",
                "EXPRESSION": "SUM(private_amount)",
                "DATA_TYPE": "DECIMAL(18,2)",
                "METRIC_TYPE": "ADDITIVE",
                "METRIC_KIND": "SIMPLE",
                "AGGREGATION_FUNCTION": "SUM",
                "MEASURE_EXPR": "private_amount",
                "SEMANTIC_FILTER_EXPR": None,
                "SQL_FILTER_EXPR": None,
                "DISTINCT_KEY_EXPR": None,
                "NON_ADDITIVE_DIMENSION_NAME": None,
                "WINDOW_SPEC_JSON": None,
                "TYPE_PARAMS_JSON": None,
                "FORMAT_HINT": None,
                "UNIT_HINT": None,
                "DISPLAY_NAME": None,
                "SENSITIVITY_LABEL": None,
                "DISPLAY_POLICY": None,
                "OWNER_ROLE": None,
                "IS_PRIVATE": True,
                "IS_CERTIFIED": False,
                "DESCRIPTION": None,
            }
        ],
        "custom_extensions": [],
        "synonyms": [],
        "instructions": [],
        "object_columns": [],
        "unique_keys": [
            {
                "UNIQUE_KEY_ID": 50,
                "ENTITY_NAME": "orders",
                "KEY_NAME": "orders_expr_key",
                "KEY_KIND": "PRIMARY",
                "DESCRIPTION": None,
                "SOURCE_FORMAT": "OSI",
            }
        ],
        "unique_key_columns": [
            {
                "UNIQUE_KEY_ID": 50,
                "ORDINAL_POSITION": 1,
                "COLUMN_NAME": None,
                "EXPRESSION": "CAST(o.order_id AS VARCHAR(36))",
            }
        ],
        "semantic_objects": [],
        "verified_queries": [],
    }


def test_export_warning_generation_for_lossy_interoperability_cases() -> None:
    document, warnings = osi.build_document(
        minimal_export_catalog(),
        osi.ExportOptions(model_name="warning_model", object_name=None, profile="interoperability"),
    )
    assert {item["code"] for item in warnings} == {
        "OSI_EXPORT_020",
        "OSI_EXPORT_021",
        "OSI_EXPORT_030",
        "OSI_EXPORT_040",
    }
    model = document["semantic_model"][0]
    assert "relationships" not in model
    assert "metrics" not in model
    assert all("fields" not in dataset for dataset in model["datasets"])
    orders = next(dataset for dataset in model["datasets"] if dataset["name"] == "orders")
    assert "primary_key" not in orders
    orders_extension = json.loads(orders["custom_extensions"][0]["data"])
    assert orders_extension["unique_keys"][0]["columns"] == [
        {"ordinal": 1, "expression": "CAST(o.order_id AS VARCHAR(36))"}
    ]


def test_operation_sql_renders_missing_optional_arguments_as_null() -> None:
    operation_item = {
        "operation": "add_unique_key_column",
        "target": "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN",
        "source_path": "$.test",
        "arguments": {
            "model_name": "sales_osi",
            "entity_name": "orders",
            "key_name": "orders_primary_key",
            "column_name": "order_id",
            "ordinal_position": 1,
        },
    }
    assert osi.render_operation_sql(operation_item) == (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
        "'sales_osi', 'orders', 'orders_primary_key', 'order_id', NULL, 1)"
    )


def test_execute_rows_or_empty_accepts_no_result_script_calls() -> None:
    class NoResultStatement:
        def fetchall(self) -> list[Any]:
            raise RuntimeError("Attempt to fetch from statement without result set")

    class FakeConnection:
        def execute(self, sql: str) -> NoResultStatement:
            assert sql == "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('x')"
            return NoResultStatement()

    assert osi.execute_rows_or_empty(FakeConnection(), "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('x')") == []


def test_apply_refuses_blocked_plan_without_database_connection() -> None:
    blocked_plan = {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "blocked",
        "source": "<test>",
        "models": [{"model_name": "blocked_model"}],
        "diagnostics": [{"code": "OSI_IMPORT_030", "severity": "ERROR", "path": "$", "message": "blocked"}],
        "operations": [],
    }
    result = osi.apply_import_plan(
        None,
        blocked_plan,
        osi.ImportApplyOptions(
            collision_policy="fail",
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=False,
        ),
    )
    assert result["status"] == "blocked"
    assert "OSI_APPLY_001" in diagnostic_codes(result)


def test_apply_metadata_warnings_can_block_before_database_connection() -> None:
    plan = {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "ok",
        "source": "<test>",
        "models": [{"model_name": "lossy_model"}],
        "diagnostics": [],
        "operations": [
            {
                "operation": "add_fact",
                "target": "SEMANTIC_ADMIN.ADD_FACT",
                "source_path": "$.fact",
                "arguments": {
                    "model_name": "lossy_model",
                    "entity_name": "orders",
                    "fact_name": "net_revenue",
                    "expression": "o.amount",
                    "data_type": "DECIMAL(18,2)",
                    "additive_policy": "ADDITIVE",
                },
                "metadata": {"object_columns": [{"object_name": "ORDERS", "ordinal": 1, "is_visible": False}]},
            }
        ],
    }
    result = osi.apply_import_plan(
        None,
        plan,
        osi.ImportApplyOptions(
            collision_policy="fail",
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=True,
        ),
    )
    assert result["status"] == "blocked"
    assert ("OSI_IMPORT_120", "ERROR") in {(item["code"], item["severity"]) for item in result["diagnostics"]}


def test_validation_warnings_as_errors_blocks_apply() -> None:
    class FakeStatement:
        def __init__(self, columns: list[str], rows: list[tuple[Any, ...]]) -> None:
            self._columns = columns
            self._rows = rows

        def description(self) -> list[tuple[str]]:
            return [(column,) for column in self._columns]

        def fetchall(self) -> list[tuple[Any, ...]]:
            return self._rows

    class FakeConnection:
        def execute(self, sql: str) -> FakeStatement:
            if "FROM SYS_SEMANTIC.MODELS" in sql:
                return FakeStatement(["MODEL_NAME", "STATUS"], [])
            if "SEMANTIC_ADMIN.VALIDATE_MODEL" in sql:
                return FakeStatement(
                    ["SEVERITY", "OBJECT_NAME", "OBJECT_TYPE", "RULE_CODE", "MESSAGE"],
                    [("WARNING", "total_revenue", "METRIC", "SEMANTIC_MODEL_999", "soft validation warning")],
                )
            raise AssertionError(f"unexpected SQL: {sql}")

    plan = {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "ok",
        "source": "<test>",
        "models": [{"model_name": "validation_warning_model"}],
        "diagnostics": [],
        "operations": [],
    }
    result = osi.apply_import_plan(
        FakeConnection(),
        plan,
        osi.ImportApplyOptions(
            collision_policy="fail",
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=True,
        ),
    )
    assert result["status"] == "rolled_back"
    assert ("OSI_APPLY_030", "ERROR") in {(item["code"], item["severity"]) for item in result["diagnostics"]}


def test_invalid_apply_mode_blocks_before_database_connection() -> None:
    plan = {
        "version": "0.2.0.dev0",
        "mode": "dry-run",
        "status": "ok",
        "source": "<test>",
        "models": [{"model_name": "mode_model"}],
        "diagnostics": [],
        "operations": [],
    }
    result = osi.apply_import_plan(
        None,
        plan,
        osi.ImportApplyOptions(
            collision_policy="fail",
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=False,
            apply_mode="bogus",
        ),
    )
    assert result["status"] == "blocked"
    assert "OSI_APPLY_002" in diagnostic_codes(result)


def test_batch_warning_json_decodes_to_diagnostics() -> None:
    rows = [
        {
            "STATUS": "OK",
            "WARNING_JSON": json.dumps(
                [
                    {
                        "code": "OSI_APPLY_030",
                        "severity": "WARNING",
                        "path": "metric",
                        "message": "validation warning",
                    }
                ]
            ),
        }
    ]
    diagnostics = osi.decode_batch_warning_diagnostics(rows)
    assert diagnostics == [
        {
            "code": "OSI_APPLY_030",
            "severity": "WARNING",
            "path": "metric",
            "message": "validation warning",
        }
    ]


def test_roundtrip_document_normalization_is_order_stable() -> None:
    left = {
        "version": "0.2.0.dev0",
        "semantic_model": [
            {
                "name": "sales",
                "datasets": [
                    {"name": "order", "source": "MART.ORDERS"},
                    {"name": "customer", "source": "MART.CUSTOMERS"},
                ],
                "custom_extensions": [
                    {"vendor_name": "PARTNER_VENDOR", "data": '{"b":2,"a":1}'},
                    {
                        "vendor_name": "EXASOL",
                        "data": json.dumps(
                            {
                                "semantic_objects": [
                                    {
                                        "object_name": "SALES",
                                        "root_entity": "order",
                                        "columns": [
                                            {"kind": "METRIC", "name": "total_revenue", "ordinal": 2},
                                            {"kind": "DIMENSION", "name": "customer_region", "ordinal": 1},
                                        ],
                                    }
                                ]
                            }
                        ),
                    },
                ],
            }
        ],
    }
    right = {
        "semantic_model": [
            {
                "custom_extensions": [
                    {
                        "data": json.dumps(
                            {
                                "semantic_objects": [
                                    {
                                        "columns": [
                                            {"name": "customer_region", "ordinal": 1, "kind": "DIMENSION"},
                                            {"name": "total_revenue", "ordinal": 2, "kind": "METRIC"},
                                        ],
                                        "root_entity": "order",
                                        "object_name": "SALES",
                                    }
                                ]
                            },
                            separators=(",", ":"),
                        ),
                        "vendor_name": "EXASOL",
                    },
                    {"data": '{"a":1,"b":2}', "vendor_name": "PARTNER_VENDOR"},
                ],
                "datasets": [
                    {"source": "MART.CUSTOMERS", "name": "customer"},
                    {"source": "MART.ORDERS", "name": "order"},
                ],
                "name": "sales_osi_roundtrip",
            }
        ],
        "version": "0.2.0.dev0",
    }
    assert osi.normalize_osi_roundtrip_document(left, "sales") == osi.normalize_osi_roundtrip_document(right, "sales")


def test_diff_json_values_reports_stable_paths() -> None:
    diffs = osi.diff_json_values(
        {"semantic_model": [{"name": "sales", "datasets": [{"name": "orders"}]}]},
        {"semantic_model": [{"name": "sales", "datasets": [{"name": "customers"}]}]},
    )
    assert diffs == [
        {
            "code": "OSI_ROUNDTRIP_001",
            "severity": "ERROR",
            "path": "$.semantic_model[0].datasets[0].name",
            "message": 'Value mismatch: expected "orders", got "customers".',
        }
    ]


def main() -> int:
    test_fixtures_validate()
    test_sales_osi_example_matches_interoperability_fixture()
    test_invalid_version_fails()
    test_custom_extension_data_must_parse()
    test_allowed_dialects_come_from_schema()
    test_bigquery_dialect_validates()
    test_json_load_works_when_pyyaml_unavailable()
    test_key_expression_column_extraction()
    test_relationship_parser()
    test_import_plan_json_core_without_yaml_dependency()
    test_rich_yaml_fixtures_have_json_planning_parity()
    test_import_plan_minimal_fixture()
    test_import_plan_warnings_as_errors_blocks()
    test_import_plan_missing_datatype_strict_blocks()
    test_import_plan_complex_relationship_prefers_native_join_condition()
    test_import_plan_invalid_relationship_fixture_fails_stably()
    test_import_plan_lossless_preserves_native_metadata()
    test_import_plan_bigquery_dialect_fallback_warns_and_strict_blocks()
    test_import_plan_native_key_extension_precedes_core_keys()
    test_invalid_exasol_extension_envelope_blocks_import_plan()
    test_import_plan_assigns_distinct_names_to_repeated_non_exasol_extensions()
    test_import_plan_preserves_raw_semantic_object_extensions()
    test_export_warning_generation_for_lossy_interoperability_cases()
    test_operation_sql_renders_missing_optional_arguments_as_null()
    test_execute_rows_or_empty_accepts_no_result_script_calls()
    test_apply_refuses_blocked_plan_without_database_connection()
    test_apply_metadata_warnings_can_block_before_database_connection()
    test_validation_warnings_as_errors_blocks_apply()
    test_invalid_apply_mode_blocks_before_database_connection()
    test_batch_warning_json_decodes_to_diagnostics()
    test_roundtrip_document_normalization_is_order_stable()
    test_diff_json_values_reports_stable_paths()
    print("ok osi tool tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
