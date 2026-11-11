"""Hand-written sales-model case generation; preserve its RNG call order."""

from __future__ import annotations

import random
from typing import Any

from ..cases import (CaseLabel, Filter, HavingClause, JsonTlpCase, OrderBy,
                     PairedCase, Profile, Spec, TlpCase)

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


class HandwrittenGenerator:
    name = "handwritten"
    profiles = frozenset({Profile.PAIRED, Profile.JSON_TLP})

    def generate(self, rng: random.Random, profile: Profile, seed: int, idx: int):
        label = CaseLabel(seed=seed, idx=idx)
        if profile == Profile.PAIRED:
            spec = gen_spec(rng)
            return PairedCase(label, spec_to_json(spec), spec_to_semantic_sql(spec))
        if profile == Profile.JSON_TLP:
            case = gen_tlp_case(rng)
            return JsonTlpCase(
                label,
                spec_to_json(_make_spec(case.group_dim, case.metric, [])),
                spec_to_json(_make_spec(case.group_dim, case.metric, [case.predicate])),
                spec_to_json(_make_spec(case.group_dim, case.metric, [negate_filter(case.predicate)])),
                spec_to_json(_make_spec(case.group_dim, case.metric,
                                        [Filter(case.partition_dim, "IS NULL")])),
            )
        raise ValueError(f"handwritten generator does not provide {profile.value}")
