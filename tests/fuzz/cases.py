"""Typed inputs and results shared by semantic fuzz generators and oracles."""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Literal, Protocol, TypeAlias


class Profile(str, Enum):
    """The input shape a generator can provide and an oracle can accept."""

    def __new__(cls, value: str, description: str) -> Profile:
        member = str.__new__(cls, value)
        member._value_ = value
        member.__doc__ = description
        return member

    LABELLED_SQL = ("labelled-sql", "One Semantic SQL statement with an expected compiler outcome.")
    PAIRED = ("paired-json-sql", "Equivalent JSON request and Semantic SQL statement.")
    JSON_TLP = ("four-json-tlp", "Base, predicate, complement, and NULL partition as JSON requests.")
    PAIRED_TLP = ("four-paired-tlp", "The same four TLP variants, each with JSON and Semantic SQL.")
    REFERENCE = ("sql-reference", "Semantic SQL with an independently written reference query.")


@dataclass(frozen=True)
class CaseLabel:
    seed: int
    idx: int
    shape: str = ""
    rule: str = ""
    syntax_intent: str = "valid"
    expected_status: Literal["ACCEPT", "REJECT"] | None = None
    expected_code: str | None = None


@dataclass
class Filter:
    field: str
    op: str
    value: Any = None


@dataclass
class OrderBy:
    field: str
    direction: str


@dataclass
class HavingClause:
    field: str
    op: str
    value: float | int


@dataclass
class Spec:
    dimensions: list[str] = field(default_factory=list)
    metrics: list[str] = field(default_factory=list)
    filters: list[Filter] = field(default_factory=list)
    having: list[HavingClause] = field(default_factory=list)
    order_by: list[OrderBy] = field(default_factory=list)
    limit: int | None = None


@dataclass
class TlpCase:
    group_dim: str
    metric: str
    partition_dim: str
    predicate: Filter


@dataclass(frozen=True)
class LabelledSqlCase:
    label: CaseLabel
    sql: str
    control_sql: str | None = None
    variant_sql: str | None = None
    shrink_candidates: tuple[str, ...] = ()
    profile: Profile = field(default=Profile.LABELLED_SQL, init=False)


@dataclass(frozen=True)
class PairedCase:
    label: CaseLabel
    json_payload: dict[str, Any]
    sql: str
    profile: Profile = field(default=Profile.PAIRED, init=False)


@dataclass(frozen=True)
class JsonTlpCase:
    label: CaseLabel
    base: dict[str, Any]
    predicate: dict[str, Any]
    complement: dict[str, Any]
    null: dict[str, Any]
    profile: Profile = field(default=Profile.JSON_TLP, init=False)


@dataclass(frozen=True)
class PairedTlpCase:
    label: CaseLabel
    base: PairedCase
    predicate: PairedCase
    complement: PairedCase
    null: PairedCase
    profile: Profile = field(default=Profile.PAIRED_TLP, init=False)


@dataclass(frozen=True)
class ReferenceCase:
    label: CaseLabel
    sql: str
    reference_sql: str
    expected_code: str | None = None
    profile: Profile = field(default=Profile.REFERENCE, init=False)


FuzzCase: TypeAlias = LabelledSqlCase | PairedCase | JsonTlpCase | PairedTlpCase | ReferenceCase


@dataclass(frozen=True)
class CaseResult:
    idx: int
    verdict: str
    detail: str = ""
    json_payload: dict[str, Any] | None = None
    sql_text: str | None = None
    seed: int | None = None
    rule: str = ""
    expected: str = ""
    actual: str = ""
    minimized_sql: str | None = None
    variant_sql: str | None = None
    stage: str = ""
    exasol_error: str = ""
    rows: str = ""
    timings: str = ""


class Generator(Protocol):
    name: str
    profiles: frozenset[Profile]

    def generate(self, rng: random.Random, profile: Profile, seed: int, idx: int) -> FuzzCase: ...


class Oracle(Protocol):
    name: str
    accepted_profiles: tuple[Profile, ...]
    database_free: bool

    def run(self, backend: Any, case: FuzzCase, verbose: bool) -> CaseResult: ...


def validate_case(case: FuzzCase, profile: Profile) -> None:
    """Reject malformed generator output before either backend is started."""
    if case.profile != profile:
        raise ValueError(f"case {case.label.idx}: expected {profile.value}, got {case.profile.value}")
    if isinstance(case, LabelledSqlCase):
        if not case.sql.strip() or case.label.expected_status is None:
            raise ValueError(f"case {case.label.idx}: labelled SQL needs SQL and an expected status")
        if case.label.expected_status == "REJECT" and not case.label.expected_code:
            raise ValueError(f"case {case.label.idx}: REJECT needs an expected error code")
        if case.label.syntax_intent == "valid" and case.label.expected_status == "REJECT" \
                and not case.control_sql:
            raise ValueError(f"case {case.label.idx}: semantic rejection needs an accepted control")
    elif isinstance(case, PairedCase):
        if not case.json_payload or not case.sql.strip():
            raise ValueError(f"case {case.label.idx}: paired case needs JSON and SQL")
    elif isinstance(case, (JsonTlpCase, PairedTlpCase)):
        for name in ("base", "predicate", "complement", "null"):
            value = getattr(case, name)
            if isinstance(case, PairedTlpCase) and isinstance(value, PairedCase):
                validate_case(value, Profile.PAIRED)
            elif isinstance(case, JsonTlpCase) and isinstance(value, dict) and value:
                continue
            else:
                raise ValueError(f"case {case.label.idx}: invalid or missing TLP variant {name}")
    elif isinstance(case, ReferenceCase):
        if not case.sql.strip() or not (case.reference_sql.strip() or case.expected_code):
            raise ValueError(f"case {case.label.idx}: SQL and reference or refusal required")
