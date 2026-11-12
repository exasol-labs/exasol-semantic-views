"""Check labelled Semantic SQL against the database-free Lua compiler."""

from __future__ import annotations

from typing import Any

from ..cases import CaseResult, FuzzCase, LabelledSqlCase, Profile

class ContractOracle:
    name = "contract"
    accepted_profiles: tuple[Profile, ...] = (Profile.LABELLED_SQL,)
    database_free = True

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, LabelledSqlCase)
        if verbose:
            print(f"[{case.label.idx}] expected = {case.label.expected_status}, sem-sql = {case.sql}")
        result = backend.compile(case.label.idx, case.sql)
        expected = case.label.expected_status
        if expected == "ACCEPT":
            passed = result["status"] == "OK" and result["generated_sql_present"]
        else:
            passed = (result["status"] == "ERROR"
                      and result["error_code"] == case.label.expected_code
                      and not result["generated_sql_present"])
        if passed:
            return CaseResult(case.label.idx, "match", detail=result["status"], sql_text=case.sql)
        detail = (f"expected={expected}/{case.label.expected_code} "
                  f"observed={result['status']}/{result['error_code']} "
                  f"generated_sql={result['generated_sql_present']}")
        return CaseResult(case.label.idx, "contract-mismatch", detail=detail, sql_text=case.sql)
