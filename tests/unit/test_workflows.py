"""Check the wiring between the GitHub Actions workflows.

The static-checks job runs zizmor for workflow syntax and security audits. These
tests cover relationships that a valid individual workflow can still get wrong.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
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
        lanes = {"static-checks", "database-free", "dependency-audit", "system-tests",
                 "fuzz-smoke"}
        self.assertTrue(lanes)
        self.assertEqual(set(jobs["ci-gate"]["needs"]), lanes | {"sonar"})
        self.assertTrue(all(local_target(jobs[name]) for name in lanes))

    def test_pr_fuzz_runs_in_parallel_with_fixed_campaign(self) -> None:
        jobs = self.workflows["ci.yml"]["jobs"]
        smoke = jobs["fuzz-smoke"]
        self.assertEqual(local_target(smoke), "fuzz.yml")
        self.assertNotIn("needs", smoke)
        self.assertEqual(smoke["with"], {
            "seeds": "0 1 2 7 42", "cases": "100", "timeout_minutes": "30",
            "artifact_name": "fuzz-smoke-results",
        })

        fuzz = self.workflows["fuzz.yml"]
        self.assertEqual(set(fuzz["on"]["workflow_call"]["inputs"]),
                         set(smoke["with"]))
        campaign = next(step for step in fuzz["jobs"]["fuzz"]["steps"]
                        if "run_release_gate.sh --fuzz-only" in step.get("run", ""))
        self.assertIn("inputs.seeds", campaign["env"]["FUZZ_SEEDS"])
        self.assertIn("inputs.cases", campaign["env"]["FUZZ_CASES"])
        artifacts = [step["with"]["name"] for step in fuzz["jobs"]["fuzz"]["steps"]
                     if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertTrue(all("inputs.artifact_name" in name for name in artifacts))

    def test_fuzz_runner_includes_sqlglot_contract_for_each_seed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory)
            fake_python = location / "python"
            calls = location / "calls"
            fake_python.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FUZZ_CALLS"\n')
            fake_python.chmod(0o755)
            completed = subprocess.run(
                ["sh", "tools/run_release_gate.sh", "--fuzz-only"],
                cwd=ROOT, capture_output=True, text=True, check=False,
                env={**os.environ, "PYTHON_BIN": str(fake_python),
                     "FUZZ_SEEDS": "0 42", "FUZZ_CASES": "3", "FUZZ_CALLS": str(calls)},
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertEqual(calls.read_text().splitlines(), [
                f"tests/fuzz/run_semantic_fuzz.py --generator {generator} --oracle {oracle} "
                f"--seed {seed} --cases 3"
                for seed in (0, 42)
                for generator, oracle in (("handwritten", "differential"),
                                          ("handwritten", "tlp"),
                                          ("sqlglot", "contract"))
            ])

    def test_ci_gate_fails_for_failed_or_skipped_jobs(self) -> None:
        gate = self.workflows["ci.yml"]["jobs"]["ci-gate"]
        self.assertEqual(gate["if"], "${{ always() }}")
        script = gate["steps"][0]["run"]
        self.assertEqual(gate["steps"][0]["env"]["NEEDS_RESULTS"],
                         "${{ join(needs.*.result, ' ') }}")
        results = {name: {"result": "success"} for name in gate["needs"]}
        for state in ("success", "failure", "skipped", "cancelled"):
            results["fuzz-smoke"]["result"] = state
            completed = subprocess.run(
                ["bash", "-e", "-c", script], cwd=ROOT, capture_output=True, text=True,
                env={**os.environ, "NEEDS_RESULTS": " ".join(
                    job["result"] for job in results.values())}, check=False,
            )
            self.assertEqual(completed.returncode == 0, state == "success",
                             f"fuzz-smoke={state}: {completed.stdout}{completed.stderr}")

    def test_sonar_scans_after_both_coverage_jobs(self) -> None:
        jobs = self.workflows["ci.yml"]["jobs"]
        sonar = jobs["sonar"]
        self.assertEqual(set(sonar["needs"]), {"database-free", "system-tests"})
        self.assertEqual(local_target(sonar), "sonar.yml")
        steps = self.workflows["sonar.yml"]["jobs"]["sonar"]["steps"]
        self.assertTrue(any("sonarqube-scan-action@" in step.get("uses", "") for step in steps))
        self.assertTrue(any("coverage combine" in step.get("run", "") for step in steps))

        unit_steps = self.workflows["database-free.yml"]["jobs"]["database-free"]["steps"]
        system_steps = self.workflows["system-tests.yml"]["jobs"]["system-tests"]["steps"]
        self.assertTrue(any(step.get("with", {}).get("name") == "python-unit-coverage"
                            for step in unit_steps))
        self.assertTrue(any(step.get("with", {}).get("name") == "python-integration-coverage"
                            for step in system_steps))
        self.assertTrue(any("ESV_SYSTEM_COVERAGE=1" in step.get("run", "")
                            for step in system_steps))

    def test_release_waits_for_ci_and_fuzz(self) -> None:
        jobs = self.workflows["release.yml"]["jobs"]
        self.assertEqual(local_target(jobs["tests"]), "ci.yml")
        self.assertEqual(local_target(jobs["fuzz"]), "fuzz.yml")
        self.assertNotIn("with", jobs["fuzz"])
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
