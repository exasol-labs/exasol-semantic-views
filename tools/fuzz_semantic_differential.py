#!/usr/bin/env python3
"""Fuzz testing for the semantic compiler.

Two oracle modes, both fed by one shared random generator:

  differential (default)
    Runs the same canonical request through both COMPILE_REQUEST_JSON and
    COMPILE_SQL and compares row sets. Enforces the architectural invariant
    that the two input lanes share the same planner: any divergence is a bug
    in one of the surfaces or in the shared pipeline.

  tlp
    Ternary Logic Partitioning. Runs a base aggregate `SELECT dim, SUM(m)
    GROUP BY dim`, then three partitioned copies with `WHERE p`, `WHERE NOT p`,
    and `WHERE dim_p IS NULL`. For every group, the three partitions must sum
    to the base. This is a true correctness oracle: the differential mode
    can't catch a bug that's wrong in both lanes; TLP can.

Requires the sales seed model to be installed (tools/install.py --example).

Usage:
    python3 tools/fuzz_semantic_differential.py                # default: differential, 30 cases, seed=0
    python3 tools/fuzz_semantic_differential.py --oracle tlp   # TLP correctness partitions
    python3 tools/fuzz_semantic_differential.py --seed 42 --cases 200
    python3 tools/fuzz_semantic_differential.py --verbose      # print each spec
"""

from __future__ import annotations

import argparse
import json
import os
import random
import ssl
import sys
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any


# ---------------------------------------------------------------------------
# Sales seed model surface (must match sql/examples/sales_model_seed.sql)
# ---------------------------------------------------------------------------

MODEL = "sales"
OBJECT = "SALES"

# (name, sql-type, sample values used when generating filters)
DIMENSIONS: list[tuple[str, str, list[Any]]] = [
    ("customer_region", "varchar", ["North", "South", "West"]),
    ("order_status",    "varchar", ["COMPLETE", "CANCELLED"]),
    ("product_category","varchar", ["Widgets", "Gadgets", "Gizmos"]),
    ("order_month",     "date",    ["2026-01-01", "2026-02-01", "2026-03-01"]),
]

METRICS = ["total_revenue", "completed_revenue", "gross_margin", "total_cost"]

DIM_NAMES = [d[0] for d in DIMENSIONS]
DIM_BY_NAME = {d[0]: d for d in DIMENSIONS}


# ---------------------------------------------------------------------------
# Canonical Spec + serializers
# ---------------------------------------------------------------------------

@dataclass
class Filter:
    field: str
    op: str
    value: Any = None  # scalar, list (for IN/BETWEEN), or None (IS [NOT] NULL)


@dataclass
class OrderBy:
    field: str
    direction: str  # "asc" | "desc"


@dataclass
class HavingClause:
    field: str          # metric name
    op: str             # >, >=, <, <=, =, !=
    value: float | int


@dataclass
class Spec:
    dimensions: list[str] = field(default_factory=list)
    metrics: list[str] = field(default_factory=list)
    filters: list[Filter] = field(default_factory=list)
    having: list[HavingClause] = field(default_factory=list)
    order_by: list[OrderBy] = field(default_factory=list)
    limit: int | None = None


def _literal_semantic_sql(value: Any, typ: str) -> str:
    """Render a Python value as a Semantic SQL literal for the given dim type."""
    if typ == "date":
        return f"DATE '{value}'"
    return "'" + str(value).replace("'", "''") + "'"


def _literal_json(value: Any) -> Any:
    """JSON side accepts date strings directly."""
    return value


def spec_to_json(spec: Spec) -> dict:
    req: dict = {
        "model": MODEL,
        "object": OBJECT,
        "dimensions": list(spec.dimensions),
        "metrics": list(spec.metrics),
        "client": "fuzz_differential",
    }
    if spec.filters:
        req["filters"] = [
            {"field": f.field, "op": f.op, **({"value": _literal_json(f.value)} if f.value is not None else {})}
            for f in spec.filters
        ]
    if spec.having:
        req["having"] = [{"field": h.field, "op": h.op, "value": h.value} for h in spec.having]
    if spec.order_by:
        req["order_by"] = [{"field": o.field, "direction": o.direction} for o in spec.order_by]
    if spec.limit is not None:
        req["limit"] = spec.limit
    return req


def spec_to_semantic_sql(spec: Spec) -> str:
    select_list = ", ".join(spec.dimensions + spec.metrics)
    if not select_list:
        select_list = "*"
    parts = [f"SELECT {select_list}", f"FROM SEMANTIC_{OBJECT.upper()}.{OBJECT}"]
    if spec.dimensions:
        parts.append("GROUP BY " + ", ".join(spec.dimensions))
    if spec.filters:
        parts.append("WHERE " + " AND ".join(_filter_to_sql(f) for f in spec.filters))
    if spec.having:
        parts.append("HAVING " + " AND ".join(
            f"{h.field} {h.op} {h.value}" for h in spec.having
        ))
    if spec.order_by:
        parts.append("ORDER BY " + ", ".join(
            f"{o.field} {o.direction.upper()}" for o in spec.order_by
        ))
    if spec.limit is not None:
        parts.append(f"LIMIT {spec.limit}")
    return " ".join(parts)


def _filter_to_sql(f: Filter) -> str:
    _, typ, _ = DIM_BY_NAME[f.field]
    if f.op == "IS NULL":
        return f"{f.field} IS NULL"
    if f.op == "IS NOT NULL":
        return f"{f.field} IS NOT NULL"
    if f.op == "IN":
        vals = ", ".join(_literal_semantic_sql(v, typ) for v in f.value)
        return f"{f.field} IN ({vals})"
    if f.op == "BETWEEN":
        lo, hi = f.value
        return f"{f.field} BETWEEN {_literal_semantic_sql(lo, typ)} AND {_literal_semantic_sql(hi, typ)}"
    return f"{f.field} {f.op} {_literal_semantic_sql(f.value, typ)}"


# ---------------------------------------------------------------------------
# Generator
# ---------------------------------------------------------------------------

FILTER_OPS = ["=", "!=", "IN", "BETWEEN", "IS NULL", "IS NOT NULL"]


def gen_spec(rng: random.Random) -> Spec:
    # 1..3 dimensions (at least one for a groupable query)
    n_dims = rng.randint(1, 3)
    dims = rng.sample(DIM_NAMES, k=n_dims)

    # 1..3 metrics
    n_metrics = rng.randint(1, 3)
    metrics = rng.sample(METRICS, k=n_metrics)

    # 0..2 filters on any dimension (may target dims not selected)
    filters: list[Filter] = []
    for _ in range(rng.randint(0, 2)):
        dname, dtyp, samples = rng.choice(DIMENSIONS)
        op = rng.choice(FILTER_OPS)
        if op in ("IS NULL", "IS NOT NULL"):
            filters.append(Filter(dname, op))
        elif op == "IN":
            k = rng.randint(1, min(2, len(samples)))
            filters.append(Filter(dname, op, rng.sample(samples, k=k)))
        elif op == "BETWEEN":
            a, b = sorted(rng.sample(samples, k=2)) if len(samples) >= 2 else (samples[0], samples[0])
            filters.append(Filter(dname, op, [a, b]))
        else:
            filters.append(Filter(dname, op, rng.choice(samples)))

    # 30% chance of a HAVING clause on a selected metric (post-aggregate filter).
    # Values are drawn from a range that spans zero so the predicate is a real
    # partition, not a tautology.
    having: list[HavingClause] = []
    if rng.random() < 0.3:
        having.append(HavingClause(
            field=rng.choice(metrics),
            op=rng.choice([">", ">=", "<", "<=", "=", "!="]),
            value=rng.choice([0, 100, 500, 1000, 2500]),
        ))

    # 50% chance of an ORDER BY on a selected output
    order_by: list[OrderBy] = []
    if rng.random() < 0.5:
        selectable = dims + metrics
        order_by.append(OrderBy(rng.choice(selectable), rng.choice(["asc", "desc"])))

    # 30% chance of a LIMIT — only meaningful with a deterministic ORDER BY,
    # so we skip LIMIT unless we chose ORDER BY (avoids nondeterministic row sets)
    limit = None
    if order_by and rng.random() < 0.3:
        limit = rng.choice([1, 5, 10])

    return Spec(dims, metrics, filters, having, order_by, limit)


# ---------------------------------------------------------------------------
# Connection + compile helpers
# ---------------------------------------------------------------------------

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


def _sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_json(con, payload: dict) -> dict:
    row = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({_sql_string(json.dumps(payload))})"
    ).fetchone()
    return {"status": row[0], "error_code": row[1], "error_message": row[2],
            "generated_sql": row[4]}


def compile_sql(con, sql: str) -> dict:
    row = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({_sql_string(sql)})"
    ).fetchone()
    return {"status": row[0], "error_code": row[1], "error_message": row[2],
            "generated_sql": row[4]}


# ---------------------------------------------------------------------------
# Row-set comparison
# ---------------------------------------------------------------------------

def _normalize_cell(v: Any) -> Any:
    if isinstance(v, Decimal):
        # normalize to reduced-precision float to absorb representation noise
        return round(float(v), 6)
    if isinstance(v, float):
        return round(v, 6)
    return v


def _normalize_rows(rows: list[tuple]) -> list[tuple]:
    normalized = [tuple(_normalize_cell(c) for c in r) for r in rows]
    return sorted(normalized, key=lambda r: tuple(str(c) for c in r))


def _error_suffix(code: str | None) -> str:
    """Strip the routing prefix from an error code (SEMANTIC_REQUEST_080 -> 080)."""
    if not code:
        return ""
    parts = code.rsplit("_", 1)
    return parts[-1] if len(parts) == 2 else code


def compare_rows(a: list[tuple], b: list[tuple]) -> str | None:
    """Return None if row sets are equivalent, else a human-readable diff summary."""
    na, nb = _normalize_rows(a), _normalize_rows(b)
    if na == nb:
        return None
    if len(na) != len(nb):
        return f"row count differs: json={len(na)} sql={len(nb)}"
    for i, (ra, rb) in enumerate(zip(na, nb)):
        if ra != rb:
            return f"first diff at sorted-row {i}: json={ra!r} sql={rb!r}"
    return "unknown diff"


# ---------------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------------

@dataclass
class CaseResult:
    idx: int
    spec: Spec
    verdict: str          # "match" | "both-error" | "status-mismatch" | "row-diff" | "exec-error"
    detail: str = ""
    json_payload: dict | None = None
    sql_text: str | None = None


def run_case(con, idx: int, spec: Spec, verbose: bool) -> CaseResult:
    payload = spec_to_json(spec)
    sql_text = spec_to_semantic_sql(spec)

    if verbose:
        print(f"[{idx}] json    = {json.dumps(payload)}")
        print(f"[{idx}] sem-sql = {sql_text}")

    j = compile_json(con, payload)
    s = compile_sql(con, sql_text)

    if j["status"] != s["status"]:
        return CaseResult(idx, spec, "status-mismatch",
            detail=(f"json={j['status']}/{j['error_code']} sql={s['status']}/{s['error_code']} "
                    f"json_msg={j['error_message']!r} sql_msg={s['error_message']!r}"),
            json_payload=payload, sql_text=sql_text)

    if j["status"] == "ERROR":
        # Both errored; require the same error class. The prefix
        # (SEMANTIC_REQUEST_ vs SEMANTIC_QUERY_) records which surface caught
        # the error and is expected to differ — compare only the numeric suffix.
        if _error_suffix(j["error_code"]) != _error_suffix(s["error_code"]):
            return CaseResult(idx, spec, "status-mismatch",
                detail=f"both ERROR but codes differ: json={j['error_code']} sql={s['error_code']}",
                json_payload=payload, sql_text=sql_text)
        return CaseResult(idx, spec, "both-error", detail=f"{j['error_code']} / {s['error_code']}",
                          json_payload=payload, sql_text=sql_text)

    try:
        j_rows = [tuple(r) for r in con.execute(j["generated_sql"]).fetchall()]
        s_rows = [tuple(r) for r in con.execute(s["generated_sql"]).fetchall()]
    except Exception as e:  # noqa: BLE001 — reporting only
        return CaseResult(idx, spec, "exec-error", detail=str(e),
                          json_payload=payload, sql_text=sql_text)

    diff = compare_rows(j_rows, s_rows)
    if diff is None:
        return CaseResult(idx, spec, "match", detail=f"{len(j_rows)} rows",
                          json_payload=payload, sql_text=sql_text)
    return CaseResult(idx, spec, "row-diff", detail=diff,
                      json_payload=payload, sql_text=sql_text)


# ---------------------------------------------------------------------------
# TLP oracle
# ---------------------------------------------------------------------------

# Metrics that decompose linearly across a row-set partition. Ratios like
# gross_margin_pct don't — a / b for the union isn't a/b for the parts summed.
LINEAR_METRICS = ["total_revenue", "completed_revenue", "gross_margin", "total_cost"]

# Partition operators supported by BOTH surfaces (see SEMANTIC_REQUEST_033
# emitter for the JSON allow-list) with a well-defined complement inside that
# allow-list. NOT IN / NOT LIKE / NOT BETWEEN are missing from the allow-list,
# so IN- and BETWEEN-based partitions can't be tested via TLP without adding
# OR support to the filter grammar.
_TLP_NEGATION = {
    "=": "!=",
    "!=": "=",
    "<": ">=",
    ">=": "<",
    ">": "<=",
    "<=": ">",
}


def negate_filter(f: Filter) -> Filter:
    return Filter(f.field, _TLP_NEGATION[f.op], f.value)


@dataclass
class TlpCase:
    group_dim: str
    metric: str
    partition_dim: str
    predicate: Filter


def gen_tlp_case(rng: random.Random) -> TlpCase:
    group_dim, partition_dim = rng.sample(DIM_NAMES, k=2)
    metric = rng.choice(LINEAR_METRICS)
    _, dtyp, samples = DIM_BY_NAME[partition_dim]
    op = rng.choice(list(_TLP_NEGATION.keys()))
    value = rng.choice(samples)
    return TlpCase(group_dim, metric, partition_dim, Filter(partition_dim, op, value))


def _make_spec(group_dim: str, metric: str, filters: list[Filter]) -> Spec:
    return Spec(
        dimensions=[group_dim],
        metrics=[metric],
        filters=filters,
        order_by=[OrderBy(group_dim, "asc")],
    )


def run_tlp_case(con, idx: int, case: TlpCase, verbose: bool) -> CaseResult:
    base_spec = _make_spec(case.group_dim, case.metric, [])
    p_spec = _make_spec(case.group_dim, case.metric, [case.predicate])
    not_p_spec = _make_spec(case.group_dim, case.metric, [negate_filter(case.predicate)])
    null_spec = _make_spec(case.group_dim, case.metric, [Filter(case.partition_dim, "IS NULL")])

    if verbose:
        for label, s in (("base", base_spec), ("p", p_spec), ("not_p", not_p_spec), ("null", null_spec)):
            print(f"[{idx}] tlp/{label}: {json.dumps(spec_to_json(s))}")

    try:
        base = _tlp_run(con, base_spec)
        via_true = _tlp_run(con, p_spec)
        via_false = _tlp_run(con, not_p_spec)
        via_null = _tlp_run(con, null_spec)
    except _TlpCompileError as e:
        return CaseResult(idx, base_spec, "compile-error", detail=str(e),
                          json_payload=spec_to_json(base_spec))

    keys = set(base) | set(via_true) | set(via_false) | set(via_null)
    diffs: list[str] = []
    for k in sorted(keys, key=lambda x: str(x)):
        b = base.get(k)
        parts = via_true.get(k, 0.0) + via_false.get(k, 0.0) + via_null.get(k, 0.0)
        if b is None:
            # Base has no row for k; parts must sum to zero.
            if abs(parts) > 1e-6:
                diffs.append(f"group {k!r}: base=None but parts sum={parts}")
        else:
            if abs(float(b) - parts) > max(1e-6, abs(float(b)) * 1e-9):
                diffs.append(f"group {k!r}: base={b} != partitions={parts} "
                             f"(t={via_true.get(k)}, f={via_false.get(k)}, n={via_null.get(k)})")

    if not diffs:
        return CaseResult(idx, base_spec, "match", detail=f"{len(keys)} groups",
                          json_payload=spec_to_json(base_spec))
    return CaseResult(idx, base_spec, "row-diff", detail="; ".join(diffs[:2]),
                      json_payload=spec_to_json(base_spec))


class _TlpCompileError(RuntimeError):
    pass


def _tlp_run(con, spec: Spec) -> dict:
    """Compile+execute one spec, return {group_key: metric_value} dict."""
    payload = spec_to_json(spec)
    result = compile_json(con, payload)
    if result["status"] != "OK":
        raise _TlpCompileError(f"{payload!r} -> {result['error_code']}: {result['error_message']}")
    rows = con.execute(result["generated_sql"]).fetchall()
    out: dict = {}
    for row in rows:
        key, value = row[0], row[1]
        if value is None:
            continue
        out[key] = float(value) if not isinstance(value, (int, float)) else value
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--cases", type=int, default=30)
    ap.add_argument("--oracle", choices=("differential", "tlp"), default="differential")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    con = connect()

    try:
        # ensure the sales model is published (idempotent — no rows if already)
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        counts = {"match": 0, "both-error": 0, "status-mismatch": 0,
                  "row-diff": 0, "exec-error": 0, "compile-error": 0}
        failures: list[CaseResult] = []
        good = ("match", "both-error")

        for i in range(args.cases):
            if args.oracle == "differential":
                spec = gen_spec(rng)
                result = run_case(con, i, spec, args.verbose)
            else:
                case = gen_tlp_case(rng)
                result = run_tlp_case(con, i, case, args.verbose)
            counts[result.verdict] += 1
            marker = "ok " if result.verdict in good else "FAIL"
            print(f"{marker} [{i:03d}] {result.verdict:16s} {result.detail}")
            if result.verdict not in good:
                failures.append(result)

        print()
        print("=" * 60)
        for k, v in counts.items():
            print(f"  {k:16s} {v}")

        if failures:
            print()
            print(f"{len(failures)} divergences — reproducible payloads below:")
            for f in failures:
                print(f"  --- case {f.idx} ({f.verdict}: {f.detail}) ---")
                print(f"  json:    {json.dumps(f.json_payload)}")
                if f.sql_text:
                    print(f"  sem-sql: {f.sql_text}")
            return 1

        print(f"\nAll {args.cases} cases equivalent under seed={args.seed}, oracle={args.oracle}.")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
