#!/usr/bin/env python3
"""A promotion completes, and the name that is left over is only a name.

F17 has been carried forward untested through two studies. The observation was
that after promoting a representation, the one *named* `primary` holds role
`ALTERNATE` -- but no promotion had ever actually completed, so the observation
was vacuous. Both studies were refused before reaching it: first
`SEMANTIC_ADMIN_045` while the second representation did not exist, then
`SEMANTIC_ADMIN_058` once it did, because the target did not anchor the
relationship key with a bare `DIRECT` identity binding.

So this is the fixture that gets past both. The entity has a single-column
unique key, both sources expose that column, and each representation binds the
semantic identity directly to it. A third gate is easy to trip over and worth
naming: multi-representation key probes need a session `QUERY_TIMEOUT`, and
without one validation returns `PRECONDITION` (`SEMANTIC_MODEL_041`) -- which is
not an error, so a check that counts only errors reads it as a clean run and the
promotion is refused later for a reason that looks unrelated.

The answer is that F17 is not a defect. The roles swap, the entity's source
moves, and a query returns rows from the promoted source. What is left is a
representation *called* `primary` whose role is `ALTERNATE` -- correct, because a
name is a label and the role is what the layer reads -- and the promotion already
says so in its `WARNINGS` column (`SEMANTIC_ADMIN_221`) and names the rename that
settles it. This verifier holds all of that, so the finding does not have to be
carried forward again.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

MODEL = "promotion_verify"
SCHEMA = "PROMOTION_VERIFY_SRC"
PUBLISHED = "SEMANTIC_PROMOTION_VERIFY"
KEY_JSON = '[{"ordinal_position":1,"column_name":"customer_id"}]'
CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")
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


def main() -> int:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    # Multi-representation key probes need this. Without it VALIDATE_MODEL
    # returns PRECONDITION rather than an error, and the promotion is then
    # refused by SEMANTIC_ADMIN_048 for what looks like an unrelated reason.
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")

    def script(call: str):
        statement = con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{call}")
        try:
            rows = statement.fetchall()
        except Exception:  # noqa: BLE001 -- several admin scripts return no rows
            rows = []
        con.commit()
        return rows

    def teardown() -> None:
        for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                          f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"):
            try:
                con.execute(statement)
                con.commit()
            except Exception:  # noqa: BLE001 -- absent on the first run
                con.rollback()

    def representations() -> list[tuple]:
        return [tuple(row) for row in con.execute(
            "SELECT r.REPRESENTATION_NAME, r.REPRESENTATION_ROLE"
            " FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID"
            f" WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')"
            " AND r.STATUS = 'ACTIVE' ORDER BY 1").fetchall()]

    def entity_source() -> str:
        return con.execute(
            "SELECT e.SOURCE_OBJECT FROM SYS_SEMANTIC.ENTITIES e"
            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID"
            f" WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')").fetchone()[0]

    teardown()
    try:
        # Two sources for one entity, both exposing the canonical key, holding
        # different names -- so a query proves which source is being read rather
        # than merely proving it did not raise.
        con.execute(f"CREATE SCHEMA {SCHEMA}")
        con.execute(f"CREATE TABLE {SCHEMA}.C_OPS"
                    " (CUSTOMER_ID DECIMAL(18,0), NAME VARCHAR(50))")
        con.execute(f"CREATE TABLE {SCHEMA}.C_WAREHOUSE"
                    " (CUSTOMER_ID DECIMAL(18,0), NAME VARCHAR(50))")
        con.execute(f"INSERT INTO {SCHEMA}.C_OPS VALUES (1,'ops-alice'),(2,'ops-bob')")
        con.execute(f"INSERT INTO {SCHEMA}.C_WAREHOUSE"
                    " VALUES (1,'wh-alice'),(2,'wh-bob')")
        con.commit()

        script(f"CREATE_MODEL('{MODEL}', '{PUBLISHED}', 'promotion probe', NULL)")
        script(f"ADD_ENTITY('{MODEL}', 'customer', '{SCHEMA}', 'C_OPS', 'c',"
               " 'c.customer_id', 'One customer', 'Customers')")
        script(f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL}', 'customer', 'pk', 'PRIMARY',"
               f" 'Customer key', 'NATIVE', '{KEY_JSON}')")
        script(f"ADD_SEMANTIC_OBJECT('{MODEL}', 'C360', 'customer', 'Customer 360')")
        script(f"ADD_DIMENSION('{MODEL}', 'C360', 'customer', 'cname', 'c.name',"
               " 'VARCHAR(50)', 'Name', 'Resolved name', NULL, TRUE)")
        script(f"ADD_SEMANTIC_IDENTITY('{MODEL}', 'customer', 'cid', 'GLOBAL',"
               " 'DECIMAL(18,0)', 'Certified identity')")
        # The bare DIRECT binding on the key column is what SEMANTIC_ADMIN_058
        # requires and what both studies lacked.
        script(f"ADD_IDENTITY_BINDING('{MODEL}', 'cid', 'primary',"
               " 'c.customer_id', 'DIRECT')")
        script(f"ADD_ENTITY_REPRESENTATION('{MODEL}', 'customer', 'warehouse',"
               f" 'RELATION', '{SCHEMA}', 'C_WAREHOUSE', 20, 'MANUAL')")
        script(f"ADD_IDENTITY_BINDING('{MODEL}', 'cid', 'warehouse',"
               " 'c.customer_id', 'DIRECT')")

        findings = script(f"VALIDATE_MODEL('{MODEL}')")
        check("the fixture validates with nothing to report", findings, [])
        check("and starts with the roles the names suggest", representations(),
              [("primary", "PRIMARY"), ("warehouse", "ALTERNATE")])

        # The promotion itself -- the step no study has reached.
        promoted = script(f"SET_PRIMARY_REPRESENTATION('{MODEL}', 'customer',"
                          " 'warehouse')")
        if not promoted:
            fail("the promotion completes", "it returned no row")
            return 1
        ok("the promotion completes")

        check("the roles swap", representations(),
              [("primary", "ALTERNATE"), ("warehouse", "PRIMARY")])
        check("exactly one representation holds PRIMARY",
              sum(1 for _, role in representations() if role == "PRIMARY"), 1)
        check("and the entity now reads the promoted source",
              entity_source(), "C_WAREHOUSE")

        # F17, stated exactly: the leftover name is reported, not left to be
        # discovered, and the remedy is named.
        warnings = " ".join(str(value) for value in promoted[0])
        check("the promotion warns that the name and the role now disagree",
              "SEMANTIC_ADMIN_221" in warnings, True)
        check("and names the rename that settles it",
              "RENAME_ENTITY_REPRESENTATION" in warnings, True)

        check("the model still validates after the promotion",
              script(f"VALIDATE_MODEL('{MODEL}')"), [])

        # The substance: the promotion moved the data, not just a role column.
        script(f"PUBLISH_MODEL('{MODEL}')")
        lane = connect()
        try:
            lane.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT ="
                         " SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR")
            names = sorted(row[0] for row in lane.execute(
                f"SELECT CNAME FROM {PUBLISHED}.C360").fetchall())
            check("a query returns rows from the promoted source", names,
                  ["wh-alice", "wh-bob"])
        finally:
            lane.close()

        # And the remedy the warning names actually works.
        script(f"RENAME_ENTITY_REPRESENTATION('{MODEL}', 'customer', 'primary',"
               " 'ops_legacy')")
        check("renaming the demoted representation settles the confusion",
              representations(), [("ops_legacy", "ALTERNATE"),
                                  ("warehouse", "PRIMARY")])
    finally:
        teardown()

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\npromotion completes; the leftover name is reported, not a defect")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
