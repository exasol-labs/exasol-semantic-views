#!/usr/bin/env python3
"""A poisoned COMPILE_CACHE row is not executed: the cached statement is checked
against the relations the model declares before it is served.

The vector this exists for. SYS_SEMANTIC.COMPILE_CACHE is an ordinary table, and
the compiler is not the only thing that can write to it. Whoever can run
`UPDATE SYS_SEMANTIC.COMPILE_CACHE SET GENERATED_SQL = ...` chooses the text that
a published guarded view then executes with the view owner's rights, for every
caller, with no compile in between. The cache is a hole straight through the
governed-source architecture unless a cache row is treated as untrusted input on
the way out.

The check is containment plus non-emptiness: every relation the statement reads
must be one the model declares, and it must read at least one of them.
Containment alone waves through `SELECT 'PWNED'`, which reads nothing -- the
shortest poisoned entry there is.

What this proves and what it does not. It proves a rewritten entry cannot make
the runtime read a relation outside the model, and cannot replace the answer
with a constant. It is defence in depth, not a closed door: until the catalog's
write surface is taken away from callers (G3), the same principal who can UPDATE
COMPILE_CACHE can also INSERT the declaration that would widen the boundary.
What it removes is the far easier half of that -- rewriting one text column.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, compile_request, sql_string  # noqa: E402

MODEL = "sales"
OBJECT = "SALES"
REQUEST = {"model": MODEL, "object": OBJECT, "dimensions": ["customer_region"],
           "metrics": ["total_revenue"]}
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


def cache_rows(con) -> list[tuple]:
    return con.execute(
        "SELECT c.MODEL_VERSION_ID, c.CACHE_KEY, c.GENERATED_SQL "
        "FROM SYS_SEMANTIC.COMPILE_CACHE c "
        "JOIN SYS_SEMANTIC.MODELS m ON m.ACTIVE_VERSION_ID = c.MODEL_VERSION_ID "
        f"WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')").fetchall()


def poison(con, version_id, cache_key, statement) -> None:
    con.execute(
        "UPDATE SYS_SEMANTIC.COMPILE_CACHE SET GENERATED_SQL = "
        f"{sql_string(statement)} WHERE MODEL_VERSION_ID = {version_id} "
        f"AND CACHE_KEY = {sql_string(cache_key)}")
    con.commit()


def seeded_entry(con) -> tuple:
    """Compile once so there is an entry, and return it."""
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    first = compile_request(con, REQUEST)
    if first["status"] != "OK":
        raise SystemExit(f"setup failed: {first['error_code']} {first['error_message']}")
    rows = cache_rows(con)
    if len(rows) != 1:
        raise SystemExit(f"setup failed: expected one cache row, got {len(rows)}")
    return first, rows[0]


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    # A repeat request is served from the cache. This is the assertion that keeps
    # the check honest: if the renderer ever emits a relation shape the boundary
    # does not recognise, every hit becomes a silent recompile, and the cost of
    # the whole compile-cache lane goes away without anything failing. Here it
    # fails.
    first, (version_id, cache_key, _) = seeded_entry(con)
    again = compile_request(con, REQUEST)
    check("a legitimate entry is still served from cache", again["status"], "OK")
    check("cached SQL is returned unchanged", again["generated_sql"], first["generated_sql"])
    hits = con.execute(
        "SELECT HIT_COUNT FROM SYS_SEMANTIC.COMPILE_CACHE "
        f"WHERE MODEL_VERSION_ID = {version_id} "
        f"AND CACHE_KEY = {sql_string(cache_key)}").fetchone()
    check("the hit was recorded, so it was a hit and not a recompile",
          (hits or [0])[0] >= 1, True)

    # The demonstrated vector: an analyst rewrites GENERATED_SQL and every caller
    # of the published view runs it with the owner's rights.
    for name, statement in (
        ("a constant is refused", "SELECT 'PWNED' AS \"customer_region\", 1 AS \"total_revenue\""),
        ("an undeclared relation is refused",
         'SELECT c."CONNECTION_NAME" AS "customer_region", 1 AS "total_revenue"'
         ' FROM "SYS_SEMANTIC"."COMPILE_CACHE" c'),
        ("a declared relation joined to an undeclared one is refused",
         'SELECT o."CUSTOMER_REGION" AS "customer_region", 1 AS "total_revenue"'
         ' FROM "MART"."ORDERS" o, "SYS_SEMANTIC"."MODELS" m'),
    ):
        first, (version_id, cache_key, _) = seeded_entry(con)
        poison(con, version_id, cache_key, statement)
        served = compile_request(con, REQUEST)
        if served["status"] != "OK":
            fail(name, f"compile failed instead of recompiling: {served['error_code']}")
            continue
        if served["generated_sql"] == statement:
            fail(name, "the poisoned statement was served")
            continue
        check(name, served["generated_sql"], first["generated_sql"])
        # The row is dropped rather than left to be re-checked on every request.
        check(f"{name} -- the entry is discarded", len(cache_rows(con)) <= 1, True)
        surviving = cache_rows(con)
        if surviving and surviving[0][2] == statement:
            fail(f"{name} -- the entry is discarded", "the poisoned row survived")

    # A relation the model does declare stays inside the boundary, so this is a
    # boundary check and not a checksum: the point is what the statement reads,
    # not that it is byte-identical to what the compiler wrote.
    first, (version_id, cache_key, _) = seeded_entry(con)
    declared = con.execute(
        "SELECT r.SOURCE_SCHEMA, r.SOURCE_OBJECT "
        "FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r "
        "JOIN SYS_SEMANTIC.MODELS m ON m.ACTIVE_VERSION_ID = r.VERSION_ID "
        f"WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}') AND r.STATUS = 'ACTIVE' "
        "ORDER BY r.SOURCE_SCHEMA, r.SOURCE_OBJECT LIMIT 1").fetchone()
    inside = (f'SELECT CAST(NULL AS VARCHAR(50)) AS "customer_region",'
              f' COUNT(*) AS "total_revenue" FROM "{declared[0]}"."{declared[1]}" x')
    poison(con, version_id, cache_key, inside)
    served = compile_request(con, REQUEST)
    check("a rewritten statement inside the boundary is still served",
          served["generated_sql"], inside)

    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok cache integrity: a cached statement may only read what the model declares")


if __name__ == "__main__":
    main()
