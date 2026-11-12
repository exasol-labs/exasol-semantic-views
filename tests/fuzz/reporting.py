"""Per-case and reproduction output for semantic fuzz campaigns."""

from __future__ import annotations

import json

from .cases import CaseResult


def print_result(result: CaseResult, good: set[str]) -> None:
    marker = "ok " if result.verdict in good else "FAIL"
    print(f"{marker} [{result.idx:03d}] {result.verdict:16s} {result.detail}")


def print_failures(failures: list[CaseResult]) -> None:
    if not failures:
        return
    print()
    print(f"{len(failures)} divergences — reproducible payloads below:")
    for result in failures:
        print(f"  --- case {result.idx} ({result.verdict}: {result.detail}) ---")
        print(f"  json:    {json.dumps(result.json_payload)}")
        if result.sql_text:
            print(f"  sem-sql: {result.sql_text}")
