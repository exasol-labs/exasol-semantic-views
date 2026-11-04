"""Check the wiring between the GitHub Actions workflows.

The static-checks job runs zizmor for workflow syntax and security audits. These
tests cover relationships that a valid individual workflow can still get wrong.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
LOCAL_PREFIXES = ("$/.github/workflows/", "./.github/workflows/")


def load_workflows() -> dict[str, dict]:
    # BaseLoader keeps GitHub's `on` key as a string (YAML 1.1 treats it as a
    # boolean) while still parsing the workflow structure.
    return {
        path.name: yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        for path in WORKFLOWS.glob("*.yml")
    }


def local_target(job: dict) -> str | None:
    uses = job.get("uses", "")
    for prefix in LOCAL_PREFIXES:
        if uses.startswith(prefix):
            return uses[len(prefix):]
    return None


class WorkflowWiringTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workflows = load_workflows()

    def test_jobs_that_check_out_code_disable_telemetry(self) -> None:
        for name, workflow in self.workflows.items():
            for job_name, job in workflow["jobs"].items():
                checks_out_code = any(
                    step.get("uses", "").startswith("actions/checkout@")
                    for step in job.get("steps", [])
                )
                if checks_out_code:
                    setting = job.get("env", {}).get(
                        "EXASOL_TELEMETRY_DISABLE",
                        workflow.get("env", {}).get("EXASOL_TELEMETRY_DISABLE"),
                    )
                    self.assertEqual(setting, "true", f"{name}:{job_name}")

    def test_local_workflow_calls_resolve_without_cycles(self) -> None:
        calls = {}
        for name, workflow in self.workflows.items():
            targets = set()
            for job_name, job in workflow["jobs"].items():
                target = local_target(job)
                if target is None:
                    continue
                self.assertIn(target, self.workflows, f"{name}:{job_name} calls missing workflow")
                self.assertIn("workflow_call", self.workflows[target]["on"],
                              f"{name}:{job_name} calls a workflow without workflow_call")
                targets.add(target)
            calls[name] = targets

        visiting = set()
        visited = set()

        def visit(name: str) -> None:
            self.assertNotIn(name, visiting, f"cycle in workflow calls at {name}")
            if name in visited:
                return
            visiting.add(name)
            for target in calls[name]:
                visit(target)
            visiting.remove(name)
            visited.add(name)

        for name in calls:
            visit(name)

    def test_ci_gate_waits_for_every_reusable_lane(self) -> None:
        jobs = self.workflows["ci.yml"]["jobs"]
        lanes = set(jobs) - {"ci-gate"}
        self.assertTrue(lanes)
        self.assertEqual(set(jobs["ci-gate"]["needs"]), lanes)
        self.assertTrue(all(local_target(jobs[name]) for name in lanes))

    def test_release_waits_for_ci_and_fuzz(self) -> None:
        jobs = self.workflows["release.yml"]["jobs"]
        self.assertEqual(local_target(jobs["tests"]), "ci.yml")
        self.assertEqual(local_target(jobs["fuzz"]), "fuzz.yml")
        self.assertEqual(jobs["fuzz"]["needs"], "tests")
        self.assertEqual(set(jobs["release"]["needs"]), {"tests", "fuzz"})

    def test_standalone_workflows_keep_their_triggers(self) -> None:
        self.assertIn("pull_request", self.workflows["ci.yml"]["on"])
        self.assertIn("push", self.workflows["ci.yml"]["on"])
        self.assertIn("workflow_dispatch", self.workflows["ci.yml"]["on"])
        self.assertIn("workflow_dispatch", self.workflows["fuzz.yml"]["on"])
        self.assertIn("schedule", self.workflows["dependency-audit.yml"]["on"])
        self.assertEqual(self.workflows["release.yml"]["on"]["push"]["tags"], ["v*"])


if __name__ == "__main__":
    unittest.main()
