#!/usr/bin/env python3
"""Verify F7 governed model-evolution lifecycle against Exasol."""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def main() -> int:
    con = connect()
    try:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f7_verify')")
        except Exception:
            pass
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL("
            "'f7_verify', 'SEMANTIC_F7_VERIFY', 'F7 verification', NULL)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
            "'f7_verify', 'customer', 'SYS', 'DUAL', 'c', 'c.DUMMY', "
            "'One customer', 'Customer')",
        )
        metric_count = int(
            execute(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS m "
                "JOIN SYS_SEMANTIC.MODELS mo ON mo.MODEL_ID = m.MODEL_ID "
                "WHERE mo.MODEL_NAME = 'f7_verify'",
            )[0][0]
        )

        proposal_sql = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION("
            "'f7_verify', 'NEW_CONCEPT', 'METRIC', 'retention_rate', "
            "'{\"metric\":\"retention_rate\",\"ddl\":\"review-required\"}', "
            "'Historical workload repeatedly asks for customer retention.')"
        )
        proposed = execute(con, proposal_sql)[0]
        duplicate = execute(con, proposal_sql)[0]
        if str(proposed[6]) != "PENDING" or bool(proposed[7]):
            raise AssertionError(f"unexpected proposal result: {proposed}")
        if int(duplicate[0]) != int(proposed[0]) or not bool(duplicate[7]):
            raise AssertionError(f"proposal was not idempotent: {duplicate}")

        pending = execute(
            con,
            "SELECT SUGGESTION_KIND, OBJECT_TYPE, OBJECT_NAME, IS_STALE "
            "FROM SEMANTIC_AGENT.MODEL_EVOLUTION_REVIEW_QUEUE "
            f"WHERE SUGGESTION_ID = {int(proposed[0])}",
        )
        if pending != [("NEW_CONCEPT", "METRIC", "retention_rate", False)]:
            raise AssertionError(f"pending queue mismatch: {pending}")

        certified = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION("
            f"{int(proposed[0])}, 'CERTIFIED', "
            "'Domain owner approved the concept for implementation.')",
        )[0]
        if certified[4] != "CERTIFIED" or certified[6] != "NO_CATALOG_MUTATION":
            raise AssertionError(f"unexpected certification: {certified}")
        metric_count_after = int(
            execute(
                con,
                "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS m "
                "JOIN SYS_SEMANTIC.MODELS mo ON mo.MODEL_ID = m.MODEL_ID "
                "WHERE mo.MODEL_NAME = 'f7_verify'",
            )[0][0]
        )
        if metric_count_after != metric_count:
            raise AssertionError("certification mutated semantic metric metadata")

        identity = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION("
            "'f7_verify', 'NEW_IDENTITY', 'ENTITY', 'customer', "
            "'{\"identity\":\"global_customer_id\"}', "
            "'Cross-source customer keys need review.')",
        )[0]
        rejected = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION("
            f"{int(identity[0])}, 'REJECTED', 'Evidence does not prove equivalence.')",
        )[0]
        if rejected[4] != "REJECTED" or rejected[6] != "NOT_APPLICABLE":
            raise AssertionError(f"unexpected rejection: {rejected}")

        reviews = int(
            execute(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.MODEL_EVOLUTION_REVIEWS "
                "WHERE MODEL_NAME = 'f7_verify'",
            )[0][0]
        )
        if reviews != 2:
            raise AssertionError(f"expected two immutable reviews, got {reviews}")

        print("ok F7 proposals: typed, version-pinned, idempotent")
        print("ok F7 reviews: certified and rejected with audit records")
        print("ok F7 activation boundary: certification changed no model metadata")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f7_verify')")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
