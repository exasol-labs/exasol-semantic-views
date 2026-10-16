#!/usr/bin/env python3
"""Verify generated draft bindings are diagnosed and replaceable in place."""

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
        dsn=(
            f"{os.environ.get('EXASOL_HOST', 'localhost')}:"
            f"{os.environ.get('EXASOL_PORT', '8563')}"
        ),
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


def validation_errors(con: Any) -> list[tuple[Any, ...]]:
    rows = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('fb015_verify')")
    return [row for row in rows if str(row[0]) == "ERROR"]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb015_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS FB015_VERIFY CASCADE")
        con.execute("CREATE SCHEMA FB015_VERIFY")
        con.execute(
            "CREATE TABLE FB015_VERIFY.SUBSCRIBERS_PRIMARY ("
            "SUBSCRIBER_ID DECIMAL(18,0), PLAN VARCHAR(30), "
            "COUNTRY VARCHAR(2), PLAN_S VARCHAR(30))"
        )
        con.execute(
            "CREATE TABLE FB015_VERIFY.SUBSCRIBERS_MONGO ("
            "SUBSCRIBER_ID DECIMAL(18,0))"
        )
        con.execute(
            "INSERT INTO FB015_VERIFY.SUBSCRIBERS_PRIMARY VALUES "
            "(1, 'premium', 'DK', 'PREMIUM'), (2, 'basic', 'SE', 'BASIC')"
        )
        con.execute(
            "INSERT INTO FB015_VERIFY.SUBSCRIBERS_MONGO VALUES (1), (2)"
        )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('fb015_verify', "
            "'SEMANTIC_FB015_VERIFY', 'FB-015 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('fb015_verify', "
            "'subscriber', 'FB015_VERIFY', 'SUBSCRIBERS_PRIMARY', 's', "
            "'s.subscriber_id', 'One subscriber', 'Subscribers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('fb015_verify', "
            "'subscriber', 'subscriber_pk', 'PRIMARY', 'Subscriber key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('fb015_verify', "
            "'subscriber', 'subscriber_pk', 'SUBSCRIBER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('fb015_verify', "
            "'SUBSCRIBERS', 'subscriber', 'Subscribers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('fb015_verify', "
            "'SUBSCRIBERS', 'subscriber', 'plan', 's.plan', 'VARCHAR(30)', "
            "'Plan', 'Plan', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('fb015_verify', "
            "'SUBSCRIBERS', 'subscriber', 'country', 's.country', 'VARCHAR(2)', "
            "'Country', 'Country', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('fb015_verify', "
            "'SUBSCRIBERS', 'subscriber', 'plan_s', 's.plan_s', 'VARCHAR(30)', "
            "'Plan normalized', 'Normalized plan', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('fb015_verify', "
            "'subscriber', 'subscriber_identity', 'GLOBAL', 'DECIMAL(18,0)', "
            "'Subscriber identity')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('fb015_verify', "
            "'subscriber_identity', 'primary', 's.subscriber_id', 'DIRECT')",
        ]
        for statement in setup:
            execute(con, statement)
        if validation_errors(con):
            raise AssertionError("baseline draft model is invalid")

        representation = execute(
            con,
            "EXECUTE SCRIPT "
            "SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING("
            "'fb015_verify', 'subscriber', 'mongo', 'RELATION', "
            "'FB015_VERIFY', 'SUBSCRIBERS_MONGO', 20, 'MANUAL', "
            "'subscriber_identity', 's.subscriber_id', 'DIRECT', NULL)",
        )
        if len(representation) != 1 or len(representation[0]) != 10:
            raise AssertionError(f"unexpected compound result: {representation}")
        if int(representation[0][8]) != 3:
            raise AssertionError(f"expected three generated binding issues: {representation}")
        issue_text = str(representation[0][9])
        for attribute_name in ("plan", "country", "plan_s"):
            if f"{attribute_name}@mongo" not in issue_text:
                raise AssertionError(f"missing {attribute_name} diagnostic: {issue_text}")

        duplicate = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING("
            "'fb015_verify', 'DIMENSION', 'plan', 'mongo', "
            "'NULL', 'FALLBACK', 2)"
        )
        try:
            execute(con, duplicate)
        except Exception as exc:
            message = str(exc)
            if "SEMANTIC_ADMIN_024" not in message or "REPLACE_ATTRIBUTE_BINDING" not in message:
                raise AssertionError(f"duplicate error omitted replacement remedy: {exc}") from exc
        else:
            raise AssertionError("duplicate ADD_ATTRIBUTE_BINDING was accepted")

        before = dict(
            execute(
                con,
                "SELECT ATTRIBUTE_NAME, ATTRIBUTE_BINDING_ID "
                "FROM SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS "
                "WHERE MODEL_NAME = 'fb015_verify' AND REPRESENTATION_NAME = 'mongo'",
            )
        )
        for attribute_name in ("plan", "country", "plan_s"):
            rows = execute(
                con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING("
                f"'fb015_verify', 'DIMENSION', '{attribute_name}', 'mongo', "
                "'NULL', 'FALLBACK', 2)",
            )
            if len(rows) != 1 or int(rows[0][0]) != int(before[attribute_name]):
                raise AssertionError(f"replacement changed binding identity: {rows}")
        if validation_errors(con):
            raise AssertionError("replacement did not repair the draft model")

        invalid = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING("
            "'fb015_verify', 'DIMENSION', 'plan', 'mongo', "
            "'s.missing_plan', 'FALLBACK', 2)"
        )
        try:
            execute(con, invalid)
        except Exception as exc:
            if "SEMANTIC_ADMIN_093" not in str(exc):
                raise AssertionError(f"unexpected replacement rejection: {exc}") from exc
        else:
            raise AssertionError("invalid replacement was accepted")
        restored = execute(
            con,
            "SELECT SOURCE_EXPRESSION FROM SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS "
            "WHERE MODEL_NAME = 'fb015_verify' AND ATTRIBUTE_NAME = 'plan' "
            "AND REPRESENTATION_NAME = 'mongo'",
        )
        if restored != [("NULL",)] or validation_errors(con):
            raise AssertionError(f"invalid replacement was not restored: {restored}")

        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('fb015_verify')")
        print("ok FB-015 diagnostics: draft registration returned three binding issues")
        print("ok FB-015 remedy: duplicate ADD names REPLACE_ATTRIBUTE_BINDING")
        print("ok FB-015 replacement: three bindings repaired in place")
        print("ok FB-015 rollback: invalid replacement restored the valid binding")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb015_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS FB015_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
