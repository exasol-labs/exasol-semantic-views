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
