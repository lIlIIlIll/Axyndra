from __future__ import annotations

import json
import unittest
from pathlib import Path

from omp_evals.edit_causal import (
    EditSyntaxViolation, analyze_candidate_edit_syntax, syntax_violation,
)
from omp_evals.storage import ArtifactStore
from omp_evals.failure_analysis import candidate_diagnostic, strict_outcome
from omp_evals.model import AgentTermination, GraderSeverity


class Exp001RContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(__file__).resolve().parents[2]
        cls.experiment = cls.root / "eval_experiments/EXP-001R-edit-aci-model-contract-alignment"
        cls.a = cls._load("condition-a2.json")
        cls.b = cls._load("condition-b2.json")
        cls.verification = cls._load("deterministic-verification.json")

    @classmethod
    def _load(cls, name):
        return json.loads((cls.experiment / name).read_text())

    def test_shared_parser_application_and_schema_identity(self):
        for name in ("parserDigest", "applicationDigest", "toolSchemaDigest"):
            self.assertEqual(self.a["manifest"][name], self.b["manifest"][name], name)
        self.assertTrue(self.verification["controlledVariableChecks"]["sourceDiffLimited"])

    def test_only_edit_model_contract_differs_in_controlled_manifest(self):
        self.assertNotEqual(
            self.a["manifest"]["editModelContractDigest"],
            self.b["manifest"]["editModelContractDigest"],
        )
        excluded = {
            "id", "agentBinaryDigest", "agentBinaryArtifactRef", "toolDescriptionDigest",
            "editModelContractDigest", "editAciContract",
        }
        a = {key: value for key, value in self.a["manifest"].items() if key not in excluded}
        b = {key: value for key, value in self.b["manifest"].items() if key not in excluded}
        self.assertEqual(a, b)

    def test_a2_examples_reject_as_missing_colon_and_b2_examples_accept(self):
        self.assertEqual(
            {value["syntaxViolation"] for value in self.verification["a2MalformedExamples"].values()},
            {"MissingRequiredColon"},
        )
        self.assertTrue(all(
            value["outcome"] == "Accepted"
            for value in self.verification["b2DocumentedExamples"].values()
        ))

    def test_error_recovery_is_aligned_only_in_b2(self):
        self.assertTrue(all(
            not value["a2ShowsRequiredColon"] and value["b2ShowsRequiredColon"]
            for value in self.verification["errorRecovery"].values()
        ))

    def test_missing_required_colon_detection_has_no_false_positive(self):
        self.assertEqual(
            syntax_violation("[a#EC00]\nSWAP 5\n+x"),
            EditSyntaxViolation.MISSING_REQUIRED_COLON,
        )
        self.assertIsNone(syntax_violation("[a#EC00]\nSWAP 5:\n+x"))
        self.assertIsNone(syntax_violation("[a#EC00]\nDEL 5"))

    def test_offline_candidate_metric_reads_operations_without_execution(self):
        import tempfile
        with tempfile.TemporaryDirectory(prefix="exp001r-metric-") as temporary:
            artifacts = ArtifactStore(Path(temporary) / "artifacts")
            started = artifacts.put_json({"sequence": 1, "event": {
                "code": "tool.execution_started", "name": "edit", "call_id": "c",
                "arguments": {"input": "[a#EC00]\nSWAP 5\n+x"},
            }})
            completed = artifacts.put_json({"sequence": 2, "event": {
                "code": "tool.execution_completed", "name": "edit", "call_id": "c",
                "is_error": True, "output": {"error": "edit.invalid_hashline",
                "message": "unsupported hashline operation: SWAP 5"},
            }})
            metrics = analyze_candidate_edit_syntax(
                "trial", {"operation_refs": [started, completed]}, artifacts,
            )
            self.assertEqual(metrics["missingRequiredColonAttempts"], 1)
            self.assertEqual(metrics["trialsWithMissingRequiredColon"], 1)
            self.assertEqual(metrics["modelCalls"], 0)
            self.assertEqual(metrics["graderExecutions"], 0)

    def test_paired_plan_freezes_three_interleaved_trials_each(self):
        plan = self._load("experiment-plan.json")
        order = [item["conditionFingerprint"] for item in plan["order"]]
        self.assertEqual(len(order), 6)
        self.assertEqual(order.count(self.a["fingerprint"]), 3)
        self.assertEqual(order.count(self.b["fingerprint"]), 3)
        self.assertEqual(order, [
            self.a["fingerprint"], self.b["fingerprint"], self.b["fingerprint"],
            self.a["fingerprint"], self.a["fingerprint"], self.b["fingerprint"],
        ])

    def test_candidate_correct_timeout_remains_strict_fail(self):
        diagnostic = candidate_diagnostic("candidate", ({
            "grader_id": "targeted", "severity": GraderSeverity.GATE.value,
            "status": "Pass", "outcome_requirement": "TargetedBehavior",
        },))
        self.assertEqual(diagnostic.outcome.value, "Correct")
        self.assertEqual(
            strict_outcome("Valid", AgentTermination.TIMED_OUT.value, diagnostic).value, "Fail",
        )

    def test_parent_exp001_is_referenced_not_overwritten(self):
        parent = self._load("parent-evidence.json")
        self.assertEqual(parent["parentExperiment"], "EXP-001-edit-aci-contract-alignment")
        self.assertEqual(parent["causalLinkAssessment"], "Contradicted")
        self.assertEqual(
            json.loads((self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/decision.json").read_text())["decision"],
            "Inconclusive",
        )

    def test_preflight_is_offline_and_paid_trials_are_not_fabricated(self):
        manifest = self._load("manifest.json")
        trials = self._load("trial-index.json")
        self.assertEqual(manifest["status"], "ReadyForRealExecution")
        self.assertEqual(trials["completedTrials"], [])
        self.assertEqual(manifest["offlineProof"], {
            "modelCalls": 0, "agentTrials": 0, "graderExecutions": 0, "candidateMutations": 0,
        })


if __name__ == "__main__":
    unittest.main()
