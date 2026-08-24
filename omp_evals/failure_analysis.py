from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any, Mapping, Optional, Sequence

from .model import (
    AgentTermination, CandidateDiagnostic, CandidateOutcome, ClassificationSource,
    FAILURE_TAXONOMY_VERSION, FailureAnalysisReport, FailureAttribution,
    FailureClassification, FailureEvidenceRef, StrictEvalOutcome, TrialFailureAnalysis,
    TrialTimeline, TrialTimelineEvent, TrialValidity, jsonable,
)
from .storage import ArtifactStore, EvalDatabase
from .util import new_id, utc_now


_REQUIRED_SEVERITIES = {"Gate", "Required"}
_SIGNIFICANT_CODES = {
    "run.started", "run.completed", "run.failed", "run.cancelled",
    "model.started", "model.completed", "model.request_attempt_completed",
    "tool.execution_started", "tool.execution_completed", "turn.completed",
    "context.compacted",
}


def candidate_diagnostic(
    candidate_id: Optional[str], grader_results: Sequence[Mapping[str, Any]]
) -> CandidateDiagnostic:
    if not candidate_id:
        return CandidateDiagnostic(CandidateOutcome.UNAVAILABLE, (), (), None, None, None, None)
    required = [item for item in grader_results if item.get("severity") in _REQUIRED_SEVERITIES]
    if not required:
        return CandidateDiagnostic(CandidateOutcome.UNGRADABLE, (), (), None, None, None, None)
    passed = tuple(str(item["grader_id"]) for item in required if item.get("status") == "Pass")
    failed = tuple(str(item["grader_id"]) for item in required if item.get("status") != "Pass")
    if any(item.get("status") == "Error" for item in required):
        outcome = CandidateOutcome.UNGRADABLE
    else:
        outcome = CandidateOutcome.CORRECT if not failed else CandidateOutcome.INCORRECT
    return CandidateDiagnostic(
        outcome=outcome, required_graders_passed=passed, required_graders_failed=failed,
        targeted_passed=_requirement_passed(required, "TargetedBehavior"),
        regression_passed=_requirement_passed(required, "Regression"),
        hard_constraints_passed=_requirement_passed(required, "HardConstraints"),
        artifact_integrity_passed=_requirement_passed(required, "ArtifactIntegrity"),
    )


def strict_outcome(
    validity: str, termination: str, diagnostic: CandidateDiagnostic
) -> Optional[StrictEvalOutcome]:
    if validity != TrialValidity.VALID.value:
        return None
    if termination == AgentTermination.COMPLETED.value and diagnostic.outcome == CandidateOutcome.CORRECT:
        return StrictEvalOutcome.PASS
    return StrictEvalOutcome.FAIL


class OfflineFailureAnalyzer:
    """Reads terminal facts and immutable artifacts; never launches Agent or grader code."""

    def __init__(self, database: EvalDatabase, artifacts: ArtifactStore):
        self.database = database
        self.artifacts = artifacts

    def analyze(
        self, target_id: str, annotations: Optional[Mapping[str, Any]] = None,
        persist: bool = True,
    ) -> FailureAnalysisReport:
        rows = self._target_rows(target_id)
        analyses = tuple(self._analyze_row(row, annotations or {}) for row in rows)
        summary = _summary(analyses)
        report = FailureAnalysisReport(
            id=new_id("failure-analysis"), target_id=target_id,
            taxonomy_version=FAILURE_TAXONOMY_VERSION, analyses=analyses,
            summary=summary, created_at=utc_now(),
        )
        if persist:
            self.database.save_failure_analysis(jsonable(report))
        return report

    def attribution_from_annotation(
        self, trial_id: str, value: Mapping[str, Any], persist: bool = True,
    ) -> FailureAttribution:
        trial = self.database.load_trial(trial_id)
        if trial["validity"] != TrialValidity.VALID.value:
            raise ValueError("infrastructure-invalid trials cannot receive Agent failure attribution")
        evidence = tuple(FailureEvidenceRef(
            kind=str(item["kind"]), reference=str(item["reference"]),
            detail=str(item.get("detail", "")),
        ) for item in value.get("evidence", []))
        self._validate_evidence(trial_id, evidence)
        latest = self.database.latest_failure_attribution(trial_id)
        attribution = FailureAttribution(
            id=new_id("failure-attribution"), trial_id=trial_id,
            taxonomy_version=str(value.get("taxonomyVersion", FAILURE_TAXONOMY_VERSION)),
            primary=FailureClassification(value["primary"]),
            contributing=tuple(FailureClassification(item) for item in value.get("contributing", [])),
            confidence=float(value.get("confidence", 1.0)), evidence_refs=evidence,
            source=ClassificationSource(value.get("source", "Manual")), created_at=utc_now(),
            supersedes_id=latest["id"] if latest else None,
        )
        if not 0.0 <= attribution.confidence <= 1.0:
            raise ValueError("classification confidence must be between 0 and 1")
        if persist:
            self.database.save_failure_attribution(jsonable(attribution))
        return attribution

    def _analyze_row(
        self, row: Mapping[str, Any], annotations: Mapping[str, Any]
    ) -> TrialFailureAnalysis:
        trial = row["trial"]
        result = row.get("result") or {}
        candidate_id = trial.get("candidate_snapshot_id")
        grader_results = result.get("grader_results", [])
        diagnostic = candidate_diagnostic(candidate_id, grader_results)
        strict = strict_outcome(trial["validity"], trial["termination"], diagnostic)
        candidate = self.database.load_candidate(candidate_id) if candidate_id else None
        frames = self._frames(candidate) if candidate else []
        duration = result.get("timing", {}).get("agentMillis")
        timeline = _timeline(trial, frames, grader_results, diagnostic, duration)
        stored = self.database.latest_failure_attribution(trial["id"])
        annotation = annotations.get(trial["id"])
        if annotation:
            attribution = self.attribution_from_annotation(trial["id"], annotation, persist=False)
        elif stored:
            attribution = _attribution_from_json(stored)
        else:
            attribution = _deterministic_attribution(trial, strict, diagnostic)
        diff = self.artifacts.get_bytes(candidate["diff_ref"]).decode() if candidate else ""
        return TrialFailureAnalysis(
            trial_id=trial["id"], candidate_snapshot_id=candidate_id,
            strict_outcome=strict, candidate_diagnostic=diagnostic,
            termination=AgentTermination(trial["termination"]), validity=TrialValidity(trial["validity"]),
            failure_attribution=attribution, timeline=timeline,
            diff_diagnostic=_diff_diagnostic(diff),
            usage=row.get("metrics") or result.get("usage", {}),
            duration_millis=duration,
        )

    def _target_rows(self, target_id: str) -> list[Mapping[str, Any]]:
        try:
            rows = self.database.experiment_trials(target_id)
        except KeyError:
            rows = []
        if rows:
            return [{
                "trial": row["trial_json"], "result": row["result_json"],
                "metrics": row.get("metrics_json"),
            } for row in rows]
        trial = self.database.load_trial(target_id)
        return [{
            "trial": trial, "result": self.database.load_eval_result(target_id),
            "metrics": self.database.load_metrics(target_id),
        }]

    def _frames(self, candidate: Mapping[str, Any]) -> list[Mapping[str, Any]]:
        return [
            json.loads(line) for line in self.artifacts.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
            if line.strip()
        ]

    def _validate_evidence(self, trial_id: str, evidence: Sequence[FailureEvidenceRef]) -> None:
        trial = self.database.load_trial(trial_id)
        candidate_id = trial.get("candidate_snapshot_id")
        candidate = self.database.load_candidate(candidate_id) if candidate_id else None
        result = self.database.load_eval_result(trial_id) or {}
        frames = self._frames(candidate) if candidate else []
        sequences = {str(frame.get("sequence")) for frame in frames if frame.get("sequence") is not None}
        graders = {str(item["grader_id"]) for item in result.get("grader_results", [])}
        artifact_refs = set()
        if candidate:
            artifact_refs.update(candidate.get("operation_refs", []))
            artifact_refs.update(candidate.get(name) for name in (
                "diff_ref", "transcript_ref", "trajectory_ref", "runtime_log_ref",
                "workspace_artifact_ref", "filesystem_manifest_ref", "final_answer_ref",
            ))
        for item in evidence:
            if item.kind == "trajectory_event" and item.reference not in sequences:
                raise ValueError(f"unknown trajectory event sequence: {item.reference}")
            elif item.kind == "grader_result" and item.reference not in graders:
                raise ValueError(f"unknown grader result: {item.reference}")
            elif item.kind in ("artifact", "operation_artifact"):
                if item.reference not in artifact_refs:
                    raise ValueError(f"artifact is not owned by candidate: {item.reference}")
                self.artifacts.get_bytes(item.reference)
            elif item.kind == "trial_fact" and item.reference not in (
                "termination", "validity", "candidateOutcome", "strictOutcome",
            ):
                raise ValueError(f"unknown trial fact: {item.reference}")
            elif item.kind not in (
                "trajectory_event", "grader_result", "artifact", "operation_artifact", "trial_fact",
            ):
                raise ValueError(f"unsupported evidence reference kind: {item.kind}")


def _requirement_passed(results: Sequence[Mapping[str, Any]], requirement: str) -> Optional[bool]:
    selected = [item for item in results if item.get("outcome_requirement") == requirement]
    return None if not selected else all(item.get("status") == "Pass" for item in selected)


def _timeline(
    trial: Mapping[str, Any], frames: Sequence[Mapping[str, Any]],
    grader_results: Sequence[Mapping[str, Any]], diagnostic: CandidateDiagnostic,
    duration_millis: Optional[int],
) -> TrialTimeline:
    events: list[TrialTimelineEvent] = []
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, Mapping) or event.get("code") not in _SIGNIFICANT_CODES:
            continue
        detail = {key: event[key] for key in (
            "code", "request_id", "call_id", "name", "arguments", "is_error", "outcome",
            "error_code", "usage", "output",
        ) if key in event}
        events.append(TrialTimelineEvent(
            sequence=frame.get("sequence"), relative_millis=None,
            event_type=str(event["code"]), detail=detail,
        ))
    events.append(TrialTimelineEvent(
        sequence=None, relative_millis=None, event_type="candidate.graded",
        detail={"outcome": diagnostic.outcome.value,
                "graders": {item["grader_id"]: item["status"] for item in grader_results}},
    ))
    events.append(TrialTimelineEvent(
        sequence=None, relative_millis=None, event_type="agent.terminated",
        detail={"termination": trial["termination"], "validity": trial["validity"]},
    ))
    return TrialTimeline(
        trial_id=trial["id"], events=tuple(events),
        wall_duration_millis=duration_millis,
        timing_support="per-event wall timestamps unavailable; sequence ordering only",
    )


def _diff_diagnostic(diff: str) -> Mapping[str, Any]:
    files = []
    additions = deletions = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            files.append(line[6:])
        elif line.startswith("+") and not line.startswith("+++"):
            additions += 1
        elif line.startswith("-") and not line.startswith("---"):
            deletions += 1
    return {
        "changedFiles": files, "additions": additions, "deletions": deletions,
        "empty": not bool(diff.strip()), "diff": diff,
        "referenceSimilarityUsedForGrading": False,
    }


def _deterministic_attribution(
    trial: Mapping[str, Any], strict: Optional[StrictEvalOutcome], diagnostic: CandidateDiagnostic,
) -> Optional[FailureAttribution]:
    if trial["validity"] != TrialValidity.VALID.value or strict != StrictEvalOutcome.FAIL:
        return None
    if (diagnostic.outcome == CandidateOutcome.CORRECT and
            trial["termination"] != AgentTermination.COMPLETED.value):
        primary = FailureClassification.AGENT_TERMINATION_FAILURE
        confidence = 1.0
        evidence = (
            FailureEvidenceRef("trial_fact", "candidateOutcome", "all required graders passed"),
            FailureEvidenceRef("trial_fact", "termination", trial["termination"]),
            FailureEvidenceRef("trial_fact", "validity", trial["validity"]),
        )
    else:
        primary = FailureClassification.UNCLASSIFIED_VALID_FAILURE
        confidence = 1.0
        evidence = ()
    return FailureAttribution(
        id=new_id("failure-attribution-ephemeral"), trial_id=trial["id"],
        taxonomy_version=FAILURE_TAXONOMY_VERSION, primary=primary,
        contributing=(), confidence=confidence, evidence_refs=evidence,
        source=ClassificationSource.DETERMINISTIC_RULE, created_at=utc_now(),
    )


def _attribution_from_json(value: Mapping[str, Any]) -> FailureAttribution:
    source_value = str(value["source"])
    source_aliases = {
        "manual": ClassificationSource.MANUAL.value,
        "deterministic": ClassificationSource.DETERMINISTIC_RULE.value,
        "model": ClassificationSource.MODEL_ASSISTED.value,
    }
    return FailureAttribution(
        id=value["id"], trial_id=value["trial_id"], taxonomy_version=value["taxonomy_version"],
        primary=FailureClassification(value["primary"]),
        contributing=tuple(FailureClassification(item) for item in value.get("contributing", [])),
        confidence=float(value["confidence"]),
        evidence_refs=tuple(FailureEvidenceRef(**item) for item in value.get("evidence_refs", [])),
        source=ClassificationSource(source_aliases.get(source_value, source_value)),
        created_at=value["created_at"],
        supersedes_id=value.get("supersedes_id"),
    )


def _summary(analyses: Sequence[TrialFailureAnalysis]) -> Mapping[str, Any]:
    valid = [item for item in analyses if item.validity == TrialValidity.VALID]
    strict = Counter(item.strict_outcome.value for item in valid if item.strict_outcome)
    candidates = Counter(item.candidate_diagnostic.outcome.value for item in valid)
    terminations = Counter(item.termination.value for item in analyses)
    causes = Counter(
        item.failure_attribution.primary.value for item in valid if item.failure_attribution
    )
    return {
        "trials": len(analyses), "validTrials": len(valid),
        "invalidInfrastructure": len(analyses) - len(valid),
        "strictOutcomes": dict(strict), "candidateOutcomes": dict(candidates),
        "terminations": dict(terminations), "primaryFailureCauses": dict(causes),
        "strictPassRate": strict.get("Pass", 0) / len(valid) if valid else None,
        "candidateCorrectRate": candidates.get("Correct", 0) / len(valid) if valid else None,
    }
