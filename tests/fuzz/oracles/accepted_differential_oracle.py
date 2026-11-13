"""Compare paired JSON and SQL cases that are required to compile successfully."""

from __future__ import annotations

import json
from time import perf_counter
from typing import Any

from sqlglot import exp, parse_one

from ..cases import CaseResult, FuzzCase, PairedCase, Profile
from .row_comparison import compare_typed_rows


def sql_projection_fields(sql: str) -> list[str]:
    """Resolve selected fields, including aliases and MEASURE wrappers."""
    query = parse_one(sql, dialect="exasol")
    select = query if isinstance(query, exp.Select) else query.find(exp.Select)
    if select is None:
        raise ValueError("SQL has no SELECT projection")
    fields = []
    for item in select.expressions:
        column = item.find(exp.Column)
        if column is None:
            raise ValueError(f"SQL projection is not a semantic field: {item.sql()}")
        fields.append(column.name.lower())
    return fields


class AcceptedDifferentialOracle:
    name = "accepted-differential"
    accepted_profiles: tuple[Profile, ...] = (Profile.PAIRED,)
    database_free = False

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, PairedCase)
        if case.label.expected_status != "ACCEPT":
            raise ValueError("accepted-differential requires ACCEPT-labelled paired cases")
        idx, payload, sql = case.label.idx, case.json_payload, case.sql
        if verbose:
            print(f"[{idx}] json    = {json.dumps(payload)}")
            print(f"[{idx}] sem-sql = {sql}")
        timings: dict[str, float] = {}
        rows: dict[str, list[tuple]] = {}
        stage = "compile-json"
        try:
            started = perf_counter()
            j = backend.compile_json(payload)
            timings[stage] = perf_counter() - started
            stage = "compile-sql"
            started = perf_counter()
            s = backend.compile_sql(sql)
            timings[stage] = perf_counter() - started
            if j["status"] != "OK" or s["status"] != "OK":
                error = f"json={j.get('error_message')} sql={s.get('error_message')}"
                return CaseResult(idx, "compile-error", json_payload=payload, sql_text=sql,
                                  stage="compile", expected="OK/OK",
                                  actual=f"{j['status']}/{j.get('error_code')} | "
                                         f"{s['status']}/{s.get('error_code')}",
                                  detail=error, exasol_error=error, timings=str(timings))
            stage = "execute-json"
            started = perf_counter()
            rows["json"] = [tuple(row) for row in backend.execute(j["generated_sql"]).fetchall()]
            timings[stage] = perf_counter() - started
            stage = "execute-sql"
            started = perf_counter()
            sql_rows = [tuple(row) for row in backend.execute(s["generated_sql"]).fetchall()]
            timings[stage] = perf_counter() - started
            fields = sql_projection_fields(sql)
            requested = [name.lower() for name in payload.get("dimensions", []) + payload.get("metrics", [])]
            positions = [fields.index(name) for name in requested]
            rows["sql"] = [tuple(row[pos] for pos in positions) for row in sql_rows]
            diff = compare_typed_rows(rows["json"], rows["sql"],
                                      ordered=payload.get("limit") is not None)
            return CaseResult(idx, "match" if diff is None else "row-diff",
                              detail=diff or f"{len(rows['json'])} rows", json_payload=payload,
                              sql_text=sql, stage="compare", rows=str(rows) if diff else "",
                              timings=str(timings))
        except Exception as exc:  # noqa: BLE001 -- retain the failing stage
            if stage.startswith(("compile", "execute")):
                timings.setdefault(stage, perf_counter() - started)
            return CaseResult(idx, "exec-error", detail=str(exc), json_payload=payload,
                              sql_text=sql, stage=stage, exasol_error=str(exc),
                              rows=str(rows), timings=str(timings))
