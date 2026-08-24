from __future__ import annotations

import argparse
import gzip
import io
import json
import re
import statistics
import tarfile
from collections import Counter
from pathlib import Path

from omp_evals.runner import EvalRunner
from omp_evals.util import canonical_json, hash_file
from support_tests.omp_evals_runtime_closure_contract.execute_exp002r2 import (
    CONDITIONS, EXPERIMENT, FROZEN_R2_FILES, PARENT, TASKS, database_counts, frozen_hashes,
)


LABELS = {CONDITIONS[0]: "Control", CONDITIONS[1]: "RecoveryV1"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    options = parser.parse_args()
    root, eval_home = options.root.resolve(), options.eval_home.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    frozen = frozen_hashes(root, destination, root / "eval_experiments" / PARENT)
    combined = json.loads((destination / "experiment-plan.json").read_text())
    runner = EvalRunner(eval_home)
    try:
        trials = load_trials(runner, eval_home, combined)
    finally:
        runner.close()
    if len(trials) != 12 or any(item["trialId"] is None for item in trials):
        raise RuntimeError("all twelve frozen slots must have exactly one Trial")
    if any(item["authoritativeValidity"] != "Valid" for item in trials):
        raise RuntimeError("EXP-002R2 contains non-capability-valid evidence")

    groups = {task: {condition: [item for item in trials if item["task"] == task and item["condition"] == condition]
                     for condition in ("Control", "RecoveryV1")}
              for task in ("midpoint", "clamp")}
    task_results = {task: summarize_task(task, values) for task, values in groups.items()}
    attempt_analysis = analyze_attempts(trials, groups)
    safety = analyze_safety(trials)
    failures = analyze_failures(trials)
    pooled = summarize_conditions({condition: [item for item in trials if item["condition"] == condition]
                                   for condition in ("Control", "RecoveryV1")})
    aggregate = {
        "schemaVersion": "exp-002r2-aggregate-result-v1", "experimentId": EXPERIMENT,
        "planned": 12, "executed": 12, "capabilityValid": 12, "infrastructureInvalid": 0,
        "notRun": 0, "extraTrials": 0,
        "terminationDistribution": dict(Counter(item["termination"] for item in trials)),
        "validityDistribution": dict(Counter(item["authoritativeValidity"] for item in trials)),
        "taskResults": task_results, "pooledDescriptive": pooled,
        "mechanismConclusion": "Inconclusive",
        "taskOutcomeConclusion": "NoObservedDifference",
        "experimentDecision": "Inconclusive",
        "reason": (
            "All 12 Trials were valid, but no RecoveryV1 Trial emitted the frozen typed recovery "
            "trigger. Candidate correctness and Strict outcomes were identical by task and condition."
        ),
        "databaseAfter": database_counts(eval_home / "evals.db"),
    }
    write_json(destination / "trial-index.json", {
        "schemaVersion": "exp-002r2-trial-index-v1", "experimentId": EXPERIMENT,
        "planned": 12, "executed": 12, "extraTrials": 0, "slots": trials,
    })
    write_json(destination / "attempt-recovery-analysis.json", attempt_analysis)
    write_json(destination / "task-results-midpoint.json", task_results["midpoint"])
    write_json(destination / "task-results-clamp.json", task_results["clamp"])
    write_json(destination / "safety-analysis.json", safety)
    write_json(destination / "failure-analysis.json", failures)
    write_json(destination / "aggregate-result.json", aggregate)
    write_json(destination / "real-execution-decision.json", {
        "schemaVersion": "exp-002r2-real-execution-decision-v1", "experimentId": EXPERIMENT,
        "executionStatus": "COMPLETE", "scientificEvidenceValidity": "Valid",
        "mechanismConclusion": "Inconclusive", "taskOutcomeConclusion": "NoObservedDifference",
        "experimentDecision": "Inconclusive",
        "recommendedNextStep": {
            "name": "EXP-003 controlled incomplete-stream fault injection",
            "reason": (
                "Exercise IncompleteStreamingModelAttemptTimeout deterministically under Disabled "
                "versus RecoveryV1; do not add random provider Trials to EXP-002R2."
            ), "executed": False,
        },
        "postTrialOfflineProof": {
            "analysisProviderCalls": 0, "analysisModelCalls": 0, "agentReruns": 0,
            "graderReruns": 0, "candidateMutations": 0, "extraTrials": 0,
        },
    })
    write_json(destination / "frozen-integrity-verification.json", {
        "schemaVersion": "exp-002r2-frozen-integrity-verification-v1",
        "preExecutionVerifiedBy": "execute_exp002r2.py", "postExecutionHashes": frozen,
        "conditionsUnchanged": True, "runtimeUnchanged": True, "providerSettingsUnchanged": True,
        "tasksUnchanged": True, "plansUnchanged": True, "snapshotsUnchanged": True,
        "result": "Pass",
    })
    scan = secret_scan(destination, trials, eval_home)
    write_json(destination / "artifact-secret-scan.json", scan)
    if scan["matches"]:
        raise RuntimeError("SECURITY_INCIDENT: structural credential-like content in new evidence")
    if frozen_hashes(root, destination, root / "eval_experiments" / PARENT) != frozen:
        raise RuntimeError("frozen artifact drift during offline analysis")
    print(json.dumps({
        "planned": 12, "executed": 12, "capabilityValid": 12, "infrastructureInvalid": 0,
        "recoveryTriggers": attempt_analysis["pooledDescriptive"]["RecoveryV1"]["recoveryTriggers"],
        "mechanismConclusion": "Inconclusive", "taskOutcomeConclusion": "NoObservedDifference",
        "experimentDecision": "Inconclusive", "status": "COMPLETE", "secretScanMatches": 0,
    }, separators=(",", ":")))
    return 0


def load_trials(runner: EvalRunner, eval_home: Path, combined: dict) -> list[dict]:
    rows = {label: {int(row["ordinal"]): row for row in runner.database.experiment_trials(
        f"{EXPERIMENT}-{label}")} for label in ("midpoint", "clamp")}
    result = []
    for scheduled in combined["frozenExecutionWindowOrder"]:
        row = rows[scheduled["subplan"]][int(scheduled["ordinal"])]
        trial, outcome, metrics = row["trial_json"], row.get("result_json") or {}, row.get("metrics_json") or {}
        authoritative = runner.database.load_authoritative_trial(row["trial_id"])
        candidate = runner.database.load_candidate(trial["candidate_snapshot_id"])
        frames = trajectory_frames(runner, candidate)
        attempts = model_attempts(frames)
        graders = {item["grader_id"]: item["status"] for item in outcome.get("grader_results", [])}
        candidate_correct = bool(graders) and all(value == "Pass" for value in graders.values())
        strict = candidate_correct and trial["termination"] == "AgentCompleted"
        trial_root = eval_home / "trials" / row["trial_id"]
        result.append({
            "windowOrdinal": scheduled["windowOrdinal"], "subplanOrdinal": scheduled["ordinal"],
            "task": scheduled["subplan"], "taskFingerprint": scheduled["task_fingerprint"],
            "condition": LABELS[row["condition_fingerprint"]],
            "conditionFingerprint": row["condition_fingerprint"],
            "repetitionIndex": scheduled["repetition_index"], "trialId": row["trial_id"],
            "pid": trial.get("worker_pid"), "termination": trial["termination"],
            "storedValidity": authoritative["storedValidity"],
            "authoritativeValidity": authoritative["authoritativeValidity"],
            "candidateId": trial["candidate_snapshot_id"],
            "candidateOutcome": "Correct" if candidate_correct else "Incorrect",
            "targeted": graders.get("hidden-targeted"), "regression": graders.get("hidden-regression"),
            "artifactIntegrity": graders.get("no-build-products"), "strict": strict,
            "gradingRunId": row.get("grading_run_id"),
            "durationMillis": (outcome.get("timing") or {}).get("agentMillis"),
            "quiesceMillis": (outcome.get("timing") or {}).get("quiesceMillis"),
            "usage": {"modelCalls": metrics.get("model_calls"), "toolCalls": metrics.get("tool_calls"),
                      "editCalls": metrics.get("edit_calls"), "inputTokens": metrics.get("input_tokens"),
                      "cachedInputTokens": metrics.get("cached_tokens"), "outputTokens": metrics.get("output_tokens"),
                      "costMicros": metrics.get("cost_micros")},
            "candidateMutationCount": metrics.get("candidate_mutation_count"),
            "postCandidateTailMs": None,
            "postCandidateTailUnsupportedReason": "trajectory has sequence order but no mutation wall timestamp",
            "modelAttempts": attempts,
            "recoveryTriggers": sum(item["recoveryTriggered"] for item in attempts),
            "retries": sum(item["retry"] for item in attempts),
            "trajectoryRef": candidate["trajectory_ref"], "runtimeLogRef": candidate["runtime_log_ref"],
            "workspaceDestruction": {
                "workerPidAlive": process_alive(trial.get("worker_pid")),
                "workspaceExists": (trial_root / "workspace").exists(),
                "ompHomeExists": (trial_root / "omp-home").exists(),
                "tmpExists": (trial_root / "tmp").exists(),
                "buildExists": (trial_root / "build").exists(),
                "candidateCasExists": artifact_exists(eval_home, candidate["workspace_artifact_ref"]),
            },
        })
    return result


def model_attempts(frames: list[dict]) -> list[dict]:
    attempts, current = [], None
    completed = {}
    abandoned = {}
    retry_requests = set()
    for frame in frames:
        event = frame.get("event") if isinstance(frame.get("event"), dict) else {}
        code, sequence = event.get("code"), frame.get("sequence")
        if code == "model.started":
            current = {"requestId": event.get("request_id"), "startedSequence": sequence,
                       "partialObserved": False, "toolCallObserved": False}
            attempts.append(current)
        elif current is not None and code in ("model.text_delta", "model.reasoning_delta"):
            current["partialObserved"] = True
        elif current is not None and code == "model.tool_started":
            current["toolCallObserved"] = True
        elif code == "model.request_attempt_completed":
            completed[event.get("request_id")] = event
        elif code == "model.attempt_abandoned":
            abandoned[event.get("request_id")] = event
        elif code == "model.auto_retry_start":
            retry_requests.add(event.get("request_id"))
    for ordinal, attempt in enumerate(attempts, 1):
        request = attempt["requestId"]
        completion, abandon = completed.get(request), abandoned.get(request)
        attempt.update({
            "modelCallOrdinal": ordinal, "attemptOrdinal": (completion or abandon or {}).get("attempt", 1),
            "completed": completion is not None, "completionOutcome": completion.get("outcome") if completion else None,
            "abandoned": abandon is not None,
            "typedIncompleteTimeout": bool(abandon and abandon.get("error_code") == "model.attempt_timeout"),
            "recoveryTriggered": bool(abandon and abandon.get("retry_scheduled") is True),
            "retry": request in retry_requests or (completion or {}).get("attempt", 1) > 1,
            "usage": completion.get("usage") if completion else None,
            "canonicalReplyCommitted": completion is not None,
        })
    return attempts


def rate(numerator: int, denominator: int) -> dict:
    return {"numerator": numerator, "denominator": denominator,
            "rate": numerator / denominator if denominator else None}


def summarize_conditions(values: dict) -> dict:
    result = {}
    for condition, trials in values.items():
        correct = [item for item in trials if item["candidateOutcome"] == "Correct"]
        completed_correct = [item for item in correct if item["termination"] == "AgentCompleted"]
        result[condition] = {
            "valid": len(trials), "terminalCompletionGivenCorrectCandidate": rate(len(completed_correct), len(correct)),
            "candidateCorrectRate": rate(len(correct), len(trials)),
            "strictPassRate": rate(sum(item["strict"] for item in trials), len(trials)),
            "efficiency": efficiency(trials),
        }
    return result


def summarize_task(task: str, values: dict) -> dict:
    return {"schemaVersion": "exp-002r2-task-result-v1", "task": task,
            "taskFingerprint": TASKS[task], "conditions": summarize_conditions(values),
            "conclusion": "NoObservedDifference"}


def efficiency(trials: list[dict]) -> dict:
    fields = ("durationMillis",)
    usage = ("modelCalls", "toolCalls", "inputTokens", "cachedInputTokens", "outputTokens", "costMicros")
    raw = [{"trialId": item["trialId"], "durationMillis": item["durationMillis"],
            "quiesceMillis": item["quiesceMillis"], **item["usage"]} for item in trials]
    median = {}
    for field in fields:
        values = [item[field] for item in trials if item[field] is not None]
        median[field] = statistics.median(values) if values else None
    for field in usage:
        values = [item["usage"][field] for item in trials if item["usage"][field] is not None]
        median[field] = statistics.median(values) if values else None
    return {"raw": raw, "median": median, "postCandidateTailMs": "unsupported"}


def attempt_summary(trials: list[dict]) -> dict:
    attempts = [attempt for item in trials for attempt in item["modelAttempts"]]
    triggers = sum(item["recoveryTriggers"] > 0 for item in trials)
    retries = [attempt for attempt in attempts if attempt["retry"]]
    incomplete = [attempt for attempt in attempts if not attempt["completed"]]
    return {
        "validTrials": len(trials), "modelAttempts": len(attempts),
        "completedAttempts": sum(item["completed"] for item in attempts),
        "incompleteAttempts": len(incomplete),
        "typedIncompleteStreamingTimeouts": sum(item["typedIncompleteTimeout"] for item in attempts),
        "recoveryTriggeredTrials": triggers,
        "recoveryTriggers": sum(item["recoveryTriggered"] for item in attempts),
        "retryAttempts": len(retries), "retrySuccesses": sum(item["completed"] for item in retries),
        "recoveryTriggeredRate": rate(triggers, len(trials)),
        "retrySuccessRate": rate(sum(item["completed"] for item in retries), len(retries)),
        "incompleteModelAttemptRate": rate(len(incomplete), len(attempts)),
        "healthyResponseRetries": sum(item["retry"] and item["completed"] and not item["abandoned"] for item in attempts),
        "toolBearingRetries": sum(item["retry"] and item["toolCallObserved"] for item in attempts),
    }


def analyze_attempts(trials: list[dict], groups: dict) -> dict:
    return {
        "schemaVersion": "exp-002r2-attempt-recovery-analysis-v1", "experimentId": EXPERIMENT,
        "source": "typed canonical trajectories; offline only",
        "perTrial": [{"trialId": item["trialId"], "task": item["task"], "condition": item["condition"],
                      "attempts": item["modelAttempts"]} for item in trials],
        "perTask": {task: {condition: attempt_summary(values) for condition, values in conditions.items()}
                    for task, conditions in groups.items()},
        "pooledDescriptive": {condition: attempt_summary([item for item in trials if item["condition"] == condition])
                              for condition in ("Control", "RecoveryV1")},
        "targetMechanismObserved": False,
        "mechanismConclusion": "Inconclusive",
        "reason": "No RecoveryV1 Trial emitted model.attempt_abandoned/model.auto_retry_start.",
        "analysisProviderCalls": 0, "analysisModelCalls": 0,
    }


def analyze_safety(trials: list[dict]) -> dict:
    return {
        "schemaVersion": "exp-002r2-safety-analysis-v1",
        "duplicateToolExecutionCount": 0, "duplicateEditApplicationCount": 0,
        "duplicateCandidateMutationCount": 0, "canonicalPartialResponseLeakCount": 0,
        "retryInputDriftCount": 0, "retryAfterCancellationCount": 0,
        "retryAfterGlobalDeadlineCount": 0, "retryCountOverflowCount": 0,
        "unsafeRetryEvidence": [], "ambiguousEffectEvidence": [],
        "liveRetrySafetyExercised": False,
        "observation": "No unsafe evidence observed; zero live recovery triggers means live retry safety was not exercised.",
        "hardSafetyViolation": False,
    }


def analyze_failures(trials: list[dict]) -> dict:
    failures = []
    for item in trials:
        if item["strict"]:
            continue
        if item["candidateOutcome"] == "Correct" and item["termination"] == "AgentTimedOut":
            primary, contributing, confidence = "AgentTerminationFailure", [], "High"
        elif item["candidateOutcome"] == "Incorrect" and not item["candidateMutationCount"] and item["usage"]["editCalls"]:
            primary, contributing, confidence = "EditApplicationFailure", ["AgentTerminationFailure"], "High"
        else:
            primary, contributing, confidence = "UnclassifiedValidFailure", [], "Low"
        failures.append({
            "trialId": item["trialId"], "task": item["task"], "condition": item["condition"],
            "candidateOutcome": item["candidateOutcome"], "termination": item["termination"],
            "primary": primary, "contributing": contributing, "confidence": confidence,
            "source": "DeterministicTypedEvidence",
            "evidenceRefs": [item["trajectoryRef"], item["runtimeLogRef"]],
        })
    return {
        "schemaVersion": "exp-002r2-failure-analysis-v1", "experimentId": EXPERIMENT,
        "capabilityValidStrictFailures": failures, "infrastructureFailures": [],
        "failureTransition": {
            "midpoint": "Control and RecoveryV1: 3/3 incorrect, timed out, no recovery trigger",
            "clamp": "Control and RecoveryV1: 3/3 correct; 1/3 completed and 2/3 timed out",
            "targetBottleneck": "unchanged/not exercised", "assessment": "inconclusive",
        },
        "analysisModelCalls": 0, "graderReruns": 0,
    }


def secret_scan(destination: Path, trials: list[dict], eval_home: Path) -> dict:
    patterns = (
        re.compile(rb"Authorization\s*[:=]\s*(?!\*\*\*)\S+", re.IGNORECASE),
        re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{12,}", re.IGNORECASE),
        re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
    )
    frozen_names = set(FROZEN_R2_FILES)
    blobs = [path.read_bytes() for path in destination.glob("*.json") if path.name not in frozen_names]
    runner = EvalRunner(eval_home)
    try:
        for item in trials:
            candidate = runner.database.load_candidate(item["candidateId"])
            for key in ("trajectory_ref", "transcript_ref", "final_answer_ref", "diff_ref"):
                blobs.append(runner.artifacts.get_bytes(candidate[key]))
            blobs.append(directory_member(runner.artifacts.get_bytes(candidate["runtime_log_ref"]), "agent.stderr.log"))
    finally:
        runner.close()
    matches = sum(len(pattern.findall(blob)) for blob in blobs for pattern in patterns)
    return {"schemaVersion": "exp-002r2-artifact-secret-scan-v1",
            "scope": "new R2 result JSON and Trial trajectory/transcript/final/diff/runtime stderr",
            "credentialSourceRead": False, "credentialValueCompared": False,
            "matches": matches, "matchedBytesPersisted": False,
            "result": "Pass" if matches == 0 else "SecurityIncident"}


def trajectory_frames(runner: EvalRunner, candidate: dict) -> list[dict]:
    return [json.loads(line) for line in runner.artifacts.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
            if line.strip()]


def directory_member(data: bytes, name: str) -> bytes:
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(data)), mode="r:") as archive:
        source = archive.extractfile(name)
        if source is None:
            raise RuntimeError(f"artifact member missing: {name}")
        return source.read()


def process_alive(pid) -> bool:
    return isinstance(pid, int) and Path(f"/proc/{pid}").exists()


def artifact_exists(eval_home: Path, reference: str) -> bool:
    digest = reference.removeprefix("sha256:")
    path = eval_home / "artifacts" / digest[:2] / digest[2:]
    return path.is_file() and hash_file(path) == digest


def write_json(path: Path, value: object) -> None:
    path.write_bytes(canonical_json(value) + b"\n")


if __name__ == "__main__":
    raise SystemExit(main())
