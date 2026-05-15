#!/usr/bin/env python3
"""Verify Milestone 2 validation behavior on Exasol Nano."""

from __future__ import annotations

import os
import ssl
import sys
from collections.abc import Iterable


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


def execute(con, sql: str) -> None:
    con.execute(sql)


def validate(con, model_name: str = "sales") -> list[tuple[str, str, str | None, str, str]]:
    rows = con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{model_name}')").fetchall()
    return [(row[0], row[1], row[2], row[3], row[4]) for row in rows]


def codes(issues: Iterable[tuple[str, str, str | None, str, str]]) -> set[str]:
    return {issue[3] for issue in issues}


def assert_equal(name: str, actual: int, expected: int) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected}, got {actual}")
    print(f"ok {name}: {actual}")


def assert_no_errors(name: str, issues: list[tuple[str, str, str | None, str, str]]) -> None:
    errors = [issue for issue in issues if issue[0] == "ERROR"]
    if errors:
        formatted = "; ".join(f"{issue[3]} {issue[2]}: {issue[4]}" for issue in errors)
        raise AssertionError(f"{name}: expected no errors, got {formatted}")
    print(f"ok {name}: no errors")


def assert_code(name: str, issues: list[tuple[str, str, str | None, str, str]], expected_code: str) -> None:
    actual = codes(issues)
    if expected_code not in actual:
        formatted = "; ".join(f"{issue[3]} {issue[2]}: {issue[4]}" for issue in issues)
        raise AssertionError(f"{name}: expected {expected_code}, got {sorted(actual)} ({formatted})")
    print(f"ok {name}: {expected_code}")


def with_restore(con, name: str, mutate_sql: str, restore_sql: str, expected_code: str) -> None:
    execute(con, mutate_sql)
    try:
        assert_code(name, validate(con), expected_code)
    finally:
        execute(con, restore_sql)
        assert_no_errors(f"{name} restored", validate(con))


def main() -> int:
    con = connect()
    try:
        assert_equal(
            "validation tables",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_TABLES "
                "WHERE TABLE_SCHEMA = 'SYS_SEMANTIC' "
                "AND TABLE_NAME IN ('VALIDATION_RUNS', 'VALIDATION_RESULTS', 'METRIC_DIMENSION_MATRIX')",
            ),
            3,
        )
        assert_equal(
            "validation scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                "AND SCRIPT_NAME IN ('VALIDATOR_RUNTIME', 'VALIDATE_MODEL')",
            ),
            2,
        )

        assert_no_errors("sales validation", validate(con))
        assert_equal(
            "sales metric/dimension matrix rows",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX WHERE MODEL_NAME = 'sales'"),
            20,
        )
        assert_equal(
            "sales valid metric/dimension matrix rows",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX "
                "WHERE MODEL_NAME = 'sales' AND IS_VALID = TRUE",
            ),
            20,
        )
        assert_equal(
            "sales metric dependencies",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md "
                "JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = md.METRIC_ID "
                "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = mt.MODEL_ID "
                "WHERE m.MODEL_NAME = 'sales'",
            ),
            7,
        )

        model_filter = (
            "MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales') "
            "AND VERSION_ID = (SELECT ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')"
        )

        with_restore(
            con,
            "missing source object",
            "UPDATE SYS_SEMANTIC.ENTITIES SET SOURCE_OBJECT = 'MISSING_ORDERS' "
            f"WHERE {model_filter} AND ENTITY_NAME = 'order'",
            "UPDATE SYS_SEMANTIC.ENTITIES SET SOURCE_OBJECT = 'ORDERS' "
            f"WHERE {model_filter} AND ENTITY_NAME = 'order'",
            "SEMANTIC_MODEL_001",
        )

        with_restore(
            con,
            "invalid metric dependency",
            "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'SUM(missing_fact)' "
            f"WHERE {model_filter} AND METRIC_NAME = 'total_revenue'",
            "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'SUM(net_revenue)' "
            f"WHERE {model_filter} AND METRIC_NAME = 'total_revenue'",
            "SEMANTIC_MODEL_011",
        )

        execute(
            con,
            "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'gross_margin' "
            f"WHERE {model_filter} AND METRIC_NAME = 'total_revenue'",
        )
        execute(
            con,
            "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'total_revenue' "
            f"WHERE {model_filter} AND METRIC_NAME = 'gross_margin'",
        )
        try:
            assert_code("cyclic metric dependency", validate(con), "SEMANTIC_MODEL_012")
        finally:
            execute(
                con,
                "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'SUM(net_revenue)' "
                f"WHERE {model_filter} AND METRIC_NAME = 'total_revenue'",
            )
            execute(
                con,
                "UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'total_revenue - total_cost' "
                f"WHERE {model_filter} AND METRIC_NAME = 'gross_margin'",
            )
            assert_no_errors("cyclic metric dependency restored", validate(con))

        with_restore(
            con,
            "many-to-many fanout rejection",
            "UPDATE SYS_SEMANTIC.RELATIONSHIPS "
            "SET RELATIONSHIP_CARDINALITY = 'MANY_TO_MANY', FANOUT_POLICY = NULL "
            f"WHERE {model_filter} AND RELATIONSHIP_NAME = 'order_to_customer'",
            "UPDATE SYS_SEMANTIC.RELATIONSHIPS "
            "SET RELATIONSHIP_CARDINALITY = 'MANY_TO_ONE', FANOUT_POLICY = NULL "
            f"WHERE {model_filter} AND RELATIONSHIP_NAME = 'order_to_customer'",
            "SEMANTIC_MODEL_010",
        )

        execute(
            con,
            "INSERT INTO SYS_SEMANTIC.SYNONYMS ("
            "MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE"
            ") "
            "SELECT MODEL_ID, VERSION_ID, 'METRIC', METRIC_ID, 'revenue', 'TEST' "
            "FROM SYS_SEMANTIC.METRICS "
            f"WHERE {model_filter} AND METRIC_NAME = 'total_cost'",
        )
        try:
            assert_code("ambiguous certified synonym", validate(con), "SEMANTIC_MODEL_021")
        finally:
            execute(
                con,
                "DELETE FROM SYS_SEMANTIC.SYNONYMS "
                f"WHERE {model_filter} AND OBJECT_TYPE = 'METRIC' "
                "AND SYNONYM = 'revenue' AND SYNONYM_SOURCE = 'TEST'",
            )
            assert_no_errors("ambiguous certified synonym restored", validate(con))

        execute(
            con,
            "INSERT INTO SYS_SEMANTIC.VERIFIED_QUERIES ("
            "MODEL_ID, VERSION_ID, OBJECT_ID, QUERY_NAME, NATURAL_LANGUAGE_TEXT, REQUEST_JSON, STATUS"
            ") "
            "SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, so.OBJECT_ID, "
            "'bad_missing_metric', 'bad missing metric', "
            "'{\"metrics\":[\"not_a_metric\"],\"dimensions\":[\"customer_region\"]}', 'ACTIVE' "
            "FROM SYS_SEMANTIC.MODELS m "
            "JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so "
            "ON so.MODEL_ID = m.MODEL_ID AND so.VERSION_ID = m.ACTIVE_VERSION_ID "
            "WHERE m.MODEL_NAME = 'sales' AND so.OBJECT_NAME = 'SALES'",
        )
        try:
            assert_code("verified query missing metric", validate(con), "SEMANTIC_MODEL_023")
        finally:
            execute(con, "DELETE FROM SYS_SEMANTIC.VERIFIED_QUERIES WHERE QUERY_NAME = 'bad_missing_metric'")
            assert_no_errors("verified query missing metric restored", validate(con))

        with_restore(
            con,
            "unsupported function in dimension expression",
            "INSERT INTO SYS_SEMANTIC.DIMENSIONS ("
            "  MODEL_ID, VERSION_ID, DIMENSION_NAME, EXPRESSION, DATA_TYPE, ENTITY_ID, STATUS"
            ") "
            "SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, 'quarter_test', 'QUARTER(o.order_date)', 'VARCHAR(20)', "
            "  (SELECT e.ENTITY_ID FROM SYS_SEMANTIC.ENTITIES e "
            "   WHERE UPPER(e.ENTITY_NAME) = 'ORDER' "
            "   AND e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID), "
            "  'ACTIVE' "
            "FROM SYS_SEMANTIC.MODELS m "
            "WHERE m.MODEL_NAME = 'sales'",
            "DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE DIMENSION_NAME = 'quarter_test'",
            "SEMANTIC_MODEL_016",
        )
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
