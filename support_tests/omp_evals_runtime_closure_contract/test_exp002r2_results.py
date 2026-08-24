from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT = ROOT / "eval_experiments/EXP-002R2-runtime-closure-refreeze"


class Exp002R2ResultContract(unittest.TestCase):
    def load(self, name: str):
        return json.loads((EXPERIMENT / name).read_text())

    def test_all_frozen_slots_are_valid_and_unique(self) -> None:
        value = self.load("trial-index.json")
        self.assertEqual((value["planned"], value["executed"], value["extraTrials"]), (12, 12, 0))
        self.assertEqual(len(value["slots"]), 12)
        self.assertEqual(len({item["trialId"] for item in value["slots"]}), 12)
        self.assertEqual({item["authoritativeValidity"] for item in value["slots"]}, {"Valid"})

    def test_primary_results_are_task_stratified(self) -> None:
        midpoint = self.load("task-results-midpoint.json")["conditions"]
        clamp = self.load("task-results-clamp.json")["conditions"]
        for condition in ("Control", "RecoveryV1"):
            self.assertEqual(midpoint[condition]["candidateCorrectRate"], {"numerator": 0, "denominator": 3, "rate": 0.0})
            self.assertEqual(clamp[condition]["candidateCorrectRate"], {"numerator": 3, "denominator": 3, "rate": 1.0})
            self.assertEqual(clamp[condition]["strictPassRate"], {"numerator": 1, "denominator": 3, "rate": 1 / 3})

    def test_no_live_recovery_trigger_means_inconclusive(self) -> None:
        attempts = self.load("attempt-recovery-analysis.json")
        treatment = attempts["pooledDescriptive"]["RecoveryV1"]
        self.assertEqual(treatment["recoveryTriggers"], 0)
        self.assertIsNone(treatment["retrySuccessRate"]["rate"])
        self.assertEqual(attempts["mechanismConclusion"], "Inconclusive")
        self.assertEqual(self.load("real-execution-decision.json")["experimentDecision"], "Inconclusive")

    def test_safety_and_secret_structure(self) -> None:
        safety = self.load("safety-analysis.json")
        for key in (
            "duplicateToolExecutionCount", "duplicateEditApplicationCount",
            "duplicateCandidateMutationCount", "canonicalPartialResponseLeakCount",
            "retryInputDriftCount", "retryAfterCancellationCount",
            "retryAfterGlobalDeadlineCount", "retryCountOverflowCount",
        ):
            self.assertEqual(safety[key], 0)
        self.assertFalse(safety["liveRetrySafetyExercised"])
        self.assertEqual(self.load("artifact-secret-scan.json")["matches"], 0)

    def test_frozen_integrity_and_offline_proof(self) -> None:
        self.assertEqual(self.load("frozen-integrity-verification.json")["result"], "Pass")
        proof = self.load("real-execution-decision.json")["postTrialOfflineProof"]
        self.assertEqual(set(proof.values()), {0})


if __name__ == "__main__":
    unittest.main()
