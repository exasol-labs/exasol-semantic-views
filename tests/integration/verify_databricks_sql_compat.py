#!/usr/bin/env python3
"""Verify Databricks SQL-surface compatibility in the semantic preprocessor.

Confirms that MEASURE()/agg() wrappers, GROUP BY ALL, and MEASURE() inside
HAVING / ORDER BY compile against a published semantic object, and that the
generated physical SQL matches the equivalent native (bare-name) query.
"""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any

OBJECT = "SEMANTIC_SALES.SALES"
failures = 0


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    host = os.environ.get("EXASOL_HOST", "localhost")
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"{host}:{port}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_sql(con, sql: str) -> dict[str, Any]:
    row = [tuple(r) for r in con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_string(sql)})").fetchall()][0]
    return {"status": row[0], "error_code": row[1], "error_message": row[2], "generated_sql": row[4]}


def ok(name: str, detail: str = "") -> None:
    print(f"ok  {name}{': ' + detail if detail else ''}")


def fail(name: str, detail: str) -> None:
    global failures
    failures += 1
    print(f"FAIL {name}: {detail}")


def assert_ok(con, name: str, sql: str) -> dict[str, Any]:
    res = compile_sql(con, sql)
    if res["status"] == "OK" and res["generated_sql"]:
        ok(name, "OK")
    else:
        fail(name, f"{res['error_code']}: {res['error_message']}")
    return res


def main() -> int:
    con = connect()
    try:
        # 1. MEASURE() + GROUP BY ALL is equivalent to the native bare-name query.
        dbx = assert_ok(
            con,
            "measure_group_by_all/compiles",
            "SELECT customer_region, MEASURE(total_revenue) AS total_revenue "
            f"FROM {OBJECT} GROUP BY ALL ORDER BY total_revenue DESC",
        )
        native = assert_ok(
            con,
            "native/compiles",
            "SELECT customer_region, total_revenue AS total_revenue "
            f"FROM {OBJECT} GROUP BY customer_region ORDER BY total_revenue DESC",
        )
        if dbx["generated_sql"] == native["generated_sql"]:
            ok("measure_group_by_all/equivalent", "generated SQL matches native form")
        else:
            fail("measure_group_by_all/equivalent", f"\n  dbx={dbx['generated_sql']!r}\n  native={native['generated_sql']!r}")
        if dbx["generated_sql"] and "MEASURE(" not in dbx["generated_sql"].upper():
            ok("measure_group_by_all/unwrapped", "no MEASURE() in physical SQL")
        else:
            fail("measure_group_by_all/unwrapped", "MEASURE() leaked into physical SQL")

        # 2. agg() synonym.
        assert_ok(
            con,
            "agg_synonym/compiles",
            f"SELECT customer_region, agg(total_revenue) AS total_revenue FROM {OBJECT} GROUP BY ALL",
        )

        # 3. MEASURE() inside HAVING.
        having = assert_ok(
            con,
            "having_measure/compiles",
            "SELECT customer_region, MEASURE(total_revenue) AS total_revenue "
            f"FROM {OBJECT} GROUP BY ALL HAVING MEASURE(total_revenue) > 0",
        )
        if having["generated_sql"] and "HAVING" in having["generated_sql"].upper():
            ok("having_measure/has_having", "HAVING present")
        else:
            fail("having_measure/has_having", "no HAVING in generated SQL")

        # 4. MEASURE() inside ORDER BY.
        assert_ok(
            con,
            "order_by_measure/compiles",
            "SELECT customer_region, MEASURE(total_revenue) AS total_revenue "
            f"FROM {OBJECT} GROUP BY ALL ORDER BY MEASURE(total_revenue) DESC",
        )

        # 5. GROUP BY ALL with no dimensions (pure aggregate).
        assert_ok(con, "group_by_all/no_dims", f"SELECT MEASURE(total_revenue) AS total_revenue FROM {OBJECT} GROUP BY ALL")

        # 6. Negative: MEASURE() of a dimension must be rejected.
        neg = compile_sql(con, f"SELECT MEASURE(customer_region) FROM {OBJECT} GROUP BY ALL")
        if neg["status"] == "ERROR" and neg["error_code"] == "SEMANTIC_QUERY_006":
            ok("measure_dimension/rejected", "SEMANTIC_QUERY_006")
        else:
            fail("measure_dimension/rejected", f"expected SEMANTIC_QUERY_006, got {neg['status']}/{neg['error_code']}")

        if failures:
            print(f"\nFAILED: {failures} assertion(s) failed")
            return 1
        print("\nPASSED: Databricks SQL compatibility verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
