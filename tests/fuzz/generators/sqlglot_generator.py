"""Small, deterministic SQLGlot corpus for the Lua compiler contract."""

from __future__ import annotations

import random

from ..cases import CaseLabel, LabelledSqlCase, Profile


class SqlglotGenerator:
    name = "sqlglot"
    profiles = frozenset({Profile.LABELLED_SQL})

    def generate(self, rng: random.Random, profile: Profile, seed: int, idx: int) -> LabelledSqlCase:
        if profile != Profile.LABELLED_SQL:
            raise ValueError(f"sqlglot generator does not provide {profile.value}")
        from sqlglot import parse_one, select
        from sqlglot.errors import ErrorLevel

        query = (select("order_status", "total_revenue")
                 .from_("SEMANTIC_SALES.SALES")
                 .group_by("order_status"))
        if rng.random() < 0.5:
            query = query.where(f"order_status = '{rng.choice(('COMPLETE', 'CANCELLED'))}'")
        if rng.random() < 0.5:
            query = query.order_by("order_status ASC")
            if rng.random() < 0.5:
                query = query.limit(rng.choice((1, 5, 10)))
        sql = query.sql(dialect="exasol")
        # Catch syntax errors SQLGlot detects in its rendered Exasol SQL.
        parse_one(sql, dialect="exasol", error_level=ErrorLevel.RAISE)
        return LabelledSqlCase(
            CaseLabel(seed, idx, shape="grouped-single-object", expected_status="ACCEPT"),
            sql,
        )
