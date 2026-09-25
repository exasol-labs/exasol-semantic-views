#!/usr/bin/env python3
"""Every published capability is demonstrated, in the lane whose code it names.

`SEMANTIC_CATALOG.QUERY_CAPABILITIES` is the answer to "what can I send this?",
cited from `docs/bi-tools.md` for integrators. It was checked by a test that
grepped the Lua sources for each code it named and passed if the string appeared
anywhere. That is a spell-checker, not a contract: the view told BI users to
match on `SEMANTIC_REQUEST_027` while the SQL lane emits `SEMANTIC_QUERY_027`,
and the grep passed because both spellings exist in the source. An integrator
matching the published code never matched.

So this runs the shapes instead. Each row of the view is paired with a statement
that provokes it, the statement is executed in the lane the row names, and the
code that comes back must be the code published. The pairing is keyed on the
view's own `SHAPE` text, which makes the two impossible to drift apart in either
direction: a row nobody demonstrates fails here, and a demonstration whose row
has gone fails too.

Both lanes are checked where a row names both, because that is the defect this
exists for: the same condition is `SEMANTIC_QUERY_027` through SQL and
`SEMANTIC_REQUEST_027` through the structured request, and a contract that
publishes one of them is wrong for half its readers.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, compile_request  # noqa: E402

MODEL, OBJECT = "sales", "SALES"
PUBLISHED = "SEMANTIC_SALES.SALES"
METRIC, DIMENSION = "total_cost", "order_status"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")
failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


# One entry per row of the view that names a refusal code. `sql` provokes it
# through the preprocessor; `request` through the structured lane. `setup`
# applies the policy a row is about and is undone afterwards.
#
# A row whose code is NULL publishes a capability rather than a refusal, and has
# nothing to provoke -- those are listed in SUPPORTED_SHAPES below so that a new
# row cannot be added without deciding which kind it is.
PROBES = {
    "HAVING on metrics": {
        "sql": f"SELECT CUSTOMER_REGION FROM {PUBLISHED} HAVING TOTAL_REVENUE > 0",
    },
    "GROUP BY": {
        "sql": f"SELECT CUSTOMER_REGION, PRODUCT_CATEGORY FROM {PUBLISHED}"
               " GROUP BY CUSTOMER_REGION",
    },
    "Joining an object to another relation": {
        # The aggregating form, which is what docs/bi-tools.md §4 prints beside
        # this row's code and what a BI tool emits. Without the SUM and GROUP BY
        # this demonstration passed while the documented statement returned
        # SEMANTIC_QUERY_003: the re-aggregation guard was asked before the
        # composition guard, so expansion answered with a code that only wins
        # when the other lane had no opinion, and the other lane's parse-shape
        # complaint outranked it.
        "sql": f"SELECT t0.CUSTOMER_REGION, SUM(t0.TOTAL_REVENUE) FROM {PUBLISHED} t0"
               " JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION GROUP BY 1",
    },
    "Grouping the object where the layer cannot read the statement": {
        # A CTE: the whole-statement path has no opinion on it, so the guard in
        # reference expansion is the one that answers. Where that path *can*
        # read the statement it says something sharper, which is why the bare
        # forms appear under GROUP BY and COUNT(*) instead.
        "sql": f"WITH x AS (SELECT CUSTOMER_REGION, COUNT(*) c FROM {PUBLISHED}"
               " GROUP BY CUSTOMER_REGION) SELECT * FROM x",
    },
    "Selecting a field the model withholds": {
        "setup": ("metric", {"IS_PRIVATE": "TRUE"}),
        "sql": f"SELECT CUSTOMER_REGION, {METRIC.upper()} FROM {PUBLISHED}",
        "request": {"model": MODEL, "object": OBJECT,
                    "dimensions": ["customer_region"], "metrics": [METRIC]},
    },
    "Selecting a masked field": {
        "setup": ("dimension", {"DISPLAY_POLICY": "'MASK'"}),
        "sql": f"SELECT {DIMENSION.upper()}, TOTAL_REVENUE FROM {PUBLISHED}",
        "request": {"model": MODEL, "object": OBJECT,
                    "dimensions": [DIMENSION], "metrics": ["total_revenue"]},
    },
    "Naming a field the object does not publish": {
        "sql": f"SELECT bogus_field FROM {PUBLISHED}",
        "request": {"model": MODEL, "object": OBJECT, "dimensions": ["bogus_field"]},
    },
    "Filtering on a dimension the statement does not select": {
        # The refusal half: a subquery the compile cannot run before
        # aggregation. verify_filter_grain.py holds the half that answers.
        "sql": f"SELECT TOTAL_REVENUE FROM {PUBLISHED} WHERE CUSTOMER_REGION IN"
               " (SELECT REGION FROM MART.CUSTOMERS)",
    },
    "An outer SUM or AVG over a metric that does not add up": {
        # BUG-26: the mean of per-region margins, weighted by region rather
        # than by row. MIN/MAX/COUNT and a fully grouped outer block are
        # accepted; verify_outer_reaggregation.py holds those.
        "sql": f"SELECT AVG(t.GROSS_MARGIN_PCT) FROM (SELECT CUSTOMER_REGION,"
               f" GROSS_MARGIN_PCT FROM {PUBLISHED}) t",
    },
    "An aggregate the metric does not declare": {
        # Written the way docs/bi-tools.md teaches -- "there is no GROUP BY to
        # write, it is inferred" -- and not with the explicit GROUP BY this
        # demonstration used to carry. The two forms took different lanes, and
        # only the one with the GROUP BY was refused; the documented form
        # returned a raw Exasol message, or a wrong number where Exasol had
        # nothing to object to. A contract verified against the shape the
        # implementation happens to handle is testing the implementation.
        "sql": f"SELECT CUSTOMER_REGION, MAX(TOTAL_REVENUE) FROM {PUBLISHED}",
    },
    "A SELECT list that names no field": {
        "sql": f"SELECT 1 FROM {PUBLISHED} t0",
    },
    "A wrapper naming no column of the object": {
        # Wrapped, because bare the whole-statement path answers first and says
        # something sharper about the SELECT list (`_005`). Here it has no
        # opinion, so the projection inference in reference expansion is what
        # has to refuse rather than guess at every column.
        "sql": f"SELECT COUNT(*) FROM (SELECT 1 FROM {PUBLISHED} t0) z",
    },
    "COUNT(*) over a semantic object": {
        "sql": f"SELECT COUNT(*) FROM {PUBLISHED}",
    },
    "Reading a relation the model does not vouch for": {
        # GOVERNED mode alone is not enough: every source of the demo model
        # classifies RAW, and RAW is something the model *does* vouch for -- a
        # base table carries whatever policy it carries. The refusal needs an
        # unvouched source, so one is marked DIVERGENT directly. Deriving that
        # classification from real schemas is verify_governed_mode_refuses.py's
        # job; this one only asks whether the published code is the code you get.
        "setup": ("governed", {}),
        "sql": f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {PUBLISHED}",
        "request": {"model": MODEL, "object": OBJECT,
                    "dimensions": ["customer_region"], "metrics": ["total_revenue"]},
    },
}

# Rows that publish a capability rather than a refusal. Listed so that adding a
# row to the view forces a decision here: demonstrate it, or say it is a
# capability. Nothing may be in neither.
SUPPORTED_SHAPES = {
    "SELECT over a published object",
    "WHERE on dimensions",
    "ORDER BY and LIMIT",
    "ORDER BY a field that is not selected",
    "Statements that wrap the object",
    "The shape of the statement around the object",
    "CREATE VIEW over an object",
    "Malformed or non-Exasol SQL around the object",
}


def main() -> int:
    admin = connect()
    admin.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    lane = connect()
    lane.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    published = admin.execute(
        "SELECT SHAPE, SUPPORT, SQL_REFUSAL_CODE, REQUEST_REFUSAL_CODE"
        " FROM SEMANTIC_CATALOG.QUERY_CAPABILITIES").fetchall()

    shapes = {row[0] for row in published}
    undemonstrated = sorted(shapes - set(PROBES) - SUPPORTED_SHAPES)
    if undemonstrated:
        fail("every published shape is demonstrated or declared a capability",
             ", ".join(undemonstrated))
    else:
        ok(f"all {len(shapes)} published shapes are accounted for")

    stale = sorted((set(PROBES) | SUPPORTED_SHAPES) - shapes)
    if stale:
        fail("every demonstration matches a published shape", ", ".join(stale))
    else:
        ok("no demonstration outlives its row")

    def revalidate() -> None:
        admin.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')").fetchall()

    def apply_setup(kind: str, columns: dict) -> None:
        if kind == "governed":
            admin.execute("EXECUTE SCRIPT SEMANTIC_ADMIN."
                          f"SET_MODEL_GOVERNANCE_MODE('{MODEL}', 'GOVERNED')")
            admin.commit()
            # Validation derives the trust classes, so the source is marked
            # unvouched-for *after* it, or the next run would overwrite it.
            revalidate()
            admin.execute("UPDATE SYS_SEMANTIC.SOURCE_TRUST"
                          " SET TRUST_CLASS = 'DIVERGENT'"
                          " WHERE PHYSICAL_OBJECT = 'ORDER_LINES'")
            # A successful compile of this exact shape is almost certainly in
            # the cache by the time this runs -- other verifiers ask for it --
            # and serving it would hide the refusal.
            admin.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
            admin.commit()
            return
        table = "METRICS" if kind == "metric" else "DIMENSIONS"
        column = "METRIC_NAME" if kind == "metric" else "DIMENSION_NAME"
        name = METRIC if kind == "metric" else DIMENSION
        assignments = ", ".join(f"{k} = {v}" for k, v in columns.items())
        admin.execute(f"UPDATE SYS_SEMANTIC.{table} SET {assignments}"
                      f" WHERE {column} = '{name}'")
        admin.commit()
        revalidate()

    def reset() -> None:
        # Re-validating below recomputes SOURCE_TRUST from the real schemas, so
        # the DIVERGENT marking above does not outlive this verifier.
        admin.execute("EXECUTE SCRIPT SEMANTIC_ADMIN."
                      f"SET_MODEL_GOVERNANCE_MODE('{MODEL}', 'OPEN')")
        admin.execute("UPDATE SYS_SEMANTIC.METRICS SET IS_PRIVATE = FALSE,"
                      f" DISPLAY_POLICY = NULL WHERE METRIC_NAME = '{METRIC}'")
        admin.execute("UPDATE SYS_SEMANTIC.DIMENSIONS SET IS_HIDDEN = FALSE,"
                      f" DISPLAY_POLICY = NULL WHERE DIMENSION_NAME = '{DIMENSION}'")
        admin.commit()
        revalidate()

    def sql_code(statement: str) -> str:
        try:
            lane.execute(statement).fetchall()
            return "OK"
        except Exception as exception:  # noqa: BLE001 -- the refusal is the result
            found = CODE.search(" ".join(str(exception).split()))
            return found.group(0) if found else "RAW"

    def request_code(request: dict) -> str:
        try:
            result = compile_request(admin, request)
            return result["error_code"] or result["status"]
        except Exception as exception:  # noqa: BLE001
            found = CODE.search(" ".join(str(exception).split()))
            return found.group(0) if found else "RAW"

    try:
        for shape, support, sql_expected, request_expected in published:
            probe = PROBES.get(shape)
            if probe is None:
                continue
            setup = probe.get("setup")
            if setup is not None:
                apply_setup(setup[0], setup[1])
            try:
                if sql_expected and "sql" in probe:
                    actual = sql_code(probe["sql"])
                    if actual == sql_expected:
                        ok(f"SQL lane: {shape}", actual)
                    else:
                        fail(f"SQL lane: {shape}",
                             f"published {sql_expected}, got {actual}")
                if request_expected and "request" in probe:
                    actual = request_code(probe["request"])
                    if actual == request_expected:
                        ok(f"request lane: {shape}", actual)
                    else:
                        fail(f"request lane: {shape}",
                             f"published {request_expected}, got {actual}")
                # A row that names a code for a lane it cannot demonstrate is
                # publishing an untested promise.
                if sql_expected and "sql" not in probe:
                    fail(f"SQL lane: {shape}", "names a code with no demonstration")
                if request_expected and "request" not in probe:
                    fail(f"request lane: {shape}",
                         "names a code with no demonstration")
            finally:
                if setup is not None:
                    reset()
    finally:
        reset()

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nevery published capability is demonstrated in the lane it names")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
