from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXP = ROOT / "eval_experiments/EXP-003-controlled-incomplete-stream-recovery"


class Exp003ResultContract(unittest.TestCase):
    def test_all_frozen_slots_have_one_valid_manipulation(self) -> None:
        index = load("trial-index.json")
        self.assertEqual((index["planned"], index["executed"], index["extraTrials"]), (10, 10, 0))
        self.assertEqual(len(index["slots"]), 10)
        self.assertEqual({item["slot"] for item in index["slots"]}, set(range(10)))
        self.assertTrue(all(item["authoritativeValidity"] == "Valid" for item in index["slots"]))
        self.assertTrue(all(item["manipulationValidity"] == "ValidInjectedFault"
                            for item in index["slots"]))

    def test_typed_recovery_mechanism_and_safety_result_are_separate(self) -> None:
        aggregate = load("aggregate-result.json")
        attempts = aggregate["attemptRecovery"]
        self.assertEqual(attempts["Control"]["recoveryTriggeredRate"], metric(0, 5))
        self.assertEqual(attempts["RecoveryV1"]["recoveryTriggeredRate"], metric(5, 5))
        self.assertEqual(attempts["RecoveryV1"]["retrySuccessRate"], metric(5, 5))
        self.assertEqual(aggregate["safety"]["partialCanonicalLeakRate"], metric(10, 10))
        self.assertEqual(aggregate["transportRecoverySubmechanism"], "Supported")
        self.assertEqual(aggregate["mechanismValidity"], "NotSupported")
        self.assertEqual(aggregate["safetyValidity"], "ViolationObserved")
        self.assertEqual(aggregate["experimentDecision"], "MechanismRejected")

    def test_task_outcomes_and_offline_proof_are_persisted(self) -> None:
        aggregate = load("aggregate-result.json")
        self.assertEqual(aggregate["outcomes"]["Control"]["candidateCorrectRate"], metric(0, 5))
        self.assertEqual(aggregate["outcomes"]["RecoveryV1"]["candidateCorrectRate"], metric(4, 5))
        self.assertEqual(aggregate["outcomes"]["Control"]["strictPassRate"], metric(0, 5))
        self.assertEqual(aggregate["outcomes"]["RecoveryV1"]["strictPassRate"], metric(2, 5))
        decision = load("real-execution-decision.json")
        self.assertEqual(decision["executionStatus"], "COMPLETE")
        self.assertEqual(set(decision["postTrialOfflineProof"].values()), {0})
        self.assertEqual(load("artifact-secret-scan.json")["matches"], 0)


def load(name: str) -> dict:
    return json.loads((EXP / name).read_text())


def metric(numerator: int, denominator: int) -> dict:
    return {"numerator": numerator, "denominator": denominator,
            "rate": numerator / denominator if denominator else None}


if __name__ == "__main__":
    unittest.main()
