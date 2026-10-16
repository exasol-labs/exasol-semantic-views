#!/usr/bin/env python3
"""Verify SEMANTIC_ADMIN.SET_RELATIONSHIP.

Relationships used to be add-only: re-adding was refused as a duplicate
(`SEMANTIC_ADMIN_016`) and removing was refused while key mappings existed
(`SEMANTIC_ADMIN_066`), so correcting a cardinality or a fanout policy meant a
four-step sequence -- remove the mappings in descending ordinal order, remove
the relationship, add it back, re-add the mappings. That is exactly the
operation the fan-out reason codes push modelers toward.

Asserts, against the shipped sales model:

  1. each editable field updates in place, and omitted arguments keep their
     stored value;
  2. key mappings survive the update, which is the whole point of not going
     through remove/re-add;
  3. `FANOUT_POLICY = 'NONE'` clears the column, and unrecognized values are
     refused with the same code `ADD_RELATIONSHIP` uses;
  4. endpoints stay immutable (they are not parameters at all);
  5. on a PUBLISHED model, a change that would break validation is rejected and
     the previous values are restored (`SEMANTIC_ADMIN_098`).

Run after `python3 tools/install.py --example`. Leaves the model as it found
it.
"""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any

MODEL = "sales"
RELATIONSHIP = "order_to_customer"


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


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def expect_error(con: Any, sql: str, *fragments: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        message = str(exc)
        for fragment in fragments:
            if fragment not in message:
                raise AssertionError(f"expected {fragment!r} in error, got: {message}") from exc
        return message
    raise AssertionError(f"expected a refusal from: {sql}")


def stored(con: Any, name: str = RELATIONSHIP) -> tuple[Any, ...]:
    return execute(
        con,
        "SELECT RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY, JOIN_CONDITION, "
        "FROM_ENTITY_NAME, TO_ENTITY_NAME FROM SEMANTIC_CATALOG.RELATIONSHIPS "
        f"WHERE MODEL_NAME = '{MODEL}' AND RELATIONSHIP_NAME = '{name}'",
    )[0]


def mapping_count(con: Any, name: str = RELATIONSHIP) -> int:
    return int(
        execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.RELATIONSHIP_KEY_MAPPINGS "
            f"WHERE MODEL_NAME = '{MODEL}' AND RELATIONSHIP_NAME = '{name}'",
        )[0][0]
    )


def set_relationship(con: Any, *, join_condition: str | None = None,
                     cardinality: str | None = None, join_type: str | None = None,
                     fanout_policy: str | None = None,
                     name: str = RELATIONSHIP) -> tuple[Any, ...]:
    def arg(value: str | None) -> str:
        return "NULL" if value is None else "'" + value.replace("'", "''") + "'"

    return execute(
        con,
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', '{name}', "
        f"{arg(join_condition)}, {arg(cardinality)}, {arg(join_type)}, {arg(fanout_policy)})",
    )[0]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=120")
        before = stored(con)
        mappings_before = mapping_count(con)
        assert_equal("baseline cardinality", before[0], "MANY_TO_ONE")
        assert_equal("baseline mappings", mappings_before, 1)

        # 1. Omitted arguments keep their stored value.
        row = set_relationship(con, join_type="INNER")
        assert_equal("join type updated", row[5], "INNER")
        assert_equal("cardinality untouched", row[4], before[0])
        assert_equal("join condition untouched", row[3], before[3])
        assert_equal("catalog reflects the update", stored(con)[1], "INNER")

        # 2. Key mappings survive: the reason to have this verb at all.
        assert_equal("mappings survive the update", mapping_count(con), mappings_before)

        # 3. A policy can be set and cleared.
        row = set_relationship(con, fanout_policy="reference_only")
        assert_equal("policy normalized to upper case", row[6], "REFERENCE_ONLY")
        row = set_relationship(con, fanout_policy="NONE")
        assert_equal("policy cleared", row[6], None)
        expect_error(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', '{RELATIONSHIP}', "
            "NULL, NULL, NULL, 'banana')",
            "SEMANTIC_ADMIN_003",
            "FANOUT_POLICY",
        )
        expect_error(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', '{RELATIONSHIP}', "
            "NULL, 'SIDEWAYS', NULL, NULL)",
            "SEMANTIC_ADMIN_003",
            "CARDINALITY",
        )
        expect_error(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', '{RELATIONSHIP}', "
            "NULL, NULL, NULL, NULL)",
            "SEMANTIC_ADMIN_001",
            "at least one of",
        )
        expect_error(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', 'no_such_relationship', "
            "NULL, NULL, 'LEFT', NULL)",
            "SEMANTIC_ADMIN_016",
        )

        # 4. Endpoints are immutable, so they cannot drift from the mappings.
        restored = set_relationship(con, join_type="LEFT")
        assert_equal("endpoints unchanged", stored(con)[4:], before[4:])
        assert_equal("join type restored", restored[5], "LEFT")

        # 5. On a PUBLISHED model a breaking change is rejected and restored.
        # MANY_TO_MANY on the line->order edge severs every order-grain
        # dimension from the line-grain metrics.
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
        message = expect_error(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_RELATIONSHIP('{MODEL}', 'order_line_to_order', "
            "NULL, 'MANY_TO_MANY', NULL, 'ALLOCATE')",
            "SEMANTIC_ADMIN_098",
        )
        refusal = next(
            (line.split("=>", 1)[1].strip() for line in message.splitlines()
             if line.strip().startswith("message")),
            message.strip(),
        )
        print(f"   {refusal}")
        assert_equal(
            "rejected change restored",
            stored(con, "order_line_to_order")[:3],
            ("MANY_TO_ONE", "LEFT", None),
        )
        assert_equal(
            "model validates again after restore",
            execute(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
                f"WHERE MODEL_NAME = '{MODEL}' AND SEVERITY IN ('ERROR', 'PRECONDITION')",
            )[0][0],
            0,
        )

        assert_equal("relationship left as found", stored(con), before)
        print()
        print("SET_RELATIONSHIP verified.")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
