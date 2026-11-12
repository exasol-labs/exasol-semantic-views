"""Check labelled Semantic SQL against the database-free Lua compiler."""

from __future__ import annotations

import json
import sys
from typing import Any

from ..cases import CaseResult, FuzzCase, LabelledSqlCase, Profile

class ContractOracle:
    name = "contract"
    accepted_profiles: tuple[Profile, ...] = (Profile.LABELLED_SQL,)
    database_free = True

    @staticmethod
    def _outcome(result: dict[str, Any]) -> str:
        return f"{result['status']}/{result.get('error_code') or '-'}"

    @staticmethod
    def _semantic_fields(result: dict[str, Any]) -> tuple[Any, ...]:
        plan = json.loads(result["plan_json"])
        bound = plan.get("logical_plan", {}).get("bound_query", {})
        return (plan.get("dimensions"), plan.get("metrics"),
                bound.get("global_filters"), bound.get("having_filters"),
                bound.get("order_by"), bound.get("limit"))

    @staticmethod
    def _passes(case: LabelledSqlCase, result: dict[str, Any]) -> bool:
        if case.label.expected_status == "ACCEPT":
            return result["status"] == "OK" and result["generated_sql_present"] is True
        return (result["status"] == "ERROR"
                and result.get("error_code") == case.label.expected_code
                and result["generated_sql_present"] is False)

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, LabelledSqlCase)
        if verbose:
            print(f"[{case.label.idx}] expected = {case.label.expected_status}, sem-sql = {case.sql}",
                  file=sys.stderr)
        if case.control_sql:
            control = backend.compile(case.label.idx * 1000, case.control_sql)
            if control["status"] != "OK" or control["generated_sql_present"] is not True:
                return CaseResult(case.label.idx, "contract-mismatch",
                                  detail="accepted mutation control was refused",
                                  sql_text=case.control_sql, seed=case.label.seed,
                                  rule=case.label.rule, expected="OK/-",
                                  actual=self._outcome(control), minimized_sql=case.control_sql)
        result = backend.compile(case.label.idx * 1000 + 1, case.sql)
        expected = case.label.expected_status
        passed = self._passes(case, result)
        failed_sql = case.sql
        if passed and case.variant_sql and case.variant_sql != case.sql:
            variant = backend.compile(case.label.idx * 1000 + 2, case.variant_sql)
            passed = (self._passes(case, variant)
                      and self._semantic_fields(result) == self._semantic_fields(variant))
            if not passed:
                result = variant
                failed_sql = case.variant_sql
        if passed:
            return CaseResult(case.label.idx, "match", detail=result["status"], sql_text=case.sql,
                              seed=case.label.seed, rule=case.label.rule,
                              expected=f"{expected}/{case.label.expected_code or '-'}",
                              actual=self._outcome(result))
        minimized = failed_sql
        original_outcome = self._outcome(result)
        for candidate in case.shrink_candidates:
            if len(candidate) >= len(minimized):
                continue
            smaller = backend.compile(case.label.idx * 1000 + 3, candidate)
            if self._outcome(smaller) == original_outcome and not self._passes(case, smaller):
                minimized = candidate
        detail = (f"expected={expected}/{case.label.expected_code} "
            f"observed={result['status']}/{result.get('error_code')} "
                  f"generated_sql={result['generated_sql_present']}")
        return CaseResult(case.label.idx, "contract-mismatch", detail=detail, sql_text=failed_sql,
                          seed=case.label.seed, rule=case.label.rule,
                          expected=f"{expected}/{case.label.expected_code or '-'}",
                          actual=original_outcome, minimized_sql=minimized)
