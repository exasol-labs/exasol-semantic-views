#!/usr/bin/env python3
"""Live-DB negative-path coverage for SEMANTIC_ADMIN_* error codes.

Static audit found 46 admin error codes emitted from
sql/install/003_create_semantic_admin_scripts.sql that were not asserted
anywhere in the test suite. Every code that trips at the front door of an
admin script (parameter validation, duplicate detection, missing-object
lookup) is worth pinning down here — the alternative is that a refactor
silently swallows an error path with no test to catch it.

This script covers a curated ~15-code subset that fires cheaply against the
sales seed. Grow it as new codes are added; do not remove cases to make a
change pass.

Requires the sales model installed (tools/install.py --example).
"""

from __future__ import annotations

import os
import re
import ssl
import sys
from typing import Callable


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


PASSED = 0
FAILED = 0


def assert_fails_with(con, name: str, sql: str, expected_code: str) -> None:
    """Run `sql` and assert it fails with an error message containing
    `expected_code`. Any other failure — or a successful run — is a bug."""
    global PASSED, FAILED
    try:
        con.execute(sql)
    except Exception as exc:  # pyexasol raises pyexasol.ExaQueryError; str() gives the full message
        message = str(exc)
        if expected_code in message:
            PASSED += 1
            print(f"ok  {name}: {expected_code}")
            return
        FAILED += 1
        # Preserve the actual error so the diagnostic is actionable.
        m = re.search(r"SEMANTIC_[A-Z]+_[0-9]{3}", message)
        actual = m.group(0) if m else "(no SEMANTIC code)"
        print(f"FAIL {name}: expected {expected_code}, got {actual}", file=sys.stderr)
        return
    FAILED += 1
    print(f"FAIL {name}: expected {expected_code}, but statement succeeded", file=sys.stderr)


def q(value: str) -> str:
    """Quote a string as a SQL literal."""
    return "'" + value.replace("'", "''") + "'"


CASES: list[tuple[str, str, str]] = [
    # SEMANTIC_ADMIN_001: required field missing
    (
        "admin_001/model_name_required",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(NULL, 'SEM_X', 'x', NULL)",
        "SEMANTIC_ADMIN_001",
    ),
    # PUBLISH_MODEL(NULL) fires SEMANTIC_SURFACE_002 rather than
    # SEMANTIC_ADMIN_001 — the surface layer catches missing MODEL_NAME
    # before the admin body runs. Assert the actual code:
    (
        "surface_002/publish_null_model_name",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(NULL)",
        "SEMANTIC_SURFACE_002",
    ),

    # SEMANTIC_ADMIN_002: invalid identifier syntax
    (
        "admin_002/invalid_model_name",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('123 bad name!', 'SEM_X', 'x', NULL)",
        "SEMANTIC_ADMIN_002",
    ),

    # SEMANTIC_ADMIN_003: invalid enum
    (
        "admin_003/invalid_source_kind",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        "'sales', 'zz_probe', 'MART', 'CUSTOMERS', 'c', 'c.customer_id', "
        "'probe', 'probe')",
        # Above is actually valid; force _003 via an invalid representation kind:
        "SEMANTIC_ADMIN_003",
    ),

    # SEMANTIC_ADMIN_003: FANOUT_POLICY is a closed set, not free text. An
    # unrecognized value used to be stored verbatim, which read as a safety
    # override that never existed. See docs/validation-rules.md#fanout-policy.
    (
        "admin_003/invalid_fanout_policy",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
        "'sales', 'zz_probe_m2m', 'order', 'product', "
        "'o.order_id = p.product_id', 'MANY_TO_MANY', 'LEFT', 'banana')",
        "SEMANTIC_ADMIN_003",
    ),

    # SEMANTIC_ADMIN_010: duplicate model
    (
        "admin_010/duplicate_model",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('sales', 'SEMANTIC_SALES', 'dup', NULL)",
        "SEMANTIC_ADMIN_010",
    ),

    # SEMANTIC_ADMIN_011: model not found (fires from admin bodies; PUBLISH_MODEL
    # takes the surface path and returns SEMANTIC_SURFACE_010 instead — asserted
    # below.)
    (
        "admin_011/model_not_found_add_metric",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
        "'zz_no_such_model', 'SALES', 'zz_probe', 'SUM(x)', NULL, 'ADDITIVE', "
        "'order_line', 'DECIMAL(18,2)', 'probe', 'probe', NULL, FALSE, FALSE)",
        "SEMANTIC_ADMIN_011",
    ),
    (
        "surface_010/publish_missing_model",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('zz_no_such_model')",
        "SEMANTIC_SURFACE_010",
    ),

    # SEMANTIC_ADMIN_014: entity or active primary representation not found
    (
        "admin_014/entity_not_found",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        "'sales', 'SALES', 'zz_no_entity', 'zz_probe_dim', 'e.col', "
        "'VARCHAR(10)', 'probe', 'probe', NULL, FALSE)",
        "SEMANTIC_ADMIN_014",
    ),

    # SEMANTIC_ADMIN_015: duplicate semantic object
    (
        "admin_015/duplicate_semantic_object",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
        "'sales', 'SALES', 'order_line', 'duplicate probe')",
        "SEMANTIC_ADMIN_015",
    ),

    # SEMANTIC_ADMIN_017: semantic object not found
    (
        "admin_017/object_not_found",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        "'sales', 'ZZ_NO_OBJECT', 'order_line', 'zz_probe_dim', 'ol.line_id', "
        "'DECIMAL(18,0)', 'probe', 'probe', NULL, FALSE)",
        "SEMANTIC_ADMIN_017",
    ),

    # SEMANTIC_ADMIN_019: duplicate dimension name
    (
        "admin_019/duplicate_dimension",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        "'sales', 'SALES', 'customer', 'customer_region', 'c.region', "
        "'VARCHAR(100)', 'probe', 'probe', NULL, FALSE)",
        "SEMANTIC_ADMIN_019",
    ),

    # SEMANTIC_ADMIN_020: duplicate fact name
    (
        "admin_020/duplicate_fact",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        "'sales', 'order_line', 'net_revenue', 'ol.quantity', "
        "'DECIMAL(18,2)', 'ADDITIVE', 'probe', 'probe', FALSE, FALSE)",
        "SEMANTIC_ADMIN_020",
    ),

    # SEMANTIC_ADMIN_045: active representation not found
    (
        "admin_045/representation_not_found",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
        "'sales', 'customer', 'zz_no_such_rep')",
        "SEMANTIC_ADMIN_045",
    ),
]


def find_case(name: str) -> Callable[..., None]:
    for case_name, sql, code in CASES:
        if case_name == name:
            return lambda con, s=sql, c=code, n=case_name: assert_fails_with(con, n, s, c)
    raise KeyError(name)


def main() -> int:
    con = connect()
    try:
        # SEMANTIC_ADMIN_003 needs a hand-tailored SQL because
        # ADD_ENTITY doesn't take a SOURCE_KIND argument. Substitute a call
        # that does — ADD_ENTITY_REPRESENTATION — with an invalid kind.
        rewritten: list[tuple[str, str, str]] = []
        for name, sql, code in CASES:
            if name == "admin_003/invalid_source_kind":
                sql = (
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
                    "'sales', 'customer', 'zz_bad_rep', 'ZZ_UNKNOWN_KIND', "
                    "'MART', 'CUSTOMERS', 20, 'MANUAL')"
                )
            rewritten.append((name, sql, code))
        for name, sql, code in rewritten:
            assert_fails_with(con, name, sql, code)

        print()
        outcome = "PASSED" if FAILED == 0 else "FAILED"
        print(f"{outcome}: {PASSED} passed, {FAILED} failed")
        return 0 if FAILED == 0 else 1
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
