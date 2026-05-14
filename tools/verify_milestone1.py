#!/usr/bin/env python3
"""Verify Milestone 1 catalog and sales seed on Exasol Nano."""

from __future__ import annotations

import os
import ssl
import sys


EXPECTED_TABLES = {
    "MODELS",
    "MODEL_VERSIONS",
    "ENTITIES",
    "SEMANTIC_OBJECTS",
    "RELATIONSHIPS",
    "DIMENSIONS",
    "FACTS",
    "METRICS",
    "SEMANTIC_DEFINITION_SOURCES",
    "METRIC_INPUTS",
    "METRIC_FILTERS",
    "CALCULATION_GROUPS",
    "CALCULATION_ITEMS",
    "OBJECT_COLUMNS",
    "METRIC_DEPENDENCIES",
    "SYNONYMS",
    "AGENT_INSTRUCTIONS",
    "VERIFIED_QUERIES",
    "AGENT_REQUEST_LOG",
    "AGENT_FEEDBACK",
    "AGENT_SUGGESTIONS",
    "MATERIALIZATIONS",
    "MATERIALIZATION_COLUMNS",
    "OBJECT_PRIVILEGES",
    "QUERY_LOG",
    "VALIDATION_RUNS",
    "VALIDATION_RESULTS",
    "METRIC_DIMENSION_MATRIX",
}

EXPECTED_SCRIPTS = {
    "CREATE_MODEL",
    "ADD_ENTITY",
    "ADD_SEMANTIC_OBJECT",
    "CREATE_SEMANTIC_OBJECT",
    "ADD_RELATIONSHIP",
    "ADD_DIMENSION",
    "ADD_FACT",
    "ADD_METRIC",
    "ADD_SYNONYM",
    "VALIDATOR_RUNTIME",
    "VALIDATE_MODEL",
    "SEMANTIC_DEFINITION_RUNTIME",
    "APPLY_SEMANTIC_DEFINITION",
    "DESCRIBE_SEMANTIC_METRIC",
    "EXPLAIN_SEMANTIC_METRIC",
    "EXPORT_SEMANTIC_DEFINITION",
    "ENABLE_SEMANTIC_SQL",
    "DISABLE_SEMANTIC_SQL",
    "COMPILER_RUNTIME",
    "COMPILE_REQUEST_JSON",
}


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


def scalar(con, sql: str) -> int:
    rows = con.execute(sql).fetchall()
    return int(rows[0][0])


def assert_equal(name: str, actual: int, expected: int) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected}, got {actual}")
    print(f"ok {name}: {actual}")


def assert_at_least(name: str, actual: int, expected: int) -> None:
    if actual < expected:
        raise AssertionError(f"{name}: expected at least {expected}, got {actual}")
    print(f"ok {name}: {actual}")


def main() -> int:
    con = connect()
    try:
        schemas = ["SYS_SEMANTIC", "SEMANTIC_CATALOG", "SEMANTIC_ADMIN", "SEMANTIC_AGENT", "MART"]
        for schema in schemas:
            assert_equal(
                f"schema {schema}",
                scalar(con, f"SELECT COUNT(*) FROM SYS.EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '{schema}'"),
                1,
            )

        table_list = "', '".join(sorted(EXPECTED_TABLES))
        assert_equal(
            "SYS_SEMANTIC tables",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_TABLES "
                f"WHERE TABLE_SCHEMA = 'SYS_SEMANTIC' AND TABLE_NAME IN ('{table_list}')",
            ),
            len(EXPECTED_TABLES),
        )

        script_list = "', '".join(sorted(EXPECTED_SCRIPTS))
        assert_equal(
            "SEMANTIC_ADMIN scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                f"WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' AND SCRIPT_NAME IN ('{script_list}')",
            ),
            len(EXPECTED_SCRIPTS),
        )

        assert_at_least(
            "SEMANTIC_CATALOG views",
            scalar(con, "SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA = 'SEMANTIC_CATALOG'"),
            16,
        )

        expected_counts = {
            "SEMANTIC_CATALOG.MODELS WHERE MODEL_NAME = 'sales'": 1,
            "SEMANTIC_CATALOG.ENTITIES WHERE MODEL_NAME = 'sales'": 4,
            "SEMANTIC_CATALOG.RELATIONSHIPS WHERE MODEL_NAME = 'sales'": 3,
            "SEMANTIC_CATALOG.DIMENSIONS WHERE MODEL_NAME = 'sales'": 4,
            "SEMANTIC_CATALOG.FACTS WHERE MODEL_NAME = 'sales'": 3,
            "SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales'": 5,
            "SEMANTIC_CATALOG.OBJECT_COLUMNS WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES' AND IS_VISIBLE = TRUE": 9,
            "SEMANTIC_CATALOG.SYNONYMS WHERE MODEL_NAME = 'sales'": 3,
            "MART.CUSTOMERS": 4,
            "MART.ORDERS": 5,
            "MART.ORDER_LINES": 7,
            "MART.PRODUCTS": 4,
            "SYS_SEMANTIC.AGENT_INSTRUCTIONS": 0,
            "SYS_SEMANTIC.VERIFIED_QUERIES": 0,
            "SYS_SEMANTIC.AGENT_REQUEST_LOG": 0,
            "SYS_SEMANTIC.AGENT_FEEDBACK": 0,
            "SYS_SEMANTIC.AGENT_SUGGESTIONS": 0,
        }
        for table_expr, expected in expected_counts.items():
            assert_equal(table_expr, scalar(con, f"SELECT COUNT(*) FROM {table_expr}"), expected)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
