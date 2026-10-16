#!/usr/bin/env python3
"""The policy columns a steward is told about can be set by a steward.

`docs/governance.md` presents four columns as a control table and
`docs/validation-rules.md` documents `SEMANTIC_MODEL_069` for a bad
`DISPLAY_POLICY`. Two of the four had no writer anywhere a steward could reach:
`DISPLAY_POLICY` and `SENSITIVITY_LABEL` were written only by a private helper
inside the OSI document importer, whose own comment observed that these columns
"had no writer anywhere in the product". The documented route to `MASK` was a
direct `UPDATE` on `SYS_SEMANTIC` -- which the same page tells stewards never to
do, and which the release had just moved behind a schema they are not granted.

So the gap was not enforcement. Enforcement worked; the study set the columns by
hand to prove it. The gap was that nothing in the product would set them.

What this holds is the whole path, because each half of it already existed and
the missing piece was that they were never joined: a steward sets the policy with
a script, a query that names the field is refused, and clearing the policy lets
the same query through again. A writer that wrote without being enforced, or an
enforcement nothing could turn on, would each pass half of this.
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, compile_request, named_row  # noqa: E402

MODEL, OBJECT = "sales", "SALES"
DIMENSION, METRIC, FACT = "order_status", "total_revenue", "net_revenue"
PUBLISHED = "SEMANTIC_SALES.SALES"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
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


def literal(value) -> str:
    return "NULL" if value is None else "'" + str(value).replace("'", "''") + "'"


def main() -> int:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    con.commit()

    def retrying(statement: str):
        """VALIDATE_MODEL and this script both write, so they collide.

        The runtime retries collisions internally; a host-side caller has to do
        the same or the test reports the database being busy as a defect.
        """
        last = None
        for attempt in range(5):
            try:
                result = con.execute(statement)
                con.commit()
                return result
            except Exception as exception:  # noqa: BLE001
                last = exception
                if "collision" not in " ".join(str(exception).split()).lower():
                    raise
                con.rollback()
                time.sleep(1.0 + attempt)
        raise last

    def set_policy(field, display_policy, sensitivity_label):
        return named_row(retrying(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_FIELD_POLICY("
            f"'{MODEL}', '{OBJECT}', '{field}', "
            f"{literal(display_policy)}, {literal(sensitivity_label)})"))

    def revalidate():
        retrying(f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")

    def request_code(fields):
        result = compile_request(con, dict(
            {"model": MODEL, "object": OBJECT}, **fields))
        return result["error_code"] or result["status"]

    def sql_code(statement):
        lane = connect()
        try:
            lane.execute(
                f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
            lane.execute(statement).fetchall()
            return "OK"
        except Exception as exception:  # noqa: BLE001 -- the refusal is the result
            found = CODE.search(" ".join(str(exception).split()))
            return found.group(0) if found else "RAW"
        finally:
            lane.close()

    try:
        # 1. the writer exists, reaches both kinds of field, and reports what it did
        #
        # Guarded: the way "no writer" fails is an exception, and an unguarded
        # call ends the run with a traceback that names no invariant -- which is
        # exactly the shape that makes a regression hard to read.
        try:
            row = set_policy(DIMENSION, "MASK", "confidential")
        except Exception as exception:  # noqa: BLE001
            fail("a dimension's policy is settable",
                 " ".join(str(exception).split())[:160])
            row = {}
        check("a dimension's policy is settable", row.get("field_kind"), "DIMENSION")
        check("and the display policy is recorded", row.get("display_policy"), "MASK")
        check("and the sensitivity label with it",
              row.get("sensitivity_label"), "confidential")

        stored = con.execute(
            "SELECT DISPLAY_POLICY, SENSITIVITY_LABEL FROM SYS_SEMANTIC.DIMENSIONS"
            f" WHERE DIMENSION_NAME = '{DIMENSION}'").fetchone()
        check("the catalog carries both columns", tuple(stored),
              ("MASK", "confidential"))

        try:
            metric_row = set_policy(METRIC, None, "restricted")
        except Exception as exception:  # noqa: BLE001
            fail("a metric's label is settable too",
                 " ".join(str(exception).split())[:160])
            metric_row = {}
        check("a metric's label is settable too", metric_row.get("field_kind"), "METRIC")
        check("and a NULL display policy is a value, not a no-op",
              metric_row.get("display_policy"), None)

        # 2. what it wrote is what the compiler enforces -- both lanes
        revalidate()
        check("the masked dimension is refused in the request lane",
              request_code({"dimensions": [DIMENSION], "metrics": [METRIC]}),
              "SEMANTIC_REQUEST_024")
        check("and in the SQL lane",
              sql_code(f"SELECT {DIMENSION.upper()}, {METRIC.upper()}"
                       f" FROM {PUBLISHED}"),
              "SEMANTIC_QUERY_024")

        # 3. and clearing it is a real operation, not a one-way door
        set_policy(DIMENSION, None, None)
        revalidate()
        check("clearing the policy lets the same query through",
              request_code({"dimensions": [DIMENSION], "metrics": [METRIC]}), "OK")

        # 4. a fact is refused by name rather than silently written: neither
        #    policy column has a reader for one, because it is never returned
        try:
            set_policy(FACT, "MASK", None)
            fail("setting a policy on a fact is refused", "it was accepted")
        except Exception as exception:  # noqa: BLE001
            message = " ".join(str(exception).split())
            check("setting a policy on a fact is refused",
                  "SEMANTIC_ADMIN_014" in message, True)
            check("and the refusal says where it belongs instead",
                  "metric built from this one" in message, True)

        try:
            set_policy("no_such_field", "MASK", None)
            fail("an unknown field is refused", "it was accepted")
        except Exception as exception:  # noqa: BLE001
            check("an unknown field is refused",
                  "SEMANTIC_ADMIN_013" in " ".join(str(exception).split()), True)
    finally:
        try:
            set_policy(DIMENSION, None, None)
            set_policy(METRIC, None, None)
            revalidate()
        except Exception as exception:  # noqa: BLE001
            print(f"  (cleanup: {' '.join(str(exception).split())[:90]})")

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\na steward can set the policy columns, and what they set is enforced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
