#!/usr/bin/env python3
"""Verify the Phase B typed planner and strict proof boundary on Exasol."""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any


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


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_request(con, request: dict[str, Any]) -> tuple[Any, ...]:
    payload = json.dumps(request, separators=(",", ":"))
    rows = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    ).fetchall()
    if not rows:
        raise AssertionError("compiler returned no rows")
    return rows[0]


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
    print(f"ok {label}: {actual!r}")


def assert_true(label: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(label)
    print(f"ok {label}")


def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
        request = {
            "model": "sales",
            "object": "SALES",
            "metrics": ["total_revenue"],
            "dimensions": ["customer_region"],
        }
        legacy = compile_request(con, request)
        assert_equal("legacy compile", legacy[0], "OK")
        plan = json.loads(legacy[5])
        assert_equal("logical plan version", plan["plan_version"], 3)
        assert_equal("logical plan kind", plan["logical_plan"]["plan_kind"], "SINGLE_BRANCH")
        assert_equal("legacy proof mode", plan["logical_plan"]["proof_mode"], "LEGACY_JOIN")
        assert_true("typed metric stages", bool(plan["logical_plan"]["metric_stages"]))

        strict_request = dict(request)
        strict_request["proof_mode"] = "STRICT_GRAIN"
        strict = compile_request(con, strict_request)
        assert_equal("strict compile", strict[0], "OK")
        strict_plan = json.loads(strict[5])["logical_plan"]
        proofs = strict_plan["relationship_proofs"]
        assert_true("strict proofs emitted", bool(proofs))
        assert_true(
            "strict proofs are complete",
            all(proof["status"] == "PROVEN" for proof in proofs),
        )
        assert_true(
            "strict proof records key ids",
            all(
                edge.get("unique_key_id") is not None
                for proof in proofs
                for edge in proof["edges"]
            ),
        )

        suggestions = con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SUGGEST_GRAIN_METADATA('sales')"
        ).fetchall()
        assert_true("migration assistant returns a dry-run result", bool(suggestions))

        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            "'sales', 'order_line_to_order', 'order_id', NULL, "
            "'order_id', NULL, 1)"
        )
        stale = compile_request(con, request)
        assert_equal("metadata mutation makes validation stale", stale[1], "SEMANTIC_REQUEST_010")

        cache_rows = con.execute(
            "SELECT COUNT(*) FROM SYS_SEMANTIC.COMPILE_CACHE c "
            "JOIN SYS_SEMANTIC.MODELS m ON m.ACTIVE_VERSION_ID = c.MODEL_VERSION_ID "
            "WHERE UPPER(m.MODEL_NAME) = 'SALES'"
        ).fetchall()
        assert_equal("metadata mutation clears compile cache", int(cache_rows[0][0]), 0)

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')").fetchall()
        restored = compile_request(con, request)
        assert_equal("compile after revalidation", restored[0], "OK")
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
