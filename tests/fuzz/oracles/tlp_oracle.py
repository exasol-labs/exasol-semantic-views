"""Check the aggregate identity across ternary logic partitions."""

from __future__ import annotations

import json
from typing import Any

from ..cases import CaseResult, FuzzCase, JsonTlpCase, Profile

class _TlpCompileError(RuntimeError):
    pass


def _tlp_run(backend: Any, payload: dict[str, Any]) -> dict[Any, float]:
    result = backend.compile_json(payload)
    if result["status"] != "OK":
        raise _TlpCompileError(f"{payload!r} -> {result['error_code']}: {result['error_message']}")
    rows = backend.execute(result["generated_sql"]).fetchall()
    out: dict[Any, float] = {}
    for row in rows:
        key, value = row[0], row[1]
        if value is None:
            continue
        out[key] = float(value) if not isinstance(value, (int, float)) else value
    return out


class TlpOracle:
    name = "tlp"
    accepted_profiles: tuple[Profile, ...] = (Profile.JSON_TLP,)
    database_free = False

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult:
        assert isinstance(case, JsonTlpCase)
        idx = case.label.idx
        variants = (("base", case.base), ("p", case.predicate),
                    ("not_p", case.complement), ("null", case.null))
        if verbose:
            for name, payload in variants:
                print(f"[{idx}] tlp/{name}: {json.dumps(payload)}")
        try:
            base, via_true, via_false, via_null = (
                _tlp_run(backend, payload) for _, payload in variants
            )
        except _TlpCompileError as exc:
            return CaseResult(idx, "compile-error", detail=str(exc), json_payload=case.base)

        keys = set(base) | set(via_true) | set(via_false) | set(via_null)
        diffs: list[str] = []
        for key in sorted(keys, key=lambda value: str(value)):
            value = base.get(key)
            parts = (via_true.get(key, 0.0) + via_false.get(key, 0.0)
                     + via_null.get(key, 0.0))
            if value is None:
                if abs(parts) > 1e-6:
                    diffs.append(f"group {key!r}: base=None but parts sum={parts}")
            elif abs(float(value) - parts) > max(1e-6, abs(float(value)) * 1e-9):
                diffs.append(f"group {key!r}: base={value} != partitions={parts} "
                             f"(t={via_true.get(key)}, f={via_false.get(key)}, n={via_null.get(key)})")
        if not diffs:
            return CaseResult(idx, "match", detail=f"{len(keys)} groups", json_payload=case.base)
        return CaseResult(idx, "row-diff", detail="; ".join(diffs[:2]), json_payload=case.base)


