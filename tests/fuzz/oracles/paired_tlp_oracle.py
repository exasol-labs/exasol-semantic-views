"""Check four ternary partitions through both JSON and SQL compiler paths."""

from __future__ import annotations

from time import perf_counter
from typing import Any

from ..cases import CaseResult, FuzzCase, PairedTlpCase, Profile
from ..lua_backend import CaseTimeout
from .row_comparison import compare_typed_rows


class PairedTlpOracle:
    name = "paired-tlp"
    accepted_profiles: tuple[Profile, ...] = (Profile.PAIRED_TLP,)
    database_free = False

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, PairedTlpCase)
        variants = (("base", case.base), ("p", case.predicate),
                    ("not_p", case.complement), ("null", case.null))
        variant_sql = "\n".join(f"{name}: {variant.sql}" for name, variant in variants)
        groups: dict[str, dict[str, dict[Any, float]]] = {"json": {}, "sql": {}}
        timings: dict[str, float] = {}
        stage = ""
        try:
            for name, variant in variants:
                for lane in ("json", "sql"):
                    stage = f"{name}/{lane}/compile"
                    started = perf_counter()
                    result = (backend.compile_json(variant.json_payload) if lane == "json"
                              else backend.compile_sql(variant.sql))
                    timings[stage] = perf_counter() - started
                    if result["status"] != "OK":
                        error = (f"{stage}: {result.get('error_code')}: "
                                 f"{result.get('error_message')}")
                        return CaseResult(case.label.idx, "compile-error", detail=error,
                                          sql_text=variant_sql, json_payload=case.base.json_payload,
                                          stage=stage, exasol_error=error, rows=str(groups),
                                          timings=str(timings))
                    stage = f"{name}/{lane}/execute"
                    started = perf_counter()
                    rows = backend.execute(result["generated_sql"]).fetchall()
                    timings[stage] = perf_counter() - started
                    groups[lane][name] = {row[0]: float(row[1]) for row in rows
                                          if row[1] is not None}
                    if verbose:
                        print(f"[{case.label.idx}] {stage}: {groups[lane][name]}")
            for lane in ("json", "sql"):
                stage = f"{lane}/nonempty"
                if not groups[lane]["base"]:
                    return CaseResult(case.label.idx, "contract-mismatch",
                                      detail=f"{lane} base query returned no non-NULL metric groups",
                                      sql_text=variant_sql, json_payload=case.base.json_payload,
                                      stage=stage, rows=str(groups), timings=str(timings))
                stage = f"{lane}/identity"
                base = groups[lane]["base"]
                keys = set().union(*(groups[lane][name] for name, _ in variants))
                for key in keys:
                    parts = sum(groups[lane][name].get(key, 0) for name in ("p", "not_p", "null"))
                    diff = compare_typed_rows([(base.get(key, 0),)], [(parts,)])
                    if diff:
                        return CaseResult(case.label.idx, "row-diff", detail=f"{key!r}: {diff}",
                                          sql_text=variant_sql, json_payload=case.base.json_payload,
                                          stage=stage, rows=str(groups), timings=str(timings))
            stage = "cross-lane"
            for name, _ in variants:
                j, s = groups["json"][name], groups["sql"][name]
                if set(j) != set(s):
                    return CaseResult(case.label.idx, "row-diff",
                                      detail=f"{name} group keys differ: json={set(j)} sql={set(s)}",
                                      sql_text=variant_sql, json_payload=case.base.json_payload,
                                      stage=stage, rows=str(groups), timings=str(timings))
                for key in set(j):
                    diff = compare_typed_rows([(j[key],)], [(s[key],)])
                    if diff:
                        return CaseResult(case.label.idx, "row-diff", detail=f"{name}/{key!r}: {diff}",
                                          sql_text=variant_sql, json_payload=case.base.json_payload,
                                          stage=stage, rows=str(groups), timings=str(timings))
            return CaseResult(case.label.idx, "match", detail="four variants on both paths",
                              sql_text=variant_sql, json_payload=case.base.json_payload,
                              timings=str(timings))
        except CaseTimeout:
            raise
        except Exception as exc:  # noqa: BLE001 -- retain SQL failure context
            if stage.endswith(("/compile", "/execute")):
                timings.setdefault(stage, perf_counter() - started)
            return CaseResult(case.label.idx, "exec-error", detail=str(exc),
                              sql_text=variant_sql, json_payload=case.base.json_payload,
                              stage=stage, exasol_error=str(exc), rows=str(groups),
                              timings=str(timings))
