from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from omp_evals.failure_analysis import OfflineFailureAnalyzer
from omp_evals.model import (
    AgentTermination, AgentTrial, CachePolicy, CandidateOutcome, CandidateSnapshot,
    EvalResult, EvalVerdict, FailureClassification, GraderResult, GraderSeverity,
    GraderStatus, OutcomeRequirement, ResourcePolicy, StrictEvalOutcome, TrialPlan,
    TrialState, TrialValidity, jsonable,
)
from omp_evals.storage import ArtifactStore, EvalDatabase


class FailureAnalysisContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="omp-evals-failure-analysis-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.database = EvalDatabase(self.root / "evals.db")
        self.addCleanup(self.database.close)
        self.artifacts = ArtifactStore(self.root / "artifacts")
        self.analyzer = OfflineFailureAnalyzer(self.database, self.artifacts)

    def _record(
        self, trial_id: str, termination: AgentTermination, grader_status: GraderStatus,
        validity: TrialValidity = TrialValidity.VALID,
    ) -> None:
        plan = TrialPlan(
            trial_id, "task", "agent", "environment", 0, ResourcePolicy(), CachePolicy(),
            "Denied", {}, {}, "2026-01-01T00:00:00Z",
        )
        candidate_id = None if validity != TrialValidity.VALID else f"candidate-{trial_id}"
        trial = AgentTrial(
            trial_id, plan, TrialState.COMPLETED, "2026-01-01T00:00:00Z",
            "2026-01-01T00:00:01Z", termination, validity, candidate_id, (), 123,
        )
        self.database.save_trial(jsonable(trial))
        if candidate_id is None:
            return
        trajectory = "\n".join((
            json.dumps({"sequence": 1, "event": {"code": "model.completed"}}),
            json.dumps({"sequence": 2, "event": {
                "code": "tool.execution_completed", "name": "edit", "is_error": False,
            }}),
        )) + "\n"
        common = self.artifacts.put_text("")
        snapshot = CandidateSnapshot(
            candidate_id, trial_id, "base", "final", common, common, common, common,
            self.artifacts.put_text(trajectory), (), common, common, {}, termination, (),
            "2026-01-01T00:00:01Z",
        )
        self.database.save_candidate(snapshot)
        grader = GraderResult(
            "targeted", grader_status, GraderSeverity.GATE, None, (), {}, "v1", 1,
            OutcomeRequirement.TARGETED_BEHAVIOR,
        )
        verdict = (
            EvalVerdict.PASS if termination == AgentTermination.COMPLETED and
            grader_status == GraderStatus.PASS else EvalVerdict.FAIL
        )
        result = EvalResult(
            trial_id, candidate_id, verdict, validity, (grader,),
            {"model_calls": 1, "tool_calls": 1}, {"agentMillis": 1000},
        )
        self.database.save_eval_result(trial_id, jsonable(result))

    def _analysis(self, trial_id: str):
        return self.analyzer.analyze(trial_id, persist=False).analyses[0]

    def test_outcome_matrix_keeps_candidate_and_termination_orthogonal(self):
        cases = (
            ("timeout-correct", AgentTermination.TIMED_OUT, GraderStatus.PASS,
             StrictEvalOutcome.FAIL, CandidateOutcome.CORRECT,
             FailureClassification.AGENT_TERMINATION_FAILURE),
            ("timeout-incorrect", AgentTermination.TIMED_OUT, GraderStatus.FAIL,
             StrictEvalOutcome.FAIL, CandidateOutcome.INCORRECT,
             FailureClassification.UNCLASSIFIED_VALID_FAILURE),
            ("completed-correct", AgentTermination.COMPLETED, GraderStatus.PASS,
             StrictEvalOutcome.PASS, CandidateOutcome.CORRECT, None),
            ("completed-incorrect", AgentTermination.COMPLETED, GraderStatus.FAIL,
             StrictEvalOutcome.FAIL, CandidateOutcome.INCORRECT,
             FailureClassification.UNCLASSIFIED_VALID_FAILURE),
        )
        for trial_id, termination, status, strict, candidate, failure in cases:
            with self.subTest(trial_id=trial_id):
                self._record(trial_id, termination, status)
                analysis = self._analysis(trial_id)
                self.assertEqual(analysis.strict_outcome, strict)
                self.assertEqual(analysis.candidate_diagnostic.outcome, candidate)
                self.assertEqual(analysis.termination, termination)
                actual = analysis.failure_attribution.primary if analysis.failure_attribution else None
                self.assertEqual(actual, failure)

    def test_infrastructure_invalid_is_not_an_agent_failure(self):
        self._record(
            "invalid", AgentTermination.FAILED, GraderStatus.FAIL,
            TrialValidity.INVALID_PROVIDER_INFRASTRUCTURE,
        )
        report = self.analyzer.analyze("invalid", persist=False)
        analysis = report.analyses[0]
        self.assertIsNone(analysis.strict_outcome)
        self.assertIsNone(analysis.failure_attribution)
        self.assertEqual(report.summary["validTrials"], 0)
        self.assertEqual(report.summary["invalidInfrastructure"], 1)

    def test_offline_reclassification_is_append_only_and_does_not_execute(self):
        self._record("classified", AgentTermination.TIMED_OUT, GraderStatus.FAIL)
        before = self._terminal_counts()
        first = self.analyzer.attribution_from_annotation("classified", {
            "primary": "EditApplicationFailure", "confidence": 0.9,
            "evidence": [{"kind": "trajectory_event", "reference": "2"}],
        })
        second = self.analyzer.attribution_from_annotation("classified", {
            "primary": "IncompleteImplementation", "confidence": 0.8,
            "evidence": [{"kind": "grader_result", "reference": "targeted"}],
        })
        report = self.analyzer.analyze("classified", persist=True)
        after = self._terminal_counts()
        history = self.database.failure_attribution_history("classified")
        self.assertEqual(before, after)
        self.assertEqual(len(history), 2)
        self.assertEqual(second.supersedes_id, first.id)
        self.assertEqual({item["taxonomy_version"] for item in history}, {"failure-taxonomy-v1"})
        self.assertEqual(self.database.connection.execute(
            "SELECT COUNT(*) FROM failure_analysis_runs WHERE id=?", (report.id,)
        ).fetchone()[0], 1)

    def test_historical_v02_classification_remains_readable(self):
        self._record("legacy", AgentTermination.TIMED_OUT, GraderStatus.FAIL)
        self.database.classify_failure("legacy", "Timeout", "manual", {"historical": True})
        analysis = self._analysis("legacy")
        self.assertEqual(analysis.failure_attribution.taxonomy_version, "failure-taxonomy-v0.2")
        self.assertEqual(analysis.failure_attribution.primary, FailureClassification.TIMEOUT)

    def test_unknown_evidence_reference_is_rejected(self):
        self._record("bad-evidence", AgentTermination.TIMED_OUT, GraderStatus.FAIL)
        with self.assertRaisesRegex(ValueError, "unknown trajectory event"):
            self.analyzer.attribution_from_annotation("bad-evidence", {
                "primary": "ToolUseFailure",
                "evidence": [{"kind": "trajectory_event", "reference": "999"}],
            })

    def _terminal_counts(self):
        return tuple(self.database.connection.execute(
            f"SELECT COUNT(*) FROM {table}"
        ).fetchone()[0] for table in (
            "agent_trials", "grading_runs", "grader_results", "candidate_snapshots", "eval_runs",
        ))


if __name__ == "__main__":
    unittest.main()
