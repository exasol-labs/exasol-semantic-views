#!/usr/bin/env python3
"""Verify relationship endpoint types and dependency-ordered removal."""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def expect_error(con: Any, sql: str, *fragments: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:
        message = str(exc)
        for fragment in fragments:
            if fragment not in message:
                raise AssertionError(
                    f"expected {fragment!r} in error, got: {message}"
                ) from exc
        return message
    raise AssertionError("invalid relationship operation was accepted")


def surface(con: Any) -> list[tuple[int]]:
    return [
        (int(line_id),)
        for (line_id,) in execute(
            con,
            "SELECT line_id FROM SEMANTIC_BUG32_VERIFY.LINES ORDER BY line_id",
        )
    ]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug32_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG32_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG32_VERIFY")
        con.execute(
            "CREATE TABLE BUG32_VERIFY.ORDER_LINES ("
            "LINE_ID DECIMAL(18,0), PRODUCT_ID DECIMAL(10,0))"
        )
        con.execute(
            "CREATE TABLE BUG32_VERIFY.CAMPAIGNS ("
            "PRODUCT_ID DECIMAL(18,0), CAMPAIGN_ID VARCHAR(100))"
        )
        con.execute("INSERT INTO BUG32_VERIFY.ORDER_LINES VALUES (1, 10), (2, 20)")
        con.execute(
            "INSERT INTO BUG32_VERIFY.CAMPAIGNS VALUES "
            "(10, 'CMP-001'), (20, 'CMP-002')"
        )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug32_verify', "
            "'SEMANTIC_BUG32_VERIFY', 'BUG-32 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug32_verify', 'order_line', "
            "'BUG32_VERIFY', 'ORDER_LINES', 'li', 'li.line_id', "
            "'One line', 'Order lines')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug32_verify', 'campaign', "
            "'BUG32_VERIFY', 'CAMPAIGNS', 'cp', 'cp.product_id', "
            "'One campaign row', 'Campaigns')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug32_verify', 'order_line', "
            "'line_pk', 'PRIMARY', 'Line key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug32_verify', "
            "'order_line', 'line_pk', 'LINE_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug32_verify', 'campaign', "
            "'campaign_product_key', 'PRIMARY', 'Product key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug32_verify', "
            "'campaign', 'campaign_product_key', 'PRODUCT_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug32_verify', "
            "'LINES', 'order_line', 'Lines')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug32_verify', 'LINES', "
            "'order_line', 'line_id', 'li.line_id', 'DECIMAL(18,0)', "
            "'Line ID', 'Line identifier', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('bug32_verify', "
            "'line_campaign', 'order_line', 'campaign', "
            "'li.PRODUCT_ID = cp.PRODUCT_ID', 'MANY_TO_ONE', 'LEFT', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            "'bug32_verify', 'line_campaign', 'PRODUCT_ID', NULL, "
            "'PRODUCT_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug32_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug32_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)

        expected = [(1,), (2,)]
        if surface(con) != expected:
            raise AssertionError("unexpected published baseline")

        invalid = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('bug32_verify', "
            "'line_bad_campaign', 'order_line', 'campaign', "
            "'li.PRODUCT_ID = cp.CAMPAIGN_ID', 'MANY_TO_ONE', 'LEFT', NULL)"
        )
        message = expect_error(
            con,
            invalid,
            "SEMANTIC_ADMIN_094",
            "SEMANTIC_MODEL_051",
            "LI.PRODUCT_ID",
            "DECIMAL(10,0)",
            "CP.CAMPAIGN_ID",
            "VARCHAR(100)",
        )
        if "line_bad_campaign" not in message:
            raise AssertionError(f"relationship name missing from diagnostic: {message}")
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.RELATIONSHIPS "
            "WHERE MODEL_NAME = 'bug32_verify' "
            "AND RELATIONSHIP_NAME = 'line_bad_campaign'",
        )[0][0]
        if int(residual) != 0 or surface(con) != expected:
            raise AssertionError("invalid relationship changed catalog or surface")

        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('bug32_verify', "
            "'line_campaign_legacy', 'order_line', 'campaign', "
            "'li.PRODUCT_ID = cp.PRODUCT_ID', 'MANY_TO_ONE', 'LEFT', NULL)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP("
            "'bug32_verify', 'line_campaign_legacy')",
        )
        if surface(con) != expected:
            raise AssertionError("valid relationship lifecycle changed the surface")

        expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP("
            "'bug32_verify', 'line_campaign')",
            "SEMANTIC_ADMIN_066",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP_KEY_MAPPING("
            "'bug32_verify', 'line_campaign', 1)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP("
            "'bug32_verify', 'line_campaign')",
        )
        remaining = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.RELATIONSHIPS "
            "WHERE MODEL_NAME = 'bug32_verify' AND STATUS = 'ACTIVE'",
        )[0][0]
        if int(remaining) != 0:
            raise AssertionError(f"relationship removal left {remaining} active row(s)")
        if surface(con) != expected:
            raise AssertionError("relationship removal changed the published surface")

        print("ok BUG-32 types: incompatible endpoints were rejected with model context")
        print("ok BUG-32 dependency: relationship refused removal while mappings existed")
        print("ok BUG-32 inverse: mapping and relationship removed in dependency order")
        print("ok BUG-32 availability: published surface remained certified")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug32_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG32_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
