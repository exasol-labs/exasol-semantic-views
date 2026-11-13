"""Compare installed Semantic SQL and its preprocessor with physical sales SQL."""

from __future__ import annotations

import re
from time import perf_counter
from typing import Any

from ..cases import CaseResult, FuzzCase, Profile, ReferenceCase
from ..lua_backend import CaseTimeout
from .row_comparison import compare_typed_rows


class ReferenceOracle:
    name = "reference"
    accepted_profiles: tuple[Profile, ...] = (Profile.REFERENCE,)
    database_free = False

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, ReferenceCase)
        timings: dict[str, float] = {}
        rows: dict[str, list[tuple]] = {}
        stage = "compile-sql"
        try:
            started = perf_counter()
            compiled = backend.compile_sql(case.sql)
            timings[stage] = perf_counter() - started
            if case.expected_code:
                if (compiled["status"] != "ERROR"
                        or compiled.get("error_code") != case.expected_code):
                    return self._result(case, "contract-mismatch", stage, timings, rows,
                                        f"expected {case.expected_code}; got "
                                        f"{compiled['status']}/{compiled.get('error_code')}")
                stage = "preprocessor-refusal"
                started = perf_counter()
                try:
                    backend.execute_preprocessed(case.sql).fetchall()
                except CaseTimeout:
                    raise
                except Exception as exc:  # noqa: BLE001 -- the refusal is expected
                    timings[stage] = perf_counter() - started
                    found = re.search(r"SEMANTIC_\w+_\d+", str(exc))
                    if found is None or found.group(0) != case.expected_code:
                        return self._result(case, "contract-mismatch", stage, timings, rows,
                                            f"expected {case.expected_code}; got {exc}", str(exc))
                else:
                    timings[stage] = perf_counter() - started
                    return self._result(case, "contract-mismatch", stage, timings, rows,
                                        "unsafe direct join was accepted")
                return self._result(case, "match", stage, timings, rows,
                                    case.expected_code)
            if compiled["status"] != "OK" or not compiled.get("generated_sql"):
                return self._result(case, "compile-error", stage, timings, rows,
                                    f"{compiled['status']}/{compiled.get('error_code')}: "
                                    f"{compiled.get('error_message')}",
                                    str(compiled.get("error_message") or ""))
            for name, sql in (("compiled", compiled["generated_sql"]),
                              ("preprocessor", case.sql), ("reference", case.reference_sql)):
                stage = f"execute-{name}"
                started = perf_counter()
                statement = (backend.execute_preprocessed(sql) if name == "preprocessor"
                             else backend.execute(sql))
                rows[name] = [tuple(row) for row in statement.fetchall()]
                timings[stage] = perf_counter() - started
            ordered = " LIMIT " in case.sql.upper()
            for name in ("compiled", "preprocessor"):
                stage = f"compare-{name}"
                diff = compare_typed_rows(rows[name], rows["reference"], ordered=ordered,
                                          numeric_columns=case.numeric_columns)
                if diff:
                    return self._result(case, "row-diff", stage, timings, rows, diff)
            return self._result(case, "match", "compare-reference", timings, rows,
                                f"{len(rows['reference'])} rows")
        except CaseTimeout:
            raise
        except Exception as exc:  # noqa: BLE001 -- retain the failing stage and SQL error
            if stage.startswith(("compile", "execute")):
                timings.setdefault(stage, perf_counter() - started)
            return self._result(case, "exec-error", stage, timings, rows, str(exc), str(exc))

    @staticmethod
    def _result(case: ReferenceCase, verdict: str, stage: str,
                timings: dict[str, float], rows: dict[str, list[tuple]],
                detail: str, exasol_error: str = "") -> CaseResult:
        return CaseResult(case.label.idx, verdict, detail=detail, sql_text=case.sql,
                          variant_sql=case.reference_sql or None, stage=stage,
                          exasol_error=exasol_error, rows=str(rows) if verdict != "match" else "",
                          timings=str(timings))
