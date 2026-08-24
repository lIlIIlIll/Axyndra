from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EXP002 = ROOT / "eval_experiments/EXP-002-terminal-completion-causal-preflight"


class Exp002ArtifactContractTests(unittest.TestCase):
    def _load(self, name):
        return json.loads((EXP002 / name).read_text())

    def test_offline_counts_and_source_candidates_are_unchanged(self):
        manifest = self._load("manifest.json")
        self.assertEqual(manifest["providerRequests"], 0)
        self.assertEqual(manifest["modelCalls"], 0)
        self.assertEqual(manifest["agentTrials"], 0)
        self.assertEqual(manifest["graderReruns"], 0)
        self.assertEqual(manifest["candidateMutations"], 0)
        self.assertEqual(manifest["databaseCountsBefore"], manifest["databaseCountsAfter"])
        self.assertTrue(manifest["sourceCandidateDigestsUnchanged"])

    def test_r6_artifacts_match_recorded_immutable_hashes(self):
        source = self._load("source-experiment-ref.json")
        for relative, expected in source["immutableArtifactSha256"].items():
            actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
            self.assertEqual(actual, expected, relative)

    def test_timeout_findings_preserve_high_level_agent_termination_failure(self):
        analysis = self._load("terminal-completion-analysis.json")
        self.assertEqual(analysis["highLevelFailureAttributionPreserved"], "AgentTerminationFailure")
        for label in ("B6-1", "B6-3"):
            finding = analysis["findings"][label]
            self.assertEqual(finding["termination"], "AgentTimedOut")
            self.assertEqual(finding["mechanism"], "FinalResponseStreamingIncompleteAtDeadline")
            self.assertEqual(finding["primary"], "IncompleteFinalModelAttemptAtDeadline")
            self.assertEqual(finding["pendingToolCallIds"], [])
        self.assertEqual(analysis["findings"]["B6-2"]["mechanism"], "CompletedControl")

    def test_cluster_and_recommendation_are_single_and_not_executed(self):
        causal = self._load("causal-assessment.json")
        recommendation = self._load("recommended-experiment.json")
        self.assertEqual(causal["clusterAssessment"], "SameCluster")
        self.assertEqual(causal["assessment"], "Strong")
        self.assertEqual(recommendation["independentVariable"], "FinalResponseAttemptRecoveryPolicy")
        self.assertFalse(recommendation["executionAuthorized"])

    def test_new_artifacts_do_not_contain_secret_bearing_fields(self):
        forbidden = ('"authorization"', '"api_key"', '"apikey"', '"credentialvalue"')
        for path in EXP002.glob("*.json"):
            lowered = path.read_text().lower()
            for marker in forbidden:
                self.assertNotIn(marker, lowered, path.name)


if __name__ == "__main__":
    unittest.main()
