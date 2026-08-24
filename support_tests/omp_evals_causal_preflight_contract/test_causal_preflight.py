from __future__ import annotations

import json
import hashlib
import tempfile
import unittest
from pathlib import Path

from omp_evals.edit_causal import (
    EditCommandKind, EditFixEffect, EditRejectionCause, ReplayOutcome,
    classify_command, extract_historical_edit_attempts, fix_effect, rejection_cause,
)
from omp_evals.storage import ArtifactStore


class CausalPreflightContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omp-evals-causal-preflight-")
        self.addCleanup(temporary.cleanup)
        self.artifacts = ArtifactStore(Path(temporary.name) / "artifacts")

    def _attempt(self, payload: str, message: str = "unsupported hashline operation"):
        started = self.artifacts.put_json({
            "sequence": 10,
            "event": {"code": "tool.execution_started", "name": "edit", "call_id": "c1",
                      "arguments": {"input": payload}},
        })
        completed = self.artifacts.put_json({
            "sequence": 11,
            "event": {"code": "tool.execution_completed", "name": "edit", "call_id": "c1",
                      "is_error": True, "receipt_id": "op1",
                      "output": {"error": "edit.invalid_hashline", "message": message}},
        })
        return extract_historical_edit_attempts("trial", (started, completed), self.artifacts)[0]

    def test_raw_payload_extraction_is_exact(self):
        payload = "[src/a.cj#EC00]\nSWAP 5..=6\n+one\n+two"
        attempt = self._attempt(payload)
        self.assertEqual(attempt.raw_edit_payload.encode(), payload.encode())
        self.assertEqual(attempt.raw_model_arguments, {"input": payload})
        self.assertEqual(attempt.operation_id, "op1")

    def test_extraction_does_not_mutate_cas_artifacts(self):
        payload = "[src/a.cj#EC00]\nSWAP 5\n+x"
        attempt = self._attempt(payload)
        references = (attempt.started_artifact_ref, attempt.completed_artifact_ref)
        before = {
            reference: hashlib.sha256(self.artifacts.get_bytes(reference)).hexdigest()
            for reference in references if reference
        }
        extract_historical_edit_attempts("trial", references, self.artifacts)
        after = {
            reference: hashlib.sha256(self.artifacts.get_bytes(reference)).hexdigest()
            for reference in references if reference
        }
        self.assertEqual(before, after)

    def test_single_and_range_commands_are_classified_by_intent(self):
        self.assertEqual(classify_command("[a#EC00]\nSWAP 5:\n+x"), EditCommandKind.SWAP_SINGLE)
        self.assertEqual(classify_command("[a#EC00]\nSWAP 5..=6:\n+x"), EditCommandKind.SWAP_RANGE)
        self.assertEqual(classify_command("[a#EC00]\nSWAP 5\n+x"), EditCommandKind.SWAP_SINGLE)
        self.assertEqual(classify_command("[a#EC00]\nSWAP 5..=6\n+x"), EditCommandKind.SWAP_RANGE)

    def test_range_mismatch_replay_is_direct_fix(self):
        attempt = self._attempt("[a#EC00]\nSWAP 5..=6:\n+x")
        self.assertEqual(rejection_cause(attempt), EditRejectionCause.RANGE_GRAMMAR_MISMATCH)
        accepted = ReplayOutcome("Accepted", "Applied", candidate_changed=True)
        self.assertEqual(fix_effect(attempt.historical_outcome, accepted), EditFixEffect.DIRECT_FIX)

    def test_unrelated_stale_rejection_is_no_effect(self):
        attempt = self._attempt("[a#EC00]\nSWAP 5:\n+x", "stale hashline anchor")
        self.assertEqual(rejection_cause(attempt), EditRejectionCause.STALE_ANCHOR)
        rejected = ReplayOutcome("Rejected", "NotReached", "edit.stale_anchor", "stale hashline anchor")
        self.assertEqual(fix_effect(attempt.historical_outcome, rejected), EditFixEffect.NO_EFFECT)

    def test_error_feedback_only_is_enabling_not_direct(self):
        old = ReplayOutcome("Rejected", "NotReached", "edit.invalid_hashline", "bad")
        new = ReplayOutcome("Rejected", "NotReached", "edit.invalid_hashline", "bad; use SWAP N:")
        self.assertEqual(fix_effect(old, new, feedback_actionable=True), EditFixEffect.ENABLING_FIX)
        self.assertEqual(fix_effect(old, new, feedback_actionable=False), EditFixEffect.NO_EFFECT)

    def test_checked_in_preflight_preserves_offline_counts_and_prior_decision(self):
        repository = Path(__file__).resolve().parents[2]
        experiment = repository / "eval_experiments/EXP-001-edit-aci-contract-alignment"
        report = json.loads((experiment / "causal-preflight.json").read_text())
        prior_decision = json.loads((experiment / "decision.json").read_text())
        self.assertEqual(report["aggregate"]["totalEditAttempts"], 11)
        self.assertEqual(report["aggregate"]["rangeGrammarMismatchCount"], 0)
        self.assertEqual(report["aggregate"]["bFixCoverage"], {"NoEffect": 10})
        self.assertTrue(all(item["raw_edit_payload"] for item in report["attempts"]))
        self.assertTrue(report["offlineProof"]["databaseCountsUnchanged"])
        self.assertTrue(report["offlineProof"]["candidateArtifactsUnchanged"])
        self.assertEqual(report["offlineProof"]["newModelCalls"], 0)
        self.assertEqual(report["offlineProof"]["graderExecutions"], 0)
        self.assertEqual(prior_decision["decision"], "Inconclusive")
        self.assertEqual(report["paidExperimentDisposition"], "RedesignConditionB")


if __name__ == "__main__":
    unittest.main()
