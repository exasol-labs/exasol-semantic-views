#!/usr/bin/env python3
"""Verify that a metric the planner could never compile is refused when defined.

Two shapes used to validate clean, publish, and be reported `VALID` by every
agent surface, then fail only when someone finally queried them — and because
`SELECT *` expands to every column of the object, one such metric took the whole
object down with it:

  * `COUNT(*)` has no fact input, so the planner cannot determine its input
    grain (`METRIC_INPUT_GRAIN_MISSING`) — BUG-F01;
  * `AVG` on an F3-partitioned entity has no mergeable aggregate state, and
    partitions merge states — BUG-F02.

`VALIDATE_MODEL` now classifies every metric with the planner's own code
(`ESV_METRIC_PLAN.build_dag`), so the gate cannot drift from what the compiler
decides. This asserts:

  1. `COUNT(*)` is refused (`SEMANTIC_MODEL_056`) with both supported row-count
     forms named, and nothing is persisted;
  2. both supported forms are accepted and return the same count;
  3. `AVG` on a partitioned entity is refused (`SEMANTIC_MODEL_057`);
  4. `AVG` on an unpartitioned entity is still accepted and still compiles —
     the gate does not forbid what the single-branch renderer can do;
  5. the reverse order is caught too: partitioning an entity that already
     carries a non-mergeable metric is refused by the mutation that would
     complete it;
  6. a `RATIO` of two mergeable metrics is exact on the partitioned entity.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

MODEL = "plannability_verify"
SCHEMA = "PLANNABILITY_VERIFY"
CUTOVER = "2026-07-01 00:00:00"


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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def apply_definition(con: Any, definition_sql: str) -> dict[str, Any]:
    row = execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{literal(definition_sql)}, FALSE)",
    )[0]
    return {"status": row[0], "error_code": row[1], "message": row[2]}


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    row = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})"
    )[0]
    return {"status": row[0], "error_code": row[1], "error_message": row[2],
            "generated_sql": row[4]}


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, haystack: str, needle: str) -> None:
    if needle not in (haystack or ""):
        raise AssertionError(f"{name}: {needle!r} not found in {haystack!r}")
    print(f"ok {name}: found {needle!r}")


def scalar(con: Any, sql: str) -> Any:
    rows = execute(con, sql)
    return rows[0][0] if rows else None


def metric_count(con: Any, name: str) -> int:
    return int(
        scalar(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS "
            f"WHERE MODEL_NAME = {literal(MODEL)} AND METRIC_NAME = {literal(name)}",
        )
        or 0
    )


def build_fixture(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    # Hot and cold order partitions, disjoint by construction, plus lines.
    for suffix, rows in (
        ("HOT", "(3, 30.00, TIMESTAMP '2026-07-05 00:00:00'), "
                "(4, 40.00, TIMESTAMP '2026-08-01 00:00:00')"),
        ("COLD", "(1, 10.00, TIMESTAMP '2026-01-05 00:00:00'), "
                 "(2, 20.00, TIMESTAMP '2026-02-01 00:00:00')"),
    ):
        con.execute(
            f"CREATE TABLE {SCHEMA}.ORDERS_{suffix} (ORDER_ID DECIMAL(18,0), "
            "FREIGHT_AMOUNT DECIMAL(18,2), ORDER_TS TIMESTAMP)"
        )
        con.execute(f"INSERT INTO {SCHEMA}.ORDERS_{suffix} VALUES {rows}")
    con.execute(
        f"CREATE TABLE {SCHEMA}.ORDER_LINES (LINE_ID DECIMAL(18,0), "
        "ORDER_ID DECIMAL(18,0), AMOUNT DECIMAL(18,2), LINE_TS TIMESTAMP)"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.ORDER_LINES VALUES "
        "(1, 1, 5.00, TIMESTAMP '2026-07-05 00:00:00'), "
        "(2, 1, 6.00, TIMESTAMP '2026-07-06 00:00:00'), "
        "(3, 2, 7.00, TIMESTAMP '2026-08-02 00:00:00')"
    )

    for statement in (
        f"CREATE_MODEL('{MODEL}', 'SEMANTIC_{SCHEMA}', 'Plannability gate', NULL)",
        f"ADD_ENTITY('{MODEL}', 'line', '{SCHEMA}', 'ORDER_LINES', 'l', "
        "'l.line_id', 'One order line', 'Lines')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL}', 'line', 'line_pk', 'PRIMARY', "
        "'Line identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"line_id"}]\')',
        f"ADD_SEMANTIC_OBJECT('{MODEL}', 'LINES', 'line', 'Line-grain object')",
        f"ADD_DIMENSION('{MODEL}', 'LINES', 'line', 'order_ref', "
        "'l.order_id', 'DECIMAL(18,0)', 'Order', 'Owning order', NULL, TRUE)",
        f"ADD_FACT('{MODEL}', 'line', 'amount', 'l.amount', 'DECIMAL(18,2)', "
        "'ADDITIVE', 'Amount', 'Line amount', FALSE, TRUE)",
        f"ADD_FACT('{MODEL}', 'line', 'line_one', '1', 'DECIMAL(18,0)', "
        "'ADDITIVE', 'One', 'Literal one per line', FALSE, TRUE)",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")


def build_partitioned_entity(con: Any) -> None:
    """A second object whose entity is F3-partitioned, declared as one candidate."""
    coverage = json.dumps([
        {"representation_name": "cold",
         "coverage_predicate": f"o.order_ts < TIMESTAMP '{CUTOVER}'",
         "valid_from": None, "valid_to": CUTOVER},
        {"representation_name": "primary",
         "coverage_predicate": f"o.order_ts >= TIMESTAMP '{CUTOVER}'",
         "valid_from": CUTOVER, "valid_to": None},
    ])
    for statement in (
        f"ADD_ENTITY('{MODEL}', 'order', '{SCHEMA}', 'ORDERS_HOT', 'o', "
        "'o.order_id', 'One order', 'Partitioned orders')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{MODEL}', 'order', 'order_pk', 'PRIMARY', "
        "'Order identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"order_id"}]\')',
        f"ADD_SEMANTIC_OBJECT('{MODEL}', 'ORDERS', 'order', 'Order-grain object')",
        f"ADD_FACT('{MODEL}', 'order', 'freight', 'o.freight_amount', "
        "'DECIMAL(18,2)', 'ADDITIVE', 'Freight', 'Freight', FALSE, TRUE)",
        f"ADD_FACT('{MODEL}', 'order', 'order_one', '1', 'DECIMAL(18,0)', "
        "'ADDITIVE', 'One', 'Literal one per order', FALSE, TRUE)",
        f"ADD_ENTITY_REPRESENTATION_WITH_COVERAGE('{MODEL}', 'order', 'cold', "
        f"'RELATION', '{SCHEMA}', 'ORDERS_COLD', 20, 'MANUAL', {literal(coverage)})",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        build_fixture(con)

        # 1. COUNT(*) is refused, and names both forms that do work.
        counted = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.LINES
REPLACE METRICS (
  METRIC line_count AS COUNT(*) ON ENTITY line RETURNS DECIMAL(18,0)
    FORMAT 'integer' DISPLAY 'Lines' COMMENT 'Row count' ADDITIVE PUBLIC CERTIFIED
)""")
        assert_equal("COUNT(*) refused", counted["status"], "ERROR")
        assert_contains("refusal names the rule", counted["message"], "SEMANTIC_MODEL_056")
        assert_contains("refusal names the planner reason", counted["message"],
                        "METRIC_INPUT_GRAIN_MISSING")
        assert_contains("refusal names counting a fact", counted["message"], "COUNT(<fact>)")
        assert_contains("refusal names summing a literal fact", counted["message"],
                        "SUM(<name>)")
        assert_equal("nothing was persisted", metric_count(con, "line_count"), 0)

        # 2. Both supported forms are accepted and agree.
        supported = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.LINES
REPLACE METRICS (
  METRIC line_count_sum AS SUM(line_one) ON ENTITY line RETURNS DECIMAL(18,0)
    FORMAT 'integer' DISPLAY 'Lines (sum)' COMMENT 'Sum a literal fact'
    ADDITIVE PUBLIC CERTIFIED,
  METRIC line_count_count AS COUNT(amount) ON ENTITY line RETURNS DECIMAL(18,0)
    FORMAT 'integer' DISPLAY 'Lines (count)' COMMENT 'Count a non-null fact'
    ADDITIVE PUBLIC CERTIFIED
)""")
        assert_equal("supported row-count forms accepted", supported["status"], "OK")
        counts = []
        for metric in ("line_count_sum", "line_count_count"):
            compiled = compile_request(con, {
                "model": MODEL, "object": "LINES", "metrics": [metric],
                "client": "verify_metric_plannability",
            })
            assert_equal(f"{metric} compiles", compiled["status"], "OK")
            counts.append(int(execute(con, compiled["generated_sql"])[0][0]))
        assert_equal("both row-count forms agree", counts, [3, 3])

        # 3. AVG on a partitioned entity is refused.
        build_partitioned_entity(con)
        mergeable = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.ORDERS
REPLACE METRICS (
  METRIC total_freight AS SUM(freight) ON ENTITY "order" RETURNS DECIMAL(18,2)
    FORMAT 'currency' DISPLAY 'Total Freight' COMMENT 'Freight' ADDITIVE PUBLIC CERTIFIED,
  METRIC order_count AS SUM(order_one) ON ENTITY "order" RETURNS DECIMAL(18,0)
    FORMAT 'integer' DISPLAY 'Orders' COMMENT 'Orders' ADDITIVE PUBLIC CERTIFIED
)""")
        assert_equal("mergeable F3 metrics accepted", mergeable["status"], "OK")
        averaged = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.ORDERS
ADD OR REPLACE METRIC mean_freight AS AVG(freight) ON ENTITY "order"
  RETURNS DECIMAL(18,4) FORMAT 'currency' DISPLAY 'Mean Freight'
  COMMENT 'Arithmetic mean' ADDITIVE PUBLIC CERTIFIED""")
        assert_equal("AVG on a partitioned entity refused", averaged["status"], "ERROR")
        assert_contains("refusal names the rule", averaged["message"], "SEMANTIC_MODEL_057")
        assert_contains("refusal names the aggregate", averaged["message"], "AVG")
        assert_contains("refusal names the partitioned entity", averaged["message"],
                        "'order' is partitioned")
        assert_equal("nothing was persisted", metric_count(con, "mean_freight"), 0)

        # 4. The same aggregate is still allowed where it can be compiled.
        unpartitioned_avg = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.LINES
ADD OR REPLACE METRIC mean_amount AS AVG(amount) ON ENTITY line
  RETURNS DECIMAL(18,4) FORMAT 'currency' DISPLAY 'Mean Amount'
  COMMENT 'Arithmetic mean' ADDITIVE PUBLIC CERTIFIED""")
        assert_equal("AVG on an unpartitioned entity accepted",
                     unpartitioned_avg["status"], "OK")
        compiled = compile_request(con, {
            "model": MODEL, "object": "LINES", "metrics": ["mean_amount"],
            "client": "verify_metric_plannability",
        })
        assert_equal("and it still compiles", compiled["status"], "OK")
        assert_equal("and executes", execute(con, compiled["generated_sql"])[0][0], Decimal("6"))

        # 5. The reverse order: partition an entity that already has that metric.
        coverage = json.dumps([
            {"representation_name": "linecold",
             "coverage_predicate": f"l.line_ts < TIMESTAMP '{CUTOVER}'",
             "valid_from": None, "valid_to": CUTOVER},
            {"representation_name": "primary",
             "coverage_predicate": f"l.line_ts >= TIMESTAMP '{CUTOVER}'",
             "valid_from": CUTOVER, "valid_to": None},
        ])
        con.execute(
            f"CREATE TABLE {SCHEMA}.ORDER_LINES_COLD (LINE_ID DECIMAL(18,0), "
            "ORDER_ID DECIMAL(18,0), AMOUNT DECIMAL(18,2), LINE_TS TIMESTAMP)"
        )
        con.execute(
            f"INSERT INTO {SCHEMA}.ORDER_LINES_COLD VALUES "
            "(90, 1, 1.00, TIMESTAMP '2026-01-09 00:00:00')"
        )
        # On a draft the mutation applies and the model goes stale -- the
        # contract every draft mutator follows, so a modeller can repair in
        # steps. What matters is that the gate re-runs and the now-unplannable
        # metric cannot be queried: on a published model the same candidate is
        # refused and restored, and on a draft compilation is gated.
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE("
            f"'{MODEL}', 'line', 'linecold', 'RELATION', '{SCHEMA}', "
            f"'ORDER_LINES_COLD', 20, 'MANUAL', {literal(coverage)})",
        )
        issues = execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
        gate_rows = [row for row in issues if str(row[3]) == "SEMANTIC_MODEL_057"]
        if not gate_rows:
            raise AssertionError(
                f"partitioning under a non-mergeable metric was not reported: {issues}")
        assert_contains("partitioning re-runs the gate", str(gate_rows[0][4]),
                        "no mergeable aggregate state")
        blocked = compile_request(con, {
            "model": MODEL, "object": "LINES", "metrics": ["mean_amount"],
            "client": "verify_metric_plannability",
        })
        assert_equal("the unplannable metric cannot be queried", blocked["status"], "ERROR")
        assert_equal("the metric row is still there to repair",
                     metric_count(con, "mean_amount"), 1)

        # Repair by removing the partition, and the model is clean again.
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION("
            f"'{MODEL}', 'line', 'linecold')",
        )
        repaired = execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
        assert_equal("removing the partition repairs the model",
                     [row for row in repaired if str(row[0]).upper() == "ERROR"], [])

        # 6. The exact alternative on the partitioned entity.
        ratio = apply_definition(con, f"""ALTER SEMANTIC VIEW {MODEL}.ORDERS
ADD OR REPLACE METRIC avg_freight AS total_freight / NULLIF(order_count, 0)
  ON ENTITY "order" RETURNS DECIMAL(18,6) FORMAT 'currency'
  DISPLAY 'Average Freight' COMMENT 'Mergeable ratio' RATIO PUBLIC CERTIFIED""")
        assert_equal("the mergeable ratio is accepted", ratio["status"], "OK")
        compiled = compile_request(con, {
            "model": MODEL, "object": "ORDERS", "metrics": ["avg_freight"],
            "client": "verify_metric_plannability",
        })
        assert_equal("ratio compiles across partitions", compiled["status"], "OK")
        assert_equal("ratio is exact across partitions",
                     Decimal(str(execute(con, compiled["generated_sql"])[0][0])),
                     Decimal("25"))

        print()
        print("metric plannability gate verified.")
        return 0
    finally:
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
