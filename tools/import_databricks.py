#!/usr/bin/env python3
"""Import a Databricks Unity Catalog Metric View (UCMV) YAML into Exasol.

This is a thin host-side transport: it reads a .yaml file and hands the text to
the in-database translator SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW, which
does the actual YAML parsing and translation in Lua. The generated native DDL
and any diagnostics are printed.

Usage:
  python3 tools/import_databricks.py <file.yaml> --model <name> [--schema <SCHEMA>] [--apply]

Connection defaults come from EXASOL_HOST/PORT/USER/PASSWORD.
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any


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


def import_metric_view(con, yaml_text: str, model: str, schema: str | None, apply: bool) -> dict[str, Any]:
    schema_sql = sql_string(schema) if schema else "NULL"
    apply_sql = "TRUE" if apply else "FALSE"
    sql = (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW("
        f"{sql_string(yaml_text)}, {sql_string(model)}, {schema_sql}, {apply_sql})"
    )
    rows = [tuple(row) for row in con.execute(sql).fetchall()]
    if len(rows) != 1:
        raise AssertionError(f"expected one result row, got {len(rows)}")
    row = rows[0]
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("yaml_file", help="Path to a Databricks metric view YAML file")
    parser.add_argument("--model", required=True, help="Target semantic model name")
    parser.add_argument("--schema", default=None, help="Published schema (default SEMANTIC_<MODEL>)")
    parser.add_argument("--apply", action="store_true", help="Apply the import to the catalog")
    args = parser.parse_args()

    yaml_text = Path(args.yaml_file).read_text(encoding="utf-8")
    con = connect()
    try:
        result = import_metric_view(con, yaml_text, args.model, args.schema, args.apply)
    finally:
        con.close()

    print(f"status: {result['status']}")
    if result["error_code"]:
        print(f"error: {result['error_code']}: {result['error_message']}", file=sys.stderr)
    if result["validation_run_id"] is not None:
        print(f"validation_run_id: {result['validation_run_id']}")
    if result["diagnostics"]:
        print("diagnostics:")
        for diag in result["diagnostics"]:
            print(f"  [{diag.get('severity')}] {diag.get('code')} {diag.get('path')}: {diag.get('message')}")
    print("--- generated DDL ---")
    print(result["generated_ddl"] or "")
    return 0 if result["status"] == "OK" else 1


if __name__ == "__main__":
    raise SystemExit(main())
