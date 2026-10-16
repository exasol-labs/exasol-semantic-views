#!/usr/bin/env python3
"""The policy columns do what their names say, or say what they are.

`METRICS` carries `IS_PRIVATE`, `SENSITIVITY_LABEL` and `DISPLAY_POLICY`;
`DIMENSIONS` carries `IS_HIDDEN` and the same two. Nothing read them except the
discovery views, so a field marked `RESTRICTED` / `MASK` compiled and returned
data to anyone who named it:

    visible in FIELDS_FOR_AGENT?   0        <- hidden from discovery
    compiling the PRIVATE metric   OK
    rows                           [('South','60'), ('West','1000'), ...]

That is a discovery convenience wearing the vocabulary of enforcement, which is
worse than having neither. Each column now means one thing:

  IS_PRIVATE / IS_HIDDEN  refuse wherever the field is named, filters included.
                          A field you cannot discover is not nameable.
  DISPLAY_POLICY = 'MASK' the value is not returned, and filtering on it still
                          works -- slice by it without seeing it.
  SENSITIVITY_LABEL       a label. Free text, documented as a hint, enforced by
                          nothing, because that is what a label is.

`MASK` refuses the projection rather than substituting a redacted value, and
that is deliberate. ESV groups by every selected dimension, so masking a
dimension's output would either collapse every row into one group or put a
column of identical placeholders beside real counts. Either silently changes
what the number means, which is the failure this layer exists to prevent.

None of this is a substitute for source policy. The compiler runs as the caller
and the caller can read the physical sources directly; this is defence in depth
over a control that lives in the database.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, compile_request  # noqa: E402

MODEL, OBJECT = "sales", "SALES"
METRIC, DIMENSION = "total_cost", "order_status"
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


def revalidate(con) -> list[tuple]:
    return con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')").fetchall()


def set_metric(con, **columns) -> None:
    assignments = ", ".join(f"{k} = {v}" for k, v in columns.items())
    con.execute(f"UPDATE SYS_SEMANTIC.METRICS SET {assignments} "
                f"WHERE METRIC_NAME = '{METRIC}'")
    con.commit()
    revalidate(con)


def set_dimension(con, **columns) -> None:
    assignments = ", ".join(f"{k} = {v}" for k, v in columns.items())
    con.execute(f"UPDATE SYS_SEMANTIC.DIMENSIONS SET {assignments} "
                f"WHERE DIMENSION_NAME = '{DIMENSION}'")
    con.commit()
    revalidate(con)


def code_of(con, request: dict) -> str:
    result = compile_request(con, request)
    return result["error_code"] or result["status"]


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    base = {"model": MODEL, "object": OBJECT, "dimensions": ["customer_region"]}
    select_metric = dict(base, metrics=[METRIC])
    select_dimension = {"model": MODEL, "object": OBJECT,
                        "dimensions": [DIMENSION], "metrics": ["total_revenue"]}
    filter_dimension = dict(base, metrics=["total_revenue"],
                            filters=[{"field": DIMENSION, "op": "=", "value": "COMPLETE"}])

    try:
        check("a public metric compiles", code_of(con, select_metric), "OK")

        # IS_PRIVATE: removed from discovery, and now from queries.
        set_metric(con, IS_PRIVATE="TRUE")
        hidden_from_discovery = con.execute(
            "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
            f"WHERE FIELD_NAME = '{METRIC}'").fetchone()[0]
        check("a private metric is absent from discovery", hidden_from_discovery, 0)
        check("and naming it is refused", code_of(con, select_metric), "SEMANTIC_REQUEST_027")
        set_metric(con, IS_PRIVATE="FALSE")

        # IS_HIDDEN reaches filters too: a field you cannot discover is not
        # nameable anywhere, or the filter lane becomes the way around it.
        set_dimension(con, IS_HIDDEN="TRUE")
        check("a hidden dimension is refused in the select list",
              code_of(con, select_dimension), "SEMANTIC_REQUEST_027")
        check("and in a filter, which would otherwise be the way around it",
              code_of(con, filter_dimension), "SEMANTIC_REQUEST_027")
        set_dimension(con, IS_HIDDEN="FALSE")

        # MASK is about display, so it refuses the projection and permits the filter.
        set_dimension(con, DISPLAY_POLICY="'MASK'")
        check("a masked dimension is not returned",
              code_of(con, select_dimension), "SEMANTIC_REQUEST_024")
        masked_filter = compile_request(con, filter_dimension)
        check("but filtering on it still works", masked_filter["status"], "OK")
        if masked_filter["status"] == "OK":
            rows = con.execute(masked_filter["generated_sql"]).fetchall()
            check("and the filter is applied, not ignored", len(rows) < 3, True)

        # The vocabulary is closed, so a policy nobody applies is reported.
        set_dimension(con, DISPLAY_POLICY="'REDACT'")
        codes = {r[3] for r in revalidate(con) if r[0] == "WARNING"}
        check("an unrecognised policy is reported", "SEMANTIC_MODEL_069" in codes, True)
        check("and the field still returns, because nothing claimed to mask it",
              code_of(con, select_dimension), "OK")

        set_dimension(con, DISPLAY_POLICY="NULL")
        codes = {r[3] for r in revalidate(con)}
        check("an unset policy is not reported", "SEMANTIC_MODEL_069" in codes, False)

        # SENSITIVITY_LABEL is a label: it informs and enforces nothing, which is
        # now what the docs say rather than what an operator has to discover.
        set_metric(con, SENSITIVITY_LABEL="'RESTRICTED'")
        check("a sensitivity label does not refuse", code_of(con, select_metric), "OK")
        surfaced = con.execute(
            "SELECT SENSITIVITY_LABEL FROM SEMANTIC_CATALOG.METRICS "
            f"WHERE METRIC_NAME = '{METRIC}'").fetchone()[0]
        check("and it is surfaced for whoever wants to act on it", surfaced, "RESTRICTED")
    finally:
        set_metric(con, IS_PRIVATE="FALSE", SENSITIVITY_LABEL="NULL", DISPLAY_POLICY="NULL")
        set_dimension(con, IS_HIDDEN="FALSE", SENSITIVITY_LABEL="NULL", DISPLAY_POLICY="NULL")
        con.close()

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok policy columns: enforced where they read as enforcement, labelled where they do not")


if __name__ == "__main__":
    main()
