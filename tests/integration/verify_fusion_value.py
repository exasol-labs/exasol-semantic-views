#!/usr/bin/env python3
"""The two numbers that make the case for declared fusion, computed and asserted.

Both are failures a hand-written query makes silently, and both are arithmetic
rather than opinion, so they are computed here rather than quoted — and asserted,
so the figures in `README.md` cannot drift from what the product does.

  1. **The boundary day.** A hot/cold split re-loads the cutover day into both
     tables — the most ordinary operational accident there is. A hand-rolled
     `UNION ALL` counts that day twice. F3 coverage predicates exclude it by
     construction, because each partition declares the half-open interval it
     owns.

  2. **The stranded NULL bucket.** A warehouse customer master has no loyalty
     tier for customers onboarded after its last load; a CRM extract has them.
     Reading only the warehouse strands that revenue in a `NULL` bucket. F4
     reconciliation against the authoritative source recovers it, and the
     recovered amount is a share of total revenue worth knowing.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

MODEL_F3 = "fusion_value_f3"
MODEL_F4 = "fusion_value_f4"
SCHEMA = "FUSION_VALUE"
CUTOVER = "2026-07-01 00:00:00"


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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_and_run(con: Any, request: dict[str, Any]) -> list[tuple[Any, ...]]:
    payload = json.dumps(request, separators=(",", ":"))
    row = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})"
    )[0]
    if str(row[0]) != "OK":
        raise AssertionError(f"compile failed: {row[1]} {row[2]}")
    return execute(con, str(row[4]))


def money(value: Any) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"))


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def build_tables(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")

    # ── 1. hot/cold orders, with the cutover day loaded into BOTH tables ──
    con.execute(
        f"CREATE TABLE {SCHEMA}.ORDERS_COLD (ORDER_ID DECIMAL(18,0), "
        "FREIGHT DECIMAL(18,2), ORDER_TS TIMESTAMP)"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.ORDERS_HOT (ORDER_ID DECIMAL(18,0), "
        "FREIGHT DECIMAL(18,2), ORDER_TS TIMESTAMP)"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.ORDERS_COLD VALUES "
        "(1, 1200.00, TIMESTAMP '2026-05-04 09:00:00'), "
        "(2,  850.50, TIMESTAMP '2026-06-11 14:30:00'), "
        "(3,  975.25, TIMESTAMP '2026-06-30 23:10:00'), "
        # the boundary day, loaded again by the archive job
        "(4,  480.00, TIMESTAMP '2026-07-01 08:15:00'), "
        "(5,  310.75, TIMESTAMP '2026-07-01 17:45:00')"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.ORDERS_HOT VALUES "
        "(4,  480.00, TIMESTAMP '2026-07-01 08:15:00'), "
        "(5,  310.75, TIMESTAMP '2026-07-01 17:45:00'), "
        "(6,  640.40, TIMESTAMP '2026-07-19 11:05:00'), "
        "(7,  515.10, TIMESTAMP '2026-08-02 16:20:00')"
    )

    # ── 2. a customer master missing tiers the CRM has ──
    con.execute(
        f"CREATE TABLE {SCHEMA}.CUSTOMERS_DW (CUSTOMER_ID DECIMAL(18,0), "
        "LOYALTY_TIER VARCHAR(20))"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.CUSTOMERS_CRM (CUSTOMER_ID DECIMAL(18,0), "
        "LOYALTY_TIER VARCHAR(20))"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.CUSTOMERS_DW VALUES "
        "(1, 'Gold'), (2, 'Silver'), (3, NULL), (4, NULL), (5, NULL)"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.CUSTOMERS_CRM VALUES "
        "(1, 'Gold'), (2, 'Silver'), (3, 'Gold'), (4, 'Bronze'), (5, 'Silver')"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.SALES (SALE_ID DECIMAL(18,0), "
        "CUSTOMER_ID DECIMAL(18,0), REVENUE DECIMAL(18,2))"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.SALES VALUES "
        "(1, 1, 42000.00), (2, 2, 31500.00), (3, 3, 58250.75), "
        "(4, 4, 27400.25), (5, 5, 70602.44)"
    )


def build_f3_model(con: Any) -> None:
    coverage = json.dumps([
        {"representation_name": "cold",
         "coverage_predicate": f"o.order_ts < TIMESTAMP '{CUTOVER}'",
         "valid_from": None, "valid_to": CUTOVER},
        {"representation_name": "primary",
         "coverage_predicate": f"o.order_ts >= TIMESTAMP '{CUTOVER}'",
         "valid_from": CUTOVER, "valid_to": None},
    ])
    for statement in (
        f"CREATE_MODEL('{MODEL_F3}', 'SEMANTIC_{SCHEMA}_F3', 'Boundary-day demo', NULL)",
        f"ADD_ENTITY('{MODEL_F3}', 'order', '{SCHEMA}', 'ORDERS_HOT', 'o', "
        "'o.order_id', 'One order', 'Hot/cold partitioned orders')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL_F3}', 'order', 'order_pk', 'PRIMARY', "
        "'Order identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"order_id"}]\')',
        f"ADD_SEMANTIC_OBJECT('{MODEL_F3}', 'ORDERS', 'order', 'Order-grain freight')",
        f"ADD_FACT('{MODEL_F3}', 'order', 'freight', 'o.freight', 'DECIMAL(18,2)', "
        "'ADDITIVE', 'Freight', 'Freight charged', FALSE, TRUE)",
        f"ADD_ENTITY_REPRESENTATION_WITH_COVERAGE('{MODEL_F3}', 'order', 'cold', "
        f"'RELATION', '{SCHEMA}', 'ORDERS_COLD', 20, 'MANUAL', {literal(coverage)})",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        + literal(f"""ALTER SEMANTIC VIEW {MODEL_F3}.ORDERS REPLACE METRICS (
  METRIC total_freight AS SUM(freight) ON ENTITY "order" RETURNS DECIMAL(18,2)
    FORMAT 'currency' DISPLAY 'Total Freight' COMMENT 'Freight across partitions'
    ADDITIVE PUBLIC CERTIFIED
)""")
        + ", FALSE)",
    )


def build_f4_model(con: Any) -> None:
    for statement in (
        f"CREATE_MODEL('{MODEL_F4}', 'SEMANTIC_{SCHEMA}_F4', 'Stranded-tier demo', NULL)",
        f"ADD_ENTITY('{MODEL_F4}', 'sale', '{SCHEMA}', 'SALES', 's', 's.sale_id', "
        "'One sale', 'Sales')",
        f"ADD_ENTITY('{MODEL_F4}', 'customer', '{SCHEMA}', 'CUSTOMERS_DW', 'c', "
        "'c.customer_id', 'One customer', 'Customer 360')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL_F4}', 'sale', 'sale_pk', 'PRIMARY', "
        "'Sale identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"sale_id"}]\')',
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL_F4}', 'customer', 'customer_pk', "
        "'PRIMARY', 'Customer identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"customer_id"}]\')',
        f"ADD_RELATIONSHIP('{MODEL_F4}', 'sale_to_customer', 'sale', 'customer', "
        "'s.customer_id = c.customer_id', 'MANY_TO_ONE', 'LEFT', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING('{MODEL_F4}', 'sale_to_customer', "
        "'customer_id', NULL, 'customer_id', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT('{MODEL_F4}', 'SALES', 'sale', 'Revenue by tier')",
        f"ADD_DIMENSION('{MODEL_F4}', 'SALES', 'customer', 'loyalty_tier', "
        "'c.loyalty_tier', 'VARCHAR(20)', 'Loyalty Tier', 'Resolved tier', NULL, TRUE)",
        f"ADD_FACT('{MODEL_F4}', 'sale', 'revenue', 's.revenue', 'DECIMAL(18,2)', "
        "'ADDITIVE', 'Revenue', 'Recognised revenue', FALSE, TRUE)",
        f"ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY('{MODEL_F4}', 'customer', 'crm', "
        f"'RELATION', '{SCHEMA}', 'CUSTOMERS_CRM', 20, 'MANUAL', 'AUTHORITATIVE')",
        f"ADD_ATTRIBUTE_BINDING('{MODEL_F4}', 'DIMENSION', 'loyalty_tier', 'crm', "
        "'c.loyalty_tier', 'PREFER', 1)",
        f"SET_REPRESENTATION_AUTHORITY('{MODEL_F4}', 'customer', 'primary', 'SUPPLEMENTAL')",
        f"SET_ATTRIBUTE_FUSION_POLICY('{MODEL_F4}', 'DIMENSION', 'loyalty_tier', 'RECONCILE')",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    applied = execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        + literal(f"""ALTER SEMANTIC VIEW {MODEL_F4}.SALES REPLACE METRICS (
  METRIC total_revenue AS SUM(revenue) ON ENTITY sale RETURNS DECIMAL(18,2)
    FORMAT 'currency' DISPLAY 'Total Revenue' COMMENT 'Revenue by resolved tier'
    ADDITIVE PUBLIC CERTIFIED
)""")
        + ", FALSE)",
    )
    if not applied or str(applied[0][0]) != "OK":
        raise AssertionError(f"metric definition failed: {applied}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        for model in (MODEL_F3, MODEL_F4):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{model}')")
            except Exception:
                pass
        build_tables(con)

        # ── 1. the boundary day ────────────────────────────────────────────
        build_f3_model(con)
        hand_rolled = money(execute(
            con,
            f"SELECT SUM(FREIGHT) FROM (SELECT * FROM {SCHEMA}.ORDERS_COLD "
            f"UNION ALL SELECT * FROM {SCHEMA}.ORDERS_HOT)",
        )[0][0])
        truth = money(execute(
            con,
            "SELECT SUM(FREIGHT) FROM (SELECT DISTINCT ORDER_ID, FREIGHT FROM ("
            f"SELECT ORDER_ID, FREIGHT FROM {SCHEMA}.ORDERS_COLD UNION ALL "
            f"SELECT ORDER_ID, FREIGHT FROM {SCHEMA}.ORDERS_HOT))",
        )[0][0])
        declared = money(compile_and_run(con, {
            "model": MODEL_F3, "object": "ORDERS", "metrics": ["total_freight"],
            "client": "verify_fusion_value",
        })[0][0])

        print()
        print("--- 1. the boundary day is loaded into both partitions ---------------")
        print(f"   hand-rolled UNION ALL : {hand_rolled}")
        print(f"   declared F3 fusion    : {declared}")
        print(f"   truth                 : {truth}")
        assert_equal("F3 answers the truth", declared, truth)
        if hand_rolled <= truth:
            raise AssertionError(
                f"fixture no longer double-counts the boundary day ({hand_rolled})")
        print(f"ok the hand-rolled union overstates freight by {hand_rolled - truth}")

        # ── 2. the stranded NULL bucket ────────────────────────────────────
        build_f4_model(con)
        warehouse_only = {
            str(row[0]): money(row[1])
            for row in execute(
                con,
                f"SELECT COALESCE(c.LOYALTY_TIER, '(null)'), SUM(s.REVENUE) "
                f"FROM {SCHEMA}.SALES s LEFT JOIN {SCHEMA}.CUSTOMERS_DW c "
                "ON s.CUSTOMER_ID = c.CUSTOMER_ID GROUP BY 1",
            )
        }
        reconciled = {
            str(row[0]): money(row[1])
            for row in compile_and_run(con, {
                "model": MODEL_F4, "object": "SALES", "metrics": ["total_revenue"],
                "dimensions": ["loyalty_tier"], "client": "verify_fusion_value",
            })
        }
        total = money(execute(con, f"SELECT SUM(REVENUE) FROM {SCHEMA}.SALES")[0][0])
        stranded = warehouse_only.get("(null)", Decimal("0.00"))
        share = (stranded / total * 100).quantize(Decimal("0.1"))

        print()
        print("--- 2. revenue stranded in the warehouse's NULL tier ------------------")
        print(f"   warehouse only : {dict(sorted(warehouse_only.items()))}")
        print(f"   reconciled     : {dict(sorted(reconciled.items()))}")
        print(f"   stranded       : {stranded} of {total} ({share}% of revenue)")
        if "(null)" in reconciled:
            raise AssertionError(f"reconciliation left a NULL bucket: {reconciled}")
        assert_equal("reconciliation preserves the total",
                     sum(reconciled.values()), total)
        recovered = sum(
            max(amount - warehouse_only.get(tier, Decimal("0.00")), Decimal("0.00"))
            for tier, amount in reconciled.items()
        )
        assert_equal("the recovered amount is exactly the stranded amount",
                     recovered, stranded)
        print(f"ok reconciliation recovered {stranded} ({share}% of revenue)")

        print()
        print("fusion value verified.")
        return 0
    finally:
        for model in (MODEL_F3, MODEL_F4):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{model}')")
            except Exception:
                pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
