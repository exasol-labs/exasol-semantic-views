#!/usr/bin/env python3
"""Every physical relation the planner may emit is classified, and a
materialization that does not carry its representations' policy is caught.

The defect this exists for: a materialization built over the raw mart silently
voided a representation's row-level security. A restricted principal saw one
region before the rollup was registered and every region after it, with no
error, no warning and no plan diagnostic. Each object was checked on its own
terms and neither was compared with the other.

So both are classified by one derivation -- resolve the transitive base
relations through SYS.EXA_ALL_DEPENDENCIES -- and a materialization whose bases
differ from the representations it can replace is DIVERGENT.

What this proves and what it does not: it proves a view stands between the
caller and the base tables, and that a substitution reads the same relations.
It cannot prove the view's predicate is the right policy. Claiming otherwise
would be the same error the SENSITIVITY_LABEL columns already make.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, call_admin, sql_string  # noqa: E402

MODEL = "trustdemo"
SRC = "TRUSTDEMO_SRC"
GOV = "TRUSTDEMO_GOVERNED"
failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


def check(name: str, actual, expected) -> None:
    if actual == expected:
        ok(name, repr(actual))
    else:
        fail(name, f"expected {expected!r}, got {actual!r}")


def validate(con) -> list[tuple]:
    return con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')").fetchall()


def codes(rows, severity=None) -> set[str]:
    return {r[3] for r in rows if severity is None or r[0] == severity}


def trust(con) -> dict[str, str]:
    rows = con.execute(
        "SELECT t.RELATION_KIND || ':' || t.RELATION_NAME, t.TRUST_CLASS "
        "FROM SYS_SEMANTIC.SOURCE_TRUST t "
        "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = t.MODEL_ID "
        f"WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')").fetchall()
    return {r[0]: r[1] for r in rows}


def setup(con) -> None:
    for stmt in (f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
                 f"DROP SCHEMA IF EXISTS {GOV} CASCADE",
                 f"DROP SCHEMA IF EXISTS SEMANTIC_{MODEL.upper()} CASCADE"):
        con.execute(stmt)
    try:
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
    except Exception:
        pass
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), REGION VARCHAR(50), AMOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1,'North',100),(2,'South',50)")
    con.execute(f"CREATE SCHEMA {GOV}")
    con.execute(f"CREATE VIEW {GOV}.ORDERS AS SELECT ORDER_ID, REGION, AMOUNT FROM {SRC}.ORDERS")
    # a pre-aggregate over the RAW source: the shape that voided the policy
    con.execute(f"CREATE TABLE {SRC}.REGION_ROLLUP AS SELECT REGION, SUM(AMOUNT) AS AMOUNT FROM {SRC}.ORDERS GROUP BY 1")

    A = lambda script, **kw: call_admin(con, script, **kw)
    A("CREATE_MODEL", MODEL_NAME=MODEL, PUBLISHED_SCHEMA=f"SEMANTIC_{MODEL.upper()}",
      DESCRIPTION="source trust demo")
    A("ADD_ENTITY", MODEL_NAME=MODEL, ENTITY_NAME="order", SOURCE_SCHEMA=GOV,
      SOURCE_OBJECT="ORDERS", SOURCE_ALIAS="o",
      PRIMARY_KEY_EXPR="CAST(o.order_id AS VARCHAR(36))",
      GRAIN_DESCRIPTION="One row per order", DESCRIPTION="order grain")
    A("ADD_SEMANTIC_OBJECT", MODEL_NAME=MODEL, OBJECT_NAME="ORDERS",
      ROOT_ENTITY_NAME="order", DESCRIPTION="orders")
    A("ADD_DIMENSION", MODEL_NAME=MODEL, OBJECT_NAME="ORDERS", ENTITY_NAME="order",
      DIMENSION_NAME="region", EXPRESSION="o.region", DATA_TYPE="VARCHAR(50)",
      DISPLAY_NAME="Region", DESCRIPTION="region", IS_CERTIFIED=True)
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(%s, FALSE)" % sql_string(f"""
ALTER SEMANTIC VIEW {MODEL}.ORDERS
REPLACE FACTS (FACT amount ON ENTITY "order" AS o.amount RETURNS DECIMAL(18,2)
  ADDITIVE DISPLAY 'Amount' PUBLIC CERTIFIED)
REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY "order"
  RETURNS DECIMAL(18,2) DISPLAY 'Total Amount' COMMENT 'total' ADDITIVE PUBLIC CERTIFIED)"""))


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    setup(con)

    # 1. a representation reading a view is GOVERNED, and the model validates
    rows = validate(con)
    check("governed representation classified", trust(con).get("REPRESENTATION:primary"), "GOVERNED")
    check("model with a governed source validates clean", codes(rows, "ERROR"), set())

    # 2. register the rollup built over the raw source
    call_admin(con, "REGISTER_MATERIALIZATION", MODEL_NAME=MODEL,
               MATERIALIZATION_NAME="rollup", PHYSICAL_SCHEMA=SRC,
               PHYSICAL_OBJECT="REGION_ROLLUP", MATERIALIZATION_TYPE="AGGREGATE")
    call_admin(con, "ADD_MATERIALIZATION_COLUMN", MODEL_NAME=MODEL,
               MATERIALIZATION_NAME="rollup", OBJECT_TYPE="DIMENSION",
               OBJECT_NAME="region", PHYSICAL_COLUMN="REGION")
    call_admin(con, "ADD_MATERIALIZATION_COLUMN", MODEL_NAME=MODEL,
               MATERIALIZATION_NAME="rollup", OBJECT_TYPE="METRIC",
               OBJECT_NAME="total_amount", PHYSICAL_COLUMN="AMOUNT", ROLLUP_POLICY="SUM")
    rows = validate(con)
    check("divergent materialization classified", trust(con).get("MATERIALIZATION:rollup"), "DIVERGENT")
    check("OPEN mode warns about it", "SEMANTIC_MODEL_065" in codes(rows, "WARNING"), True)
    check("OPEN mode does not refuse the model", codes(rows, "ERROR"), set())

    # 3. GOVERNED mode turns the warning into a refusal
    call_admin(con, "SET_MODEL_GOVERNANCE_MODE", MODEL_NAME=MODEL, GOVERNANCE_MODE="GOVERNED")
    rows = validate(con)
    check("GOVERNED mode refuses it", "SEMANTIC_MODEL_065" in codes(rows, "ERROR"), True)

    # 4. retiring it clears the refusal
    call_admin(con, "SET_MATERIALIZATION_STATUS", MODEL_NAME=MODEL,
               MATERIALIZATION_NAME="rollup", STATUS="INACTIVE")
    rows = validate(con)
    check("retiring the materialization clears it", codes(rows, "ERROR"), set())

    # 5. a representation on a base table is refused in GOVERNED mode
    call_admin(con, "ADD_ENTITY_REPRESENTATION", MODEL_NAME=MODEL, ENTITY_NAME="order",
               REPRESENTATION_NAME="raw", SOURCE_KIND="RELATION", SOURCE_SCHEMA=SRC,
               SOURCE_OBJECT="ORDERS", PRIORITY=10)
    rows = validate(con)
    check("raw representation classified", trust(con).get("REPRESENTATION:raw"), "RAW")
    check("GOVERNED mode refuses a raw representation",
          "SEMANTIC_MODEL_064" in codes(rows, "ERROR"), True)

    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
    for stmt in (f"DROP SCHEMA IF EXISTS {SRC} CASCADE", f"DROP SCHEMA IF EXISTS {GOV} CASCADE",
                 f"DROP SCHEMA IF EXISTS SEMANTIC_{MODEL.upper()} CASCADE"):
        con.execute(stmt)
    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok source trust: representations and materializations share one classification")


if __name__ == "__main__":
    main()
