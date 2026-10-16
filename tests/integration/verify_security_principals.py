#!/usr/bin/env python3
"""Verify model grants and source isolation with a non-SYS principal."""

from __future__ import annotations

import os
import ssl
from typing import Any

import pyexasol


TEST_USER = "ESV_COVERAGE_USER"
TEST_ROLE = "ESV_COVERAGE_ROLE"
TEST_PASSWORD = "EsvCoverage_2026"


def connect(user: str | None = None, password: str | None = None) -> Any:
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=user or os.environ.get("EXASOL_USER", "sys"),
        password=password or os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def expect_denied(connection: Any, sql: str, label: str) -> None:
    try:
        connection.execute(sql).fetchall()
    except Exception:  # pyexasol exposes server authorization errors by version
        print(f"ok {label}: denied")
        return
    raise AssertionError(f"{label}: query unexpectedly succeeded")


def drop_principals(admin: Any) -> None:
    admin.execute(
        "UPDATE SYS_SEMANTIC.MODEL_ROLE_GRANTS SET STATUS = 'REVOKED' "
        f"WHERE ROLE_NAME = '{TEST_ROLE}' AND STATUS = 'ACTIVE'"
    )
    users = admin.execute(
        f"SELECT COUNT(*) FROM SYS.EXA_ALL_USERS WHERE USER_NAME = '{TEST_USER}'"
    ).fetchall()[0][0]
    if int(users):
        admin.execute(f'DROP USER "{TEST_USER}" CASCADE')
    roles = admin.execute(
        f"SELECT COUNT(*) FROM SYS.EXA_ALL_ROLES WHERE ROLE_NAME = '{TEST_ROLE}'"
    ).fetchall()[0][0]
    if int(roles):
        admin.execute(f'DROP ROLE "{TEST_ROLE}"')


def main() -> int:
    admin = connect()
    try:
        drop_principals(admin)
        admin.execute(f'CREATE ROLE "{TEST_ROLE}"')
        admin.execute(f'CREATE USER "{TEST_USER}" IDENTIFIED BY "{TEST_PASSWORD}"')
        admin.execute(f'GRANT CREATE SESSION TO "{TEST_USER}"')
        admin.execute(f'GRANT "{TEST_ROLE}" TO "{TEST_USER}"')

        granted = admin.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', '{TEST_ROLE}')"
        ).fetchall()
        if granted[0][3] not in {"GRANTED", "ALREADY_GRANTED"}:
            raise AssertionError(f"unexpected grant status: {granted}")
        print(f"ok model role grant: {granted[0][3]}")
        duplicate = admin.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', '{TEST_ROLE}')"
        ).fetchall()
        if duplicate[0][3] != "ALREADY_GRANTED":
            raise AssertionError(f"grant is not idempotent: {duplicate}")
        print("ok model role idempotency: ALREADY_GRANTED")

        reader = connect(TEST_USER, TEST_PASSWORD)
        try:
            discovery_count = int(reader.execute(
                "SELECT COUNT(*) FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY"
            ).fetchall()[0][0])
            if discovery_count < 1:
                raise AssertionError("published discovery unexpectedly empty")
            print(f"ok delegated published discovery: {discovery_count} rows")
            expect_denied(reader, "SELECT COUNT(*) FROM MART.ORDERS",
                          "delegated raw-table bypass")
        finally:
            reader.close()

        revoked = admin.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.REVOKE_MODEL_ROLE('sales', '{TEST_ROLE}')"
        ).fetchall()
        if revoked[0][3] != "REVOKED":
            raise AssertionError(f"unexpected revoke status: {revoked}")
        print("ok model role revoke: REVOKED")

        reader = connect(TEST_USER, TEST_PASSWORD)
        try:
            expect_denied(reader,
                          "SELECT COUNT(*) FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY",
                          "revoked published access")
        finally:
            reader.close()

        audit = admin.execute(
            "SELECT STATUS FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS "
            f"WHERE ROLE_NAME = '{TEST_ROLE}' ORDER BY GRANT_ID DESC LIMIT 1"
        ).fetchall()
        if not audit or audit[0][0] != "REVOKED":
            raise AssertionError(f"grant audit row not revoked: {audit}")
        print("ok model role audit: REVOKED")
        return 0
    finally:
        try:
            drop_principals(admin)
        finally:
            admin.close()


if __name__ == "__main__":
    raise SystemExit(main())
