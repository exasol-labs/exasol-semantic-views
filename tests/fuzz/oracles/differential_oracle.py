"""Compare the JSON and Semantic SQL compiler paths on one request."""

from __future__ import annotations

import json
from typing import Any

from ..cases import CaseResult, FuzzCase, PairedCase, Profile
from .row_comparison import compare_rows

def _error_suffix(code: str | None) -> str:
    if not code:
        return ""
    parts = code.rsplit("_", 1)
    return parts[-1] if len(parts) == 2 else code


class DifferentialOracle:
    name = "differential"
    accepted_profiles: tuple[Profile, ...] = (Profile.PAIRED,)
    database_free = False

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, PairedCase)
        idx, payload, sql_text = case.label.idx, case.json_payload, case.sql
        if verbose:
            print(f"[{idx}] json    = {json.dumps(payload)}")
            print(f"[{idx}] sem-sql = {sql_text}")

        j = backend.compile_json(payload)
        s = backend.compile_sql(sql_text)
        if j["status"] != s["status"]:
            return CaseResult(idx, "status-mismatch",
                detail=(f"json={j['status']}/{j['error_code']} sql={s['status']}/{s['error_code']} "
                        f"json_msg={j['error_message']!r} sql_msg={s['error_message']!r}"),
                json_payload=payload, sql_text=sql_text)
        if j["status"] == "ERROR":
            if _error_suffix(j["error_code"]) != _error_suffix(s["error_code"]):
                return CaseResult(idx, "status-mismatch",
                    detail=f"both ERROR but codes differ: json={j['error_code']} sql={s['error_code']}",
                    json_payload=payload, sql_text=sql_text)
            return CaseResult(idx, "both-error", detail=f"{j['error_code']} / {s['error_code']}",
                              json_payload=payload, sql_text=sql_text)
        try:
            j_rows = [tuple(row) for row in backend.execute(j["generated_sql"]).fetchall()]
            s_rows = [tuple(row) for row in backend.execute(s["generated_sql"]).fetchall()]
        except Exception as exc:  # noqa: BLE001 — reporting only
            return CaseResult(idx, "exec-error", detail=str(exc),
                              json_payload=payload, sql_text=sql_text)
        diff = compare_rows(j_rows, s_rows)
        if diff is None:
            return CaseResult(idx, "match", detail=f"{len(j_rows)} rows",
                              json_payload=payload, sql_text=sql_text)
        return CaseResult(idx, "row-diff", detail=diff,
                          json_payload=payload, sql_text=sql_text)


