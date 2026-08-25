#!/usr/bin/env python3
"""Verify an F3-partitioned entity cannot be silently traversed as a join hop.

F3 expands a partitioned entity into its covered partitions only where that
entity is a metric's own leaf: the branch is duplicated per partition and the
mergeable aggregate states are merged. Everywhere else the entity was rendered
from its PRIMARY representation alone, which drops every other partition's rows.

The guard that existed was keyed on *a dimension resolving to* the partitioned
entity. It never fired when the entity was merely traversed to reach a dimension
on the far side, and the query-time guard was keyed the same way — so

    order_line --INNER--> order (F3 hot/cold) --LEFT--> customer

grouping a line-grain metric by a customer attribute validated clean, published,
and returned the primary partition's subtotal as if it were the whole (BUG-G01).
The plan contradicted itself while doing it: `fusion_strategy = UNION` with two
partitions recorded next to SQL that read one table.

Both shapes are asserted here, because the fix has to refuse one without
breaking the other:

  * the hop model is refused at definition time, at publish, and at compile —
    it must never answer with a number;
  * the leaf model, where the partitioned entity *is* what the metric aggregates,
    still fuses and still returns the total across both partitions.

The second is the point of the exercise. A guard that refused both would look
like a pass here while making F3 useless.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

SCHEMA = "G01_VERIFY"
CUTOVER = "TIMESTAMP '2026-07-01 00:00:00'"

# Orders 1 and 2 are cold (before the cutover), 3 and 4 are hot.
FREIGHT_ALL = Decimal("100")      # 10 + 20 + 30 + 40
FREIGHT_HOT_ONLY = Decimal("70")  # 30 + 40 -- the number the bug reported
REVENUE_ALL = Decimal("250")      # 40 + 60 + 70 + 80


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


def try_execute(con: Any, sql: str) -> tuple[bool, Any]:
    try:
        return True, execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        return False, str(exc)


def key_columns(*columns: str) -> str:
    return json.dumps([{"ordinal_position": index + 1, "column_name": column}
                       for index, column in enumerate(columns)])


def coverage() -> str:
    return json.dumps([
        {"representation_name": "cold",
         "coverage_predicate": f"o.order_ts < {CUTOVER}",
         "valid_from": None, "valid_to": "2026-07-01 00:00:00"},
        {"representation_name": "primary",
         "coverage_predicate": f"o.order_ts >= {CUTOVER}",
         "valid_from": "2026-07-01 00:00:00", "valid_to": None},
    ])


def build_physical(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(f"""
        CREATE TABLE {SCHEMA}.ORDERS_HOT (
          ORDER_ID DECIMAL(18,0), CUSTOMER_ID DECIMAL(18,0),
          ORDER_TS TIMESTAMP, SHIP_MODE VARCHAR(20), FREIGHT DECIMAL(18,2)
        )
    """)
    con.execute(f"CREATE TABLE {SCHEMA}.ORDERS_COLD LIKE {SCHEMA}.ORDERS_HOT")
    con.execute(f"""
        CREATE TABLE {SCHEMA}.ORDER_LINES (
          ORDER_LINE_ID DECIMAL(18,0), ORDER_ID DECIMAL(18,0),
          AMOUNT DECIMAL(18,2)
        )
    """)
    con.execute(f"""
        CREATE TABLE {SCHEMA}.CUSTOMERS (
          CUSTOMER_ID DECIMAL(18,0), REGION VARCHAR(20)
        )
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDERS_COLD VALUES
          (1, 10, TIMESTAMP '2026-01-05 00:00:00', 'GROUND', 10),
          (2, 11, TIMESTAMP '2026-02-05 00:00:00', 'EXPRESS', 20)
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDERS_HOT VALUES
          (3, 10, TIMESTAMP '2026-08-05 00:00:00', 'GROUND', 30),
          (4, 11, TIMESTAMP '2026-09-05 00:00:00', 'EXPRESS', 40)
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.ORDER_LINES VALUES
          (100, 1, 40), (101, 2, 60), (102, 3, 70), (103, 4, 80)
    """)
    con.execute(f"""
        INSERT INTO {SCHEMA}.CUSTOMERS VALUES (10, 'North'), (11, 'South')
    """)


def build_model(con: Any, model: str, with_hop_dimension: bool) -> None:
    """Model with order_line -> order(F3) -> customer.

    with_hop_dimension adds the dimension that sits *beyond* the partitioned
    entity, which is the BUG-G01 shape. Without it the model only ever uses the
    partitioned entity as a metric leaf, which F3 supports.
    """
    try:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
    except Exception:  # noqa: BLE001 - absent on the first run
        pass
    statements = [
        f"CREATE_MODEL({literal(model)},"
        f" {literal('SEMANTIC_' + model.upper())}, 'BUG-G01 verification', NULL)",
        f"ADD_ENTITY({literal(model)}, 'order_line', {literal(SCHEMA)},"
        f" 'ORDER_LINES', 'ol', 'ol.order_line_id', 'One line', 'Lines')",
        f"ADD_ENTITY({literal(model)}, 'order', {literal(SCHEMA)}, 'ORDERS_HOT',"
        f" 'o', 'o.order_id', 'One order', 'Orders')",
        f"ADD_ENTITY({literal(model)}, 'customer', {literal(SCHEMA)},"
        f" 'CUSTOMERS', 'c', 'c.customer_id', 'One customer', 'Customers')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'order_line', 'ol_pk',"
        f" 'PRIMARY', 'Line identity', 'NATIVE',"
        f" {literal(key_columns('ORDER_LINE_ID'))})",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'order', 'o_pk',"
        f" 'PRIMARY', 'Order identity', 'NATIVE',"
        f" {literal(key_columns('ORDER_ID'))})",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'customer', 'c_pk',"
        f" 'PRIMARY', 'Customer identity', 'NATIVE',"
        f" {literal(key_columns('CUSTOMER_ID'))})",
        f"ADD_SEMANTIC_OBJECT({literal(model)}, 'SALES', 'order_line', 'Lines')",
        f"ADD_SEMANTIC_OBJECT({literal(model)}, 'ORDER_HEADER', 'order', 'Orders')",
        f"ADD_RELATIONSHIP({literal(model)}, 'ol_to_o', 'order_line', 'order',"
        f" 'ol.order_id = o.order_id', 'MANY_TO_ONE', 'INNER', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({literal(model)}, 'ol_to_o', 'ORDER_ID',"
        f" NULL, 'ORDER_ID', NULL, 1)",
        f"ADD_RELATIONSHIP({literal(model)}, 'o_to_c', 'order', 'customer',"
        f" 'o.customer_id = c.customer_id', 'MANY_TO_ONE', 'LEFT', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({literal(model)}, 'o_to_c', 'CUSTOMER_ID',"
        f" NULL, 'CUSTOMER_ID', NULL, 1)",
        f"ADD_DIMENSION({literal(model)}, 'ORDER_HEADER', 'order', 'ship_mode',"
        f" 'o.ship_mode', 'VARCHAR(20)', 'Ship Mode', 'Mode', NULL, TRUE)",
        f"ADD_FACT({literal(model)}, 'order_line', 'line_amount', 'ol.amount',"
        f" 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Line amount', FALSE, TRUE)",
        f"ADD_FACT({literal(model)}, 'order', 'freight', 'o.freight',"
        f" 'DECIMAL(18,2)', 'ADDITIVE', 'Freight', 'Order freight', FALSE, TRUE)",
        f"ADD_METRIC({literal(model)}, 'SALES', 'total_revenue',"
        f" 'SUM(line_amount)', NULL, 'ADDITIVE', 'order_line', 'DECIMAL(18,2)',"
        f" 'Revenue', 'Line revenue', 'currency', FALSE, TRUE)",
        f"ADD_METRIC({literal(model)}, 'ORDER_HEADER', 'total_freight',"
        f" 'SUM(freight)', NULL, 'ADDITIVE', 'order', 'DECIMAL(18,2)',"
        f" 'Freight', 'Order freight', 'currency', FALSE, TRUE)",
    ]
    if with_hop_dimension:
        statements.append(
            f"ADD_DIMENSION({literal(model)}, 'SALES', 'customer',"
            f" 'customer_region', 'c.region', 'VARCHAR(20)', 'Region', 'Region',"
            f" NULL, TRUE)")
    for statement in statements:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")


def declare_partitions(con: Any, model: str) -> tuple[bool, Any]:
    return try_execute(
        con,
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE("
        f"{literal(model)}, 'order', 'cold', 'RELATION', {literal(SCHEMA)},"
        f" 'ORDERS_COLD', 20, 'MANUAL', {literal(coverage())})")


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    statement = con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
        f"{literal(json.dumps(request))})")
    names = [name.lower() for name in statement.columns().keys()]
    return dict(zip(names, statement.fetchone()))


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        build_physical(con)

        # ---- the BUG-G01 shape: partitioned entity as a join hop ----------
        hop = "g01_hop"
        build_model(con, hop, with_hop_dimension=True)
        errors = [row for row in execute(
            con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(hop)})")
            if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"hop model invalid before partitioning: {errors}")
        print("ok hop model is valid before the coverage declaration")

        declared, detail = declare_partitions(con, hop)
        # Declaring coverage may itself be refused (the ADD script validates), or
        # be accepted and leave the model invalid. Either is failing closed; what
        # must not happen is a valid model that answers with a subtotal.
        issues = execute(
            con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(hop)})")
        refusals = [row for row in issues
                    if str(row[0]).upper() == "ERROR"
                    and "FUSION_PARTITION_JOIN_UNSUPPORTED" in str(row[4])]
        if not declared:
            if "FUSION_PARTITION_JOIN_UNSUPPORTED" not in str(detail):
                raise AssertionError(
                    f"coverage refused for the wrong reason: {detail}")
            print("ok coverage declaration refused at the traversal")
        else:
            if not refusals:
                raise AssertionError(
                    "partitioned join hop was neither refused nor reported: "
                    f"{issues}")
            message = str(refusals[0][4])
            # The hop entity, the path it sits on, and the consequence -- the
            # reader has to be able to tell this from a plain path-safety
            # complaint, because the failure mode was a plausible number.
            for fragment in ("Entity 'order'", "ol_to_o", "sits on the join path",
                             "silently omit", "total_revenue", "customer_region"):
                if fragment not in message:
                    raise AssertionError(
                        f"refusal does not name {fragment!r}: {message}")
            if str(refusals[0][2]) != "SALES":
                raise AssertionError(
                    f"refusal is not attributed to SALES: {refusals[0]}")
            print("ok validation refuses the traversal and names the hop entity")

            published, publish_detail = try_execute(
                con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL({literal(hop)})")
            if published:
                raise AssertionError("invalid hop model published anyway")
            print("ok publish is refused while the traversal stands")

            # The decisive assertion: no path answers with a number.
            for request in (
                {"model": hop, "object": "SALES", "metrics": ["total_revenue"],
                 "dimensions": ["customer_region"]},
                {"model": hop, "object": "SALES", "metrics": ["total_revenue"],
                 "filters": [{"field": "customer_region", "op": "=",
                              "value": "North"}]},
            ):
                result = compile_request(con, request)
                if result["status"] == "OK":
                    rows = execute(con, result["generated_sql"])
                    raise AssertionError(
                        "compile returned a number for a traversed partition: "
                        f"{rows} (sql: {result['generated_sql']})")
                if not str(result.get("error_code") or "").startswith("SEMANTIC_"):
                    raise AssertionError(f"unnamed refusal: {result}")
                shape = "grouped" if "dimensions" in request else "filtered"
                print(f"ok {shape} request refused with"
                      f" {result['error_code']}, no number returned")

        # ---- the shape F3 exists for: partitioned entity as the leaf ------
        leaf = "g01_leaf"
        build_model(con, leaf, with_hop_dimension=False)
        declared, detail = declare_partitions(con, leaf)
        if not declared:
            raise AssertionError(
                f"the guard broke legitimate F3 partitioning: {detail}")
        errors = [row for row in execute(
            con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(leaf)})")
            if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"legitimate F3 model no longer validates: {errors}")
        print("ok a partitioned entity used as a metric leaf still validates")

        result = compile_request(con, {
            "model": leaf, "object": "ORDER_HEADER",
            "metrics": ["total_freight"], "dimensions": ["ship_mode"]})
        if result["status"] != "OK":
            raise AssertionError(
                f"legitimate F3 request refused: {result.get('error_code')}"
                f" {result.get('error_message')}")
        generated = result["generated_sql"]
        if "UNION ALL" not in generated:
            raise AssertionError(f"partitions were not fused: {generated}")
        if "ORDERS_COLD" not in generated or "ORDERS_HOT" not in generated:
            raise AssertionError(f"a partition is missing from the SQL: {generated}")
        total = sum(Decimal(str(row[1])) for row in execute(con, generated))
        if total != FREIGHT_ALL:
            raise AssertionError(
                f"F3 total is {total}, expected {FREIGHT_ALL}"
                f" ({FREIGHT_HOT_ONLY} would mean the cold partition was dropped)")
        print(f"ok leaf-partitioned metric fuses both partitions: {total}")

        # The bug's signature number must be unreachable, not merely unequal.
        if FREIGHT_HOT_ONLY == FREIGHT_ALL:
            raise AssertionError("fixture cannot distinguish a dropped partition")
        print(f"ok primary-only subtotal {FREIGHT_HOT_ONLY} is not what we get")

        # The guard is scoped to an actual traversal, not to the mere presence of
        # a partitioned entity in the model: the line-grain metric asked for on
        # its own never reaches `order`, so it must still answer.
        result = compile_request(con, {
            "model": leaf, "object": "SALES", "metrics": ["total_revenue"]})
        if result["status"] != "OK":
            raise AssertionError(
                "an untraversed request was refused: "
                f"{result.get('error_code')} {result.get('error_message')}")
        revenue = sum(Decimal(str(row[0]))
                      for row in execute(con, result["generated_sql"]))
        if revenue != REVENUE_ALL:
            raise AssertionError(f"line revenue is {revenue}, expected {REVENUE_ALL}")
        print(f"ok a request that never traverses the partition still answers:"
              f" {revenue}")

        for model in (hop, leaf):
            try_execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
        con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        print("BUG-G01 partitioned join hop verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
