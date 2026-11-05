#!/usr/bin/env python3
"""The AGENT_READINESS vocabulary in docs/agent-contract.md is the view's.

MODELS_FOR_AGENT decides AGENT_READINESS in one CASE expression. The contract
once named two of its six values, and an agent guard written against the
documented set rejected every model of a fully agent-ready deployment. This
test reads the values from the view and the table from the doc, so a value
added to one and not the other fails here. It also holds the doc's
"agent-ready" column to the set VERIFIED_QUERIES_FOR_AGENT serves.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT_VIEWS = (ROOT / "sql/install/006_create_semantic_agent_views.sql").read_text(encoding="utf-8")
CONTRACT = (ROOT / "docs/agent-contract.md").read_text(encoding="utf-8")


def view_vocabulary() -> list[str]:
    case = re.search(r"CASE\s+(.*?)\s+END AS AGENT_READINESS", AGENT_VIEWS, re.DOTALL)
    assert case, "MODELS_FOR_AGENT no longer decides AGENT_READINESS in a CASE"
    return re.findall(r"(?:THEN|ELSE)\s+'([A-Z_]+)'", case.group(1))


def served_vocabulary() -> set[str]:
    served = re.search(r"o\.AGENT_READINESS IN \(([^)]*)\)", AGENT_VIEWS)
    assert served, "VERIFIED_QUERIES_FOR_AGENT no longer filters on AGENT_READINESS"
    return set(re.findall(r"'([A-Z_]+)'", served.group(1)))


def documented_vocabulary() -> dict[str, bool]:
    rows = re.findall(r"^\| `([A-Z_]+)` \|.*\| (yes|no) \|$", CONTRACT, re.MULTILINE)
    return {value: ready == "yes" for value, ready in rows}


class AgentReadinessVocabularyTest(unittest.TestCase):
    def test_the_contract_lists_every_value_the_view_returns(self) -> None:
        self.assertEqual(list(documented_vocabulary()), view_vocabulary())

    def test_the_contract_calls_ready_what_verified_queries_serve(self) -> None:
        ready = {value for value, is_ready in documented_vocabulary().items() if is_ready}
        self.assertEqual(ready, served_vocabulary())


if __name__ == "__main__":
    unittest.main()
