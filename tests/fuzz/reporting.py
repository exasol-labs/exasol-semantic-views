"""Per-case and reproduction output for semantic fuzz campaigns."""

from __future__ import annotations

import json
from dataclasses import dataclass

from .cases import CaseLabel, CaseResult


@dataclass(frozen=True)
class FailureRecord:
    label: CaseLabel
    result: CaseResult


@dataclass(frozen=True)
class CampaignSummary:
    counts: dict[str, int]
    expected_counts: dict[str, int]
    rule_counts: dict[str, int]
    failures: list[FailureRecord]
    cases: int
    seed: int
    oracle_name: str
    database_free: bool
    generator_name: str = ""


def print_result(result: CaseResult, good: set[str]) -> None:
    marker = "ok " if result.verdict in good else "FAIL"
    print(f"{marker} [{result.idx:03d}] {result.verdict:16s} {result.detail}")


def print_summary(campaign: CampaignSummary) -> None:
    print()
    print("=" * 60)
    for verdict, count in campaign.counts.items():
        print(f"  {verdict:16s} {count}")
    if campaign.database_free:
        print("  expected outcomes: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.expected_counts.items())))
        print("  rules: " + ", ".join(
            f"{name}={count}" for name, count in sorted(campaign.rule_counts.items())))
    _print_failures(campaign)
    if not campaign.failures:
        print(f"\nAll {campaign.cases} cases matched under seed={campaign.seed}, "
              f"oracle={campaign.oracle_name}.")


def _print_failures(campaign: CampaignSummary) -> None:
    if not campaign.failures:
        return
    print()
    print(f"{len(campaign.failures)} divergences — reproducible payloads below:")
    for failure in campaign.failures:
        label, result = failure.label, failure.result
        print(f"  --- generator={campaign.generator_name} oracle={campaign.oracle_name} "
              f"seed={label.seed} case={label.idx} rule={label.rule} "
              f"({result.verdict}: {result.detail}) ---")
        if result.stage:
            print(f"  stage: {result.stage}")
        if result.exasol_error:
            print(f"  Exasol error: {result.exasol_error}")
        if result.rows:
            print(f"  rows: {result.rows}")
        if result.timings:
            print(f"  timings (seconds): {result.timings}")
        if result.expected:
            print(f"  expected: {result.expected}; actual: {result.actual}")
        print(f"  json:    {json.dumps(result.json_payload)}")
        if result.sql_text:
            print(f"  original SQL:  {result.sql_text}")
        if result.variant_sql:
            print(f"  variant SQL:   {result.variant_sql}")
        if result.minimized_sql:
            print(f"  minimized SQL: {result.minimized_sql}")
