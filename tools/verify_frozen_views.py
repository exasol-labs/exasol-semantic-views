#!/usr/bin/env python3
"""A view compiled from a semantic object is recorded, and judged as the model moves on.

Reference expansion made `CREATE VIEW ... AS SELECT ... FROM SEMANTIC_X.OBJ`
work: the stored text is compiled physical SQL, so the view answers with no
preprocessor at all. That is a real capability -- and the same statement is a
liability, because the view goes on answering after the model changes, with the
old answer and no error. Nothing in the view says which model it came from.

Worse, and this is why it had to wait for the trust boundary: a view frozen
while a policy-divergent rollup was active bakes that rollup in. The view then
reads the pre-aggregate and never touches the governed sources again, so the row
filter is gone permanently, in an object that looks like an ordinary view, for
every principal granted it.

So three things. A freeze is recorded with the version and the relations it
froze. VALIDATE_MODEL reports a view whose version has been superseded, and one
reading a relation the model no longer vouches for. And a model running in
GOVERNED mode refuses to freeze at all unless it can vouch for everything the
compiled SQL reads.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, call_admin, sql_string  # noqa: E402

MODEL = "frozendemo"
SRC = "FROZENDEMO_SRC"
GOV = "FROZENDEMO_GOVERNED"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"
VIEW_SCHEMA, VIEW_NAME = "MART", "V_FROZEN_DEMO"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
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


def codes(rows, severity=None) -> set:
    return {r[3] for r in rows if severity is None or r[0] == severity}


def frozen_rows(con) -> list[dict]:
    rows = con.execute(
        "SELECT VIEW_SCHEMA, VIEW_NAME, PRESENCE, FROZEN_RELATIONS, MODEL_NAME "
        "FROM SEMANTIC_CATALOG.FROZEN_VIEWS ORDER BY FROZEN_VIEW_ID").fetchall()
    return [{"schema": r[0], "name": r[1], "presence": r[2],
             "relations": r[3], "model": r[4]} for r in rows]


def teardown(con) -> None:
    for stmt in (f"DROP VIEW IF EXISTS {VIEW_SCHEMA}.{VIEW_NAME}",
                 f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
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
    con.execute("DELETE FROM SYS_SEMANTIC.FROZEN_VIEWS WHERE UPPER(VIEW_NAME) = "
                f"UPPER('{VIEW_NAME}')")
    con.commit()


def setup(con) -> None:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), REGION VARCHAR(50),"
                " AMOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1,'North',100),(2,'South',50)")
    con.execute(f"CREATE SCHEMA {GOV}")
    con.execute(f"CREATE VIEW {GOV}.ORDERS AS SELECT ORDER_ID, REGION, AMOUNT FROM {SRC}.ORDERS")
    # the pre-aggregate over the raw source: the shape that voids the policy
    con.execute(f"CREATE TABLE {SRC}.REGION_ROLLUP AS SELECT REGION, SUM(AMOUNT) AS AMOUNT"
                f" FROM {SRC}.ORDERS GROUP BY 1")

    A = lambda script, **kw: call_admin(con, script, **kw)
    A("CREATE_MODEL", MODEL_NAME=MODEL, PUBLISHED_SCHEMA=PUBLISHED,
      DESCRIPTION="frozen view demo")
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

    bi = connect()
    bi.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    # 1. freezing is recorded, with the version and the relations it froze
    bi.execute(f"CREATE VIEW {VIEW_SCHEMA}.{VIEW_NAME} AS SELECT t0.REGION, t0.TOTAL_AMOUNT"
               f" FROM {PUBLISHED}.ORDERS t0")
    bi.commit()
    rows = [r for r in frozen_rows(con) if r["name"].upper() == VIEW_NAME]
    check("the freeze is recorded", len(rows), 1)
    if rows:
        check("against the model it came from", rows[0]["model"], MODEL)
        check("and it is live", rows[0]["presence"], "LIVE")
        check("recording what it reads", f"{GOV}.ORDERS" in (rows[0]["relations"] or ""), True)

    plain = connect()
    plain.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    check("and the view answers with no preprocessor",
          sorted(str(r[1]) for r in
                 plain.execute(f"SELECT * FROM {VIEW_SCHEMA}.{VIEW_NAME} ORDER BY 1").fetchall()),
          ["100", "50"])

    def frozen_status(view=VIEW_NAME):
        rows = con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('{MODEL}')").fetchall()
        for row in rows:
            if (row[1] or "").upper() == view.upper():
                return row[2]
        return None

    check("a freshly frozen view matches what the model compiles", frozen_status(), "CURRENT")

    # 2. the model's definition changes underneath it.
    #
    # There is no version to compare: ESV creates exactly one model version and
    # authoring mutates it in place, so the only faithful test is to compile the
    # same columns again and see whether the SQL comes back the same.
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(%s, FALSE)"
                % sql_string(f"""
ALTER SEMANTIC VIEW {MODEL}.ORDERS
ADD OR REPLACE METRIC total_amount AS SUM(amount) * 1 ON ENTITY "order"
  RETURNS DECIMAL(18,2) DISPLAY 'Total' COMMENT 'total' ADDITIVE PUBLIC CERTIFIED"""))
    con.commit()
    check("a view whose model changed underneath it reads STALE", frozen_status(), "STALE")
    check("and it still answers, with the older definition",
          len(plain.execute(f"SELECT * FROM {VIEW_SCHEMA}.{VIEW_NAME}").fetchall()), 2)

    # 3. a dropped view is how one is retired, not a finding
    plain.execute(f"DROP VIEW {VIEW_SCHEMA}.{VIEW_NAME}")
    plain.commit()
    rows = [r for r in frozen_rows(con) if r["name"].upper() == VIEW_NAME]
    check("a dropped view reads as DROPPED", rows[0]["presence"] if rows else None, "DROPPED")
    check("and the check reports it as dropped too", frozen_status(), "DROPPED")
    check("and is not reported as a problem",
          "SEMANTIC_MODEL_068" in codes(validate(con)), False)

    # 4. a governed model refuses to freeze what it cannot vouch for.
    #    Registering a materialization clears the derived trust classes, so until
    #    the model is validated again it vouches for nothing -- which is exactly
    #    when freezing must not happen.
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_GOVERNANCE_MODE('{MODEL}', 'GOVERNED')")
    con.commit()
    call_admin(con, "REGISTER_MATERIALIZATION", MODEL_NAME=MODEL,
               MATERIALIZATION_NAME="rollup", PHYSICAL_SCHEMA=SRC,
               PHYSICAL_OBJECT="REGION_ROLLUP", MATERIALIZATION_TYPE="AGGREGATE")
    con.commit()
    try:
        bi.execute(f"CREATE VIEW {VIEW_SCHEMA}.{VIEW_NAME} AS SELECT t0.REGION,"
                   f" t0.TOTAL_AMOUNT FROM {PUBLISHED}.ORDERS t0")
        fail("a governed model refuses to freeze what it cannot vouch for", "it was accepted")
    except Exception as exc:
        # The refusal comes from the compile, not from a freeze-specific guard:
        # you cannot freeze SQL you cannot compile, so a second code for the same
        # condition one step later could never fire.
        check("a governed model refuses to freeze what it cannot vouch for",
              "SEMANTIC_QUERY_028" in str(exc), True)

    # ... and once it can vouch for them again, freezing works.
    validate(con)
    con.commit()
    try:
        bi.execute(f"CREATE VIEW {VIEW_SCHEMA}.{VIEW_NAME} AS SELECT t0.REGION,"
                   f" t0.TOTAL_AMOUNT FROM {PUBLISHED}.ORDERS t0")
        bi.commit()
        ok("and accepts it once the model vouches for them again")
    except Exception as exc:
        fail("and accepts it once the model vouches for them again",
             str(exc).replace("\n", " ")[:120])

    bi.close()
    plain.close()
    teardown(con)
    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok frozen views: a compiled view is recorded, tracked, and refused when unvouched")


if __name__ == "__main__":
    main()
