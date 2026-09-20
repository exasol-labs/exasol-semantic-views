#!/usr/bin/env python3
"""GOVERNED mode refuses the compile, not only the freeze.

`docs/governance.md` introduces the trust boundary with a demonstrated defect: a
rollup built over the raw tables substitutes for a proven branch and drops the
row policy its representations carry, "silently and for every caller". A
restricted principal saw one region before the materialization was registered and
every region after it.

The detection for that shipped and worked -- `SEMANTIC_MODEL_065`, a trust class,
a prose explanation, a plan block. The enforcement did not. `GOVERNED` mode was
consulted in exactly one place, the guard that refuses to freeze a view, so a
model in `GOVERNED` mode reported an `ERROR` from validation, printed *"it will
refuse to compile or to freeze a view"* in its own summary, and then served the
query. The scenario the mode was built for was still live in the mode that
promises to stop it.

That is the specific failure the page's own first paragraph names: *a control
that looks like a control and is not is worse than having neither, because
someone relies on it.*

Two things are checked here, and the second is why `RAW` is not refused: a
materialization built *from* the governed views is a table, so it classifies
`RAW` rather than `GOVERNED`, and it carries their policy perfectly well.
Refusing it would make the mode unusable with any pre-aggregate. What is refused
is what the model cannot vouch for -- `DIVERGENT`, `UNKNOWN`, and a relation set
no derivation has run against since it last changed.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, call_admin, compile_request, sql_string  # noqa: E402

MODEL = "governedcompile"
SRC = "GOVCOMPILE_SRC"
GOV = "GOVCOMPILE_GOVERNED"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"
REQUEST = {"model": MODEL, "object": "ORDERS",
           "dimensions": ["region"], "metrics": ["total_amount"]}
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


def set_mode(con, mode: str) -> None:
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_GOVERNANCE_MODE('{MODEL}', '{mode}')")
    con.commit()
    validate(con)


def cold_compile(con) -> dict:
    """Always from a cold cache: a served cache hit would hide the refusal."""
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    return compile_request(con, REQUEST)


def trust(con) -> dict:
    return {r[0]: r[1] for r in con.execute(
        "SELECT RELATION_NAME, TRUST_CLASS FROM SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL "
        f"WHERE MODEL_NAME = '{MODEL}'").fetchall()}


def teardown(con) -> None:
    for stmt in (f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
                 f"DROP SCHEMA IF EXISTS {GOV} CASCADE",
                 f"DROP SCHEMA IF EXISTS {PUBLISHED} CASCADE"):
        try:
            con.execute(stmt)
        except Exception:
            pass
    try:
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
    except Exception:
        pass
    con.commit()


def setup(con) -> None:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0),"
                " REGION VARCHAR(50), AMOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1,'North',100),(2,'South',50),(3,'West',25)")
    con.execute(f"CREATE SCHEMA {GOV}")
    # the governed view: this is where a row policy would live
    con.execute(f"CREATE VIEW {GOV}.ORDERS AS SELECT ORDER_ID, REGION, AMOUNT FROM {SRC}.ORDERS")
    # the pre-aggregate built over the RAW source, bypassing the governed view
    con.execute(f"CREATE TABLE {SRC}.REGION_ROLLUP AS SELECT REGION,"
                f" SUM(AMOUNT) AS AMOUNT FROM {SRC}.ORDERS GROUP BY 1")

    A = lambda script, **kw: call_admin(con, script, **kw)
    A("CREATE_MODEL", MODEL_NAME=MODEL, PUBLISHED_SCHEMA=PUBLISHED,
      DESCRIPTION="governed compile demo")
    A("ADD_ENTITY", MODEL_NAME=MODEL, ENTITY_NAME="order", SOURCE_SCHEMA=GOV,
      SOURCE_OBJECT="ORDERS", SOURCE_ALIAS="o",
      PRIMARY_KEY_EXPR="CAST(o.order_id AS VARCHAR(36))",
      GRAIN_DESCRIPTION="One row per order", DESCRIPTION="order grain")
    A("ADD_SEMANTIC_OBJECT", MODEL_NAME=MODEL, OBJECT_NAME="ORDERS",
      ROOT_ENTITY_NAME="order", DESCRIPTION="orders")
    A("ADD_DIMENSION", MODEL_NAME=MODEL, OBJECT_NAME="ORDERS", ENTITY_NAME="order",
      DIMENSION_NAME="region", EXPRESSION="o.region", DATA_TYPE="VARCHAR(50)",
      DISPLAY_NAME="Region", DESCRIPTION="region", IS_CERTIFIED=True)
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(%s, FALSE)"
                % sql_string(f"""
ALTER SEMANTIC VIEW {MODEL}.ORDERS
REPLACE FACTS (FACT amount ON ENTITY "order" AS o.amount RETURNS DECIMAL(18,2)
  ADDITIVE DISPLAY 'Amount' PUBLIC CERTIFIED)
REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY "order"
  RETURNS DECIMAL(18,2) DISPLAY 'Total' COMMENT 'total' ADDITIVE PUBLIC CERTIFIED)"""))
    validate(con)
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.commit()


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    setup(con)

    try:
        # 1. a governed source, and GOVERNED mode is satisfied by it
        check("the representation resolves through a view", trust(con).get("primary"), "GOVERNED")
        set_mode(con, "GOVERNED")
        check("a governed model compiles", cold_compile(con)["status"], "OK")

        # 2. the plan says which mode it compiled under. This reported OPEN for a
        #    GOVERNED model, because load_model never selected the column and
        #    `model.governance_mode or "OPEN"` turned absence into an answer.
        import json
        plan = json.loads(cold_compile(con)["plan_json"] or "{}")
        check("and the plan reports the mode it actually ran under",
              (plan.get("governance") or {}).get("governance_mode"), "GOVERNED")

        # 3. register the rollup built over the raw source
        call_admin(con, "REGISTER_MATERIALIZATION", MODEL_NAME=MODEL,
                   MATERIALIZATION_NAME="rollup", PHYSICAL_SCHEMA=SRC,
                   PHYSICAL_OBJECT="REGION_ROLLUP", MATERIALIZATION_TYPE="AGGREGATE")
        call_admin(con, "ADD_MATERIALIZATION_COLUMN", MODEL_NAME=MODEL,
                   MATERIALIZATION_NAME="rollup", OBJECT_TYPE="DIMENSION",
                   OBJECT_NAME="region", PHYSICAL_COLUMN="REGION")
        call_admin(con, "ADD_MATERIALIZATION_COLUMN", MODEL_NAME=MODEL,
                   MATERIALIZATION_NAME="rollup", OBJECT_TYPE="METRIC",
                   OBJECT_NAME="total_amount", PHYSICAL_COLUMN="AMOUNT",
                   ROLLUP_POLICY="SUM")
        con.commit()
        validate(con)
        check("the rollup is classified divergent", trust(con).get("rollup"), "DIVERGENT")

        # 4. the compile is refused, and this is the whole point
        refused = cold_compile(con)
        check("a governed model refuses to compile against it", refused["status"], "ERROR")
        check("with a code naming the governance decision",
              refused["error_code"], "SEMANTIC_REQUEST_028")
        check("and the message names the relation",
              "REGION_ROLLUP" in (refused["error_message"] or "").upper(), True)
        check("and no SQL is returned to run", refused["generated_sql"], None)

        # 5. OPEN reports rather than refuses -- that is what the modes mean
        set_mode(con, "OPEN")
        check("the same model in OPEN mode still answers", cold_compile(con)["status"], "OK")
        warnings = {r[3] for r in validate(con) if r[0] == "WARNING"}
        check("and says so as a warning", "SEMANTIC_MODEL_065" in warnings, True)

        # 6. retiring the rollup restores the governed model
        set_mode(con, "GOVERNED")
        check("still refused before the rollup is retired", cold_compile(con)["status"], "ERROR")
        call_admin(con, "SET_MATERIALIZATION_STATUS", MODEL_NAME=MODEL,
                   MATERIALIZATION_NAME="rollup", STATUS="INACTIVE")
        con.commit()
        validate(con)
        restored = cold_compile(con)
        check("and served again once it is retired", restored["status"], "OK")
        check("reading the governed view, not the rollup",
              GOV in (restored["generated_sql"] or ""), True)
    finally:
        teardown(con)
        con.close()

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok governed mode: the refusal reaches the compile, not only the freeze")


if __name__ == "__main__":
    main()
