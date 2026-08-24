from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from omp_evals.benchmark import (
    _experiment_invariants, _experiment_order, build_condition,
)
from omp_evals.failure_analysis import candidate_diagnostic, strict_outcome
from omp_evals.model import (
    AgentTermination, CachePolicy, CapabilityTag, EvalSuite, EvalSuiteTask,
    ExperimentDecision, GraderSeverity, ResourcePolicy, SuiteKind,
    TaskLifecycle, QualifiedEvalTask, jsonable,
)
from omp_evals.storage import EvalDatabase
from omp_evals.util import new_id, utc_now


class Exp001ContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omp-evals-exp001-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binary_a = self._binary("a", "baseline")
        self.binary_b = self._binary("b", "aligned")
        self.task = QualifiedEvalTask(
            id="midpoint", version="1", category="BugFix", prompt="fix midpoint",
            fixture="fixture", fixture_digest="fixture-digest", base_revision="fixture-v1",
            visible_constraints=(), resource_policy=ResourcePolicy(agent_wall_time_seconds=300),
            cache_policy=CachePolicy(), network_policy="ProviderOnly",
            graders=({"id":"targeted","version":"1","severity":"Gate"},),
            grader_bundle="hidden", task_fingerprint="same-task", qualification_fingerprint="q",
            bundle_root=str(self.root), lifecycle=TaskLifecycle.QUALIFIED,
            capabilities=(CapabilityTag.EXISTING_CODE_EDIT,),
        )
        self.condition_a = self._condition("a", self.binary_a, "N.=M")
        self.condition_b = self._condition("b", self.binary_b, "N..=M")

    def _binary(self, name: str, version: str) -> Path:
        path = self.root / f"agent-{name}"
        path.write_text(f"#!/bin/sh\necho {version}\n")
        path.chmod(0o755)
        return path

    def _condition(self, name: str, binary: Path, parser_range: str):
        path = self.root / f"condition-{name}.json"
        path.write_text(json.dumps({
            "id": f"condition-{name}", "version": "1", "provider": "fixture",
            "agentBinary": str(binary), "environmentClass": "same-environment",
            "toolDescriptionDigest": "same-description",
            "editAciContract": {
                "modelVisibleRange": "N..=M", "parserAcceptedRange": parser_range,
                "application": "same-atomic-application",
            },
        }))
        return build_condition(path, self.task, binary, None)

    def test_conditions_differ_only_by_edit_contract_binary_and_identity(self):
        self.assertNotEqual(self.condition_a.fingerprint, self.condition_b.fingerprint)
        self.assertNotEqual(
            self.condition_a.manifest["agentBinaryDigest"],
            self.condition_b.manifest["agentBinaryDigest"],
        )
        excluded = {"id", "agentBinaryDigest", "editAciContract"}
        a = {k:v for k,v in self.condition_a.manifest.items() if k not in excluded}
        b = {k:v for k,v in self.condition_b.manifest.items() if k not in excluded}
        self.assertEqual(a, b)
        self.assertEqual(self.condition_a.agent, self.condition_b.agent)

    def test_task_grader_budget_environment_and_interleaving_are_paired(self):
        invariants = _experiment_invariants(
            (self.task,), (self.condition_a, self.condition_b), paired=True,
        )
        self.assertEqual(invariants["taskFingerprints"], ["same-task"])
        self.assertEqual(invariants["environmentClass"], "same-environment")
        self.assertIn("same-task", invariants["graderSpecDigests"])
        self.assertIn("same-task", invariants["budgetDigests"])
        order = _experiment_order((self.task,), (self.condition_a, self.condition_b), 3, 1001)
        self.assertEqual(len(order), 6)
        self.assertEqual([x.condition_fingerprint for x in order].count(self.condition_a.fingerprint), 3)
        self.assertEqual([x.condition_fingerprint for x in order].count(self.condition_b.fingerprint), 3)
        self.assertEqual(
            [x.condition_fingerprint for x in order],
            [self.condition_a.fingerprint, self.condition_b.fingerprint,
             self.condition_b.fingerprint, self.condition_a.fingerprint,
             self.condition_a.fingerprint, self.condition_b.fingerprint],
        )

    def test_correct_candidate_timeout_remains_strict_fail(self):
        diagnostic = candidate_diagnostic("candidate", ({
            "grader_id": "targeted", "severity": GraderSeverity.GATE.value,
            "status": "Pass", "outcome_requirement": "TargetedBehavior",
        },))
        self.assertEqual(diagnostic.outcome.value, "Correct")
        self.assertEqual(
            strict_outcome("Valid", AgentTermination.TIMED_OUT.value, diagnostic).value, "Fail",
        )

    def test_experiment_decisions_are_immutable_and_versioned(self):
        database = EvalDatabase(self.root / "evals.db")
        self.addCleanup(database.close)
        first = ExperimentDecision(
            new_id("decision"), "experiment-1", "1", "Inconclusive", "first evidence",
            ("aggregate-v1",), ("one task",), None, utc_now(),
        )
        second = ExperimentDecision(
            new_id("decision"), "experiment-1", "2", "AdoptB", "more evidence",
            ("aggregate-v2",), ("one task",), "EXP-002", utc_now(),
        )
        database.save_experiment_decision(jsonable(first))
        database.save_experiment_decision(jsonable(second))
        self.assertEqual([x["version"] for x in database.experiment_decisions("experiment-1")], ["1", "2"])
        with self.assertRaises(Exception):
            database.save_experiment_decision(jsonable(first))


if __name__ == "__main__":
    unittest.main()
