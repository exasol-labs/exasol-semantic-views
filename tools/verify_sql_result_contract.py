#!/usr/bin/env python3
"""A SQL client gets back the select list it asked for.

The semantic planner emits columns in its own order -- dimensions, then metrics
-- named after the semantic field. A client asked for something else, and until
2026-09-19 got none of it:

  * `SELECT total_revenue, customer_region` came back reversed. A client that
    binds by position puts revenue in the region column and never errors.
  * `AS "c11"` was discarded, so a tool that binds by the alias it requested
    finds no such column.
  * an unaliased column came back lower-case, where the published view's own
    metadata advertises it upper-case.

All three are one defect -- the compiled SQL was never re-projected into the
caller's select list -- and one fix. This asserts the *column names and their
order*, which the rest of the suite does not: every other check compares values,
and values are identical whichever column they arrive in.

The structured lane keeps returning semantic field names: it has no select list,
its consumers read by semantic name, and that contract is documented.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, sql_string  # noqa: E402

PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
VIEW = "SEMANTIC_SALES.SALES"
failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


def columns_of(con, statement: str) -> list[str]:
    return [name for name in con.execute(statement).columns().keys()]


def check(con, name: str, statement: str, expected: list[str]) -> None:
    actual = columns_of(con, statement)
    if actual == expected:
        ok(name, str(actual))
    else:
        fail(name, f"expected {expected}, got {actual}")


def main() -> None:
    con = connect()
    con.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    check(con, "select-list order is preserved",
          f"SELECT total_revenue, customer_region FROM {VIEW}",
          ["TOTAL_REVENUE", "CUSTOMER_REGION"])
    check(con, "interleaved select list keeps its order",
          f"SELECT total_revenue, customer_region, total_cost, order_status FROM {VIEW}",
          ["TOTAL_REVENUE", "CUSTOMER_REGION", "TOTAL_COST", "ORDER_STATUS"])
    check(con, "output aliases are honoured",
          f'SELECT customer_region AS "c11", MEASURE(total_revenue) AS "a0" FROM {VIEW}',
          ["c11", "a0"])
    check(con, "unaliased columns match the published metadata",
          f"SELECT customer_region, total_revenue FROM {VIEW}",
          ["CUSTOMER_REGION", "TOTAL_REVENUE"])

    advertised = [row[0] for row in con.execute(
        "SELECT COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS "
        "WHERE COLUMN_SCHEMA = 'SEMANTIC_SALES' AND COLUMN_TABLE = 'SALES' "
        "ORDER BY COLUMN_ORDINAL_POSITION").fetchall()]
    star = columns_of(con, f"SELECT * FROM {VIEW}")
    if star == advertised:
        ok("SELECT * matches what the view advertises", f"{len(star)} columns")
    else:
        fail("SELECT * matches what the view advertises",
             f"view advertises {advertised}, query returned {star}")

    # Renaming must not move the data.
    rows = con.execute(
        f'SELECT total_revenue AS "a0", customer_region AS "c11" FROM {VIEW} '
        f'ORDER BY "c11"').fetchall()
    if rows and all(isinstance(row[1], str) for row in rows):
        ok("projection renames without reordering the data", str(rows[:2]))
    else:
        fail("projection renames without reordering the data", str(rows[:2]))

    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    # The structured lane has no select list and keeps its documented names.
    statement = con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(%s)" % sql_string(
            '{"model":"sales","object":"SALES","dimensions":["customer_region"],'
            '"metrics":["total_revenue"]}'))
    names = [name.lower() for name in statement.columns().keys()]
    generated = dict(zip(names, statement.fetchone()))["generated_sql"]
    structured = columns_of(con, generated)
    if structured == ["customer_region", "total_revenue"]:
        ok("structured lane keeps semantic field names", str(structured))
    else:
        fail("structured lane keeps semantic field names", str(structured))

    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok sql result contract: select list, order and names preserved")


if __name__ == "__main__":
    main()
