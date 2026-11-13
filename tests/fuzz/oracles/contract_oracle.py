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
    def _semantic_fields(result: dict[str, Any]) -> dict[str, Any]:
        plan = json.loads(result["plan_json"])
        bound = plan.get("logical_plan", {}).get("bound_query", {})
        return {"dimensions": plan.get("dimensions"), "metrics": plan.get("metrics"),
                "global_filters": bound.get("global_filters"),
                "having_filters": bound.get("having_filters"),
                "order_by": bound.get("order_by"), "limit": bound.get("limit")}

    @staticmethod
    def _failure_signature(result: dict[str, Any]) -> tuple[Any, ...]:
        return (result["status"], result.get("error_code"),
                result["generated_sql_present"])

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
        if passed and case.variant_sql and case.variant_sql != case.sql:
            variant = backend.compile(case.label.idx * 1000 + 2, case.variant_sql)
            if not self._passes(case, variant):
                return CaseResult(case.label.idx, "contract-mismatch",
                                  detail="meaning-preserving variant failed the contract",
                                  sql_text=case.sql, variant_sql=case.variant_sql,
                                  seed=case.label.seed, rule=case.label.rule,
                                  expected=self._outcome(result), actual=self._outcome(variant))
            original_fields = self._semantic_fields(result)
            variant_fields = self._semantic_fields(variant)
            if original_fields != variant_fields:
                changed = [key for key in original_fields
                           if original_fields[key] != variant_fields[key]]
                return CaseResult(case.label.idx, "contract-mismatch",
                                  detail="variant changed semantic fields: " + ", ".join(changed),
                                  sql_text=case.sql, variant_sql=case.variant_sql,
                                  seed=case.label.seed, rule=case.label.rule,
                                  expected=json.dumps(original_fields, sort_keys=True),
                                  actual=json.dumps(variant_fields, sort_keys=True))
        if passed:
            return CaseResult(case.label.idx, "match", detail=result["status"], sql_text=case.sql,
                              seed=case.label.seed, rule=case.label.rule,
                              expected=f"{expected}/{case.label.expected_code or '-'}",
                              actual=self._outcome(result))
        minimized = case.sql
        original_outcome = self._outcome(result)
        for offset, candidate in enumerate(case.shrink_candidates, start=3):
            if len(candidate) >= len(minimized):
                continue
            smaller = backend.compile(case.label.idx * 1000 + offset, candidate)
            if (self._failure_signature(smaller) == self._failure_signature(result)
                    and not self._passes(case, smaller)):
                minimized = candidate
        detail = (f"expected={expected}/{case.label.expected_code} "
            f"observed={result['status']}/{result.get('error_code')} "
                  f"generated_sql={result['generated_sql_present']}")
        return CaseResult(case.label.idx, "contract-mismatch", detail=detail, sql_text=case.sql,
                          seed=case.label.seed, rule=case.label.rule,
                          expected=f"{expected}/{case.label.expected_code or '-'}",
                          actual=original_outcome, minimized_sql=minimized)
