"""Bounded SQLGlot generation for the published sales model."""

from __future__ import annotations

import random
from dataclasses import replace

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


def _spec(rng: random.Random, *, contract: bool = False) -> Spec:
    dim = "order_status" if contract else rng.choice(DIM_NAMES)
    metric = "total_revenue" if contract else rng.choice(METRICS)
    filters = []
    if rng.randrange(3) != 0:
        name, _, values = (DIMENSIONS[1] if contract else rng.choice(DIMENSIONS[:3]))
        filters = [Filter(name, "=", rng.choice(values))]
    having = [HavingClause(metric, ">", 0)] if rng.randrange(4) == 0 else []
    ordering = [OrderBy(dim, "asc")] if rng.choice((True, False)) else []
    return Spec([dim], [metric], filters, having, ordering,
                5 if ordering and rng.randrange(4) == 0 else None)


def _shrink_candidates(spec: Spec, **render_options: bool) -> tuple[str, ...]:
    """Remove optional clauses while retaining the original fields and syntax form."""
    candidates = []
    reduced = spec
    if reduced.limit is not None:
        reduced = replace(reduced, limit=None)
        candidates.append(_render(reduced, **render_options))
    if reduced.order_by:
        reduced = replace(reduced, order_by=[])
        candidates.append(_render(reduced, **render_options))
    if reduced.having:
        reduced = replace(reduced, having=[])
        candidates.append(_render(reduced, **render_options))
    if reduced.filters:
        reduced = replace(reduced, filters=[])
        candidates.append(_render(reduced, **render_options))
    return tuple(candidates)


def _malformed(rng: random.Random) -> tuple[str, str, str]:
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


def _joined(rng: random.Random) -> str:
    keys = rng.sample(DIM_NAMES, k=rng.choice((1, 2)))
    left_metric, right_metric = "total_revenue", "total_cost"
    left = _render(Spec(keys, [left_metric]))
    right = _render(Spec(keys, [right_metric]))
    columns = ", ".join(f"l.{key}" for key in keys)
    on = " AND ".join(f"l.{key} = r.{key}" for key in keys)
    kind = rng.choice(("LEFT", "INNER"))
    if rng.choice((True, False)):
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


def _contract_join(rng: random.Random, rule: str) -> tuple[str, str]:
    """Return one accepted join and a single unsafe edit of that join."""
    if rule == "cross-object-composition":
        control = ("SELECT s.order_status, s.total_revenue "
                   "FROM SEMANTIC_SALES.SALES AS s")
        mutated = ("SELECT s.order_status, s.total_revenue "
                   "FROM SEMANTIC_SALES.SALES AS s JOIN "
                   "SEMANTIC_SALES.ORDER_HEADER AS h "
                   "ON s.order_status = h.ship_mode")
    else:
        keys = rng.sample(DIM_NAMES, k=2 if rule == "missing-grouping-key" else 1)
        left = _render(Spec(keys, ["total_revenue"]))
        right = _render(Spec(keys, ["total_cost"]))
        columns = ", ".join(f"l.{key}" for key in keys)
        on = " AND ".join(f"l.{key} = r.{key}" for key in keys)
        prefix = (f"SELECT {columns}, l.total_revenue, r.total_cost "
                  f"FROM ({left}) AS l INNER JOIN ({right}) AS r ")
        control = prefix + "ON " + on
        if rule == "missing-grouping-key":
            mutated = prefix + f"ON l.{keys[0]} = r.{keys[0]}"
        elif rule == "or-join":
            mutated = prefix + f"ON {on} OR l.total_revenue > 0"
        elif rule == "using-join":
            mutated = prefix + f"USING ({keys[0]})"
        else:
            raise ValueError(f"unknown join mutation: {rule}")
    _parse(control)
    _parse(mutated)
    return control, mutated


CONTRACT_SCHEDULE = ("accepted", "omitted-grouping-dimension", "measure-dimension",
                     "invalid-ordinal", "safe-join", "missing-grouping-key",
                     "or-join", "using-join", "cross-object-composition", "malformed")


def _reference_join(kind: str) -> tuple[str, str]:
    """Independent physical reference for the one-key additive sales join."""
    source = ("SELECT o.order_status, "
              "SUM(ol.quantity * ol.net_unit_price) AS total_revenue "
              "FROM MART.ORDERS o JOIN MART.ORDER_LINES ol "
              "ON o.order_id = ol.order_id GROUP BY o.order_status")
    semantic = _render(Spec(["order_status"], ["total_revenue"]))
    def outer(inner: str) -> str:
        return ("SELECT l.order_status, l.total_revenue AS left_revenue, "
                "r.total_revenue AS right_revenue "
                f"FROM ({inner}) AS l {kind} JOIN ({inner}) AS r "
                "ON l.order_status = r.order_status")
    sql, reference = outer(semantic), outer(source)
    _parse(sql)
    _parse(reference)
    return sql, reference


_SOURCE_DIMENSIONS = {
    "customer_region": "c.region", "order_status": "o.order_status",
    "product_category": "p.category", "order_month": "DATE_TRUNC('month', o.order_date)",
}
_SOURCE_METRICS = {
    "total_revenue": "SUM(ol.quantity * ol.net_unit_price)",
    "total_cost": "SUM(ol.quantity * ol.unit_cost)",
    "gross_margin": "SUM(ol.quantity * (ol.net_unit_price - ol.unit_cost))",
    "completed_revenue": ("SUM(CASE WHEN o.order_status = 'COMPLETE' "
                          "THEN ol.quantity * ol.net_unit_price END)"),
}


def _reference_single(spec: Spec) -> str:
    """Render fixed sales-source formulas, never compiler output or catalog expressions."""
    dimensions = [f"{_SOURCE_DIMENSIONS[name]} AS {name}" for name in spec.dimensions]
    metrics = [f"{_SOURCE_METRICS[name]} AS {name}" for name in spec.metrics]
    source = (" FROM MART.ORDER_LINES ol LEFT JOIN MART.ORDERS o ON ol.order_id = o.order_id "
              "LEFT JOIN MART.CUSTOMERS c ON o.customer_id = c.customer_id "
              "LEFT JOIN MART.PRODUCTS p ON ol.product_id = p.product_id")
    where = ""
    if spec.filters:
        clauses = []
        for filt in spec.filters:
            value = str(filt.value).replace("'", "''")
            clauses.append(f"{_SOURCE_DIMENSIONS[filt.field]} {filt.op} '{value}'")
        where = " WHERE " + " AND ".join(clauses)
    grouped = ("SELECT " + ", ".join(dimensions + metrics) + source + where
               + " GROUP BY " + ", ".join(_SOURCE_DIMENSIONS[name]
                                             for name in spec.dimensions))
    sql = "SELECT " + ", ".join(spec.dimensions + spec.metrics) + f" FROM ({grouped}) src"
    if spec.having:
        sql += " WHERE " + " AND ".join(
            f"{h.field} {h.op} {h.value}" for h in spec.having)
    if spec.order_by:
        sql += " ORDER BY " + ", ".join(
            f"{order.field} {order.direction.upper()}" for order in spec.order_by)
    if spec.limit is not None:
        sql += f" LIMIT {spec.limit}"
    _parse(sql)
    return sql


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
                return self._reference(rng, seed, idx)
            case _:
                raise ValueError(f"sqlglot generator does not provide {profile.value}")

    def _labelled_sql(self, rng: random.Random, seed: int, idx: int) -> LabelledSqlCase:
        rule = CONTRACT_SCHEDULE[idx % len(CONTRACT_SCHEDULE)]
        if rule == "malformed":
            sql, shape, code = _malformed(rng)
            try:
                _parse(sql)
            except ParseError:
                pass
            else:
                raise ValueError(f"case {idx}: malformed template parses in SQLGlot")
            return LabelledSqlCase(CaseLabel(seed, idx, shape, shape,
                                             "invalid", "REJECT", code), sql)
        if rule == "safe-join":
            return LabelledSqlCase(
                CaseLabel(seed, idx, "grouped-join", "whole-grouping-key",
                          "valid", "ACCEPT"), _joined(rng))
        if rule in {"missing-grouping-key", "or-join", "using-join",
                    "cross-object-composition"}:
            control, sql = _contract_join(rng, rule)
            return LabelledSqlCase(
                CaseLabel(seed, idx, "grouped-join", rule,
                          "valid", "REJECT", "SEMANTIC_QUERY_012"), sql,
                control_sql=control)
        if rule == "omitted-grouping-dimension":
            spec = Spec(["order_status", "customer_region"], ["total_revenue"])
            control = _render(spec)
            sql = control.replace("GROUP BY order_status, customer_region",
                                  "GROUP BY order_status")
            code = "SEMANTIC_QUERY_008"
        elif rule == "measure-dimension":
            control = _render(Spec(["order_status"], ["total_revenue"]))
            sql = control.replace("order_status, total_revenue",
                                  "MEASURE(order_status), total_revenue", 1)
            code = "SEMANTIC_QUERY_006"
        elif rule == "invalid-ordinal":
            control = _render(Spec(["order_status"], ["total_revenue"],
                                   order_by=[OrderBy("order_status", "asc")]))
            sql = control.replace("ORDER BY order_status ASC", "ORDER BY 3 ASC")
            code = "SEMANTIC_QUERY_064"
        else:
            spec = _spec(rng, contract=True)
            mode = (idx // len(CONTRACT_SCHEDULE)) % 3
            render_options = {"alias": mode == 0, "inferred": mode == 1,
                              "wrapper": mode == 2}
            sql = _render(spec, **render_options)
            variant = _render(spec, quoted=True, inferred=mode == 1,
                              wrapper=mode == 2)
            return LabelledSqlCase(
                CaseLabel(seed, idx, "single-object", "documented-subset",
                          "valid", "ACCEPT"), sql, variant_sql=variant,
                shrink_candidates=_shrink_candidates(spec, **render_options))
        if sql == control:
            raise ValueError(f"case {idx}: mutation {rule} did not change SQL")
        _parse(sql)
        return LabelledSqlCase(
            CaseLabel(seed, idx, "single-object", rule, "valid", "REJECT", code),
            sql, control_sql=control)

    def _paired(self, rng: random.Random, seed: int, idx: int) -> PairedCase:
        spec = _spec(rng)
        if spec.limit is not None:
            spec.order_by = [OrderBy(spec.dimensions[0], "asc"),
                             OrderBy(spec.metrics[0], "asc")]
        return PairedCase(CaseLabel(seed, idx, "single-object", "paired",
                                    expected_status="ACCEPT"),
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

    def _reference(self, rng: random.Random, seed: int, idx: int) -> ReferenceCase:
        shape = idx % 8
        if shape in (5, 6):
            kind = "INNER" if shape == 5 else "LEFT"
            sql, reference = _reference_join(kind)
            return ReferenceCase(CaseLabel(seed, idx, f"{kind.lower()}-grouped-join",
                                           "whole-grouping-key"), sql, reference)
        if shape == 7:
            _, sql = _contract_join(rng, "cross-object-composition")
            return ReferenceCase(CaseLabel(seed, idx, "unsafe-direct-join",
                                           "cross-object-composition", "valid", "REJECT",
                                           "SEMANTIC_QUERY_012"), sql, "", "SEMANTIC_QUERY_012")
        specs = (
            Spec(["order_status"], ["total_revenue"]),
            Spec(["customer_region"], ["total_cost"],
                 [Filter("order_status", "=", "COMPLETE")]),
            Spec(["product_category"], ["completed_revenue"]),
            Spec(["order_month"], ["gross_margin"], order_by=[OrderBy("order_month", "asc")],
                 limit=2),
            Spec(["order_status"], ["total_revenue"],
                 having=[HavingClause("total_revenue", ">", 0)]),
        )
        spec = specs[shape]
        sql = _render(spec, alias=shape == 0, inferred=shape == 2,
                      wrapper=shape == 4)
        return ReferenceCase(CaseLabel(seed, idx, "single-object", f"sample-{shape}",
                                       expected_status="ACCEPT"),
                             sql, _reference_single(spec))
