#!/usr/bin/env python3
"""Verify the grain relationship between a metric's facts and its object root.

A metric's fact rows live at the grain of its leaf entities; the object root
decides the grain they are aggregated at. Those are different questions and the
answers point in opposite directions, so proving one settles nothing about the
other:

  * root -> leaf safe says the root can read that entity's columns, which is
    what a *dimension* needs;
  * leaf -> root safe says each fact row belongs to at most one root row, which
    is what an *aggregate* needs.

Only the first direction was ever proven, and only through the metric/dimension
matrix -- which reports nothing unless some dimension is incompatible. A view
whose dimensions all sat on safe branches, or which had no dimensions at all,
validated clean, published, and returned an inflated number through both query
paths while every agent surface called the metric valid (finding F18, filed Low
on the assumption that the dependent metric was always refused; it is not).

The evaluation's own closing note asked for this shape of test: enumerate the
*positions* a fact entity can occupy relative to the root and assert a number
for each, rather than testing only the position that happens to work. All four
positions are covered here:

  1. leaf == root                -> accepted, exact
  2. leaf coarser than the root  -> refused SEMANTIC_MODEL_059 (was: silently
                                    multiplied by the fan-out)
  3. leaf finer than the root    -> refused SEMANTIC_MODEL_030 (root cannot
                                    safely reach the leaf at all)
  4. leaf ONE_TO_ONE with root   -> accepted, exact -- the guard must not
                                    over-reach to every leaf that is not the
                                    root itself
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

SCHEMA = "GRAIN_POS_VERIFY"

# 3 orders; order 1 has two lines, orders 2 and 3 one each.
FREIGHT_TOTAL = Decimal("60")     # 10 + 20 + 30
LINE_TOTAL = Decimal("10")        # 1 + 2 + 3 + 4
SURCHARGE_TOTAL = Decimal("6")    # 1 + 2 + 3, one row per order
FANNED_FREIGHT = Decimal("70")    # 10 + 10 + 20 + 30, the number F18 returned


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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def expect_refusal(con: Any, label: str, sql: str, code: str) -> str:
    """Run sql, require it to fail naming `code`, and return the message."""
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the message is the assertion
        message = str(exc)
        if code not in message:
            raise AssertionError(f"{label}: expected {code}, got: {message}") from None
        print(f"ok {label}: refused with {code}")
        return message
    raise AssertionError(f"{label}: expected {code}, but the call was accepted")


def key_columns(*columns: str) -> str:
    return json.dumps([{"column_name": column} for column in columns])


def build_physical(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(f"""
        CREATE TABLE {SCHEMA}.ORDERS (
          ORDER_ID DECIMAL(18,0), FREIGHT DECIMAL(18,2), SHIP_MODE VARCHAR(20)
        )
    """)
    con.execute(f"""
        CREATE TABLE {SCHEMA}.ORDER_LINES (
          ORDER_ID DECIMAL(18,0), LINE_ID DECIMAL(18,0), AMOUNT DECIMAL(18,2)
        )
    """)
    # One row per order: a ONE_TO_ONE satellite, so its facts are at the order's
    # own grain even though it is not the order entity.
    con.execute(f"""
        CREATE TABLE {SCHEMA}.ORDER_EXTRA (
          ORDER_ID DECIMAL(18,0), SURCHARGE DECIMAL(18,2)
        )
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDERS VALUES
          (1, 10, 'GROUND'), (2, 20, 'EXPRESS'), (3, 30, 'GROUND')
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDER_LINES VALUES
          (1, 1, 1), (1, 2, 2), (2, 1, 3), (3, 1, 4)
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDER_EXTRA VALUES (1, 1), (2, 2), (3, 3)
    """)


def base_model(con: Any, model: str, root_entity: str, object_name: str) -> None:
    """Model with order_line -MANY_TO_ONE-> order and a ONE_TO_ONE satellite."""
    try:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
    except Exception:  # noqa: BLE001 - absent on the first run
        pass
    statements = [
        f"CREATE_MODEL({literal(model)}, {literal('SEMANTIC_' + model.upper())},"
        f" 'grain position verification', NULL)",
        f"ADD_ENTITY({literal(model)}, 'order_line', {literal(SCHEMA)},"
        f" 'ORDER_LINES', 'ol', 'ol.order_id', 'One order line', 'Lines')",
        f"ADD_ENTITY({literal(model)}, 'order', {literal(SCHEMA)}, 'ORDERS',"
        f" 'o', 'o.order_id', 'One order', 'Orders')",
        f"ADD_ENTITY({literal(model)}, 'order_extra', {literal(SCHEMA)},"
        f" 'ORDER_EXTRA', 'oe', 'oe.order_id', 'One order', 'Order satellite')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'order_line', 'ol_pk',"
        f" 'PRIMARY', 'Line identity', 'NATIVE',"
        f" {literal(key_columns('ORDER_ID', 'LINE_ID'))})",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'order', 'o_pk',"
        f" 'PRIMARY', 'Order identity', 'NATIVE',"
        f" {literal(key_columns('ORDER_ID'))})",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'order_extra', 'oe_pk',"
        f" 'PRIMARY', 'Order identity', 'NATIVE',"
        f" {literal(key_columns('ORDER_ID'))})",
        f"ADD_SEMANTIC_OBJECT({literal(model)}, {literal(object_name)},"
        f" {literal(root_entity)}, 'Grain position view')",
        f"ADD_RELATIONSHIP({literal(model)}, 'ol_to_o', 'order_line', 'order',"
        f" 'ol.order_id = o.order_id', 'MANY_TO_ONE', 'INNER', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({literal(model)}, 'ol_to_o', 'ORDER_ID',"
        f" NULL, 'ORDER_ID', NULL, 1)",
        f"ADD_RELATIONSHIP({literal(model)}, 'o_to_oe', 'order', 'order_extra',"
        f" 'o.order_id = oe.order_id', 'ONE_TO_ONE', 'INNER', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({literal(model)}, 'o_to_oe', 'ORDER_ID',"
        f" NULL, 'ORDER_ID', NULL, 1)",
        f"ADD_FACT({literal(model)}, 'order_line', 'line_amount',"
        f" 'ol.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Line amount',"
        f" FALSE, TRUE)",
        f"ADD_FACT({literal(model)}, 'order', 'freight', 'o.freight',"
        f" 'DECIMAL(18,2)', 'ADDITIVE', 'Freight', 'Order freight', FALSE, TRUE)",
        f"ADD_FACT({literal(model)}, 'order_extra', 'surcharge',"
        f" 'oe.surcharge', 'DECIMAL(18,2)', 'ADDITIVE', 'Surcharge',"
        f" 'Order surcharge', FALSE, TRUE)",
    ]
    for statement in statements:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")


def add_metric(model: str, object_name: str, name: str, expression: str,
               base_entity: str) -> str:
    return (
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC({literal(model)},"
        f" {literal(object_name)}, {literal(name)}, {literal(expression)}, NULL,"
        f" 'ADDITIVE', {literal(base_entity)}, 'DECIMAL(18,2)', 'M', 'Metric',"
        f" 'currency', FALSE, TRUE)"
    )


def compile_value(con: Any, model: str, object_name: str, metric: str) -> Decimal:
    request = json.dumps({"model": model, "object": object_name,
                          "metrics": [metric]})
    statement = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(request)})")
    names = [name.lower() for name in statement.columns().keys()]
    result = dict(zip(names, statement.fetchone()))
    if result["status"] != "OK":
        raise AssertionError(
            f"compile of {metric} failed: {result.get('error_code')}"
            f" {result.get('error_message')}")
    rows = execute(con, result["generated_sql"])
    return Decimal(str(rows[0][0]))


def assert_value(label: str, actual: Decimal, expected: Decimal) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected}, got {actual}")
    print(f"ok {label}: {actual}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        build_physical(con)

        # ---- position 1: leaf == root -------------------------------------
        model = "grainpos_same"
        base_model(con, model, "order_line", "LINES")
        execute(con, add_metric(model, "LINES", "total_amount",
                                "SUM(line_amount)", "order_line"))
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(model)})")
        assert_value("position 1 (leaf == root) is exact",
                     compile_value(con, model, "LINES", "total_amount"),
                     LINE_TOTAL)

        # ---- position 2: leaf coarser than root ---------------------------
        # The F18 shape. Before the fix this was accepted, validated clean, and
        # returned FANNED_FREIGHT instead of FREIGHT_TOTAL.
        message = expect_refusal(
            con, "position 2 (leaf coarser than root) is refused",
            add_metric(model, "LINES", "total_freight", "SUM(freight)", "order"),
            "SEMANTIC_MODEL_059")
        for fragment in ("order", "order_line", "LINES"):
            if fragment not in message:
                raise AssertionError(
                    f"SEMANTIC_MODEL_059 does not name {fragment!r}: {message}")
        print("ok position 2 message names the leaf, the root and the object")

        # Nothing persisted, and the model is still valid and queryable.
        # Scoped to this model: 'total_freight' is a legitimate metric name in
        # the reference model, where it sits on an order-rooted object.
        rows = execute(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS mt"
                            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = mt.MODEL_ID"
                            " WHERE mt.METRIC_NAME = 'total_freight'"
                            " AND mt.STATUS = 'ACTIVE'"
                            f" AND m.MODEL_NAME = {literal(model)}")
        if int(rows[0][0]) != 0:
            raise AssertionError("refused metric was persisted anyway")
        print("ok position 2 left no catalog row")
        assert_value("position 2 rollback kept the object queryable",
                     compile_value(con, model, "LINES", "total_amount"),
                     LINE_TOTAL)

        # ---- position 3: leaf finer than root -----------------------------
        # The mirror image: the root cannot safely reach the leaf at all, so the
        # metric/dimension matrix refuses it. Asserted so the two rules stay
        # distinguishable -- a regression that made 059 fire here would look
        # like a pass if only the refusal were checked.
        coarse = "grainpos_coarse"
        base_model(con, coarse, "order", "ORDERS")
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION({literal(coarse)},"
                     f" 'ORDERS', 'order', 'ship_mode', 'o.ship_mode',"
                     f" 'VARCHAR(20)', 'Ship Mode', 'Ship mode', NULL, TRUE)")
        expect_refusal(
            con, "position 3 (leaf finer than root) is refused",
            add_metric(coarse, "ORDERS", "total_amount", "SUM(line_amount)",
                       "order_line"),
            "SEMANTIC_MODEL_030")

        # ---- position 4: leaf ONE_TO_ONE with the root --------------------
        # Not the root entity, but at the root's grain, so aggregation is exact
        # and the guard must allow it.
        execute(con, add_metric(coarse, "ORDERS", "total_freight",
                                "SUM(freight)", "order"))
        execute(con, add_metric(coarse, "ORDERS", "total_surcharge",
                                "SUM(surcharge)", "order_extra"))
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(coarse)})")
        assert_value("position 4 (root's own entity) is exact",
                     compile_value(con, coarse, "ORDERS", "total_freight"),
                     FREIGHT_TOTAL)
        assert_value("position 4 (ONE_TO_ONE leaf) is accepted and exact",
                     compile_value(con, coarse, "ORDERS", "total_surcharge"),
                     SURCHARGE_TOTAL)

        # The fan-out number the old behavior produced must not be reachable
        # from the fixed model at all.
        if FANNED_FREIGHT == FREIGHT_TOTAL:
            raise AssertionError("fixture no longer distinguishes fan-out")
        print(f"ok fan-out value {FANNED_FREIGHT} is unreachable"
              f" (truth {FREIGHT_TOTAL})")

        for model_name in (model, coarse):
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model_name)})")
        con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        print("F18 metric grain positions verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
