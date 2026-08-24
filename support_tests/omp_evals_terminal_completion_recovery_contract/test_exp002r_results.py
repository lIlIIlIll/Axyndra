from __future__ import annotations

import json
import unittest
from pathlib import Path

from omp_evals.util import hash_file
from support_tests.omp_evals_terminal_completion_recovery_contract.execute_exp002r import (
    CONDITIONS,
    EXPERIMENT,
    FROZEN_HASHES,
)


class Exp002RResultIntegrityContract(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[2]
        self.experiment = self.root / "eval_experiments" / EXPERIMENT

    def load(self, name: str):
        return json.loads((self.experiment / name).read_text())

    def test_frozen_design_remains_byte_identical(self) -> None:
        self.assertEqual(
            {name: hash_file(self.root / name) for name in FROZEN_HASHES},
            FROZEN_HASHES,
        )

    def test_all_twelve_frozen_slots_are_unique_and_ordered(self) -> None:
        index = self.load("trial-index.json")
        slots = index["slots"]
        self.assertEqual(index["planned"], 12)
        self.assertEqual(index["executed"], 12)
        self.assertEqual(index["extraTrials"], 0)
        self.assertEqual([item["windowOrdinal"] for item in slots], list(range(12)))
        self.assertEqual(len({item["trialId"] for item in slots}), 12)
        self.assertEqual([item["conditionFingerprint"] for item in slots], [
            CONDITIONS[0], CONDITIONS[0], CONDITIONS[1], CONDITIONS[1],
            CONDITIONS[1], CONDITIONS[1], CONDITIONS[0], CONDITIONS[0],
            CONDITIONS[0], CONDITIONS[0], CONDITIONS[1], CONDITIONS[1],
        ])

    def test_runtime_failure_is_append_only_effective_validity(self) -> None:
        slots = self.load("trial-index.json")["slots"]
        self.assertEqual({item["storedValidity"] for item in slots}, {"Valid"})
        self.assertEqual(
            {item["effectiveValidity"] for item in slots},
            {"InvalidEnvironmentInfrastructure"},
        )
        self.assertEqual(
            {item["runtimeFailureCategory"] for item in slots},
            {"FrozenRuntimeClosureSymbolResolutionFailure"},
        )

    def test_target_recovery_mechanism_was_not_observed(self) -> None:
        analysis = self.load("attempt-recovery-analysis.json")
        self.assertFalse(analysis["targetMechanismObserved"])
        self.assertEqual(analysis["mechanismConclusion"], "Inconclusive")
        pooled = analysis["pooledDescriptive"]
        self.assertEqual(pooled["Control"]["modelAttempts"], 6)
        self.assertEqual(pooled["RecoveryV1"]["modelAttempts"], 6)
        self.assertEqual(pooled["RecoveryV1"]["recoveryTriggers"], 0)
        self.assertEqual(pooled["RecoveryV1"]["retryAttempts"], 0)

    def test_invalid_trials_have_no_agent_failure_attribution(self) -> None:
        failure = self.load("failure-analysis.json")
        self.assertEqual(failure["capabilityValidStrictFailures"], [])
        self.assertEqual(failure["agentFailureAttributions"], [])
        self.assertEqual(len(failure["infrastructureFailures"]), 12)

    def test_cleanup_and_candidate_cas_contract(self) -> None:
        slots = self.load("trial-index.json")["slots"]
        for item in slots:
            cleanup = item["workspaceDestruction"]
            self.assertFalse(cleanup["workerPidAlive"])
            self.assertFalse(cleanup["workspaceExists"])
            self.assertFalse(cleanup["ompHomeExists"])
            self.assertFalse(cleanup["tmpExists"])
            self.assertFalse(cleanup["buildExists"])
            self.assertTrue(cleanup["candidateCasExists"])

    def test_security_gate_and_secret_scan(self) -> None:
        preflight = self.load("real-execution-preflight.json")
        gate = preflight["credentialRotationGate"]
        self.assertEqual(gate["status"], "Verified")
        self.assertEqual(gate["source"], "user")
        self.assertFalse(gate["secret"])
        self.assertFalse(gate["credentialInspected"])
        scan = self.load("artifact-secret-scan.json")
        self.assertEqual(scan["matches"], 0)
        self.assertEqual(scan["result"], "Pass")

    def test_decision_is_inconclusive_and_experiment_invalidated(self) -> None:
        decision = self.load("real-execution-decision.json")
        self.assertEqual(decision["status"], "INCOMPLETE")
        self.assertEqual(decision["statusReason"], "EXPERIMENT_INVALIDATED")
        self.assertEqual(decision["mechanismConclusion"], "Inconclusive")
        self.assertEqual(decision["taskOutcomeConclusion"], "Inconclusive")
        self.assertEqual(decision["experimentDecision"], "Inconclusive")
        self.assertEqual(set(decision["postTrialOfflineProof"].values()), {0})


if __name__ == "__main__":
    unittest.main()
