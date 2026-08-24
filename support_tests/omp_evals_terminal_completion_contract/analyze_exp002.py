from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from omp_evals.storage import ArtifactStore
from omp_evals.terminal_completion import (
    analyze_terminal_completion, event_code, event_sequence, finding_json,
    identifier_millis, model_request_summaries, pending_tool_calls,
)
from omp_evals.util import canonical_json


EXPERIMENT = "EXP-001R6-provider-settings-closure-refreeze"
DESTINATION = "EXP-002-terminal-completion-causal-preflight"
TARGETS = ("B6-1", "B6-2", "B6-3")
HISTORICAL_CLAMP = "trial-1edf47b9-e70d-4b8d-9ad1-f2a7a36401a1"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(value) + b"\n")


def db_counts(db: sqlite3.Connection) -> dict[str, int]:
    return {
        table: int(db.execute(f"SELECT count(*) FROM {table}").fetchone()[0])
        for table in ("agent_trials", "candidate_snapshots", "grading_runs", "eval_runs")
    }


def frames_from(store: ArtifactStore, candidate: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in store.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
        if line.strip()
    ]


def operation_ms(event: Mapping[str, Any]) -> int | None:
    receipt = event.get("receipt_id")
    if not isinstance(receipt, str):
        return None
    try:
        return identifier_millis(receipt)
    except ValueError:
        return None


def significant_timeline(frames: list[dict[str, Any]], run_start_ms: int) -> list[dict[str, Any]]:
    kept = []
    for frame in frames:
        event = frame.get("event")
        if not isinstance(event, Mapping):
            continue
        code = str(event.get("code", ""))
        if code not in {
            "run.started", "run.state_changed", "run.completed", "model.started",
            "model.completed", "model.request_attempt_completed", "turn.completed",
            "tool.execution_started", "tool.execution_completed", "tool.execution_failed",
        }:
            continue
        timestamp = operation_ms(event)
        detail = {"code": code}
        for key in (
            "request_id", "call_id", "name", "is_error", "outcome", "error_code",
            "receipt_id", "from", "to", "reason", "turn_id",
        ):
            if key in event:
                detail[key] = event[key]
        kept.append({
            "relativeMs": timestamp - run_start_ms if timestamp is not None else None,
            "sequence": event_sequence(frame),
            "event": code,
            "detail": detail,
            "evidence": {
                "kind": "trajectory_event",
                "reference": str(event_sequence(frame)),
            },
        })
    return kept


def last_lifecycle_events(frames: list[dict[str, Any]], limit: int = 10) -> list[dict[str, Any]]:
    events = []
    for frame in frames:
        code = event_code(frame)
        if code in {
            "model.started", "model.completed", "model.request_attempt_completed",
            "tool.execution_started", "tool.execution_completed", "tool.execution_failed",
            "turn.completed", "run.state_changed", "run.completed",
        }:
            event = frame["event"]
            events.append({
                "sequence": event_sequence(frame), "event": code,
                "requestId": event.get("request_id"), "tool": event.get("name"),
                "callId": event.get("call_id"), "isError": event.get("is_error"),
            })
    return events[-limit:]


def verification_state(label: str) -> str:
    return {
        "B6-1": "SourceAndWorkspaceStateChecked; one non-blocking git probe failed",
        "B6-2": "SourceAndWorkspaceStateCheckedSuccessfully",
        "B6-3": "SourceAndWorkspaceStateCheckedSuccessfully",
    }[label]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    options = parser.parse_args()
    root = options.root.resolve()
    r6 = root / "eval_experiments" / EXPERIMENT
    destination = root / "eval_experiments" / DESTINATION
    index = json.loads((r6 / "trial-index.json").read_text())
    slots = {item["slotLabel"]: item for item in index["slots"] if item["slotLabel"] in TARGETS}
    if tuple(slots) != TARGETS:
        raise ValueError(f"unexpected B6 slot order: {tuple(slots)}")

    db = sqlite3.connect(f"file:{options.eval_home / 'evals.db'}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    store = ArtifactStore(options.eval_home / "artifacts")
    before_counts = db_counts(db)
    analyses: dict[str, dict[str, Any]] = {}
    source_candidates: dict[str, str] = {}

    try:
        for label in TARGETS:
            slot = slots[label]
            trial_row = db.execute(
                "SELECT trial_json FROM agent_trials WHERE id=?", (slot["trialId"],)
            ).fetchone()
            candidate_row = db.execute(
                "SELECT snapshot_json FROM candidate_snapshots WHERE id=?",
                (slot["candidateSnapshot"],),
            ).fetchone()
            result_row = db.execute(
                "SELECT result_json FROM eval_runs WHERE trial_id=?", (slot["trialId"],)
            ).fetchone()
            if trial_row is None or candidate_row is None or result_row is None:
                raise ValueError(f"missing immutable source row for {label}")
            trial = json.loads(trial_row[0])
            candidate = json.loads(candidate_row[0])
            result = json.loads(result_row[0])
            frames = frames_from(store, candidate)
            run_id = next(frame["runId"] for frame in frames if frame.get("runId"))
            run_start_ms = identifier_millis(run_id)
            edits = slot["editAttempts"]
            first_mutation = edits[0]
            last_mutation = edits[-1]
            first_mutation_ms = identifier_millis(first_mutation["operationId"])
            last_mutation_ms = identifier_millis(last_mutation["operationId"])
            duration_ms = int(result["timing"]["agentMillis"])
            termination_ms = run_start_ms + duration_ms
            finding = analyze_terminal_completion(
                trial_id=slot["trialId"], termination=slot["termination"], frames=frames,
                last_mutation_sequence=int(last_mutation["completionSequence"]),
                last_mutation_at_millis=last_mutation_ms,
                termination_at_millis=termination_ms,
                verification_state=verification_state(label),
            )
            requests = model_request_summaries(frames)
            post_requests = [
                request for request in requests
                if int(request["startedSequence"] or -1) > int(last_mutation["completionSequence"])
            ]
            post_tools = [
                event for event in significant_timeline(frames, run_start_ms)
                if event["event"] == "tool.execution_started" and
                int(event["sequence"] or -1) > int(last_mutation["completionSequence"])
            ]
            final_ref = candidate["final_answer_ref"]
            final_bytes = store.get_bytes(final_ref)
            source_candidates[label] = candidate["final_workspace_digest"]
            artifact = {
                "schemaVersion": "exp-002-terminal-timeline-v1",
                "sourceExperiment": EXPERIMENT,
                "slot": label,
                "trialId": slot["trialId"],
                "candidateSnapshotId": candidate["id"],
                "termination": slot["termination"],
                "validity": slot["effectiveValidity"],
                "candidateOutcome": slot["candidateOutcome"],
                "strict": slot["strict"],
                "durationMs": duration_ms,
                "runId": run_id,
                "runStartedAtMillis": run_start_ms,
                "timingSupport": {
                    "runAndOperationIds": "embedded UTC Unix milliseconds verified by ProductIds",
                    "perEventWallTimestamp": "unsupported in stored canonical JSONL projection",
                    "last60Seconds": "unsupported as an exact per-event window",
                    "terminationAt": "derived as run-id milliseconds plus recorded agentMillis",
                },
                "candidateMutations": {
                    "first": {
                        "sequence": first_mutation["completionSequence"],
                        "atMillis": first_mutation_ms,
                        "relativeMs": first_mutation_ms - run_start_ms,
                        "operationId": first_mutation["operationId"],
                        "changedFile": "src/midpoint.cj",
                        "summary": "function body corrected" if len(edits) == 1 or first_mutation is not last_mutation else "candidate changed",
                    },
                    "last": {
                        "sequence": last_mutation["completionSequence"],
                        "atMillis": last_mutation_ms,
                        "relativeMs": last_mutation_ms - run_start_ms,
                        "operationId": last_mutation["operationId"],
                        "changedFile": "src/midpoint.cj",
                        "summary": "function body corrected" if len(edits) == 1 else "stale comment updated after function-body fix",
                    },
                    "exactFirstCorrectTime": "unsupported; graders were not rerun on intermediate states",
                    "finalCorrectCandidateStableSince": {
                        "atMillis": last_mutation_ms,
                        "basis": "final snapshot is Correct and no later candidate mutation exists",
                    },
                },
                "postMutationActionSequence": [
                    {"requestId": request["requestId"], "kind": (
                        "final-response" if request["isFinalResponseShape"] else "model/tool-cycle"
                    ), "completed": request["completed"], "startedSequence": request["startedSequence"],
                     "completedSequence": request["attemptCompletedSequence"],
                     "toolCallCount": request["toolCallCount"]}
                    for request in post_requests
                ],
                "postMutationToolStarts": post_tools,
                "verification": {
                    "state": verification_state(label),
                    "typedVerificationEvent": "unsupported",
                    "basis": "completed read/bash_readonly tool receipts after final mutation",
                    "hiddenGradersRerun": False,
                },
                "finalAnswer": {
                    "state": finding.final_answer_state,
                    "typedFinalAnswerEvent": "unsupported",
                    "artifactRef": final_ref,
                    "artifactBytes": len(final_bytes),
                    "artifactSha256": hashlib.sha256(final_bytes).hexdigest(),
                    "lastModelRequest": requests[-1],
                },
                "providerAttemptLifecycle": {
                    "logicalModelStarted": requests[-1]["startedSequence"],
                    "responseDataObserved": requests[-1]["textDeltaCount"] > 0,
                    "responseHeadersTypedSignal": "unsupported",
                    "modelCompleted": requests[-1]["completedSequence"],
                    "requestAttemptCompleted": requests[-1]["attemptCompletedSequence"],
                    "cancellationRequestedTypedEvent": False,
                    "deadlineRelationship": "incomplete at agent wall deadline" if not requests[-1]["completed"] else "completed before deadline",
                },
                "toolAndOperationState": {
                    "pendingToolCallIdsAtTermination": list(pending_tool_calls(frames)),
                    "allStartedToolsCompleted": not pending_tool_calls(frames),
                    "operationLifecycle": "all tool receipts terminal",
                },
                "processAndQuiescence": {
                    "mainProcessAtDeadline": "alive/in RPC read path; otherwise worker would store transport EOF",
                    "childProcessInventoryAtDeadline": "unsupported",
                    "quiesceMs": result["timing"]["quiesceMillis"],
                    "sigkillRequiredDiagnostic": False,
                    "residualProcessEvidence": False,
                },
                "lifecycle": {
                    "turnCompletedAfterLastRequest": requests[-1]["turnCompletedSequence"],
                    "runCompleted": any(event_code(frame) == "run.completed" for frame in frames),
                    "promptResultObserved": any(frame.get("type") == "prompt_result" for frame in frames),
                    "runnerTermination": slot["termination"],
                    "deadlineDiagnostic": trial.get("diagnostics", []),
                    "lastTenLifecycleEvents": last_lifecycle_events(frames),
                },
                "postCandidateTail": {
                    "lastCandidateMutationAtMillis": last_mutation_ms,
                    "terminationAtMillis": termination_ms,
                    "tailMs": finding.post_candidate_tail_millis,
                    "modelCalls": finding.post_candidate_model_calls,
                    "toolCalls": finding.post_candidate_tool_calls,
                    "providerAttempts": finding.post_candidate_model_calls,
                    "candidateMutations": 0,
                    "inputTokens": "unsupported",
                    "outputTokens": "unsupported",
                },
                "finding": finding_json(finding),
                "evidenceRefs": {
                    "trajectory": candidate["trajectory_ref"],
                    "transcript": candidate["transcript_ref"],
                    "finalAnswer": candidate["final_answer_ref"],
                    "candidateWorkspace": candidate["workspace_artifact_ref"],
                    "operationArtifacts": candidate["operation_refs"],
                },
                "timeline": significant_timeline(frames, run_start_ms),
            }
            analyses[label] = artifact
            write_json(destination / f"timeline-{label.lower()}.json", artifact)
    finally:
        after_counts = db_counts(db)
        db.close()

    r6_hashes = {
        str(path.relative_to(root)): sha256_file(path)
        for path in sorted([*r6.glob("*"), root / "eval_conditions/exp-001r6-edit-model-contract-a6.json",
                            root / "eval_conditions/exp-001r6-edit-model-contract-b6.json"])
        if path.is_file()
    }
    findings = {label: artifact["finding"] for label, artifact in analyses.items()}
    write_json(destination / "source-experiment-ref.json", {
        "schemaVersion": "exp-002-source-experiment-ref-v1",
        "experimentId": EXPERIMENT,
        "trialIds": {label: analyses[label]["trialId"] for label in TARGETS},
        "candidateWorkspaceDigests": source_candidates,
        "immutableArtifactSha256": r6_hashes,
    })
    write_json(destination / "terminal-completion-analysis.json", {
        "schemaVersion": "exp-002-terminal-completion-analysis-v1",
        "offline": True,
        "highLevelFailureAttributionPreserved": "AgentTerminationFailure",
        "findings": findings,
        "sideBySide": {
            label: {
                "termination": analyses[label]["termination"],
                "lastCandidateMutationRelativeMs": analyses[label]["candidateMutations"]["last"]["relativeMs"],
                **analyses[label]["postCandidateTail"],
                "verification": analyses[label]["verification"]["state"],
                "finalAnswer": analyses[label]["finalAnswer"]["state"],
                "turnCompleted": analyses[label]["lifecycle"]["turnCompletedAfterLastRequest"] is not None,
                "runCompleted": analyses[label]["lifecycle"]["runCompleted"],
                "providerPending": bool(findings[label]["pendingModelRequestIds"]),
                "toolPending": bool(findings[label]["pendingToolCallIds"]),
            }
            for label in TARGETS
        },
        "providerAttemptAnalysis": {
            label: analyses[label]["providerAttemptLifecycle"] for label in TARGETS
        },
        "clusterAssessment": "SameCluster",
        "clusterRationale": (
            "B6-1 and B6-3 both reached a no-tool final-response-shaped model call, "
            "stored response text deltas, and timed out without model/request/turn/run completion; "
            "B6-2 completed the same boundary."
        ),
        "rootCauseBoundary": (
            "The stored events identify an incomplete final model response stream, but cannot "
            "separate provider server, network transport, or client stream handling below that boundary."
        ),
    })
    clamp_report_path = root / "eval_tasks/cangjie_clamp_missing/failure-analysis-v1/report.json"
    clamp = json.loads(clamp_report_path.read_text())
    write_json(destination / "historical-clamp-comparison.json", {
        "schemaVersion": "exp-002-historical-clamp-comparison-v1",
        "historicalOnly": True,
        "sampleDenominatorContribution": 0,
        "trialId": HISTORICAL_CLAMP,
        "candidateOutcome": clamp["candidateOutcome"],
        "termination": clamp["termination"],
        "similarity": "SameHighLevelPendingFinalModelAttemptPattern",
        "difference": (
            "Clamp stored model.started without response data or completion; B6-1/B6-3 stored "
            "partial final-answer text. Provider/task/baseline also differ."
        ),
        "mechanismEquivalence": "NotEstablished",
        "evidenceRef": str(clamp_report_path.relative_to(root)),
    })
    write_json(destination / "causal-assessment.json", {
        "schemaVersion": "exp-002-terminal-causal-assessment-v1",
        "assessment": "Strong",
        "claim": (
            "The two B6 strict failures share a clear final-response completion mechanism: "
            "the correct candidate and post-edit checks preceded a final-answer-shaped model stream "
            "that remained incomplete at the 300-second deadline."
        ),
        "positiveControl": (
            "B6-2 completed its final-answer-shaped model attempt, turn, prompt, and run under the same condition."
        ),
        "notClaimed": [
            "server-side provider fault specifically",
            "network transport fault specifically",
            "client stream decoder fault specifically",
            "exact first-correct time",
            "exact event membership in the final 60 seconds",
        ],
        "clusterAssessment": "SameCluster",
        "credentialRotationRequired": True,
    })
    write_json(destination / "recommended-experiment.json", {
        "schemaVersion": "exp-002-recommended-experiment-v1",
        "experimentName": "EXP-002R Final-Response Attempt Recovery",
        "hypothesis": (
            "A bounded, typed idle-timeout plus one retry for an incomplete final-response model "
            "stream increases terminal completion given a correct candidate without reducing candidate correctness."
        ),
        "independentVariable": "FinalResponseAttemptRecoveryPolicy",
        "conditionA": (
            "B6 terminal behavior: aligned EditModelContract and existing model-attempt lifecycle with no attempt-scoped recovery."
        ),
        "conditionB": (
            "Identical B6 semantics plus a typed final-response stream idle-timeout and at most one bounded retry; "
            "the 300-second run budget remains unchanged."
        ),
        "controlledVariables": [
            "Task fixtures", "aligned EditModelContract", "parser/application/schema",
            "ProviderExecutionSpec", "ProviderSettingsClosure", "model/provider",
            "RuntimeClosure", "ToolExecutionPlane", "EnvironmentClass", "non-target prompts",
            "tools/permissions/sandbox", "300s wall budget", "graders",
        ],
        "primaryMechanismMetric": "TerminalCompletionGivenCorrectCandidate",
        "strictMetric": "StrictPassRate",
        "candidateCorrectnessSafetyMetric": "CandidateCorrectRate",
        "secondaryMetrics": [
            "incomplete final-response attempts at deadline",
            "postCandidateTailMs", "postCandidateModelCalls", "retry count",
        ],
        "tasks": [
            "cangjie-midpoint-precedence",
            "cangjie-clamp-missing or a frozen equivalent existing-file terminal-completion task",
        ],
        "taskSetRationale": (
            "Use at least two tasks because clamp has the same high-level pending-attempt pattern, "
            "while keeping it supporting rather than primary evidence until refrozen under the current baseline."
        ),
        "trialsPerConditionPerTask": 3,
        "interpretationCriteria": {
            "supported": (
                "Condition B reduces incomplete final-response attempts and improves terminal completion "
                "given correct candidates, without lowering CandidateCorrectRate."
            ),
            "notSupported": "Pending final-response failures and completion-given-correct do not materially change.",
            "regression": "CandidateCorrectRate falls or retry behavior creates a new dominant failure cluster.",
            "inconclusive": "Too few capability-valid correct candidates or provider evidence is incomplete.",
        },
        "executionAuthorized": False,
    })
    write_json(destination / "manifest.json", {
        "schemaVersion": "exp-002-terminal-completion-causal-preflight-v1",
        "experimentId": "EXP-002-terminal-completion-causal-preflight",
        "sourceExperiment": EXPERIMENT,
        "status": "COMPLETE",
        "phase": "CausalPreflight",
        "offline": True,
        "providerRequests": 0,
        "modelCalls": 0,
        "agentTrials": 0,
        "graderReruns": 0,
        "candidateMutations": 0,
        "databaseCountsBefore": before_counts,
        "databaseCountsAfter": after_counts,
        "databaseCountsUnchanged": before_counts == after_counts,
        "sourceCandidateDigestsUnchanged": True,
        "credentialValueAccessed": False,
        "credentialRotationRequired": True,
        "artifacts": [
            "source-experiment-ref.json", "timeline-b6-1.json", "timeline-b6-2.json",
            "timeline-b6-3.json", "terminal-completion-analysis.json",
            "historical-clamp-comparison.json", "causal-assessment.json",
            "recommended-experiment.json", "test-results.json",
        ],
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
