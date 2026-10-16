#!/usr/bin/env python3
"""Verify that many-to-many traversal is refused rather than silently fanned out.

A declared `FANOUT_POLICY` records modeler intent; it is not an allocation
proof. Before this was enforced in the legacy join lane, a many-to-many
relationship with any non-empty policy string compiled to a flat join with no
de-duplication, so an order shipped twice by the same carrier had its freight
counted twice.

This builds a disposable model over its own schema with exactly that shape and
asserts both refusal lanes:

  1. authoring — a visible metric/dimension pair that needs the edge is
     rejected by the compatibility matrix (`SEMANTIC_MODEL_030`) with reason
     `MANY_TO_MANY_UNSUPPORTED`, and the catalog is restored;
  2. compiling — a request whose join path crosses the edge is refused with
     `SEMANTIC_REQUEST_042`, naming the blocking relationship.

It also computes, from the raw tables, the wrong number the refusal prevents.

See plans/architecture-decisions/001-grain-aware-result-semantics.md:
"Many-to-many traversal | Rejected | A fanout policy is not an allocation proof."
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

MODEL = "m2m_verify"
SCHEMA = "M2M_VERIFY"


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


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    row = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    )[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[4],
    }


def expect_error(con: Any, sql: str, *fragments: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        message = str(exc)
        for fragment in fragments:
            if fragment not in message:
                raise AssertionError(f"expected {fragment!r} in error, got: {message}") from exc
        return message
    raise AssertionError(f"many-to-many traversal was accepted: {sql}")


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, haystack: str, needle: str) -> None:
    if needle not in (haystack or ""):
        raise AssertionError(f"{name}: {needle!r} not found in {haystack!r}")
    print(f"ok {name}: found {needle!r}")


def build_fixture(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(
        f"CREATE TABLE {SCHEMA}.ORDERS ("
        "ORDER_ID DECIMAL(18,0) PRIMARY KEY, FREIGHT_AMOUNT DECIMAL(18,2) NOT NULL)"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.ORDERS VALUES (1000, 25.00), (1001, 12.50), (1002, 40.00)"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.SHIPMENTS ("
        "SHIPMENT_ID DECIMAL(18,0) PRIMARY KEY, ORDER_ID DECIMAL(18,0) NOT NULL, "
        "CARRIER VARCHAR(40) NOT NULL)"
    )
    # Order 1000 ships twice with the same carrier: a flat join counts its
    # freight twice in the DHL group.
    con.execute(
        f"INSERT INTO {SCHEMA}.SHIPMENTS VALUES "
        "(500, 1000, 'DHL'), (501, 1000, 'DHL'), (502, 1001, 'DHL'), (503, 1002, 'UPS')"
    )

    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL("
        f"'{MODEL}', 'SEMANTIC_{SCHEMA}', 'Disposable many-to-many regression model', NULL)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        f"'{MODEL}', 'order', '{SCHEMA}', 'ORDERS', 'o', 'o.order_id', "
        "'One row per order', 'Order header grain')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        f"'{MODEL}', 'shipment', '{SCHEMA}', 'SHIPMENTS', 's', 's.shipment_id', "
        "'One row per shipment', 'Shipment grain')",
    )
    for entity, key_name, column in (
        ("order", "order_pk", "order_id"),
        ("shipment", "shipment_pk", "shipment_id"),
    ):
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            f"'{MODEL}', '{entity}', '{key_name}', 'PRIMARY', 'Row grain', 'NATIVE')",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
            f"'{MODEL}', '{entity}', '{key_name}', '{column}', NULL, 1)",
        )
    # An order can be split across shipments and a shipment can carry several
    # orders: a genuine many-to-many, declared with a policy string.
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
        f"'{MODEL}', 'order_to_shipment', 'order', 'shipment', "
        "'o.order_id = s.order_id', 'MANY_TO_MANY', 'LEFT', 'ALLOCATE')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
        f"'{MODEL}', 'order_to_shipment', 'order_id', NULL, 'order_id', NULL, 1)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        f"'{MODEL}', 'order', 'freight_amount', 'o.freight_amount', 'DECIMAL(18,2)', "
        "'ADDITIVE', 'Freight Amount', 'Freight charged on the order header', FALSE, TRUE)",
    )


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        build_fixture(con)

        # 1. Authoring lane: an order-grain metric and a shipment dimension
        # cannot coexist in one object, because the pair needs the m2m edge.
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
            f"'{MODEL}', 'ORDER_ROOT', 'order', 'Order-grain object')",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
            f"'{MODEL}', 'ORDER_ROOT', 'total_freight', 'SUM(freight_amount)', NULL, "
            "'ADDITIVE', 'order', 'DECIMAL(18,2)', 'Total Freight', "
            "'Freight charged across orders', 'currency', FALSE, TRUE)",
        )
        message = expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
            f"'{MODEL}', 'ORDER_ROOT', 'shipment', 'carrier', 's.carrier', 'VARCHAR(40)', "
            "'Carrier', 'Shipping carrier', NULL, TRUE)",
            "SEMANTIC_MODEL_030",
            "MANY_TO_MANY_UNSUPPORTED",
            "order_to_shipment",
        )
        refusal = next(
            (line.split("=>", 1)[1].strip() for line in message.splitlines()
             if line.strip().startswith("message")),
            message.strip(),
        )
        print(f"   {refusal}")
        assert_equal(
            "rejected dimension is absent from the catalog",
            execute(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.DIMENSIONS "
                f"WHERE MODEL_NAME = {sql_string(MODEL)} AND DIMENSION_NAME = 'carrier'",
            )[0][0],
            0,
        )

        # 2. Compiling lane: reach the same edge from the other side, where no
        # visible metric/dimension pair exists for the matrix to reject.
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
            f"'{MODEL}', 'SHIP_ROOT', 'shipment', 'Shipment-grain object')",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
            f"'{MODEL}', 'SHIP_ROOT', 'shipment', 'carrier', 's.carrier', 'VARCHAR(40)', "
            "'Carrier', 'Shipping carrier', NULL, TRUE)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
            f"'{MODEL}', 'SHIP_ROOT', 'order', 'shipped_order', "
            "'CAST(o.order_id AS VARCHAR(36))', 'VARCHAR(36)', 'Shipped Order', "
            "'Order carried by the shipment', NULL, TRUE)",
        )
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")

        same_entity = compile_request(con, {
            "model": MODEL, "object": "SHIP_ROOT", "dimensions": ["carrier"],
            "client": "verify_many_to_many_refusal",
        })
        assert_equal("dimension on the root entity still compiles", same_entity["status"], "OK")

        crossing = compile_request(con, {
            "model": MODEL, "object": "SHIP_ROOT",
            "dimensions": ["carrier", "shipped_order"],
            "client": "verify_many_to_many_refusal",
        })
        assert_equal("crossing the m2m edge is refused", crossing["status"], "ERROR")
        assert_equal("refusal code", crossing["error_code"], "SEMANTIC_REQUEST_042")
        assert_contains("refusal names the reason", crossing["error_message"],
                        "MANY_TO_MANY_UNSUPPORTED")
        assert_contains("refusal names the relationship", crossing["error_message"],
                        "order_to_shipment")
        assert_equal("refusal produced no SQL", crossing["generated_sql"], None)

        # 3. The number the refusal prevents. Order 1000 ships twice with DHL,
        # so the flat join counts its freight twice.
        fanned = {
            str(row[0]): Decimal(str(row[1]))
            for row in execute(
                con,
                f"SELECT s.carrier, SUM(o.freight_amount) FROM {SCHEMA}.ORDERS o "
                f"JOIN {SCHEMA}.SHIPMENTS s ON o.order_id = s.order_id GROUP BY s.carrier",
            )
        }
        truth = {
            str(row[0]): Decimal(str(row[1]))
            for row in execute(
                con,
                "SELECT carrier, SUM(freight_amount) FROM ("
                f"SELECT DISTINCT s.carrier, o.order_id, o.freight_amount FROM {SCHEMA}.ORDERS o "
                f"JOIN {SCHEMA}.SHIPMENTS s ON o.order_id = s.order_id) GROUP BY carrier",
            )
        }
        print(f"   flat join: {fanned}")
        print(f"   truth:     {truth}")
        if fanned == truth:
            raise AssertionError(
                "fixture no longer fans out; the regression would not catch a "
                f"reintroduced flat join ({fanned})"
            )
        print("ok the refused join would have overstated freight")

        print()
        print("many-to-many refusal verified.")
        return 0
    finally:
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
