"""Bounded SQLGlot generation for the published sales model."""

from __future__ import annotations

import random

from sqlglot import parse_one, select
from sqlglot.errors import ErrorLevel, ParseError

from ..cases import (CaseLabel, Filter, HavingClause, LabelledSqlCase, OrderBy,
                     PairedCase, PairedTlpCase, Profile, ReferenceCase, Spec,
                     FuzzCase)
from .handwritten import (DIMENSIONS, DIM_NAMES, METRICS,
                          _make_spec, gen_tlp_case, negate_filter, spec_to_json)


def _parse(sql: str) -> None:
    parse_one(sql, dialect="exasol", error_level=ErrorLevel.RAISE)


def _render(spec: Spec, *, alias: bool = False, quoted: bool = False,
            inferred: bool = False, wrapper: bool = False) -> str:
    """Render a single-object request using SQLGlot's AST builder."""
    def field(name: str) -> str:
        rendered = '"' + name + '"' if quoted else name
        return "s." + rendered if alias else rendered

    selections = [field(d) for d in spec.dimensions]
    selections += [f"MEASURE({field(m)})" if wrapper else field(m)
                   for m in spec.metrics]
    if alias and selections:
        selections[0] += " AS group_key"
    source = '"SEMANTIC_SALES"."SALES"' if quoted else "SEMANTIC_SALES.SALES"
    query = select(*selections).from_(source + (" AS s" if alias else ""))
    if spec.filters:
        predicates = []
        for filt in spec.filters:
            lhs = field(filt.field)
            if filt.op == "IS NULL":
                predicates.append(f"{lhs} IS NULL")
            else:
                value = str(filt.value).replace("'", "''")
                predicates.append(f"{lhs} {filt.op} '{value}'")
        query = query.where(" AND ".join(predicates))
    if spec.dimensions and not inferred:
        query = query.group_by(*(field(d) for d in spec.dimensions))
    if spec.having:
        query = query.having(" AND ".join(
            f"{field(h.field)} {h.op} {h.value}" for h in spec.having))
    if spec.order_by:
        query = query.order_by(*(f"{field(o.field)} {o.direction.upper()}"
                                 for o in spec.order_by))
    if spec.limit is not None:
        query = query.limit(spec.limit)
    sql = query.sql(dialect="exasol")
    _parse(sql)
    return sql


def _spec(rng: random.Random, idx: int, *, contract: bool = False) -> Spec:
    dim = "order_status" if contract else rng.choice(DIM_NAMES)
    metric = "total_revenue" if contract else rng.choice(METRICS)
    filters = []
    if idx % 3:
        name, _, values = (DIMENSIONS[1] if contract else rng.choice(DIMENSIONS[:3]))
        filters = [Filter(name, "=", rng.choice(values))]
    having = [HavingClause(metric, ">", 0)] if idx % 4 == 0 else []
    ordering = [OrderBy(dim, "asc")] if idx % 2 == 0 else []
    return Spec([dim], [metric], filters, having, ordering,
                5 if ordering and idx % 4 == 0 else None)


def _malformed(rng: random.Random, idx: int) -> tuple[str, str, str]:
    """Corrupt a generated query with one bounded, parser-visible syntax defect."""
    columns = rng.choice((("order_status", "total_revenue"),
                          ("total_revenue", "order_status"),
                          ('"order_status"', '"total_revenue"'),
                          ("order_status", '"total_revenue"'),
                          ('"total_revenue"', "order_status"),
                          ('"total_revenue"', '"order_status"')))
    prefix = (select(*columns).from_("SEMANTIC_SALES.SALES")
              .sql(dialect="exasol"))
    value = rng.choice(("COMPLETE", "CANCELLED"))
    defect = rng.randrange(3)
    if defect == 0:
        return (f"{prefix} WHERE order_status = GROUP BY order_status",
                "missing-predicate-value", "SEMANTIC_QUERY_033")
    if defect == 1:
        return (f"{prefix} WHERE order_status = '{value}' "
                "GROUP BY order_status HAVING total_revenue >",
                "missing-having-value", "SEMANTIC_QUERY_033")
    return (f"{prefix} WHERE order_status = '{value}' "
            "GROUP BY order_status LIMIT", "missing-limit-value",
            "SEMANTIC_QUERY_050")


def _joined(rng: random.Random, idx: int, *, missing_key: bool = False) -> str:
    keys = rng.sample(DIM_NAMES, k=2 if missing_key else 1 + idx % 2)
    left_metric, right_metric = "total_revenue", "total_cost"
    left = _render(Spec(keys, [left_metric]))
    right = _render(Spec(keys, [right_metric]))
    columns = ", ".join(f"l.{key}" for key in keys)
    on = " AND ".join(f"l.{key} = r.{key}" for key in
                      (keys[:1] if missing_key else keys))
    kind = "LEFT" if idx % 2 else "INNER"
    if idx % 4 < 2:
        sql = (f"SELECT {columns}, l.{left_metric}, r.{right_metric} "
               f"FROM ({left}) AS l {kind} JOIN ({right}) AS r ON {on}")
    else:
        sql = (f"WITH l AS ({left}), r AS ({right}) "
               f"SELECT {columns}, l.{left_metric}, r.{right_metric} "
               f"FROM l {kind} JOIN r ON {on}")
    rendered = parse_one(sql, dialect="exasol",
                         error_level=ErrorLevel.RAISE).sql(dialect="exasol")
    _parse(rendered)
    return rendered


def _unsafe_join(rng: random.Random, idx: int) -> tuple[str, str]:
    variant = (idx // 10) % 3
    if variant == 0:
        return _joined(rng, idx, missing_key=True), "missing-grouping-key"
    if variant == 1:
        sql = ("SELECT s.order_status, s.total_revenue, h.total_freight "
               "FROM SEMANTIC_SALES.SALES AS s JOIN "
               "SEMANTIC_SALES.ORDER_HEADER AS h "
               "ON s.order_status = h.ship_mode")
        return parse_one(sql, dialect="exasol",
                         error_level=ErrorLevel.RAISE).sql(dialect="exasol"), "cross-object-composition"
    sql = ("SELECT s.order_status, s.total_revenue, o.order_id "
           "FROM SEMANTIC_SALES.SALES AS s JOIN MART.ORDERS AS o "
           "ON s.order_status = o.order_status")
    return parse_one(sql, dialect="exasol",
                     error_level=ErrorLevel.RAISE).sql(dialect="exasol"), "ungrouped-relation"


def _reference_join(idx: int) -> tuple[str, str]:
    """Independent physical reference for the one-key additive sales join."""
    source = ("SELECT o.order_status, "
              "SUM(ol.quantity * ol.net_unit_price) AS total_revenue "
              "FROM MART.ORDERS o JOIN MART.ORDER_LINES ol "
              "ON o.order_id = ol.order_id GROUP BY o.order_status")
    semantic = _render(Spec(["order_status"], ["total_revenue"]))
    kind = "LEFT" if idx % 2 else "INNER"
    def outer(inner: str) -> str:
        return ("SELECT l.order_status, l.total_revenue, r.total_revenue "
                f"FROM ({inner}) AS l {kind} JOIN ({inner}) AS r "
                "ON l.order_status = r.order_status")
    sql, reference = outer(semantic), outer(source)
    _parse(sql)
    _parse(reference)
    return sql, reference


class SqlglotGenerator:
    name = "sqlglot"
    profiles = frozenset({Profile.LABELLED_SQL, Profile.PAIRED,
                          Profile.PAIRED_TLP, Profile.REFERENCE})

    def generate(self, rng: random.Random, profile: Profile, seed: int, idx: int) -> FuzzCase:
        match profile:
            case Profile.LABELLED_SQL:
                return self._labelled_sql(rng, seed, idx)
            case Profile.PAIRED:
                return self._paired(rng, seed, idx)
            case Profile.PAIRED_TLP:
                return self._paired_tlp(rng, seed, idx)
            case Profile.REFERENCE:
                return self._reference(seed, idx)
            case _:
                raise ValueError(f"sqlglot generator does not provide {profile.value}")

    def _labelled_sql(self, rng: random.Random, seed: int, idx: int) -> LabelledSqlCase:
        if idx % 10 >= 8:
            sql, shape, code = _malformed(rng, idx)
            try:
                _parse(sql)
            except ParseError:
                pass
            else:
                raise ValueError(f"case {idx}: malformed template parses in SQLGlot")
            return LabelledSqlCase(CaseLabel(seed, idx, shape, code,
                                             "invalid", "REJECT", code), sql)
        if idx % 10 == 7:
            sql = select("unknown_field").from_("SEMANTIC_SALES.SALES").sql(
                dialect="exasol")
            _parse(sql)
            return LabelledSqlCase(
                CaseLabel(seed, idx, "single-object", "unknown-field",
                          "valid", "REJECT", "SEMANTIC_QUERY_029"), sql)
        if idx % 10 == 6:
            sql, rule = _unsafe_join(rng, idx)
            return LabelledSqlCase(
                CaseLabel(seed, idx, "grouped-join", rule,
                          "valid", "REJECT", "SEMANTIC_QUERY_012"), sql)
        if idx % 7 == 4:
            return LabelledSqlCase(
                CaseLabel(seed, idx, "grouped-join", "whole-grouping-key",
                          "valid", "ACCEPT"), _joined(rng, idx))
        spec = _spec(rng, idx, contract=True)
        return LabelledSqlCase(
            CaseLabel(seed, idx, "single-object", "documented-subset",
                      "valid", "ACCEPT"),
            _render(spec, alias=idx % 4 == 1, quoted=idx % 4 == 2,
                    inferred=idx % 4 == 3, wrapper=idx % 4 == 0))

    def _paired(self, rng: random.Random, seed: int, idx: int) -> PairedCase:
        spec = _spec(rng, idx)
        return PairedCase(CaseLabel(seed, idx, "single-object", "paired"),
                          spec_to_json(spec), _render(spec))

    def _paired_tlp(self, rng: random.Random, seed: int, idx: int) -> PairedTlpCase:
        tlp = gen_tlp_case(rng)
        variants = (
            _make_spec(tlp.group_dim, tlp.metric, []),
            _make_spec(tlp.group_dim, tlp.metric, [tlp.predicate]),
            _make_spec(tlp.group_dim, tlp.metric, [negate_filter(tlp.predicate)]),
            _make_spec(tlp.group_dim, tlp.metric,
                       [Filter(tlp.partition_dim, "IS NULL")]),
        )
        label = CaseLabel(seed, idx, "linear-metric-tlp", "four-partition")
        paired = [PairedCase(label, spec_to_json(spec), _render(spec))
                  for spec in variants]
        return PairedTlpCase(label, *paired)

    def _reference(self, seed: int, idx: int) -> ReferenceCase:
        sql, reference = _reference_join(idx)
        return ReferenceCase(CaseLabel(seed, idx, "grouped-join",
                                       "whole-grouping-key"), sql, reference)
