#!/usr/bin/env python3
"""A semantic view can be taken out of a model without destroying the model.

`ADD_SEMANTIC_OBJECT` had no counterpart. The DDL edits the *interior* of an
object — its dimensions, facts and metrics — and cannot remove the object; no
apply path reconciles a model by deleting one; and `DROP_MODEL` takes the
entities, relationships, published views, grants and frozen-view records with it.

That was not a tidiness problem. `PUBLISH_MODEL` refuses an object with no
visible columns (`SEMANTIC_SURFACE_014`), so a single mistyped
`ADD_SEMANTIC_OBJECT` left a model that **could not be published and could not be
repaired**. Filling the object in instead is not a way out: its dimensions would
need new names, because names are unique per model (`SEMANTIC_ADMIN_019`), so the
typo would become permanent in a different form.

The first check below is that obstacle, reproduced. The rest is the removal doing
only what it should: taking the view and the columns it exposes, keeping the
facts and entities — a fact belongs to an *entity* and may feed other views —
dropping the published view, and refusing when another view's metric is built on
one of the metrics it would take.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, named_row  # noqa: E402

MODEL = "removeobj_verify"
SCHEMA = "SEMANTIC_REMOVEOBJ_VERIFY"
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


def main() -> int:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    def script(call: str):
        statement = con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{call}")
        try:
            rows = statement.fetchall()
        except Exception:  # noqa: BLE001 -- several admin scripts return no rows
            rows = []
        con.commit()
        return rows

    def refusal(call: str) -> str:
        try:
            script(call)
            return "ACCEPTED"
        except Exception as exception:  # noqa: BLE001 -- the refusal is the result
            con.rollback()
            found = CODE.search(" ".join(str(exception).split()))
            return found.group(0) if found else "RAW"

    def names(sql: str) -> list:
        return [row[0] for row in con.execute(sql).fetchall()]

    def drop_model() -> None:
        try:
            script(f"DROP_MODEL('{MODEL}')")
        except Exception:  # noqa: BLE001 -- absent on the first run
            con.rollback()

    drop_model()
    try:
        script(f"CREATE_MODEL('{MODEL}', '{SCHEMA}', 'removal probe', NULL)")
        script(f"ADD_ENTITY('{MODEL}', 'order', 'MART', 'ORDERS', 'o',"
               " 'o.order_id', 'One order', 'Orders')")
        script(f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL}', 'order', 'pk', 'PRIMARY',"
               " 'k', 'NATIVE',"
               ' \'[{"ordinal_position":1,"column_name":"order_id"}]\')')
        script(f"ADD_FACT('{MODEL}', 'order', 'freight', 'o.freight_amount',"
               " 'DECIMAL(18,2)', 'ADDITIVE', 'Freight', 'f', FALSE, TRUE)")
        script(f"ADD_SEMANTIC_OBJECT('{MODEL}', 'GOOD', 'order', 'the real one')")
        script(f"ADD_DIMENSION('{MODEL}', 'GOOD', 'order', 'ship_mode',"
               " 'o.ship_mode', 'VARCHAR(20)', 'Ship', 'd', NULL, TRUE)")
        script(f"ADD_METRIC('{MODEL}', 'GOOD', 'total_freight', 'SUM(freight)',"
               " NULL, 'ADDITIVE', 'order', 'DECIMAL(18,2)', 'Freight', 'm',"
               " NULL, FALSE, TRUE)")

        # 1. the obstacle: one mistyped call and the model will not publish
        script(f"ADD_SEMANTIC_OBJECT('{MODEL}', 'ORDER_VEIW', 'order', 'typo')")
        check("a stray object blocks publishing the whole model",
              refusal(f"PUBLISH_MODEL('{MODEL}')"), "SEMANTIC_SURFACE_014")

        # 2. and it can now be taken out again
        removed = named_row(con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_OBJECT("
            f"'{MODEL}', 'ORDER_VEIW')"))
        con.commit()
        check("the stray object is removed", removed["object_name"], "ORDER_VEIW")
        script(f"PUBLISH_MODEL('{MODEL}')")
        ok("and the model publishes again")
        check("the good view is published",
              names(f"SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS"
                    f" WHERE VIEW_SCHEMA = '{SCHEMA}'"), ["GOOD"])

        # 3. removing a populated view takes its columns and its published view,
        #    and keeps what belongs to the entity
        populated = named_row(con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_OBJECT("
            f"'{MODEL}', 'GOOD')"))
        con.commit()
        check("its dimensions go with it", populated["dimensions_removed"], 1)
        check("and its metrics", populated["metrics_removed"], 1)
        check("and the published view is dropped", populated["view_dropped"], True)
        check("no view is left answering from compiled SQL",
              names(f"SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS"
                    f" WHERE VIEW_SCHEMA = '{SCHEMA}'"), [])
        check("the fact is kept -- it belongs to the entity, not the view",
              names("SELECT f.FACT_NAME FROM SYS_SEMANTIC.FACTS f"
                    " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = f.MODEL_ID"
                    f" WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')"), ["freight"])
        check("and the entity with it",
              names("SELECT e.ENTITY_NAME FROM SYS_SEMANTIC.ENTITIES e"
                    " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID"
                    f" WHERE UPPER(m.MODEL_NAME) = UPPER('{MODEL}')"), ["order"])

        # 4. the names are free again -- otherwise removal would only half-work,
        #    since a dimension name is unique per model
        script(f"ADD_SEMANTIC_OBJECT('{MODEL}', 'GOOD', 'order', 'rebuilt')")
        script(f"ADD_DIMENSION('{MODEL}', 'GOOD', 'order', 'ship_mode',"
               " 'o.ship_mode', 'VARCHAR(20)', 'Ship', 'd', NULL, TRUE)")
        script(f"ADD_METRIC('{MODEL}', 'GOOD', 'total_freight', 'SUM(freight)',"
               " NULL, 'ADDITIVE', 'order', 'DECIMAL(18,2)', 'Freight', 'm',"
               " NULL, FALSE, TRUE)")
        ok("the object and its field names can be used again")

        # 5. a view whose metric another view is built on is refused, not
        #    cascaded: the dependent would be left naming a metric that is gone
        script(f"ADD_SEMANTIC_OBJECT('{MODEL}', 'SECOND', 'order', 'second view')")
        script(f"ADD_DIMENSION('{MODEL}', 'SECOND', 'order', 'status_2',"
               " 'o.order_status', 'VARCHAR(32)', 'Status', 'd', NULL, TRUE)")
        script(f"ADD_METRIC('{MODEL}', 'SECOND', 'freight_x2', 'total_freight * 2',"
               " NULL, 'DERIVED', 'order', 'DECIMAL(18,2)', 'X2', 'm', NULL,"
               " FALSE, TRUE)")
        # The dependency is derived by validation, so it has to have run.
        script(f"VALIDATE_MODEL('{MODEL}')")
        check("a view another view's metric depends on is refused",
              refusal(f"REMOVE_SEMANTIC_OBJECT('{MODEL}', 'GOOD')"),
              "SEMANTIC_ADMIN_099")
        check("but the dependent view itself removes",
              refusal(f"REMOVE_SEMANTIC_OBJECT('{MODEL}', 'SECOND')"), "ACCEPTED")
        check("and then so does the one it depended on",
              refusal(f"REMOVE_SEMANTIC_OBJECT('{MODEL}', 'GOOD')"), "ACCEPTED")

        # 6. the ordinary refusals
        check("an unknown object is refused",
              refusal(f"REMOVE_SEMANTIC_OBJECT('{MODEL}', 'NO_SUCH')"),
              "SEMANTIC_ADMIN_017")
        check("an unknown model is refused",
              refusal("REMOVE_SEMANTIC_OBJECT('no_such_model', 'GOOD')"),
              "SEMANTIC_ADMIN_011")
    finally:
        drop_model()
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
            con.commit()
        except Exception:  # noqa: BLE001 -- best effort
            con.rollback()

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\na semantic view can be removed, and only it is removed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
