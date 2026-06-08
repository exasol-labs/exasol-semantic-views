#!/usr/bin/env python3
"""Open Semantic Interchange import/export tooling.

Milestone 2 implements export and offline validation. The converter is
host-side by design: Exasol keeps SQL/Lua runtime behavior in the database,
while YAML/JSON/schema handling stays in Python.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OSI_VERSION = "0.2.0.dev0"
OSI_SCHEMA = ROOT / "schemas/osi/0.2.0.dev0/osi-schema.json"
VALID_PROFILES = {"interoperability", "lossless"}
OSI_DIALECT = "ANSI_SQL"


class OsiError(Exception):
    """Base class for CLI-visible OSI errors."""


class OsiValidationError(OsiError):
    """Raised when a document fails OSI validation."""

    def __init__(self, errors: list[str]) -> None:
        self.errors = errors
        super().__init__("\n".join(errors))


@dataclass(frozen=True)
class ExportOptions:
    model_name: str
    object_name: str | None
    profile: str


@dataclass(frozen=True)
class ImportOptions:
    profile: str
    strict: bool
    warnings_as_errors: bool
    target_model: str | None = None
    published_schema: str | None = None
    source: str | None = None


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def normalize_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    return value


def clean_json_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: clean_json_value(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [clean_json_value(v) for v in value]
    return normalize_value(value)


def compact_json(data: dict[str, Any]) -> str:
    return json.dumps(clean_json_value(data), ensure_ascii=False, separators=(",", ":"))


def add_if_present(target: dict[str, Any], key: str, value: Any) -> None:
    if value is not None and value != "":
        target[key] = normalize_value(value)


def fetch_dicts(con: Any, sql: str) -> list[dict[str, Any]]:
    stmt = con.execute(sql)
    if hasattr(stmt, "description"):
        columns = [col[0].upper() for col in stmt.description()]
    else:
        columns = [col.upper() for col in stmt.column_names()]
    return [
        {columns[index]: normalize_value(value) for index, value in enumerate(row)}
        for row in stmt.fetchall()
    ]


def connect(args: argparse.Namespace) -> Any:
    try:
        import pyexasol  # type: ignore
    except ImportError as exc:
        raise OsiError("pyexasol is required for export: pip install pyexasol") from exc

    return pyexasol.connect(
        dsn=f"{args.host}:{args.port}",
        user=args.user,
        password=args.password,
        encryption=True,
        websocket_sslopt=None if args.tls_verify else {"cert_reqs": ssl.CERT_NONE},
    )


def load_catalog(con: Any, model_name: str, object_name: str | None) -> dict[str, Any]:
    model_rows = fetch_dicts(
        con,
        "SELECT * FROM SEMANTIC_CATALOG.MODELS "
        f"WHERE UPPER(MODEL_NAME) = UPPER({sql_string(model_name)})",
    )
    if not model_rows:
        raise OsiError(f"Model not found: {model_name}")
    model = model_rows[0]
    if model.get("ACTIVE_VERSION_ID") is None:
        raise OsiError(f"Model has no active version: {model_name}")

    model_filter = (
        f"MODEL_NAME = {sql_string(model['MODEL_NAME'])} "
        f"AND VERSION_NUMBER = {int(model['ACTIVE_VERSION_NUMBER'])}"
    )
    object_filter = ""
    if object_name:
        object_rows = fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS "
            f"WHERE {model_filter} AND UPPER(OBJECT_NAME) = UPPER({sql_string(object_name)})",
        )
        if not object_rows:
            raise OsiError(f"Semantic object not found: {model_name}.{object_name}")
        object_filter = f" AND OBJECT_NAME = {sql_string(object_rows[0]['OBJECT_NAME'])}"

    return {
        "model": model,
        "semantic_objects": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS "
            f"WHERE {model_filter} ORDER BY OBJECT_ID",
        ),
        "entities": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.ENTITIES "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY ENTITY_ID",
        ),
        "dimensions": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.DIMENSIONS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY DIMENSION_ID",
        ),
        "facts": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.FACTS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY FACT_ID",
        ),
        "metrics": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.METRICS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY METRIC_ID",
        ),
        "relationships": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.RELATIONSHIPS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY RELATIONSHIP_ID",
        ),
        "object_columns": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.OBJECT_COLUMNS "
            f"WHERE MODEL_NAME = {sql_string(model['MODEL_NAME'])}{object_filter} "
            "ORDER BY OBJECT_NAME, ORDINAL_POSITION, COLUMN_KIND, COLUMN_NAME",
        ),
        "synonyms": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.SYNONYMS "
            f"WHERE {model_filter} ORDER BY OBJECT_TYPE, OBJECT_ID, SYNONYM",
        ),
        "instructions": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.AGENT_INSTRUCTIONS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY SCOPE_TYPE, SCOPE_ID, PRIORITY, INSTRUCTION_ID",
        ),
        "verified_queries": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.VERIFIED_QUERIES "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY VERIFIED_QUERY_ID",
        ),
        "unique_keys": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.UNIQUE_KEYS "
            f"WHERE {model_filter} AND STATUS = 'ACTIVE' ORDER BY ENTITY_ID, UNIQUE_KEY_ID",
        ),
        "unique_key_columns": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS "
            f"WHERE {model_filter} ORDER BY UNIQUE_KEY_ID, ORDINAL_POSITION",
        ),
        "custom_extensions": fetch_dicts(
            con,
            "SELECT * FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS "
            f"WHERE {model_filter} ORDER BY CUSTOM_EXTENSION_ID",
        ),
        "object_name": object_name,
    }


def index_by(rows: list[dict[str, Any]], column: str) -> dict[Any, dict[str, Any]]:
    return {row[column]: row for row in rows}


def rows_by(rows: list[dict[str, Any]], column: str) -> dict[Any, list[dict[str, Any]]]:
    result: dict[Any, list[dict[str, Any]]] = {}
    for row in rows:
        result.setdefault(row[column], []).append(row)
    return result


def rows_by_pair(rows: list[dict[str, Any]], first: str, second: str) -> dict[tuple[Any, Any], list[dict[str, Any]]]:
    result: dict[tuple[Any, Any], list[dict[str, Any]]] = {}
    for row in rows:
        result.setdefault((row[first], row[second]), []).append(row)
    return result


def column_refs(expression: str | None) -> list[tuple[str, str]]:
    if not expression:
        return []
    refs: list[tuple[str, str]] = []
    for alias, column in re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b", expression):
        refs.append((alias, column))
    return refs


def simple_key_columns(expression: str | None, alias: str | None) -> list[str]:
    if not expression or not alias:
        return []
    columns: list[str] = []
    seen: set[str] = set()
    for ref_alias, column in column_refs(expression):
        if ref_alias.upper() != alias.upper():
            continue
        normalized = column.lower()
        if normalized not in seen:
            columns.append(column)
            seen.add(normalized)
    return columns


def parse_relationship_columns(
    relationship: dict[str, Any],
    entity_by_name: dict[str, dict[str, Any]],
) -> tuple[list[str], list[str]] | None:
    from_entity = entity_by_name.get(relationship["FROM_ENTITY_NAME"])
    to_entity = entity_by_name.get(relationship["TO_ENTITY_NAME"])
    if not from_entity or not to_entity:
        return None
    from_alias = from_entity["SOURCE_ALIAS"].upper()
    to_alias = to_entity["SOURCE_ALIAS"].upper()
    from_columns: list[str] = []
    to_columns: list[str] = []
    pieces = re.split(r"\s+AND\s+", relationship.get("JOIN_CONDITION") or "", flags=re.IGNORECASE)
    for piece in pieces:
        match = re.match(
            r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*$",
            piece,
        )
        if not match:
            return None
        left_alias, left_col, right_alias, right_col = match.groups()
        left_alias = left_alias.upper()
        right_alias = right_alias.upper()
        if left_alias == from_alias and right_alias == to_alias:
            from_columns.append(left_col)
            to_columns.append(right_col)
        elif left_alias == to_alias and right_alias == from_alias:
            from_columns.append(right_col)
            to_columns.append(left_col)
        else:
            return None
    if not from_columns:
        return None
    return from_columns, to_columns


def ai_context_for(
    synonyms_by_object: dict[tuple[Any, Any], list[dict[str, Any]]],
    instructions_by_scope: dict[tuple[Any, Any], list[dict[str, Any]]],
    object_type: str,
    object_id: Any,
    examples: list[str] | None = None,
) -> dict[str, Any] | None:
    context: dict[str, Any] = {}
    synonyms = [row["SYNONYM"] for row in synonyms_by_object.get((object_type, object_id), [])]
    if synonyms:
        context["synonyms"] = synonyms
    instructions = [
        row["INSTRUCTION_TEXT"]
        for row in instructions_by_scope.get((object_type, object_id), [])
        if row.get("INSTRUCTION_TEXT")
    ]
    if instructions:
        context["instructions"] = "\n".join(instructions)
    if examples:
        context["examples"] = examples
    return context or None


def raw_extension(row: dict[str, Any]) -> dict[str, str]:
    return {"vendor_name": str(row["VENDOR_NAME"]), "data": str(row["DATA_JSON"])}


def extension_rows_for(
    extensions_by_scope: dict[tuple[Any, Any], list[dict[str, Any]]],
    scope_type: str,
    scope_id: Any,
) -> list[dict[str, Any]]:
    return extensions_by_scope.get((scope_type, scope_id), [])


def catalog_extension_metadata(rows: list[dict[str, Any]], vendor_name: str = "EXASOL") -> list[dict[str, Any]]:
    metadata: list[dict[str, Any]] = []
    for row in rows:
        if str(row["VENDOR_NAME"]).upper() != vendor_name:
            continue
        metadata.append(
            {
                "extension_name": row.get("EXTENSION_NAME"),
                "source_format": row.get("SOURCE_FORMAT"),
                "data": row.get("DATA_JSON"),
            }
        )
    return metadata


def append_non_exasol_extensions(target: list[dict[str, str]], rows: list[dict[str, Any]]) -> None:
    for row in rows:
        if str(row["VENDOR_NAME"]).upper() != "EXASOL":
            target.append(raw_extension(row))


def make_exasol_extension(data: dict[str, Any]) -> dict[str, str]:
    return {"vendor_name": "EXASOL", "data": compact_json(data)}


def object_columns_for(
    rows: list[dict[str, Any]],
    column_kind: str,
    object_ref_id: Any,
) -> list[dict[str, Any]]:
    result = []
    for row in rows:
        if row["COLUMN_KIND"] == column_kind and row["OBJECT_REF_ID"] == object_ref_id:
            result.append(
                {
                    "object_name": row["OBJECT_NAME"],
                    "ordinal": row["ORDINAL_POSITION"],
                }
            )
    return result


def selected_object_columns(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    object_name = catalog.get("object_name")
    rows = catalog["object_columns"]
    if not object_name:
        return rows
    return [row for row in rows if row["OBJECT_NAME"].upper() == object_name.upper()]


def selected_ref_ids(catalog: dict[str, Any], kind: str) -> set[Any]:
    object_name = catalog.get("object_name")
    if not object_name:
        return {row["OBJECT_REF_ID"] for row in catalog["object_columns"] if row["COLUMN_KIND"] == kind}
    return {
        row["OBJECT_REF_ID"]
        for row in catalog["object_columns"]
        if row["COLUMN_KIND"] == kind and row["OBJECT_NAME"].upper() == object_name.upper() and row["IS_VISIBLE"]
    }


def sort_field_rows(rows: list[dict[str, Any]], object_rows: list[dict[str, Any]], kind: str, id_column: str) -> list[dict[str, Any]]:
    ordinal_by_id = {
        row["OBJECT_REF_ID"]: row["ORDINAL_POSITION"]
        for row in object_rows
        if row["COLUMN_KIND"] == kind and row.get("IS_VISIBLE")
    }
    return sorted(rows, key=lambda row: (ordinal_by_id.get(row[id_column], 10_000_000), row[id_column]))


def bool_value(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).lower() == "true"


def dimension_payload(
    row: dict[str, Any],
    object_rows: list[dict[str, Any]],
    extension_rows: list[dict[str, Any]],
    profile: str,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "field_kind": "DIMENSION",
        "entity_name": row.get("ENTITY_NAME"),
        "data_type": row.get("DATA_TYPE"),
    }
    add_if_present(data, "display_name", row.get("DISPLAY_NAME"))
    add_if_present(data, "format_hint", row.get("FORMAT_HINT"))
    add_if_present(data, "unit_hint", row.get("UNIT_HINT"))
    add_if_present(data, "sensitivity_label", row.get("SENSITIVITY_LABEL"))
    add_if_present(data, "display_policy", row.get("DISPLAY_POLICY"))
    data["is_hidden"] = bool_value(row.get("IS_HIDDEN"))
    data["is_certified"] = bool_value(row.get("IS_CERTIFIED"))
    if profile == "lossless":
        data["object_columns"] = object_columns_for(object_rows, "DIMENSION", row["DIMENSION_ID"])
    catalog_extensions = catalog_extension_metadata(extension_rows)
    if catalog_extensions:
        data["catalog_custom_extensions"] = catalog_extensions
    return data


def fact_payload(
    row: dict[str, Any],
    object_rows: list[dict[str, Any]],
    extension_rows: list[dict[str, Any]],
    profile: str,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "field_kind": "FACT",
        "entity_name": row.get("ENTITY_NAME"),
        "data_type": row.get("DATA_TYPE"),
        "additive_policy": row.get("ADDITIVE_POLICY"),
    }
    add_if_present(data, "display_name", row.get("DISPLAY_NAME"))
    add_if_present(data, "format_hint", row.get("FORMAT_HINT"))
    add_if_present(data, "unit_hint", row.get("UNIT_HINT"))
    add_if_present(data, "sensitivity_label", row.get("SENSITIVITY_LABEL"))
    add_if_present(data, "display_policy", row.get("DISPLAY_POLICY"))
    data["is_private"] = bool_value(row.get("IS_PRIVATE"))
    data["is_certified"] = bool_value(row.get("IS_CERTIFIED"))
    if profile == "lossless":
        data["object_columns"] = object_columns_for(object_rows, "FACT", row["FACT_ID"])
    catalog_extensions = catalog_extension_metadata(extension_rows)
    if catalog_extensions:
        data["catalog_custom_extensions"] = catalog_extensions
    return data


def metric_payload(
    row: dict[str, Any],
    object_rows: list[dict[str, Any]],
    extension_rows: list[dict[str, Any]],
    profile: str,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "data_type": row.get("DATA_TYPE"),
        "base_entity": row.get("BASE_ENTITY_NAME"),
        "metric_type": row.get("METRIC_TYPE"),
        "metric_kind": row.get("METRIC_KIND") or row.get("METRIC_TYPE"),
    }
    for key, column in [
        ("aggregation_function", "AGGREGATION_FUNCTION"),
        ("measure_expr", "MEASURE_EXPR"),
        ("semantic_filter_expr", "SEMANTIC_FILTER_EXPR"),
        ("sql_filter_expr", "SQL_FILTER_EXPR"),
        ("distinct_key_expr", "DISTINCT_KEY_EXPR"),
        ("non_additive_dimension", "NON_ADDITIVE_DIMENSION_NAME"),
        ("window_spec_json", "WINDOW_SPEC_JSON"),
        ("type_params_json", "TYPE_PARAMS_JSON"),
        ("format_hint", "FORMAT_HINT"),
        ("unit_hint", "UNIT_HINT"),
        ("display_name", "DISPLAY_NAME"),
        ("sensitivity_label", "SENSITIVITY_LABEL"),
        ("display_policy", "DISPLAY_POLICY"),
        ("owner_role", "OWNER_ROLE"),
    ]:
        add_if_present(data, key, row.get(column))
    data["is_private"] = bool_value(row.get("IS_PRIVATE"))
    data["is_certified"] = bool_value(row.get("IS_CERTIFIED"))
    if profile == "lossless":
        data["object_columns"] = object_columns_for(object_rows, "METRIC", row["METRIC_ID"])
    catalog_extensions = catalog_extension_metadata(extension_rows)
    if catalog_extensions:
        data["catalog_custom_extensions"] = catalog_extensions
    return data


def entity_payload(
    row: dict[str, Any],
    unique_keys: list[dict[str, Any]],
    extension_rows: list[dict[str, Any]],
    profile: str,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "entity_name": row["ENTITY_NAME"],
        "source_schema": row["SOURCE_SCHEMA"],
        "source_object": row["SOURCE_OBJECT"],
        "source_alias": row["SOURCE_ALIAS"],
    }
    add_if_present(data, "primary_key_expr", row.get("PRIMARY_KEY_EXPR"))
    add_if_present(data, "grain_description", row.get("GRAIN_DESCRIPTION"))
    add_if_present(data, "description", row.get("DESCRIPTION"))
    if unique_keys:
        key_payloads = []
        for key_row in unique_keys:
            key_payload = {
                "key_name": key_row["KEY_NAME"],
                "key_kind": key_row["KEY_KIND"],
                "source_format": key_row["SOURCE_FORMAT"],
            }
            add_if_present(key_payload, "description", key_row.get("DESCRIPTION"))
            key_payload["columns"] = key_row.get("columns", [])
            key_payloads.append(key_payload)
        data["unique_keys"] = key_payloads
    catalog_extensions = catalog_extension_metadata(extension_rows)
    if catalog_extensions:
        data["catalog_custom_extensions"] = catalog_extensions
    return data


def relationship_payload(row: dict[str, Any], extension_rows: list[dict[str, Any]]) -> dict[str, Any]:
    data: dict[str, Any] = {
        "from_entity": row.get("FROM_ENTITY_NAME"),
        "to_entity": row.get("TO_ENTITY_NAME"),
        "join_condition": row.get("JOIN_CONDITION"),
        "relationship_cardinality": row.get("RELATIONSHIP_CARDINALITY"),
        "join_type": row.get("JOIN_TYPE"),
        "fanout_policy": row.get("FANOUT_POLICY"),
        "path_priority": row.get("PATH_PRIORITY"),
    }
    add_if_present(data, "description", row.get("DESCRIPTION"))
    catalog_extensions = catalog_extension_metadata(extension_rows)
    if catalog_extensions:
        data["catalog_custom_extensions"] = catalog_extensions
    return data


def semantic_objects_payload(
    semantic_objects: list[dict[str, Any]],
    object_columns: list[dict[str, Any]],
    extensions_by_scope: dict[tuple[Any, Any], list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    result = []
    for obj in semantic_objects:
        columns = []
        for col in sorted(
            [row for row in object_columns if row["OBJECT_NAME"] == obj["OBJECT_NAME"]],
            key=lambda row: row["ORDINAL_POSITION"],
        ):
            columns.append(
                {
                    "kind": col["COLUMN_KIND"],
                    "name": col["COLUMN_NAME"],
                    "ordinal": col["ORDINAL_POSITION"],
                    "is_visible": bool_value(col["IS_VISIBLE"]),
                }
            )
        object_payload: dict[str, Any] = {
            "object_name": obj["OBJECT_NAME"],
            "root_entity": obj.get("ROOT_ENTITY_NAME"),
            "description": obj.get("DESCRIPTION"),
            "columns": columns,
        }
        scope_extensions = extension_rows_for(extensions_by_scope, "SEMANTIC_OBJECT", obj["OBJECT_ID"])
        if scope_extensions:
            object_payload["custom_extensions"] = [raw_extension(row) for row in scope_extensions]
        result.append(clean_json_value(object_payload))
    return result


def build_unique_key_columns(catalog: dict[str, Any]) -> dict[Any, list[dict[str, Any]]]:
    by_id = rows_by(catalog["unique_key_columns"], "UNIQUE_KEY_ID")
    result: dict[Any, list[dict[str, Any]]] = {}
    for unique_key_id, rows in by_id.items():
        result[unique_key_id] = [
            {
                "ordinal": row["ORDINAL_POSITION"],
                "column_name": row.get("COLUMN_NAME"),
                "expression": row.get("EXPRESSION"),
            }
            for row in rows
        ]
    return result


def simple_unique_key_values(unique_key: dict[str, Any]) -> list[str] | None:
    values = []
    for column in unique_key.get("columns", []):
        if not column.get("column_name") or column.get("expression"):
            return None
        values.append(str(column["column_name"]))
    return values if values else None


def build_entity_unique_keys(catalog: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    columns_by_key = build_unique_key_columns(catalog)
    result: dict[str, list[dict[str, Any]]] = {}
    for key_row in catalog["unique_keys"]:
        enriched = dict(key_row)
        enriched["columns"] = columns_by_key.get(key_row["UNIQUE_KEY_ID"], [])
        result.setdefault(key_row["ENTITY_NAME"], []).append(enriched)
    return result


def build_document(catalog: dict[str, Any], options: ExportOptions) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    warnings: list[dict[str, Any]] = []
    model = catalog["model"]
    entity_by_name = index_by(catalog["entities"], "ENTITY_NAME")
    synonyms_by_object = rows_by_pair(catalog["synonyms"], "OBJECT_TYPE", "OBJECT_ID")
    instructions_by_scope = rows_by_pair(catalog["instructions"], "SCOPE_TYPE", "SCOPE_ID")
    extensions_by_scope = rows_by_pair(catalog["custom_extensions"], "SCOPE_TYPE", "SCOPE_ID")
    selected_columns = selected_object_columns(catalog)
    dimension_ids = selected_ref_ids(catalog, "DIMENSION")
    fact_ids = selected_ref_ids(catalog, "FACT")
    metric_ids = selected_ref_ids(catalog, "METRIC")

    if not options.object_name or options.profile == "lossless":
        dimensions = list(catalog["dimensions"])
        facts = list(catalog["facts"])
        metrics = list(catalog["metrics"])
    else:
        dimensions = [row for row in catalog["dimensions"] if row["DIMENSION_ID"] in dimension_ids]
        facts = [row for row in catalog["facts"] if row["FACT_ID"] in fact_ids]
        metrics = [row for row in catalog["metrics"] if row["METRIC_ID"] in metric_ids]

    used_entities = {row["ENTITY_NAME"] for row in dimensions}
    used_entities.update(row["ENTITY_NAME"] for row in facts)
    used_entities.update(row["BASE_ENTITY_NAME"] for row in metrics if row.get("BASE_ENTITY_NAME"))
    if options.profile == "lossless" or not options.object_name:
        entities = list(catalog["entities"])
    else:
        changed = True
        while changed:
            changed = False
            for relationship in catalog["relationships"]:
                if relationship["FROM_ENTITY_NAME"] in used_entities or relationship["TO_ENTITY_NAME"] in used_entities:
                    before = len(used_entities)
                    used_entities.add(relationship["FROM_ENTITY_NAME"])
                    used_entities.add(relationship["TO_ENTITY_NAME"])
                    changed = changed or len(used_entities) > before
        entities = [row for row in catalog["entities"] if row["ENTITY_NAME"] in used_entities]

    unique_keys_by_entity = build_entity_unique_keys(catalog)
    dataset_docs = []
    for entity in entities:
        fields = []
        entity_dimensions = sort_field_rows(
            [row for row in dimensions if row["ENTITY_NAME"] == entity["ENTITY_NAME"]],
            selected_columns,
            "DIMENSION",
            "DIMENSION_ID",
        )
        for dimension in entity_dimensions:
            extension_rows = extension_rows_for(extensions_by_scope, "DIMENSION", dimension["DIMENSION_ID"])
            field_doc: dict[str, Any] = {
                "name": dimension["DIMENSION_NAME"],
                "expression": {"dialects": [{"dialect": OSI_DIALECT, "expression": dimension["EXPRESSION"]}]},
                "dimension": {},
            }
            if dimension.get("DATA_TYPE") and re.search(r"\b(DATE|TIMESTAMP)\b", str(dimension["DATA_TYPE"]), re.I):
                field_doc["dimension"]["is_time"] = True
            add_if_present(field_doc, "description", dimension.get("DESCRIPTION"))
            context = ai_context_for(synonyms_by_object, instructions_by_scope, "DIMENSION", dimension["DIMENSION_ID"])
            if context:
                field_doc["ai_context"] = context
            extensions = [make_exasol_extension(dimension_payload(dimension, catalog["object_columns"], extension_rows, options.profile))]
            append_non_exasol_extensions(extensions, extension_rows)
            field_doc["custom_extensions"] = extensions
            fields.append(field_doc)

        entity_facts = sort_field_rows(
            [row for row in facts if row["ENTITY_NAME"] == entity["ENTITY_NAME"]],
            selected_columns,
            "FACT",
            "FACT_ID",
        )
        for fact in entity_facts:
            if options.profile == "interoperability" and bool_value(fact.get("IS_PRIVATE")):
                warnings.append(
                    {
                        "code": "OSI_EXPORT_020",
                        "severity": "WARNING",
                        "path": f"facts.{fact['FACT_NAME']}",
                        "message": "Private fact omitted from interoperability export.",
                    }
                )
                continue
            extension_rows = extension_rows_for(extensions_by_scope, "FACT", fact["FACT_ID"])
            field_doc = {
                "name": fact["FACT_NAME"],
                "label": "fact",
                "expression": {"dialects": [{"dialect": OSI_DIALECT, "expression": fact["EXPRESSION"]}]},
            }
            add_if_present(field_doc, "description", fact.get("DESCRIPTION"))
            context = ai_context_for(synonyms_by_object, instructions_by_scope, "FACT", fact["FACT_ID"])
            if context:
                field_doc["ai_context"] = context
            extensions = [make_exasol_extension(fact_payload(fact, catalog["object_columns"], extension_rows, options.profile))]
            append_non_exasol_extensions(extensions, extension_rows)
            field_doc["custom_extensions"] = extensions
            fields.append(field_doc)

        keys_for_entity = unique_keys_by_entity.get(entity["ENTITY_NAME"], [])
        dataset_doc: dict[str, Any] = {
            "name": entity["ENTITY_NAME"],
            "source": f"{entity['SOURCE_SCHEMA']}.{entity['SOURCE_OBJECT']}",
        }
        primary_key = None
        unique_keys = []
        for key_row in keys_for_entity:
            values = simple_unique_key_values(key_row)
            if values is None:
                warnings.append(
                    {
                        "code": "OSI_EXPORT_030",
                        "severity": "WARNING",
                        "path": f"datasets.{entity['ENTITY_NAME']}.unique_keys.{key_row['KEY_NAME']}",
                        "message": "Expression-based unique key preserved in Exasol extension only.",
                    }
                )
                continue
            if key_row["KEY_KIND"] == "PRIMARY" and primary_key is None:
                primary_key = values
            else:
                unique_keys.append(values)
        if primary_key is None:
            primary_key = simple_key_columns(entity.get("PRIMARY_KEY_EXPR"), entity.get("SOURCE_ALIAS"))
        if primary_key:
            dataset_doc["primary_key"] = primary_key
        if unique_keys:
            dataset_doc["unique_keys"] = unique_keys
        add_if_present(dataset_doc, "description", entity.get("DESCRIPTION"))
        if fields:
            dataset_doc["fields"] = fields
        context = ai_context_for(synonyms_by_object, instructions_by_scope, "ENTITY", entity["ENTITY_ID"])
        if context:
            dataset_doc["ai_context"] = context
        extension_rows = extension_rows_for(extensions_by_scope, "ENTITY", entity["ENTITY_ID"])
        extensions = [make_exasol_extension(entity_payload(entity, keys_for_entity, extension_rows, options.profile))]
        append_non_exasol_extensions(extensions, extension_rows)
        dataset_doc["custom_extensions"] = extensions
        dataset_docs.append(dataset_doc)

    relationship_docs = []
    exported_relationship_ids = set()
    entity_names = {row["ENTITY_NAME"] for row in entities}
    for relationship in catalog["relationships"]:
        if relationship["FROM_ENTITY_NAME"] not in entity_names or relationship["TO_ENTITY_NAME"] not in entity_names:
            continue
        parsed_columns = parse_relationship_columns(relationship, entity_by_name)
        extension_rows = extension_rows_for(extensions_by_scope, "RELATIONSHIP", relationship["RELATIONSHIP_ID"])
        if parsed_columns is None:
            warnings.append(
                {
                    "code": "OSI_EXPORT_040",
                    "severity": "WARNING",
                    "path": f"relationships.{relationship['RELATIONSHIP_NAME']}",
                    "message": "Relationship join condition is not a simple equality column mapping.",
                }
            )
            continue
        from_columns, to_columns = parsed_columns
        rel_doc = {
            "name": relationship["RELATIONSHIP_NAME"],
            "from": relationship["FROM_ENTITY_NAME"],
            "to": relationship["TO_ENTITY_NAME"],
            "from_columns": from_columns,
            "to_columns": to_columns,
        }
        context = ai_context_for(synonyms_by_object, instructions_by_scope, "RELATIONSHIP", relationship["RELATIONSHIP_ID"])
        if context:
            rel_doc["ai_context"] = context
        extensions = [make_exasol_extension(relationship_payload(relationship, extension_rows))]
        append_non_exasol_extensions(extensions, extension_rows)
        rel_doc["custom_extensions"] = extensions
        relationship_docs.append(rel_doc)
        exported_relationship_ids.add(relationship["RELATIONSHIP_ID"])

    metric_docs = []
    for metric in sort_field_rows(metrics, selected_columns, "METRIC", "METRIC_ID"):
        if options.profile == "interoperability" and bool_value(metric.get("IS_PRIVATE")):
            warnings.append(
                {
                    "code": "OSI_EXPORT_021",
                    "severity": "WARNING",
                    "path": f"metrics.{metric['METRIC_NAME']}",
                    "message": "Private metric omitted from interoperability export.",
                }
            )
            continue
        extension_rows = extension_rows_for(extensions_by_scope, "METRIC", metric["METRIC_ID"])
        metric_doc: dict[str, Any] = {
            "name": metric["METRIC_NAME"],
            "expression": {"dialects": [{"dialect": OSI_DIALECT, "expression": metric["EXPRESSION"]}]},
        }
        add_if_present(metric_doc, "description", metric.get("DESCRIPTION"))
        context = ai_context_for(synonyms_by_object, instructions_by_scope, "METRIC", metric["METRIC_ID"])
        if context:
            metric_doc["ai_context"] = context
        extensions = [make_exasol_extension(metric_payload(metric, catalog["object_columns"], extension_rows, options.profile))]
        append_non_exasol_extensions(extensions, extension_rows)
        metric_doc["custom_extensions"] = extensions
        metric_docs.append(metric_doc)

    examples = [
        row["NATURAL_LANGUAGE_TEXT"]
        for row in catalog["verified_queries"]
        if row.get("NATURAL_LANGUAGE_TEXT")
           and (not options.object_name or row.get("OBJECT_NAME") in {None, options.object_name})
    ]
    semantic_model: dict[str, Any] = {
        "name": model["MODEL_NAME"],
        "datasets": dataset_docs,
    }
    add_if_present(semantic_model, "description", model.get("DESCRIPTION"))
    model_context = ai_context_for(synonyms_by_object, instructions_by_scope, "MODEL", model["MODEL_ID"], examples)
    if model_context:
        semantic_model["ai_context"] = model_context
    if relationship_docs:
        semantic_model["relationships"] = relationship_docs
    if metric_docs:
        semantic_model["metrics"] = metric_docs

    model_extension_rows = extension_rows_for(extensions_by_scope, "MODEL", model["MODEL_ID"])
    model_extension_data: dict[str, Any] = {
        "published_schema": model.get("PUBLISHED_SCHEMA"),
        "owner_role": model.get("OWNER_ROLE"),
        "profile": options.profile,
    }
    if options.object_name:
        model_extension_data["semantic_object"] = options.object_name
    if options.profile == "lossless":
        model_extension_data["semantic_objects"] = semantic_objects_payload(
            catalog["semantic_objects"], catalog["object_columns"], extensions_by_scope
        )
        skipped_relationships = [
            relationship_payload(row, extension_rows_for(extensions_by_scope, "RELATIONSHIP", row["RELATIONSHIP_ID"]))
            for row in catalog["relationships"]
            if row["RELATIONSHIP_ID"] not in exported_relationship_ids
        ]
        if skipped_relationships:
            model_extension_data["relationships_requiring_native_join_condition"] = skipped_relationships
    catalog_extensions = catalog_extension_metadata(model_extension_rows)
    if catalog_extensions:
        model_extension_data["catalog_custom_extensions"] = catalog_extensions
    model_extensions = [make_exasol_extension(model_extension_data)]
    append_non_exasol_extensions(model_extensions, model_extension_rows)
    semantic_model["custom_extensions"] = model_extensions

    document = {
        "version": OSI_VERSION,
        "semantic_model": [semantic_model],
    }
    return clean_json_value(document), warnings


def export_model(con: Any, options: ExportOptions) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if options.profile not in VALID_PROFILES:
        raise OsiError(f"Unsupported profile: {options.profile}")
    catalog = load_catalog(con, options.model_name, options.object_name)
    document, warnings = build_document(catalog, options)
    validate_document(document)
    return document, warnings


def load_document(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in {".yaml", ".yml"}:
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise OsiError("PyYAML is required to read YAML files. Use JSON mode or install PyYAML.") from exc
        data = yaml.safe_load(text)
    else:
        data = json.loads(text)
    if not isinstance(data, dict):
        raise OsiValidationError(["$ must be an object"])
    return data


def extension_data_errors(extension: Any, path: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(extension, dict):
        return [f"{path} must be an object"]
    if set(extension) - {"vendor_name", "data"}:
        errors.append(f"{path} contains unsupported keys: {sorted(set(extension) - {'vendor_name', 'data'})}")
    if not isinstance(extension.get("vendor_name"), str) or not extension.get("vendor_name"):
        errors.append(f"{path}.vendor_name must be a non-empty string")
    if not isinstance(extension.get("data"), str):
        errors.append(f"{path}.data must be a JSON string")
    else:
        try:
            json.loads(extension["data"])
        except json.JSONDecodeError as exc:
            errors.append(f"{path}.data must parse as JSON: {exc.msg}")
    return errors


def validate_extension_array(value: Any, path: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        return [f"{path} must be an array"]
    errors: list[str] = []
    for index, extension in enumerate(value):
        errors.extend(extension_data_errors(extension, f"{path}[{index}]"))
    return errors


def validate_expression(value: Any, path: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"{path} must be an object"]
    if set(value) - {"dialects"}:
        errors.append(f"{path} contains unsupported keys: {sorted(set(value) - {'dialects'})}")
    dialects = value.get("dialects")
    if not isinstance(dialects, list) or not dialects:
        errors.append(f"{path}.dialects must be a non-empty array")
        return errors
    for index, dialect in enumerate(dialects):
        dialect_path = f"{path}.dialects[{index}]"
        if not isinstance(dialect, dict):
            errors.append(f"{dialect_path} must be an object")
            continue
        if set(dialect) - {"dialect", "expression"}:
            errors.append(f"{dialect_path} contains unsupported keys")
        if dialect.get("dialect") not in {"ANSI_SQL", "SNOWFLAKE", "MDX", "TABLEAU", "DATABRICKS", "MAQL"}:
            errors.append(f"{dialect_path}.dialect is unsupported: {dialect.get('dialect')}")
        if not isinstance(dialect.get("expression"), str) or not dialect.get("expression"):
            errors.append(f"{dialect_path}.expression must be a non-empty string")
    return errors


def validate_ai_context(value: Any, path: str) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return []
    if not isinstance(value, dict):
        return [f"{path} must be a string or object"]
    errors: list[str] = []
    if "instructions" in value and not isinstance(value["instructions"], str):
        errors.append(f"{path}.instructions must be a string")
    for key in ["synonyms", "examples"]:
        if key in value:
            if not isinstance(value[key], list) or not all(isinstance(item, str) for item in value[key]):
                errors.append(f"{path}.{key} must be an array of strings")
    return errors


def validate_field(value: Any, path: str) -> list[str]:
    allowed = {"name", "expression", "dimension", "label", "description", "ai_context", "custom_extensions"}
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"{path} must be an object"]
    extra = set(value) - allowed
    if extra:
        errors.append(f"{path} contains unsupported keys: {sorted(extra)}")
    if not isinstance(value.get("name"), str) or not value.get("name"):
        errors.append(f"{path}.name must be a non-empty string")
    if "expression" not in value:
        errors.append(f"{path}.expression is required")
    else:
        errors.extend(validate_expression(value["expression"], f"{path}.expression"))
    if "dimension" in value:
        if not isinstance(value["dimension"], dict):
            errors.append(f"{path}.dimension must be an object")
        elif set(value["dimension"]) - {"is_time"}:
            errors.append(f"{path}.dimension contains unsupported keys")
    if "label" in value and not isinstance(value["label"], str):
        errors.append(f"{path}.label must be a string")
    if "description" in value and not isinstance(value["description"], str):
        errors.append(f"{path}.description must be a string")
    errors.extend(validate_ai_context(value.get("ai_context"), f"{path}.ai_context"))
    errors.extend(validate_extension_array(value.get("custom_extensions"), f"{path}.custom_extensions"))
    return errors


def validate_dataset(value: Any, path: str) -> list[str]:
    allowed = {"name", "source", "primary_key", "unique_keys", "description", "ai_context", "fields", "custom_extensions"}
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"{path} must be an object"]
    extra = set(value) - allowed
    if extra:
        errors.append(f"{path} contains unsupported keys: {sorted(extra)}")
    for key in ["name", "source"]:
        if not isinstance(value.get(key), str) or not value.get(key):
            errors.append(f"{path}.{key} must be a non-empty string")
    if "primary_key" in value and (
        not isinstance(value["primary_key"], list) or not all(isinstance(item, str) for item in value["primary_key"])
    ):
        errors.append(f"{path}.primary_key must be an array of strings")
    if "unique_keys" in value:
        if not isinstance(value["unique_keys"], list):
            errors.append(f"{path}.unique_keys must be an array")
        else:
            for index, unique_key in enumerate(value["unique_keys"]):
                if not isinstance(unique_key, list) or not all(isinstance(item, str) for item in unique_key):
                    errors.append(f"{path}.unique_keys[{index}] must be an array of strings")
    if "description" in value and not isinstance(value["description"], str):
        errors.append(f"{path}.description must be a string")
    errors.extend(validate_ai_context(value.get("ai_context"), f"{path}.ai_context"))
    if "fields" in value:
        if not isinstance(value["fields"], list):
            errors.append(f"{path}.fields must be an array")
        else:
            for index, field in enumerate(value["fields"]):
                errors.extend(validate_field(field, f"{path}.fields[{index}]"))
    errors.extend(validate_extension_array(value.get("custom_extensions"), f"{path}.custom_extensions"))
    return errors


def validate_relationship(value: Any, path: str) -> list[str]:
    allowed = {"name", "from", "to", "from_columns", "to_columns", "ai_context", "custom_extensions"}
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"{path} must be an object"]
    extra = set(value) - allowed
    if extra:
        errors.append(f"{path} contains unsupported keys: {sorted(extra)}")
    for key in ["name", "from", "to"]:
        if not isinstance(value.get(key), str) or not value.get(key):
            errors.append(f"{path}.{key} must be a non-empty string")
    for key in ["from_columns", "to_columns"]:
        if not isinstance(value.get(key), list) or not value[key] or not all(isinstance(item, str) for item in value[key]):
            errors.append(f"{path}.{key} must be a non-empty array of strings")
    errors.extend(validate_ai_context(value.get("ai_context"), f"{path}.ai_context"))
    errors.extend(validate_extension_array(value.get("custom_extensions"), f"{path}.custom_extensions"))
    return errors


def validate_metric(value: Any, path: str) -> list[str]:
    allowed = {"name", "expression", "description", "ai_context", "custom_extensions"}
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"{path} must be an object"]
    extra = set(value) - allowed
    if extra:
        errors.append(f"{path} contains unsupported keys: {sorted(extra)}")
    if not isinstance(value.get("name"), str) or not value.get("name"):
        errors.append(f"{path}.name must be a non-empty string")
    if "expression" not in value:
        errors.append(f"{path}.expression is required")
    else:
        errors.extend(validate_expression(value["expression"], f"{path}.expression"))
    if "description" in value and not isinstance(value["description"], str):
        errors.append(f"{path}.description must be a string")
    errors.extend(validate_ai_context(value.get("ai_context"), f"{path}.ai_context"))
    errors.extend(validate_extension_array(value.get("custom_extensions"), f"{path}.custom_extensions"))
    return errors


def fallback_validate_document(document: dict[str, Any]) -> list[str]:
    allowed = {"version", "semantic_model"}
    errors: list[str] = []
    extra = set(document) - allowed
    if extra:
        errors.append(f"$ contains unsupported keys: {sorted(extra)}")
    if document.get("version") != OSI_VERSION:
        errors.append(f"$.version must be {OSI_VERSION!r}")
    models = document.get("semantic_model")
    if not isinstance(models, list) or not models:
        errors.append("$.semantic_model must be a non-empty array")
        return errors
    for model_index, model in enumerate(models):
        path = f"$.semantic_model[{model_index}]"
        if not isinstance(model, dict):
            errors.append(f"{path} must be an object")
            continue
        model_allowed = {"name", "description", "ai_context", "datasets", "relationships", "metrics", "custom_extensions"}
        extra = set(model) - model_allowed
        if extra:
            errors.append(f"{path} contains unsupported keys: {sorted(extra)}")
        if not isinstance(model.get("name"), str) or not model.get("name"):
            errors.append(f"{path}.name must be a non-empty string")
        if "description" in model and not isinstance(model["description"], str):
            errors.append(f"{path}.description must be a string")
        errors.extend(validate_ai_context(model.get("ai_context"), f"{path}.ai_context"))
        datasets = model.get("datasets")
        if not isinstance(datasets, list) or not datasets:
            errors.append(f"{path}.datasets must be a non-empty array")
        else:
            for index, dataset in enumerate(datasets):
                errors.extend(validate_dataset(dataset, f"{path}.datasets[{index}]"))
        if "relationships" in model:
            if not isinstance(model["relationships"], list):
                errors.append(f"{path}.relationships must be an array")
            else:
                for index, relationship in enumerate(model["relationships"]):
                    errors.extend(validate_relationship(relationship, f"{path}.relationships[{index}]"))
        if "metrics" in model:
            if not isinstance(model["metrics"], list):
                errors.append(f"{path}.metrics must be an array")
            else:
                for index, metric in enumerate(model["metrics"]):
                    errors.extend(validate_metric(metric, f"{path}.metrics[{index}]"))
        errors.extend(validate_extension_array(model.get("custom_extensions"), f"{path}.custom_extensions"))
    return errors


def validate_document(document: dict[str, Any]) -> None:
    errors: list[str] = []
    try:
        import jsonschema  # type: ignore
    except ImportError:
        errors = fallback_validate_document(document)
    else:
        schema = json.loads(OSI_SCHEMA.read_text(encoding="utf-8"))
        validator = jsonschema.Draft202012Validator(schema)
        for error in sorted(validator.iter_errors(document), key=lambda item: list(item.path)):
            path = "$" + "".join(f"[{part!r}]" if isinstance(part, str) else f"[{part}]" for part in error.path)
            errors.append(f"{path}: {error.message}")
        errors.extend(fallback_validate_document(document))
    if errors:
        deduped = list(dict.fromkeys(errors))
        raise OsiValidationError(deduped)


EXASOL_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
NATIVE_METRIC_TYPES = {"ADDITIVE", "RATIO", "DISTINCT", "SEMI_ADDITIVE", "WINDOW", "DERIVED"}

MODEL_EXTENSION_KEYS = {
    "published_schema",
    "owner_role",
    "profile",
    "semantic_object",
    "semantic_objects",
    "relationships_requiring_native_join_condition",
    "catalog_custom_extensions",
}
ENTITY_EXTENSION_KEYS = {
    "entity_name",
    "source_schema",
    "source_object",
    "source_alias",
    "primary_key_expr",
    "grain_description",
    "description",
    "unique_keys",
    "catalog_custom_extensions",
}
FIELD_EXTENSION_KEYS = {
    "field_kind",
    "entity_name",
    "source_alias",
    "data_type",
    "additive_policy",
    "display_name",
    "format_hint",
    "unit_hint",
    "sensitivity_label",
    "display_policy",
    "is_hidden",
    "is_private",
    "is_certified",
    "object_columns",
    "catalog_custom_extensions",
}
RELATIONSHIP_EXTENSION_KEYS = {
    "from_entity",
    "to_entity",
    "join_condition",
    "relationship_cardinality",
    "join_type",
    "fanout_policy",
    "path_priority",
    "description",
    "requires_native_join_condition",
    "catalog_custom_extensions",
}
METRIC_EXTENSION_KEYS = {
    "data_type",
    "base_entity",
    "metric_type",
    "metric_kind",
    "aggregation_function",
    "measure_expr",
    "semantic_filter_expr",
    "sql_filter_expr",
    "distinct_key_expr",
    "non_additive_dimension",
    "window_spec_json",
    "type_params_json",
    "format_hint",
    "unit_hint",
    "display_name",
    "sensitivity_label",
    "display_policy",
    "owner_role",
    "is_private",
    "is_certified",
    "object_columns",
    "catalog_custom_extensions",
}


def diagnostic(code: str, severity: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "severity": severity, "path": path, "message": message}


def add_diagnostic(diagnostics: list[dict[str, str]], code: str, severity: str, path: str, message: str) -> None:
    diagnostics.append(diagnostic(code, severity, path, message))


def finalize_diagnostics(diagnostics: list[dict[str, str]], warnings_as_errors: bool) -> list[dict[str, str]]:
    if not warnings_as_errors:
        return diagnostics
    return [
        dict(item, severity="ERROR") if item["severity"] == "WARNING" else item
        for item in diagnostics
    ]


def diagnostics_blocking(diagnostics: list[dict[str, str]]) -> bool:
    return any(item["severity"] == "ERROR" for item in diagnostics)


def is_valid_exasol_name(value: Any) -> bool:
    return isinstance(value, str) and bool(EXASOL_NAME_RE.match(value))


def sanitize_exasol_name(value: str, prefix: str = "osi") -> str:
    name = re.sub(r"[^A-Za-z0-9_]", "_", value.strip())
    name = re.sub(r"_+", "_", name).strip("_")
    if not name:
        name = prefix
    if not re.match(r"^[A-Za-z]", name):
        name = f"{prefix}_{name}"
    return name


def generated_alias(name: str, used_aliases: set[str]) -> str:
    base = sanitize_exasol_name(name, "t").lower()
    candidate = base[:30] or "t"
    suffix = 2
    while candidate.upper() in used_aliases:
        trim_at = max(1, 30 - len(str(suffix)) - 1)
        candidate = f"{base[:trim_at]}_{suffix}"
        suffix += 1
    used_aliases.add(candidate.upper())
    return candidate


def default_published_schema(model_name: str) -> str:
    return sanitize_exasol_name(f"SEMANTIC_{model_name.upper()}", "SEMANTIC")


def json_path_key(path: str, key: str) -> str:
    return f"{path}.{key}"


def extension_path(path: str, index: int) -> str:
    return f"{path}.custom_extensions[{index}]"


def parse_exasol_extensions(value: Any, path: str, diagnostics: list[dict[str, str]]) -> list[dict[str, Any]]:
    parsed: list[dict[str, Any]] = []
    if not isinstance(value, list):
        return parsed
    for index, extension in enumerate(value):
        if not isinstance(extension, dict):
            continue
        if str(extension.get("vendor_name", "")).upper() != "EXASOL":
            continue
        data = extension.get("data")
        if not isinstance(data, str):
            continue
        try:
            parsed_data = json.loads(data)
        except json.JSONDecodeError as exc:
            add_diagnostic(
                diagnostics,
                "OSI_IMPORT_080",
                "ERROR",
                extension_path(path, index),
                f"Exasol extension data must parse as JSON: {exc.msg}",
            )
            continue
        parsed.append({"data": parsed_data, "raw_data": data, "path": extension_path(path, index)})
    return parsed


def canonical_exasol_extension(value: Any, path: str, diagnostics: list[dict[str, str]]) -> dict[str, Any]:
    extensions = parse_exasol_extensions(value, path, diagnostics)
    if not extensions:
        return {}
    if len(extensions) > 1:
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_100",
            "WARNING",
            path,
            "Multiple Exasol extensions found; using the first one as the canonical native envelope.",
        )
    data = extensions[0]["data"]
    if not isinstance(data, dict):
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_100",
            "ERROR",
            extensions[0]["path"],
            "Exasol extension envelope must be a JSON object.",
        )
        return {}
    return data


def validate_catalog_custom_extensions(value: Any, path: str, diagnostics: list[dict[str, str]]) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", path, "catalog_custom_extensions must be an array.")
        return
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        if not isinstance(item, dict):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", item_path, "catalog custom extension must be an object.")
            continue
        data = item.get("data")
        if not isinstance(data, str):
            add_diagnostic(diagnostics, "OSI_IMPORT_080", "ERROR", f"{item_path}.data", "catalog custom extension data must be a JSON string.")
            continue
        try:
            json.loads(data)
        except json.JSONDecodeError as exc:
            add_diagnostic(diagnostics, "OSI_IMPORT_080", "ERROR", f"{item_path}.data", f"catalog custom extension data must parse as JSON: {exc.msg}")


def validate_object_columns(value: Any, path: str, diagnostics: list[dict[str, str]], require_kind: bool = False) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", path, "object_columns must be an array.")
        return
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        if not isinstance(item, dict):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", item_path, "object column must be an object.")
            continue
        if "ordinal" in item and not isinstance(item["ordinal"], int):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{item_path}.ordinal", "object column ordinal must be an integer.")
        if require_kind and item.get("kind") not in {"DIMENSION", "FACT", "METRIC"}:
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{item_path}.kind", "object column kind must be DIMENSION, FACT, or METRIC.")
        if require_kind and not isinstance(item.get("name"), str):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{item_path}.name", "object column name must be a string.")


def validate_unique_key_extensions(value: Any, path: str, diagnostics: list[dict[str, str]]) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", path, "unique_keys must be an array.")
        return
    for key_index, key in enumerate(value):
        key_path = f"{path}[{key_index}]"
        if not isinstance(key, dict):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", key_path, "unique key extension must be an object.")
            continue
        if not isinstance(key.get("key_name"), str) or not key.get("key_name"):
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{key_path}.key_name", "native unique key name is required.")
        if key.get("key_kind") not in {"PRIMARY", "UNIQUE", "ALTERNATE"}:
            add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{key_path}.key_kind", "native unique key kind must be PRIMARY, UNIQUE, or ALTERNATE.")
        columns = key.get("columns")
        if not isinstance(columns, list) or not columns:
            add_diagnostic(diagnostics, "OSI_IMPORT_090", "ERROR", f"{key_path}.columns", "native unique key must contain at least one column.")


def validate_exasol_envelope(
    data: dict[str, Any],
    context: str,
    path: str,
    diagnostics: list[dict[str, str]],
) -> None:
    allowed_by_context = {
        "model": MODEL_EXTENSION_KEYS,
        "entity": ENTITY_EXTENSION_KEYS,
        "field": FIELD_EXTENSION_KEYS,
        "relationship": RELATIONSHIP_EXTENSION_KEYS,
        "metric": METRIC_EXTENSION_KEYS,
    }
    allowed = allowed_by_context[context]
    extra = sorted(set(data) - allowed)
    if extra:
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_100",
            "WARNING",
            path,
            f"Exasol extension envelope has unsupported keys that will be preserved only as extension metadata: {extra}",
        )
    validate_catalog_custom_extensions(data.get("catalog_custom_extensions"), f"{path}.catalog_custom_extensions", diagnostics)
    if context == "model":
        semantic_objects = data.get("semantic_objects")
        if semantic_objects is not None:
            if not isinstance(semantic_objects, list):
                add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{path}.semantic_objects", "semantic_objects must be an array.")
            else:
                for index, semantic_object in enumerate(semantic_objects):
                    object_path = f"{path}.semantic_objects[{index}]"
                    if not isinstance(semantic_object, dict):
                        add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", object_path, "semantic object metadata must be an object.")
                        continue
                    if not isinstance(semantic_object.get("object_name"), str) or not semantic_object.get("object_name"):
                        add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{object_path}.object_name", "semantic object name is required.")
                    validate_object_columns(semantic_object.get("columns"), f"{object_path}.columns", diagnostics, require_kind=True)
        native_relationships = data.get("relationships_requiring_native_join_condition")
        if native_relationships is not None and not isinstance(native_relationships, list):
            add_diagnostic(diagnostics, "OSI_IMPORT_110", "ERROR", f"{path}.relationships_requiring_native_join_condition", "native relationship metadata must be an array.")
    elif context == "entity":
        validate_unique_key_extensions(data.get("unique_keys"), f"{path}.unique_keys", diagnostics)
    elif context == "field":
        if "field_kind" in data and data.get("field_kind") not in {"DIMENSION", "FACT"}:
            add_diagnostic(diagnostics, "OSI_IMPORT_040", "ERROR", f"{path}.field_kind", "field_kind must be DIMENSION or FACT.")
        validate_object_columns(data.get("object_columns"), f"{path}.object_columns", diagnostics)
    elif context == "relationship":
        if data.get("requires_native_join_condition") and not data.get("join_condition"):
            add_diagnostic(diagnostics, "OSI_IMPORT_110", "ERROR", path, "relationship marked as native join but join_condition is missing.")
    elif context == "metric":
        validate_object_columns(data.get("object_columns"), f"{path}.object_columns", diagnostics)


def selected_expression(expression: dict[str, Any], path: str, diagnostics: list[dict[str, str]], strict: bool) -> str | None:
    dialects = expression.get("dialects")
    if not isinstance(dialects, list):
        return None
    fallback: str | None = None
    fallback_dialect: str | None = None
    for dialect in dialects:
        if not isinstance(dialect, dict):
            continue
        if isinstance(dialect.get("expression"), str) and fallback is None:
            fallback = dialect["expression"]
            fallback_dialect = str(dialect.get("dialect"))
        if dialect.get("dialect") == OSI_DIALECT and isinstance(dialect.get("expression"), str):
            return dialect["expression"]
    if fallback is not None:
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_070",
            "ERROR" if strict else "WARNING",
            path,
            f"No {OSI_DIALECT} expression found; using {fallback_dialect}.",
        )
    return fallback


def parse_source(source: str, path: str, diagnostics: list[dict[str, str]]) -> tuple[str | None, str | None]:
    pieces = [piece.strip() for piece in source.split(".")]
    if len(pieces) != 2 or not all(pieces):
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_020",
            "ERROR",
            path,
            "Dataset source must map to an Exasol schema.object reference.",
        )
        return None, None
    return pieces[0], pieces[1]


def primary_key_expression(alias: str, columns: list[str] | None) -> str | None:
    if not columns:
        return None
    if len(columns) == 1:
        return f"{alias}.{columns[0]}"
    return " || '-' || ".join(f"CAST({alias}.{column} AS VARCHAR(36))" for column in columns)


def normalize_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).lower() in {"true", "1", "yes"}


def add_operation(
    operations: list[dict[str, Any]],
    operation: str,
    target: str,
    source_path: str,
    arguments: dict[str, Any],
    metadata: dict[str, Any] | None = None,
) -> None:
    payload = {
        "operation": operation,
        "target": target,
        "source_path": source_path,
        "arguments": clean_json_value(arguments),
    }
    if metadata:
        payload["metadata"] = clean_json_value(metadata)
    operations.append(payload)


def non_exasol_extension_operations(
    model_name: str,
    scope_type: str,
    scope_name: str | None,
    extensions: Any,
    source_path: str,
    operations: list[dict[str, Any]],
) -> None:
    if not isinstance(extensions, list):
        return
    for index, extension in enumerate(extensions):
        if not isinstance(extension, dict):
            continue
        vendor_name = extension.get("vendor_name")
        data = extension.get("data")
        if not isinstance(vendor_name, str) or vendor_name.upper() == "EXASOL" or not isinstance(data, str):
            continue
        add_operation(
            operations,
            "add_custom_extension",
            "SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION",
            extension_path(source_path, index),
            {
                "model_name": model_name,
                "scope_type": scope_type,
                "scope_name": scope_name,
                "vendor_name": vendor_name,
                "data_json": data,
                "source_format": "OSI",
                "extension_name": "default",
            },
        )


def catalog_extension_operations(
    model_name: str,
    scope_type: str,
    scope_name: str | None,
    catalog_extensions: Any,
    source_path: str,
    operations: list[dict[str, Any]],
) -> None:
    if not isinstance(catalog_extensions, list):
        return
    for index, item in enumerate(catalog_extensions):
        if not isinstance(item, dict) or not isinstance(item.get("data"), str):
            continue
        add_operation(
            operations,
            "add_custom_extension",
            "SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION",
            f"{source_path}.catalog_custom_extensions[{index}]",
            {
                "model_name": model_name,
                "scope_type": scope_type,
                "scope_name": scope_name,
                "vendor_name": "EXASOL",
                "data_json": item["data"],
                "source_format": item.get("source_format") or "OSI",
                "extension_name": item.get("extension_name") or "default",
            },
        )


def ai_context_operations(
    model_name: str,
    object_type: str,
    object_name: str | None,
    ai_context: Any,
    source_path: str,
    operations: list[dict[str, Any]],
    diagnostics: list[dict[str, str]],
) -> None:
    if ai_context is None:
        return
    instructions: str | None = None
    synonyms: list[str] = []
    examples: list[str] = []
    if isinstance(ai_context, str):
        instructions = ai_context
    elif isinstance(ai_context, dict):
        if isinstance(ai_context.get("instructions"), str):
            instructions = ai_context["instructions"]
        if isinstance(ai_context.get("synonyms"), list):
            synonyms = [item for item in ai_context["synonyms"] if isinstance(item, str)]
        if isinstance(ai_context.get("examples"), list):
            examples = [item for item in ai_context["examples"] if isinstance(item, str)]

    if synonyms:
        if object_type in {"ENTITY", "DIMENSION", "FACT", "METRIC", "SEMANTIC_OBJECT"} and object_name:
            for index, synonym in enumerate(synonyms):
                add_operation(
                    operations,
                    "add_synonym",
                    "SEMANTIC_ADMIN.ADD_SYNONYM",
                    f"{source_path}.ai_context.synonyms[{index}]",
                    {
                        "model_name": model_name,
                        "object_type": object_type,
                        "object_name": object_name,
                        "synonym": synonym,
                        "source": "OSI",
                    },
                )
        else:
            add_diagnostic(
                diagnostics,
                "OSI_IMPORT_120",
                "WARNING",
                f"{source_path}.ai_context.synonyms",
                f"Synonyms for {object_type} are not supported by the current admin helper surface.",
            )
    if instructions:
        if object_type in {"MODEL", "SEMANTIC_OBJECT", "ENTITY", "DIMENSION", "FACT", "METRIC"}:
            add_operation(
                operations,
                "add_agent_instruction",
                "SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION",
                f"{source_path}.ai_context.instructions",
                {
                    "model_name": model_name,
                    "scope_type": object_type,
                    "scope_name": object_name,
                    "instruction_kind": "GENERAL",
                    "instruction_text": instructions,
                    "applies_to_role": None,
                    "priority": 100,
                },
            )
        else:
            add_diagnostic(
                diagnostics,
                "OSI_IMPORT_120",
                "WARNING",
                f"{source_path}.ai_context.instructions",
                f"Instructions for {object_type} are not supported by the current admin helper surface.",
            )
    for index, example in enumerate(examples):
        add_operation(
            operations,
            "add_agent_instruction",
            "SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION",
            f"{source_path}.ai_context.examples[{index}]",
            {
                "model_name": model_name,
                "scope_type": object_type if object_type in {"MODEL", "SEMANTIC_OBJECT", "ENTITY", "DIMENSION", "FACT", "METRIC"} else "MODEL",
                "scope_name": object_name if object_type in {"SEMANTIC_OBJECT", "ENTITY", "DIMENSION", "FACT", "METRIC"} else None,
                "instruction_kind": "GENERAL",
                "instruction_text": f"Example: {example}",
                "applies_to_role": None,
                "priority": 200,
            },
        )


def semantic_objects_for_model(model: dict[str, Any], model_ext: dict[str, Any], datasets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    semantic_objects = model_ext.get("semantic_objects")
    if isinstance(semantic_objects, list) and semantic_objects:
        return [item for item in semantic_objects if isinstance(item, dict)]
    root_entity = datasets[0]["name"] if datasets else "root"
    if isinstance(model_ext.get("semantic_object"), str) and model_ext["semantic_object"]:
        return [{"object_name": model_ext["semantic_object"], "root_entity": root_entity, "columns": []}]
    return [{"object_name": sanitize_exasol_name(str(model.get("name", "OSI_MODEL")).upper(), "OBJECT"), "root_entity": root_entity, "columns": []}]


def object_name_for_member(
    member_name: str,
    member_kind: str,
    member_ext: dict[str, Any],
    semantic_objects: list[dict[str, Any]],
) -> str:
    object_columns = member_ext.get("object_columns")
    if isinstance(object_columns, list) and object_columns:
        sorted_columns = sorted(
            [item for item in object_columns if isinstance(item, dict) and isinstance(item.get("object_name"), str)],
            key=lambda item: item.get("ordinal", 10_000_000),
        )
        if sorted_columns:
            return str(sorted_columns[0]["object_name"])
    for semantic_object in semantic_objects:
        for column in semantic_object.get("columns") or []:
            if not isinstance(column, dict):
                continue
            if column.get("name") == member_name and column.get("kind") == member_kind:
                return str(semantic_object["object_name"])
    return str(semantic_objects[0]["object_name"])


def generated_unique_key_name(entity_name: str, key_kind: str, index: int | None = None) -> str:
    if key_kind == "PRIMARY":
        return sanitize_exasol_name(f"{entity_name}_primary_key", "key")
    return sanitize_exasol_name(f"{entity_name}_unique_key_{index or 1}", "key")


def planned_core_keys(dataset: dict[str, Any], entity_name: str) -> list[dict[str, Any]]:
    keys = []
    primary_key = dataset.get("primary_key")
    if isinstance(primary_key, list) and primary_key:
        keys.append(
            {
                "key_name": generated_unique_key_name(entity_name, "PRIMARY"),
                "key_kind": "PRIMARY",
                "source_format": "OSI",
                "description": "Imported from OSI primary_key.",
                "columns": [{"ordinal": index + 1, "column_name": column} for index, column in enumerate(primary_key)],
            }
        )
    unique_keys = dataset.get("unique_keys")
    if isinstance(unique_keys, list):
        for key_index, unique_key in enumerate(unique_keys, start=1):
            if isinstance(unique_key, list):
                keys.append(
                    {
                        "key_name": generated_unique_key_name(entity_name, "UNIQUE", key_index),
                        "key_kind": "UNIQUE",
                        "source_format": "OSI",
                        "description": "Imported from OSI unique_keys.",
                        "columns": [{"ordinal": index + 1, "column_name": column} for index, column in enumerate(unique_key)],
                    }
                )
    return keys


def add_key_operations(
    model_name: str,
    entity_name: str,
    keys: list[dict[str, Any]],
    source_path: str,
    operations: list[dict[str, Any]],
    diagnostics: list[dict[str, str]],
) -> None:
    for key_index, key in enumerate(keys):
        key_path = f"{source_path}.keys[{key_index}]"
        key_name = key.get("key_name")
        key_kind = key.get("key_kind") or "UNIQUE"
        if not is_valid_exasol_name(key_name):
            add_diagnostic(diagnostics, "OSI_IMPORT_090", "ERROR", f"{key_path}.key_name", f"Unique key name cannot map to Exasol: {key_name!r}.")
            continue
        add_operation(
            operations,
            "add_unique_key",
            "SEMANTIC_ADMIN.ADD_UNIQUE_KEY",
            key_path,
            {
                "model_name": model_name,
                "entity_name": entity_name,
                "key_name": key_name,
                "key_kind": key_kind,
                "description": key.get("description"),
                "source_format": key.get("source_format") or "OSI",
            },
        )
        columns = key.get("columns")
        if not isinstance(columns, list) or not columns:
            add_diagnostic(diagnostics, "OSI_IMPORT_090", "ERROR", f"{key_path}.columns", "Unique key must contain at least one column.")
            continue
        for ordinal, column in enumerate(columns, start=1):
            if not isinstance(column, dict):
                add_diagnostic(diagnostics, "OSI_IMPORT_090", "ERROR", f"{key_path}.columns[{ordinal - 1}]", "Unique key column must be an object.")
                continue
            column_name = column.get("column_name")
            expression = column.get("expression")
            add_operation(
                operations,
                "add_unique_key_column",
                "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN",
                f"{key_path}.columns[{ordinal - 1}]",
                {
                    "model_name": model_name,
                    "entity_name": entity_name,
                    "key_name": key_name,
                    "column_name": column_name,
                    "expression": expression,
                    "ordinal_position": column.get("ordinal") or ordinal,
                },
            )


def normalize_metric_type(metric_ext: dict[str, Any], path: str, diagnostics: list[dict[str, str]]) -> str:
    metric_type = str(metric_ext.get("metric_type") or metric_ext.get("metric_kind") or "DERIVED").upper()
    if metric_type == "SIMPLE" or metric_type == "FILTERED":
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_120",
            "WARNING",
            path,
            f"Native metric_type {metric_type!r} maps to ADDITIVE for the current admin helper surface.",
        )
        return "ADDITIVE"
    if metric_type not in NATIVE_METRIC_TYPES:
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_050",
            "WARNING",
            path,
            f"Metric type {metric_type!r} is not supported by ADD_METRIC; planning DERIVED.",
        )
        return "DERIVED"
    return metric_type


def build_relationship_join(
    relationship: dict[str, Any],
    relationship_ext: dict[str, Any],
    aliases_by_entity: dict[str, str],
    path: str,
    diagnostics: list[dict[str, str]],
) -> str | None:
    if relationship_ext.get("join_condition"):
        return str(relationship_ext["join_condition"])
    from_entity = relationship.get("from")
    to_entity = relationship.get("to")
    from_columns = relationship.get("from_columns")
    to_columns = relationship.get("to_columns")
    if not isinstance(from_entity, str) or not isinstance(to_entity, str):
        return None
    if from_entity not in aliases_by_entity or to_entity not in aliases_by_entity:
        add_diagnostic(diagnostics, "OSI_IMPORT_060", "ERROR", path, "Relationship references an unknown dataset.")
        return None
    if not isinstance(from_columns, list) or not isinstance(to_columns, list) or len(from_columns) != len(to_columns):
        add_diagnostic(diagnostics, "OSI_IMPORT_060", "ERROR", path, "Relationship from_columns and to_columns must have the same length.")
        return None
    pieces = []
    for from_column, to_column in zip(from_columns, to_columns):
        pieces.append(f"{aliases_by_entity[from_entity]}.{from_column} = {aliases_by_entity[to_entity]}.{to_column}")
    return " AND ".join(pieces)


def plan_import(document: dict[str, Any], options: ImportOptions) -> dict[str, Any]:
    validate_document(document)
    diagnostics: list[dict[str, str]] = []
    operations: list[dict[str, Any]] = []

    models = document.get("semantic_model")
    if not isinstance(models, list):
        raise OsiValidationError(["$.semantic_model must be an array"])
    if options.target_model and len(models) != 1:
        add_diagnostic(
            diagnostics,
            "OSI_IMPORT_010",
            "ERROR",
            "$.semantic_model",
            "--target-model can only be used when the OSI document contains one semantic model.",
        )

    plan_models: list[dict[str, Any]] = []
    for model_index, model in enumerate(models):
        model_path = f"$.semantic_model[{model_index}]"
        if not isinstance(model, dict):
            continue
        model_ext = canonical_exasol_extension(model.get("custom_extensions"), model_path, diagnostics)
        if model_ext:
            validate_exasol_envelope(model_ext, "model", f"{model_path}.custom_extensions[0].data", diagnostics)
        profile = options.profile
        if profile == "auto":
            profile = str(model_ext.get("profile") or "interoperability")
        if profile not in VALID_PROFILES:
            add_diagnostic(diagnostics, "OSI_IMPORT_001", "ERROR", model_path, f"Unsupported import profile: {profile}")
            profile = "interoperability"

        source_model_name = str(model.get("name"))
        model_name = options.target_model or source_model_name
        if not is_valid_exasol_name(model_name):
            add_diagnostic(diagnostics, "OSI_IMPORT_010", "ERROR", f"{model_path}.name", f"Model name cannot map to Exasol: {model_name!r}.")
            model_name = sanitize_exasol_name(model_name, "model")
        published_schema = options.published_schema or model_ext.get("published_schema") or default_published_schema(model_name)
        if not is_valid_exasol_name(published_schema):
            add_diagnostic(diagnostics, "OSI_IMPORT_020", "ERROR", f"{model_path}.custom_extensions", f"Published schema cannot map to Exasol: {published_schema!r}.")
            published_schema = default_published_schema(model_name)

        datasets = model.get("datasets")
        if not isinstance(datasets, list):
            datasets = []
        semantic_objects = semantic_objects_for_model(model, model_ext, datasets)
        add_operation(
            operations,
            "create_model",
            "SEMANTIC_ADMIN.CREATE_MODEL",
            model_path,
            {
                "model_name": model_name,
                "published_schema": published_schema,
                "description": model.get("description"),
                "owner_role": model_ext.get("owner_role"),
            },
        )
        catalog_extension_operations(model_name, "MODEL", None, model_ext.get("catalog_custom_extensions"), f"{model_path}.custom_extensions[0].data", operations)
        non_exasol_extension_operations(model_name, "MODEL", None, model.get("custom_extensions"), model_path, operations)
        ai_context_operations(model_name, "MODEL", None, model.get("ai_context"), model_path, operations, diagnostics)

        aliases_by_entity: dict[str, str] = {}
        entity_ext_by_name: dict[str, dict[str, Any]] = {}
        dataset_by_entity: dict[str, dict[str, Any]] = {}
        used_aliases: set[str] = set()
        field_specs: list[dict[str, Any]] = []
        metric_specs: list[dict[str, Any]] = []

        for dataset_index, dataset in enumerate(datasets):
            dataset_path = f"{model_path}.datasets[{dataset_index}]"
            if not isinstance(dataset, dict):
                continue
            entity_ext = canonical_exasol_extension(dataset.get("custom_extensions"), dataset_path, diagnostics)
            if entity_ext:
                validate_exasol_envelope(entity_ext, "entity", f"{dataset_path}.custom_extensions[0].data", diagnostics)
            source_schema = entity_ext.get("source_schema")
            source_object = entity_ext.get("source_object")
            if not source_schema or not source_object:
                parsed_schema, parsed_object = parse_source(str(dataset.get("source", "")), f"{dataset_path}.source", diagnostics)
                source_schema = source_schema or parsed_schema
                source_object = source_object or parsed_object
            entity_name = str(entity_ext.get("entity_name") or dataset.get("name"))
            if not is_valid_exasol_name(entity_name):
                add_diagnostic(diagnostics, "OSI_IMPORT_020", "ERROR", f"{dataset_path}.name", f"Dataset name cannot map to Exasol entity: {entity_name!r}.")
                entity_name = sanitize_exasol_name(entity_name, "entity")
            source_alias = entity_ext.get("source_alias")
            if isinstance(source_alias, str) and is_valid_exasol_name(source_alias):
                if source_alias.upper() in used_aliases:
                    add_diagnostic(diagnostics, "OSI_IMPORT_020", "ERROR", f"{dataset_path}.custom_extensions", f"Duplicate source alias: {source_alias}.")
                used_aliases.add(source_alias.upper())
            else:
                source_alias = generated_alias(entity_name, used_aliases)
                add_diagnostic(
                    diagnostics,
                    "OSI_IMPORT_020",
                    "WARNING",
                    dataset_path,
                    f"Dataset has no Exasol source_alias extension; generated alias {source_alias!r}.",
                )
            primary_key_expr = entity_ext.get("primary_key_expr") or primary_key_expression(str(source_alias), dataset.get("primary_key"))

            add_operation(
                operations,
                "add_entity",
                "SEMANTIC_ADMIN.ADD_ENTITY",
                dataset_path,
                {
                    "model_name": model_name,
                    "entity_name": entity_name,
                    "source_schema": source_schema,
                    "source_object": source_object,
                    "source_alias": source_alias,
                    "primary_key_expr": primary_key_expr,
                    "grain_description": entity_ext.get("grain_description"),
                    "description": dataset.get("description") or entity_ext.get("description"),
                },
            )
            aliases_by_entity[entity_name] = str(source_alias)
            entity_ext_by_name[entity_name] = entity_ext
            dataset_by_entity[entity_name] = dataset
            catalog_extension_operations(model_name, "ENTITY", entity_name, entity_ext.get("catalog_custom_extensions"), f"{dataset_path}.custom_extensions[0].data", operations)
            non_exasol_extension_operations(model_name, "ENTITY", entity_name, dataset.get("custom_extensions"), dataset_path, operations)
            ai_context_operations(model_name, "ENTITY", entity_name, dataset.get("ai_context"), dataset_path, operations, diagnostics)

            native_keys = entity_ext.get("unique_keys")
            key_source_path = f"{dataset_path}.custom_extensions[0].data.unique_keys"
            if not isinstance(native_keys, list) or not native_keys:
                native_keys = planned_core_keys(dataset, entity_name)
                key_source_path = dataset_path
            add_key_operations(model_name, entity_name, list(native_keys), key_source_path, operations, diagnostics)

            fields = dataset.get("fields")
            if isinstance(fields, list):
                for field_index, field in enumerate(fields):
                    if not isinstance(field, dict):
                        continue
                    field_specs.append(
                        {
                            "field": field,
                            "path": f"{dataset_path}.fields[{field_index}]",
                            "entity_name": entity_name,
                        }
                    )

        for semantic_object_index, semantic_object in enumerate(semantic_objects):
            object_path = f"{model_path}.custom_extensions[0].data.semantic_objects[{semantic_object_index}]"
            object_name = semantic_object.get("object_name")
            root_entity = semantic_object.get("root_entity") or (datasets[0]["name"] if datasets else None)
            if not is_valid_exasol_name(object_name):
                add_diagnostic(diagnostics, "OSI_IMPORT_100", "ERROR", f"{object_path}.object_name", f"Semantic object name cannot map to Exasol: {object_name!r}.")
                continue
            if root_entity not in aliases_by_entity:
                add_diagnostic(diagnostics, "OSI_IMPORT_020", "ERROR", f"{object_path}.root_entity", f"Semantic object root entity is unknown: {root_entity!r}.")
                continue
            add_operation(
                operations,
                "add_semantic_object",
                "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT",
                object_path,
                {
                    "model_name": model_name,
                    "object_name": object_name,
                    "root_entity_name": root_entity,
                    "description": semantic_object.get("description"),
                },
                metadata={"columns": semantic_object.get("columns") or []},
            )
            non_exasol_extension_operations(model_name, "SEMANTIC_OBJECT", str(object_name), semantic_object.get("custom_extensions"), object_path, operations)

        for relationship_index, relationship in enumerate(model.get("relationships") or []):
            if not isinstance(relationship, dict):
                continue
            relationship_path = f"{model_path}.relationships[{relationship_index}]"
            relationship_ext = canonical_exasol_extension(relationship.get("custom_extensions"), relationship_path, diagnostics)
            if relationship_ext:
                validate_exasol_envelope(relationship_ext, "relationship", f"{relationship_path}.custom_extensions[0].data", diagnostics)
            from_entity = str(relationship_ext.get("from_entity") or relationship.get("from"))
            to_entity = str(relationship_ext.get("to_entity") or relationship.get("to"))
            join_condition = build_relationship_join(relationship, relationship_ext, aliases_by_entity, relationship_path, diagnostics)
            if not join_condition:
                continue
            if from_entity not in aliases_by_entity or to_entity not in aliases_by_entity:
                add_diagnostic(diagnostics, "OSI_IMPORT_060", "ERROR", relationship_path, "Relationship references an unknown entity.")
                continue
            add_operation(
                operations,
                "add_relationship",
                "SEMANTIC_ADMIN.ADD_RELATIONSHIP",
                relationship_path,
                {
                    "model_name": model_name,
                    "relationship_name": relationship.get("name"),
                    "from_entity_name": from_entity,
                    "to_entity_name": to_entity,
                    "join_condition": join_condition,
                    "cardinality": relationship_ext.get("relationship_cardinality") or "MANY_TO_ONE",
                    "join_type": relationship_ext.get("join_type") or "LEFT",
                    "fanout_policy": relationship_ext.get("fanout_policy"),
                },
                metadata={"requires_native_join_condition": bool(relationship_ext.get("requires_native_join_condition"))},
            )
            catalog_extension_operations(model_name, "RELATIONSHIP", str(relationship.get("name")), relationship_ext.get("catalog_custom_extensions"), f"{relationship_path}.custom_extensions[0].data", operations)
            non_exasol_extension_operations(model_name, "RELATIONSHIP", str(relationship.get("name")), relationship.get("custom_extensions"), relationship_path, operations)
            ai_context_operations(model_name, "RELATIONSHIP", str(relationship.get("name")), relationship.get("ai_context"), relationship_path, operations, diagnostics)

        native_relationships = model_ext.get("relationships_requiring_native_join_condition")
        if isinstance(native_relationships, list):
            for rel_index, rel in enumerate(native_relationships):
                if not isinstance(rel, dict):
                    continue
                native_path = f"{model_path}.custom_extensions[0].data.relationships_requiring_native_join_condition[{rel_index}]"
                if not rel.get("join_condition"):
                    add_diagnostic(diagnostics, "OSI_IMPORT_110", "ERROR", native_path, "Native relationship extension is missing join_condition.")
                    continue
                add_operation(
                    operations,
                    "add_relationship",
                    "SEMANTIC_ADMIN.ADD_RELATIONSHIP",
                    native_path,
                    {
                        "model_name": model_name,
                        "relationship_name": rel.get("relationship_name") or sanitize_exasol_name(f"{rel.get('from_entity')}_to_{rel.get('to_entity')}", "relationship"),
                        "from_entity_name": rel.get("from_entity"),
                        "to_entity_name": rel.get("to_entity"),
                        "join_condition": rel.get("join_condition"),
                        "cardinality": rel.get("relationship_cardinality") or "MANY_TO_ONE",
                        "join_type": rel.get("join_type") or "LEFT",
                        "fanout_policy": rel.get("fanout_policy"),
                    },
                    metadata={"requires_native_join_condition": True},
                )

        for spec in field_specs:
            field = spec["field"]
            field_path = spec["path"]
            field_ext = canonical_exasol_extension(field.get("custom_extensions"), field_path, diagnostics)
            if field_ext:
                validate_exasol_envelope(field_ext, "field", f"{field_path}.custom_extensions[0].data", diagnostics)
            field_kind = field_ext.get("field_kind")
            if not field_kind:
                if "dimension" in field:
                    field_kind = "DIMENSION"
                elif str(field.get("label", "")).lower() == "fact":
                    field_kind = "FACT"
                else:
                    field_kind = "DIMENSION"
                    add_diagnostic(
                        diagnostics,
                        "OSI_IMPORT_040",
                        "ERROR" if options.strict else "WARNING",
                        field_path,
                        "Field classification is ambiguous; planning it as a dimension.",
                    )
            field_kind = str(field_kind).upper()
            entity_name = str(field_ext.get("entity_name") or spec["entity_name"])
            expression = selected_expression(field["expression"], json_path_key(field_path, "expression"), diagnostics, options.strict)
            data_type = field_ext.get("data_type")
            if not data_type:
                data_type = "DATE" if field.get("dimension", {}).get("is_time") else ("DECIMAL(36,6)" if field_kind == "FACT" else "VARCHAR(2000000)")
                add_diagnostic(
                    diagnostics,
                    "OSI_IMPORT_030",
                    "ERROR" if options.strict else "WARNING",
                    field_path,
                    f"Field datatype missing; planning fallback {data_type}.",
                )
            object_name = object_name_for_member(str(field.get("name")), field_kind, field_ext, semantic_objects)
            if field_kind == "DIMENSION":
                add_operation(
                    operations,
                    "add_dimension",
                    "SEMANTIC_ADMIN.ADD_DIMENSION",
                    field_path,
                    {
                        "model_name": model_name,
                        "object_name": object_name,
                        "entity_name": entity_name,
                        "dimension_name": field.get("name"),
                        "expression": expression,
                        "data_type": data_type,
                        "display_name": field_ext.get("display_name"),
                        "description": field.get("description"),
                        "format_hint": field_ext.get("format_hint"),
                        "is_certified": normalize_bool(field_ext.get("is_certified"), False),
                    },
                    metadata={"object_columns": field_ext.get("object_columns") or []},
                )
                scope_type = "DIMENSION"
            elif field_kind == "FACT":
                add_operation(
                    operations,
                    "add_fact",
                    "SEMANTIC_ADMIN.ADD_FACT",
                    field_path,
                    {
                        "model_name": model_name,
                        "entity_name": entity_name,
                        "fact_name": field.get("name"),
                        "expression": expression,
                        "data_type": data_type,
                        "additive_policy": field_ext.get("additive_policy") or "ADDITIVE",
                        "display_name": field_ext.get("display_name"),
                        "description": field.get("description"),
                        "is_private": normalize_bool(field_ext.get("is_private"), False),
                        "is_certified": normalize_bool(field_ext.get("is_certified"), False),
                    },
                    metadata={"object_columns": field_ext.get("object_columns") or []},
                )
                scope_type = "FACT"
            else:
                add_diagnostic(diagnostics, "OSI_IMPORT_040", "ERROR", field_path, f"Unsupported field_kind: {field_kind}.")
                continue
            catalog_extension_operations(model_name, scope_type, str(field.get("name")), field_ext.get("catalog_custom_extensions"), f"{field_path}.custom_extensions[0].data", operations)
            non_exasol_extension_operations(model_name, scope_type, str(field.get("name")), field.get("custom_extensions"), field_path, operations)
            ai_context_operations(model_name, scope_type, str(field.get("name")), field.get("ai_context"), field_path, operations, diagnostics)

        for metric_index, metric in enumerate(model.get("metrics") or []):
            if not isinstance(metric, dict):
                continue
            metric_path = f"{model_path}.metrics[{metric_index}]"
            metric_ext = canonical_exasol_extension(metric.get("custom_extensions"), metric_path, diagnostics)
            if metric_ext:
                validate_exasol_envelope(metric_ext, "metric", f"{metric_path}.custom_extensions[0].data", diagnostics)
            base_entity = metric_ext.get("base_entity")
            if not base_entity:
                if len(aliases_by_entity) == 1:
                    base_entity = next(iter(aliases_by_entity))
                else:
                    add_diagnostic(diagnostics, "OSI_IMPORT_050", "ERROR", metric_path, "Metric base entity is ambiguous without Exasol extension metadata.")
                    base_entity = next(iter(aliases_by_entity), None)
            elif base_entity not in aliases_by_entity:
                add_diagnostic(diagnostics, "OSI_IMPORT_050", "ERROR", metric_path, f"Metric base entity is unknown: {base_entity!r}.")
            expression = selected_expression(metric["expression"], json_path_key(metric_path, "expression"), diagnostics, options.strict)
            data_type = metric_ext.get("data_type")
            if not data_type:
                data_type = "DECIMAL(36,6)"
                add_diagnostic(
                    diagnostics,
                    "OSI_IMPORT_030",
                    "ERROR" if options.strict else "WARNING",
                    metric_path,
                    f"Metric datatype missing; planning fallback {data_type}.",
                )
            object_name = object_name_for_member(str(metric.get("name")), "METRIC", metric_ext, semantic_objects)
            metric_type = normalize_metric_type(metric_ext, f"{metric_path}.custom_extensions[0].data.metric_type", diagnostics)
            add_operation(
                operations,
                "add_metric",
                "SEMANTIC_ADMIN.ADD_METRIC",
                metric_path,
                {
                    "model_name": model_name,
                    "object_name": object_name,
                    "metric_name": metric.get("name"),
                    "expression": expression,
                    "filter_expr": metric_ext.get("sql_filter_expr") or metric_ext.get("semantic_filter_expr"),
                    "metric_type": metric_type,
                    "base_entity_name": base_entity,
                    "data_type": data_type,
                    "display_name": metric_ext.get("display_name"),
                    "description": metric.get("description"),
                    "format_hint": metric_ext.get("format_hint"),
                    "is_private": normalize_bool(metric_ext.get("is_private"), False),
                    "is_certified": normalize_bool(metric_ext.get("is_certified"), False),
                },
                metadata={
                    "metric_kind": metric_ext.get("metric_kind"),
                    "object_columns": metric_ext.get("object_columns") or [],
                    "native": clean_json_value(metric_ext),
                },
            )
            catalog_extension_operations(model_name, "METRIC", str(metric.get("name")), metric_ext.get("catalog_custom_extensions"), f"{metric_path}.custom_extensions[0].data", operations)
            non_exasol_extension_operations(model_name, "METRIC", str(metric.get("name")), metric.get("custom_extensions"), metric_path, operations)
            ai_context_operations(model_name, "METRIC", str(metric.get("name")), metric.get("ai_context"), metric_path, operations, diagnostics)

        plan_models.append(
            clean_json_value(
                {
                    "source_path": model_path,
                    "source_model_name": source_model_name,
                    "model_name": model_name,
                    "published_schema": published_schema,
                    "profile": profile,
                    "semantic_objects": [
                        {
                            "object_name": item.get("object_name"),
                            "root_entity": item.get("root_entity"),
                            "column_count": len(item.get("columns") or []),
                        }
                        for item in semantic_objects
                    ],
                }
            )
        )

    diagnostics = finalize_diagnostics(diagnostics, options.warnings_as_errors)
    status = "blocked" if diagnostics_blocking(diagnostics) else "ok"
    return clean_json_value(
        {
            "version": OSI_VERSION,
            "mode": "dry-run",
            "status": status,
            "source": options.source,
            "models": plan_models,
            "diagnostics": diagnostics,
            "operations": operations,
        }
    )


def dump_json(document: dict[str, Any]) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def dump_yaml(document: dict[str, Any]) -> str:
    try:
        import yaml  # type: ignore
    except ImportError as exc:
        raise OsiError("PyYAML is required for YAML output. Use --format json or install PyYAML.") from exc
    text = yaml.safe_dump(document, sort_keys=False, allow_unicode=True, width=120)
    text = re.sub(r"^version:\s+0\.2\.0\.dev0$", f'version: "{OSI_VERSION}"', text, count=1, flags=re.MULTILINE)
    return text


def write_output(text: str, path: Path | None) -> None:
    if path is None:
        sys.stdout.write(text)
    else:
        path.write_text(text, encoding="utf-8")


def write_warnings(warnings: list[dict[str, Any]], path: Path | None) -> None:
    payload = json.dumps({"warnings": warnings}, ensure_ascii=False, indent=2) + "\n"
    if path is not None:
        path.write_text(payload, encoding="utf-8")
    elif warnings:
        sys.stderr.write(payload)


def infer_output_format(format_arg: str, output: Path | None) -> str:
    if format_arg != "auto":
        return format_arg
    if output and output.suffix.lower() == ".json":
        return "json"
    return "yaml"


def command_export(args: argparse.Namespace) -> int:
    options = ExportOptions(model_name=args.model, object_name=args.object, profile=args.profile)
    con = connect(args)
    try:
        document, warnings = export_model(con, options)
    finally:
        con.close()
    output_format = infer_output_format(args.format, args.output)
    text = dump_json(document) if output_format == "json" else dump_yaml(document)
    write_output(text, args.output)
    write_warnings(warnings, args.warnings_output)
    return 0


def command_validate(args: argparse.Namespace) -> int:
    document = load_document(args.path)
    validate_document(document)
    if not args.quiet:
        print(f"ok {args.path}: OSI {OSI_VERSION}")
    return 0


def command_import(args: argparse.Namespace) -> int:
    if not args.dry_run:
        raise OsiError("Milestone 3 only supports import planning. Re-run with --dry-run.")
    document = load_document(args.path)
    plan = plan_import(
        document,
        ImportOptions(
            profile=args.profile,
            strict=args.strict,
            warnings_as_errors=args.warnings_as_errors,
            target_model=args.target_model,
            published_schema=args.published_schema,
            source=str(args.path),
        ),
    )
    write_output(dump_json(plan), args.output)
    return 1 if plan["status"] == "blocked" else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Open Semantic Interchange tooling for Exasol Semantic Views.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export", help="export a semantic model as OSI")
    export_parser.add_argument("--model", required=True, help="semantic model name")
    export_parser.add_argument("--object", help="semantic object name for object-scoped interoperability export")
    export_parser.add_argument("--profile", choices=sorted(VALID_PROFILES), default="interoperability")
    export_parser.add_argument("--format", choices=["auto", "json", "yaml"], default="auto")
    export_parser.add_argument("--output", type=Path)
    export_parser.add_argument("--warnings-output", type=Path)
    export_parser.add_argument("--host", default=os.environ.get("EXASOL_HOST", "localhost"))
    export_parser.add_argument("--port", default=int(os.environ.get("EXASOL_PORT", "8563")), type=int)
    export_parser.add_argument("--user", default=os.environ.get("EXASOL_USER", "sys"))
    export_parser.add_argument("--password", default=os.environ.get("EXASOL_PASSWORD", "exasol"))
    export_parser.add_argument(
        "--tls-verify",
        action="store_true",
        default=os.environ.get("EXASOL_TLS_VERIFY", "").lower() in {"1", "true", "yes"},
        help="verify Exasol TLS certificate; disabled by default for local Nano",
    )
    export_parser.set_defaults(func=command_export)

    validate_parser = subparsers.add_parser("validate", help="validate an OSI JSON/YAML file")
    validate_parser.add_argument("path", type=Path)
    validate_parser.add_argument("--quiet", action="store_true")
    validate_parser.set_defaults(func=command_validate)

    import_parser = subparsers.add_parser("import", help="plan an OSI import")
    import_parser.add_argument("path", type=Path)
    import_parser.add_argument("--dry-run", action="store_true", help="produce a normalized import plan without database writes")
    import_parser.add_argument("--profile", choices=["auto", *sorted(VALID_PROFILES)], default="auto")
    import_parser.add_argument("--strict", action="store_true", help="treat lossy or ambiguous OSI mapping as blocking")
    import_parser.add_argument("--warnings-as-errors", action="store_true")
    import_parser.add_argument("--target-model", help="override the imported model name")
    import_parser.add_argument("--published-schema", help="override the imported model published schema")
    import_parser.add_argument("--output", type=Path)
    import_parser.set_defaults(func=command_import)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except OsiValidationError as exc:
        for error in exc.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    except (OsiError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
