"""Per-case and reproduction output for semantic fuzz campaigns."""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from typing import Protocol, TextIO

from .cases import CaseResult, FuzzCase


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


class ResultPrinter(Protocol):
    def case(self, case: FuzzCase, result: CaseResult, good: set[str]) -> None: ...

    def summary(self, campaign: CampaignSummary) -> None: ...


def _print_summary(campaign: CampaignSummary, output: TextIO) -> None:
    print(file=output)
    print("=" * 60, file=output)
    for verdict, count in campaign.counts.items():
        if verdict == "contract-mismatch" and not campaign.database_free:
            continue
        print(f"  {verdict:16s} {count}", file=output)
    if campaign.database_free:
        print("  expected outcomes: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.expected_counts.items())),
            file=output)
        print("  rules: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.rule_counts.items())),
            file=output)
    if not campaign.failures:
        print(f"\nAll {campaign.cases} cases matched under seed={campaign.seed}, "
              f"oracle={campaign.oracle_name}.", file=output)


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


class HumanResultPrinter:
    def case(self, case: FuzzCase, result: CaseResult, good: set[str]) -> None:
        marker = "ok " if result.verdict in good else "FAIL"
        print(f"{marker} [{result.idx:03d}] {result.verdict:16s} {result.detail}")

    def summary(self, campaign: CampaignSummary) -> None:
        _print_summary(campaign, sys.stdout)
        _print_failures(campaign.failures)


class JsonlResultPrinter:
    def case(self, case: FuzzCase, result: CaseResult, good: set[str]) -> None:
        print(json.dumps({"seed": case.label.seed, "index": case.label.idx,
                          "rule": case.label.rule, "original_sql": result.sql_text,
                          "expected": result.expected, "actual": result.actual,
                          "verdict": result.verdict,
                          "minimized_sql": result.minimized_sql}))

    def summary(self, campaign: CampaignSummary) -> None:
        _print_summary(campaign, sys.stderr)
