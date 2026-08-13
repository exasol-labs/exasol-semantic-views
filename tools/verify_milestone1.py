#!/usr/bin/env python3
"""Verify Milestone 1 catalog and sales seed on Exasol Nano."""

from __future__ import annotations

import os
import json
import ssl
import sys


EXPECTED_TABLES = {
    "MODELS",
    "MODEL_VERSIONS",
    "ENTITIES",
    "ENTITY_REPRESENTATIONS",
    "ATTRIBUTE_BINDINGS",
    "REPRESENTATION_AUTHORITIES",
    "ATTRIBUTE_FUSION_POLICIES",
    "SEMANTIC_IDENTITIES",
    "IDENTITY_BINDINGS",
    "IDENTITY_MAPPING_RELATIONS",
    "UNIQUE_KEYS",
    "UNIQUE_KEY_COLUMNS",
    "RELATIONSHIP_KEY_MAPPINGS",
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
    "CUSTOM_EXTENSIONS",
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
    "DROP_MODEL",
    "ADD_ENTITY",
    "ADD_ENTITY_REPRESENTATION",
    "ADD_ENTITY_REPRESENTATION_WITH_COVERAGE",
    "SET_REPRESENTATION_COVERAGE",
    "SET_REPRESENTATION_COVERAGE_BATCH",
    "SET_REPRESENTATION_AUTHORITY",
    "SET_ATTRIBUTE_FUSION_POLICY",
    "ADD_SEMANTIC_IDENTITY",
    "ADD_IDENTITY_BINDING",
    "ADD_IDENTITY_MAPPING_RELATION",
    "REMOVE_IDENTITY_MAPPING_RELATION",
    "REMOVE_IDENTITY_BINDING",
    "REMOVE_SEMANTIC_IDENTITY",
    "SET_PRIMARY_REPRESENTATION",
    "REMOVE_ENTITY_REPRESENTATION",
    "ADD_ATTRIBUTE_BINDING",
    "REMOVE_ATTRIBUTE_BINDING",
    "ADD_SEMANTIC_OBJECT",
    "CREATE_SEMANTIC_OBJECT",
    "ADD_RELATIONSHIP",
    "ADD_RELATIONSHIP_KEY_MAPPING",
    "SUGGEST_GRAIN_METADATA",
    "ADD_DIMENSION",
    "ADD_FACT",
    "ADD_METRIC",
    "ADD_SYNONYM",
    "VALIDATOR_RUNTIME",
    "VALIDATE_MODEL",
    "SEMANTIC_DEFINITION_RUNTIME",
    "APPLY_SEMANTIC_DEFINITION",
    "APPLY_NORMALIZED_OSI_IMPORT",
    "DESCRIBE_SEMANTIC_METRIC",
    "EXPLAIN_SEMANTIC_METRIC",
    "EXPORT_SEMANTIC_DEFINITION",
    "ENABLE_SEMANTIC_SQL",
    "DISABLE_SEMANTIC_SQL",
    "COMPILER_RUNTIME",
    "COMPILE_REQUEST_JSON",
    "ADD_CUSTOM_EXTENSION",
    "GET_CUSTOM_EXTENSIONS",
    "ADD_UNIQUE_KEY",
    "ADD_UNIQUE_KEY_COLUMN",
    "ADD_UNIQUE_KEY_WITH_COLUMNS",
    "REMOVE_UNIQUE_KEY_COLUMN",
    "REMOVE_UNIQUE_KEY",
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


def assert_script_fails(con, name: str, sql: str, expected_text: str) -> None:
    try:
        con.execute(sql).fetchall()
    except Exception as exc:  # pyexasol wraps script errors.
        if expected_text not in str(exc):
            raise AssertionError(f"{name}: expected {expected_text!r} in {exc!r}") from exc
        print(f"ok {name}: rejected")
        return
    raise AssertionError(f"{name}: expected script failure")


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
        assert_equal(
            "OSI metadata views",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS "
                "WHERE VIEW_SCHEMA = 'SEMANTIC_CATALOG' "
                "AND VIEW_NAME IN ('CUSTOM_EXTENSIONS', 'UNIQUE_KEYS', "
                "'UNIQUE_KEY_COLUMNS', 'RELATIONSHIP_KEY_MAPPINGS')",
            ),
            4,
        )

        expected_counts = {
            "SEMANTIC_CATALOG.MODELS WHERE MODEL_NAME = 'sales'": 1,
            "SEMANTIC_CATALOG.ENTITIES WHERE MODEL_NAME = 'sales'": 4,
            "SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS WHERE MODEL_NAME = 'sales'": 4,
            "SEMANTIC_CATALOG.RELATIONSHIPS WHERE MODEL_NAME = 'sales'": 3,
            "SEMANTIC_CATALOG.RELATIONSHIP_KEY_MAPPINGS WHERE MODEL_NAME = 'sales'": 3,
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
        assert_equal(
            "one primary representation per entity",
            scalar(
                con,
                "SELECT COUNT(*) FROM ("
                "SELECT ENTITY_ID FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
                "WHERE MODEL_NAME = 'sales' AND REPRESENTATION_ROLE = 'PRIMARY' "
                "AND STATUS = 'ACTIVE' GROUP BY ENTITY_ID HAVING COUNT(*) = 1)"
            ),
            4,
        )

        con.execute("DROP TABLE IF EXISTS MART.ORDERS_F1_REPLICA")
        con.execute("CREATE TABLE MART.ORDERS_F1_REPLICA AS SELECT * FROM MART.ORDERS")
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
                "'sales', 'order', 'archive', 'RELATION', 'MART', "
                "'ORDERS_F1_REPLICA', 20, 'MANUAL')"
            ).fetchall()
            assert_equal(
                "F1 alternate representation",
                scalar(
                    con,
                    "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
                    "WHERE MODEL_NAME = 'sales' AND ENTITY_NAME = 'order' "
                    "AND REPRESENTATION_NAME = 'archive' "
                    "AND REPRESENTATION_ROLE = 'ALTERNATE'",
                ),
                1,
            )
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
            assert_equal(
                "F1 equivalent representation validation errors",
                scalar(
                    con,
                    "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
                    "WHERE MODEL_NAME = 'sales' AND SEVERITY = 'ERROR'",
                ),
                0,
            )
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
                "'sales', 'order', 'archive')"
            ).fetchall()
            assert_equal(
                "F1 promoted source compatibility mirror",
                scalar(
                    con,
                    "SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITIES e "
                    "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID "
                    "WHERE m.MODEL_NAME = 'sales' AND e.ENTITY_NAME = 'order' "
                    "AND e.SOURCE_OBJECT = 'ORDERS_F1_REPLICA'",
                ),
                1,
            )
            assert_script_fails(
                con,
                "remove primary representation",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION("
                "'sales', 'order', 'archive')",
                "SEMANTIC_ADMIN_047",
            )
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
            compile_row = con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
                "'{\"model\":\"sales\",\"object\":\"SALES\","
                "\"metrics\":[\"total_revenue\"],"
                "\"dimensions\":[\"order_status\"]}')"
            ).fetchall()[0]
            selected = json.loads(compile_row[5])["selected_representations"]
            order_source = next(row for row in selected if row["entity_name"] == "order")
            if order_source["representation_name"] != "archive":
                raise AssertionError(f"F1 compile selected {order_source!r}")
            print("ok F1 compile uses promoted representation: archive")
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
                "'sales', 'order', 'primary')"
            ).fetchall()
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION("
                "'sales', 'order', 'archive')"
            ).fetchall()
        finally:
            con.execute(
                "UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS SET REPRESENTATION_ROLE = "
                "CASE WHEN REPRESENTATION_NAME = 'primary' THEN 'PRIMARY' ELSE 'ALTERNATE' END "
                "WHERE ENTITY_ID = (SELECT e.ENTITY_ID FROM SYS_SEMANTIC.ENTITIES e "
                "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID "
                "WHERE m.MODEL_NAME = 'sales' AND e.ENTITY_NAME = 'order')"
            )
            con.execute(
                "UPDATE SYS_SEMANTIC.ENTITIES SET SOURCE_OBJECT = 'ORDERS' "
                "WHERE ENTITY_NAME = 'order' AND MODEL_ID = "
                "(SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')"
            )
            con.execute(
                "DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS "
                "WHERE REPRESENTATION_NAME = 'archive' AND ENTITY_ID = "
                "(SELECT e.ENTITY_ID FROM SYS_SEMANTIC.ENTITIES e "
                "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID "
                "WHERE m.MODEL_NAME = 'sales' AND e.ENTITY_NAME = 'order')"
            )
            con.execute("DROP TABLE IF EXISTS MART.ORDERS_F1_REPLICA")

        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
            "'sales', 'MODEL', NULL, 'EXASOL', '{\"purpose\":\"osi-milestone1\"}', 'OSI', 'milestone1')"
        ).fetchall()
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
            "'sales', 'ENTITY', 'order', 'PARTNER_VENDOR', '{\"opaque\":true}', 'OSI', 'roundtrip')"
        ).fetchall()
        for scope_type, scope_name in [
            ("SEMANTIC_OBJECT", "SALES"),
            ("RELATIONSHIP", "order_line_to_order"),
            ("DIMENSION", "customer_region"),
            ("FACT", "net_revenue"),
            ("METRIC", "total_revenue"),
        ]:
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
                f"'sales', '{scope_type}', '{scope_name}', "
                f"'EXASOL', '{{\"scope\":\"{scope_type.lower()}\"}}', 'OSI', 'scope_test')"
            ).fetchall()
        assert_script_fails(
            con,
            "invalid extension JSON",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION("
            "'sales', 'MODEL', NULL, 'EXASOL', '{bad json', 'OSI', 'invalid_json')",
            "SEMANTIC_ADMIN_040",
        )
        assert_equal(
            "custom extension preservation",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS "
                "WHERE MODEL_NAME = 'sales' AND VENDOR_NAME IN ('EXASOL', 'PARTNER_VENDOR')",
            ),
            7,
        )
        assert_equal(
            "custom extension helper read",
            len(
                con.execute(
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS("
                    "'sales', NULL, NULL, NULL)"
                ).fetchall()
            ),
            7,
        )

        try:
            assert_script_fails(
                con,
                "reserved entity alias",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
                "'sales', 'reserved_alias_probe', 'MART', 'ORDERS', 'at', "
                "'at.order_id', 'Probe grain', 'Reserved alias probe')",
                "SEMANTIC_ADMIN_044",
            )
        finally:
            con.execute(
                "DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE ENTITY_ID IN ("
                "SELECT ENTITY_ID FROM SYS_SEMANTIC.ENTITIES "
                "WHERE ENTITY_NAME = 'reserved_alias_probe' "
                "AND MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS "
                "WHERE MODEL_NAME = 'sales'))"
            )
            con.execute(
                "DELETE FROM SYS_SEMANTIC.ENTITIES WHERE ENTITY_NAME = 'reserved_alias_probe' "
                "AND MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS "
                "WHERE MODEL_NAME = 'sales')"
            )

        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            "'sales', 'order', 'order_order_id_key', 'PRIMARY', 'Order primary key', 'OSI')"
        ).fetchall()
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
            "'sales', 'order', 'order_order_id_key', 'order_id', NULL, 1)"
        ).fetchall()
        assert_equal(
            "unique key preservation",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS "
                "WHERE MODEL_NAME = 'sales' "
                "AND ENTITY_NAME = 'order' "
                "AND KEY_NAME = 'order_order_id_key' "
                "AND COLUMN_NAME = 'order_id'",
            ),
            1,
        )

        try:
            con.execute(
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
                "'sales', 'order', 'order_order_id_key', '_id', NULL, 99)"
            ).fetchall()
            assert_equal(
                "leading-underscore unique key column",
                scalar(
                    con,
                    "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS "
                    "WHERE MODEL_NAME = 'sales' AND ENTITY_NAME = 'order' "
                    "AND KEY_NAME = 'order_order_id_key' AND COLUMN_NAME = '_id'",
                ),
                1,
            )
        finally:
            con.execute(
                "DELETE FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS WHERE ORDINAL_POSITION = 99 "
                "AND UNIQUE_KEY_ID = (SELECT UNIQUE_KEY_ID FROM SYS_SEMANTIC.UNIQUE_KEYS "
                "WHERE KEY_NAME = 'order_order_id_key' AND MODEL_ID = ("
                "SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales'))"
            )

        try:
            assert_script_fails(
                con,
                "expression relationship key mapping",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
                "'sales', 'order_line_to_order', NULL, "
                "'CAST(ol.order_id AS DECIMAL(18,0))', 'order_id', NULL, 99)",
                "SEMANTIC_ADMIN_043",
            )
        finally:
            con.execute(
                "DELETE FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS "
                "WHERE ORDINAL_POSITION = 99 AND RELATIONSHIP_ID = ("
                "SELECT RELATIONSHIP_ID FROM SYS_SEMANTIC.RELATIONSHIPS "
                "WHERE RELATIONSHIP_NAME = 'order_line_to_order')"
            )

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
        assert_equal(
            "OSI metadata validation errors",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
                "WHERE MODEL_NAME = 'sales' "
                "AND RULE_CODE IN ("
                "'SEMANTIC_MODEL_026', 'SEMANTIC_MODEL_027', "
                "'SEMANTIC_MODEL_028', 'SEMANTIC_MODEL_029', "
                "'SEMANTIC_MODEL_031', 'SEMANTIC_MODEL_032', "
                "'SEMANTIC_MODEL_033')",
            ),
            0,
        )

        con.execute(
            "DELETE FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS "
            "WHERE RELATIONSHIP_ID = ("
            "SELECT RELATIONSHIP_ID FROM SYS_SEMANTIC.RELATIONSHIPS "
            "WHERE RELATIONSHIP_NAME = 'order_line_to_order')"
        )
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
        assert_equal(
            "legacy relationship mapping warning",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
                "WHERE MODEL_NAME = 'sales' "
                "AND OBJECT_NAME = 'order_line_to_order' "
                "AND RULE_CODE = 'SEMANTIC_MODEL_031'",
            ),
            1,
        )
        legacy_compile = con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
            "'{\"model\":\"sales\",\"object\":\"SALES\","
            "\"metrics\":[\"total_revenue\"],"
            "\"dimensions\":[\"order_month\"]}')"
        ).fetchall()
        if not legacy_compile or legacy_compile[0][0] != "OK":
            raise AssertionError(
                "legacy relationship mapping warning must not block single-branch "
                f"compilation: {legacy_compile!r}"
            )
        print("ok legacy relationship warning: compile remains available")
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            "'sales', 'order_line_to_order', 'order_id', NULL, "
            "'order_id', NULL, 1)"
        )
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()

        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL("
            "'drop_model_probe', 'SEMANTIC_DROP_MODEL_PROBE', "
            "'DROP_MODEL verification fixture', NULL)"
        )
        con.execute("CREATE SCHEMA SEMANTIC_DROP_MODEL_PROBE")
        probe_model_id = scalar(
            con,
            "SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS "
            "WHERE MODEL_NAME = 'drop_model_probe'",
        )
        con.execute(
            "INSERT INTO SYS_SEMANTIC.QUERY_LOG (MODEL_ID, STATUS) "
            f"VALUES ({probe_model_id}, 'OK')"
        )
        drop_rows = con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('drop_model_probe')"
        ).fetchall()
        if not drop_rows or drop_rows[0][2] is not True:
            raise AssertionError(f"DROP_MODEL did not report schema removal: {drop_rows!r}")
        assert_equal(
            "DROP_MODEL catalog cleanup",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS "
                "WHERE MODEL_NAME = 'drop_model_probe'",
            ),
            0,
        )
        assert_equal(
            "DROP_MODEL log cleanup",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG "
                f"WHERE MODEL_ID = {probe_model_id}",
            ),
            0,
        )
        assert_equal(
            "DROP_MODEL schema cleanup",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCHEMAS "
                "WHERE SCHEMA_NAME = 'SEMANTIC_DROP_MODEL_PROBE'",
            ),
            0,
        )
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
