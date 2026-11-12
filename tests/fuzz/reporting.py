"""Per-case and reproduction output for semantic fuzz campaigns."""

from __future__ import annotations

import json
from dataclasses import dataclass

from .cases import CaseResult


@dataclass(frozen=True)
class CampaignSummary:
    counts: dict[str, int]
    expected_counts: dict[str, int]
    rule_counts: dict[str, int]
    failures: list[CaseResult]
    cases: int
    seed: int
    oracle_name: str
    database_free: bool


def print_result(result: CaseResult, good: set[str]) -> None:
    marker = "ok " if result.verdict in good else "FAIL"
    print(f"{marker} [{result.idx:03d}] {result.verdict:16s} {result.detail}")


def print_summary(campaign: CampaignSummary) -> None:
    print()
    print("=" * 60)
    for verdict, count in campaign.counts.items():
        if verdict == "contract-mismatch" and not campaign.database_free:
            continue
        print(f"  {verdict:16s} {count}")
    if campaign.database_free:
        print("  expected outcomes: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.expected_counts.items())))
        print("  rules: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.rule_counts.items())))
    _print_failures(campaign.failures)
    if not campaign.failures:
        print(f"\nAll {campaign.cases} cases matched under seed={campaign.seed}, "
              f"oracle={campaign.oracle_name}.")


def _print_failures(failures: list[CaseResult]) -> None:
    if not failures:
        return
    print()
    print(f"{len(failures)} divergences — reproducible payloads below:")
    for result in failures:
        print(f"  --- seed={result.seed} case={result.idx} rule={result.rule} "
              f"({result.verdict}: {result.detail}) ---")
        if result.expected:
            print(f"  expected: {result.expected}; actual: {result.actual}")
        print(f"  json:    {json.dumps(result.json_payload)}")
        if result.sql_text:
            print(f"  original SQL:  {result.sql_text}")
            print(f"  minimized SQL: {result.minimized_sql or result.sql_text}")
