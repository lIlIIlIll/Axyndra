from __future__ import annotations

import json
import unittest
from pathlib import Path

from omp_evals.util import hash_file
from support_tests.omp_evals_provider_settings_closure_contract.execute_exp001r6 import (
    A6, B6, FROZEN_HASHES, PROVIDER, SETTINGS, SNAPSHOT,
)


class Exp001R6ResultContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[2]
        self.experiment = self.root / "eval_experiments/EXP-001R6-provider-settings-closure-refreeze"

    def load(self, name: str):
        return json.loads((self.experiment / name).read_text())

    def test_frozen_inputs_remain_byte_identical(self) -> None:
        self.assertEqual(
            {name: hash_file(self.root / name) for name in FROZEN_HASHES},
            FROZEN_HASHES,
        )

    def test_all_six_frozen_slots_are_valid_and_unique(self) -> None:
        index = self.load("trial-index.json")
        self.assertEqual(len(index["slots"]), 6)
        self.assertEqual([item["slotLabel"] for item in index["slots"]], [
            "A6-1", "B6-1", "B6-2", "A6-2", "A6-3", "B6-3",
        ])
        self.assertEqual(len({item["trialId"] for item in index["slots"]}), 6)
        self.assertTrue(all(item["storedValidity"] == "Valid" for item in index["slots"]))
        self.assertTrue(all(item["effectiveValidity"] == "Valid" for item in index["slots"]))
        self.assertEqual(index["extraTrials"], 0)

    def test_provider_and_settings_identity_are_shared(self) -> None:
        index = self.load("trial-index.json")
        self.assertEqual({item["providerExecutionDigest"] for item in index["slots"]}, {PROVIDER})
        self.assertEqual({item["providerSettingsClosureDigest"] for item in index["slots"]}, {SETTINGS})

    def test_mechanism_result_is_raw_payload_backed(self) -> None:
        mechanism = self.load("mechanism-analysis.json")
        a = mechanism["conditions"]["A6"]
        b = mechanism["conditions"]["B6"]
        self.assertEqual((a["missingRequiredColonAttempts"], a["totalEditAttempts"]), (6, 6))
        self.assertEqual((b["missingRequiredColonAttempts"], b["totalEditAttempts"]), (0, 5))
        self.assertEqual((a["parserValidEditAttempts"], b["parserValidEditAttempts"]), (0, 5))
        self.assertEqual(mechanism["mechanismConclusion"], "Supported")
        self.assertTrue(all(
            attempt.get("rawPayload") and attempt.get("startedArtifactRef")
            for trial in mechanism["trials"] for attempt in trial["attempts"]
        ))

    def test_task_outcomes_keep_candidate_and_strict_separate(self) -> None:
        summary = self.load("aggregate-result.json")["experimentSummary"]
        self.assertEqual(summary["taskOutcome"]["A6"], {
            "candidateCorrect": 0, "planned": 3, "strictPass": 0, "valid": 3,
        })
        self.assertEqual(summary["taskOutcome"]["B6"], {
            "candidateCorrect": 3, "planned": 3, "strictPass": 1, "valid": 3,
        })
        self.assertEqual(summary["infrastructureInvalid"], 0)

    def test_failure_transition_moves_to_termination(self) -> None:
        report = self.load("failure-analysis.json")
        causes = [
            item["failure_attribution"]["primary"]
            for item in report["analyses"] if item.get("failure_attribution")
        ]
        self.assertEqual(causes.count("EditApplicationFailure"), 3)
        self.assertEqual(causes.count("AgentTerminationFailure"), 2)
        self.assertTrue(all(item["validity"] == "Valid" for item in report["analyses"]))

    def test_final_decision_and_offline_cutoff(self) -> None:
        decision = self.load("decision.json")
        self.assertEqual(decision["status"], "COMPLETE")
        self.assertEqual(decision["mechanismConclusion"], "Supported")
        self.assertEqual(decision["taskOutcomeConclusion"], "Improved")
        self.assertEqual(decision["productCorrectnessDecision"], "KeepAlignedContract")
        self.assertEqual(decision["experimentDecision"], "DesignNextBottleneckExperiment")
        self.assertEqual(set(decision["postTrialOfflineProof"].values()), {0})
        self.assertEqual(decision["canonicalInvariant"]["snapshotDigest"], SNAPSHOT)


if __name__ == "__main__":
    unittest.main()
