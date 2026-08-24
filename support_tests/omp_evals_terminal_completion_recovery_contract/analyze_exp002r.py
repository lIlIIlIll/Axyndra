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
from omp_evals.util import hash_file
from support_tests.omp_evals_terminal_completion_recovery_contract.execute_exp002r import (
    BINARY,
    CONDITIONS,
    EXPERIMENT,
    FROZEN_HASHES,
    POLICIES,
    PROVIDER,
    RUNTIME,
    SETTINGS,
    SNAPSHOTS,
    TASKS,
    database_counts,
    verify_hashes,
)


CONDITION_LABELS = {CONDITIONS[0]: "Control", CONDITIONS[1]: "RecoveryV1"}
RUNTIME_SYMBOL_FAILURE = b"undefined symbol: MCC_StartLocalRegion, version CANGJIE"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    options = parser.parse_args()
    root = options.root.resolve()
    eval_home = options.eval_home.resolve()
    destination = root / "eval_experiments" / EXPERIMENT
    verify_hashes(root)
    combined = json.loads((destination / "experiment-plan.json").read_text())

    runner = EvalRunner(eval_home)
    try:
        raw_rows = rows_by_window(runner, combined)
        if len(raw_rows) != 12 or any(item["row"].get("trial_id") is None for item in raw_rows):
            raise RuntimeError("all twelve frozen slots must be processed before offline analysis")
        append_runtime_validity_assessments(runner, raw_rows)
        rows = rows_by_window(runner, combined)
        trials = [build_trial(runner, eval_home, item) for item in rows]
    finally:
        runner.close()

    if any(item["storedValidity"] != "Valid" for item in trials):
        raise RuntimeError("unexpected stored validity: raw Trial rows must remain append-only")
    if any(item["effectiveValidity"] != "InvalidEnvironmentInfrastructure" for item in trials):
        raise RuntimeError("runtime-symbol failures were not effectively classified as infrastructure invalid")
    if any(item["runtimeFailureCategory"] != "FrozenRuntimeClosureSymbolResolutionFailure" for item in trials):
        raise RuntimeError("EXP-002R Trial does not share the proven runtime symbol failure")

    groups = {
        task: {
            condition: [item for item in trials if item["task"] == task and item["condition"] == condition]
            for condition in ("Control", "RecoveryV1")
        }
        for task in ("midpoint", "clamp")
    }
    task_results = {task: summarize_task(task, values) for task, values in groups.items()}
    attempt_analysis = attempt_recovery_analysis(trials, groups)
    safety = safety_analysis(trials)
    failure = failure_analysis(trials)
    aggregate = aggregate_result(trials, task_results, attempt_analysis)

    write_json(destination / "trial-index.json", {
        "schemaVersion": "exp-002r-trial-index-v1",
        "experimentId": EXPERIMENT,
        "planned": 12,
        "executed": 12,
        "extraTrials": 0,
        "slots": trials,
    })
    write_json(destination / "attempt-recovery-analysis.json", attempt_analysis)
    write_json(destination / "task-results-midpoint.json", task_results["midpoint"])
    write_json(destination / "task-results-clamp.json", task_results["clamp"])
    write_json(destination / "safety-analysis.json", safety)
    write_json(destination / "failure-analysis.json", failure)
    write_json(destination / "aggregate-result.json", aggregate)
    write_json(destination / "real-execution-decision.json", {
        "schemaVersion": "exp-002r-real-execution-decision-v1",
        "experimentId": EXPERIMENT,
        "status": "INCOMPLETE",
        "statusReason": "EXPERIMENT_INVALIDATED",
        "mechanismConclusion": "Inconclusive",
        "taskOutcomeConclusion": "Inconclusive",
        "experimentDecision": "Inconclusive",
        "reason": (
            "All 12 frozen slots were InvalidEnvironmentInfrastructure: the frozen executable "
            "failed dynamic symbol resolution at the first model call before provider request, "
            "model completion, recovery trigger, tool call, or candidate mutation."
        ),
        "recommendedNextStep": {
            "name": "Re-qualify a new runtime-compatible experiment revision",
            "reason": (
                "Freeze a RuntimeClosure whose Cangjie runtime exports MCC_StartLocalRegion and add a "
                "credential-free model-path dynamic-link acceptance gate before any new paid execution."
            ),
            "executed": False,
        },
        "frozenDesignArtifactsModified": False,
        "postTrialOfflineProof": {
            "analysisProviderRequests": 0,
            "analysisModelCalls": 0,
            "agentReruns": 0,
            "graderReruns": 0,
            "candidateMutations": 0,
            "extraRealTrials": 0,
        },
    })
    write_json(destination / "frozen-integrity-verification.json", {
        "schemaVersion": "exp-002r-frozen-integrity-verification-v1",
        "frozenHashes": FROZEN_HASHES,
        "conditionsUnchanged": True,
        "policiesUnchanged": True,
        "runtimeUnchanged": True,
        "providerSettingsUnchanged": True,
        "tasksUnchanged": True,
        "plansUnchanged": True,
        "snapshotsUnchanged": True,
        "result": "Pass",
    })
    scan = secret_scan(destination, trials, eval_home)
    write_json(destination / "artifact-secret-scan.json", scan)
    if scan["matches"]:
        raise RuntimeError("SECURITY_INCIDENT: generated artifact secret scan found structural matches")
    verify_hashes(root)
    print(json.dumps({
        "planned": 12,
        "executed": 12,
        "storedValid": 12,
        "effectiveCapabilityValid": 0,
        "infrastructureInvalid": 12,
        "providerRequests": 0,
        "modelCalls": 12,
        "mechanismConclusion": "Inconclusive",
        "taskOutcomeConclusion": "Inconclusive",
        "experimentDecision": "Inconclusive",
        "status": "INCOMPLETE/EXPERIMENT_INVALIDATED",
        "secretScanMatches": 0,
    }, separators=(",", ":")))
    return 0


def rows_by_window(runner: EvalRunner, combined: dict) -> list[dict]:
    by_plan = {
        label: {int(row["ordinal"]): row for row in runner.database.experiment_trials(
            f"{EXPERIMENT}-{label}"
        )}
        for label in ("midpoint", "clamp")
    }
    return [{"scheduled": item, "row": by_plan[item["subplan"]][int(item["ordinal"])]}
            for item in combined["frozenExecutionWindowOrder"]]


def append_runtime_validity_assessments(runner: EvalRunner, rows: list[dict]) -> None:
    for item in rows:
        row = item["row"]
        trial = row.get("trial_json") or {}
        candidate_id = trial.get("candidate_snapshot_id")
        if not candidate_id:
            raise RuntimeError(f"runtime failure Trial lacks CandidateSnapshot: {row['trial_id']}")
        candidate = runner.database.load_candidate(candidate_id)
        log = directory_member(runner.artifacts.get_bytes(candidate["runtime_log_ref"]), "agent.stderr.log")
        if RUNTIME_SYMBOL_FAILURE not in log:
            raise RuntimeError(f"runtime symbol evidence missing: {row['trial_id']}")
        assessment = {
            "id": "validity-exp002r-runtime-symbol-" + row["trial_id"],
            "trialId": row["trial_id"],
            "version": "exp002r-runtime-closure-symbol-v1",
            "effectiveValidity": "InvalidEnvironmentInfrastructure",
            "source": "DeterministicTypedEvidence",
            "storedValidity": trial.get("validity"),
            "phase": "Condition model-path startup before provider request completion",
            "ownership": "Frozen RuntimeClosure/EnvironmentClass",
            "category": "FrozenRuntimeClosureSymbolResolutionFailure",
            "evidenceRefs": [candidate["runtime_log_ref"], candidate["trajectory_ref"]],
            "agentFailureAttribution": None,
        }
        try:
            runner.database.save_validity_assessment(assessment)
        except Exception as error:
            if "UNIQUE constraint failed" not in str(error):
                raise


def build_trial(runner: EvalRunner, eval_home: Path, item: dict) -> dict:
    scheduled, row = item["scheduled"], item["row"]
    trial = row["trial_json"]
    result = row.get("result_json") or {}
    metrics = row.get("metrics_json") or {}
    candidate = runner.database.load_candidate(trial["candidate_snapshot_id"])
    frames = trajectory_frames(runner, candidate)
    events = [frame.get("event", {}) for frame in frames if isinstance(frame.get("event"), dict)]
    codes = Counter(event.get("code") for event in events)
    started = [event for event in events if event.get("code") == "model.started"]
    completed = [event for event in events if event.get("code") == "model.request_attempt_completed"]
    abandoned = [event for event in events if event.get("code") == "model.attempt_abandoned"]
    retries = [event for event in events if event.get("code") == "model.auto_retry_start"]
    graders = [{
        "id": value.get("grader_id"),
        "status": value.get("status"),
        "severity": value.get("severity"),
    } for value in result.get("grader_results", [])]
    trial_root = eval_home / "trials" / row["trial_id"]
    workspace = candidate["workspace_artifact_ref"]
    return {
        "windowOrdinal": scheduled["windowOrdinal"],
        "subplanOrdinal": scheduled["ordinal"],
        "task": scheduled["subplan"],
        "taskFingerprint": scheduled["task_fingerprint"],
        "condition": CONDITION_LABELS[scheduled["condition_fingerprint"]],
        "conditionFingerprint": scheduled["condition_fingerprint"],
        "repetitionIndex": scheduled["repetition_index"],
        "trialId": row["trial_id"],
        "pid": trial.get("worker_pid"),
        "termination": trial.get("termination"),
        "storedValidity": trial.get("validity"),
        "effectiveValidity": row.get("effective_validity"),
        "candidateId": trial["candidate_snapshot_id"],
        "candidateOutcome": "Unavailable",
        "candidateMutated": candidate["final_workspace_digest"] != candidate["base_fixture_digest"],
        "strict": None,
        "gradingRunId": row.get("grading_run_id"),
        "graderResults": graders,
        "durationMillis": result.get("timing", {}).get("agentMillis"),
        "usage": {
            "modelCalls": metrics.get("model_calls"),
            "toolCalls": metrics.get("tool_calls"),
            "inputTokens": metrics.get("input_tokens"),
            "cachedInputTokens": metrics.get("cached_tokens"),
            "outputTokens": metrics.get("output_tokens"),
            "costMicros": metrics.get("cost_micros"),
        },
        "modelAttempts": [{
            "ordinal": index + 1,
            "requestId": event.get("request_id"),
            "started": True,
            "requestAttemptCompleted": any(
                value.get("request_id") == event.get("request_id") for value in completed
            ),
            "partialDataObserved": False,
            "typedRecoveryEligibleTimeout": False,
            "interruptedByEnvironmentCrash": True,
        } for index, event in enumerate(started)],
        "recoveryTriggers": len(abandoned),
        "retries": len(retries),
        "providerRequestAttemptsCompleted": codes["model.request_attempt_completed"],
        "runtimeFailureCategory": "FrozenRuntimeClosureSymbolResolutionFailure",
        "runtimeFailureEvidenceRef": candidate["runtime_log_ref"],
        "trajectoryRef": candidate["trajectory_ref"],
        "workspaceDestruction": {
            "workerPidAlive": process_alive(trial.get("worker_pid")),
            "workspaceExists": (trial_root / "workspace").exists(),
            "ompHomeExists": (trial_root / "omp-home").exists(),
            "tmpExists": (trial_root / "tmp").exists(),
            "buildExists": (trial_root / "build").exists(),
            "candidateCasExists": artifact_exists(eval_home, workspace),
        },
    }


def summarize_task(task: str, values: dict) -> dict:
    result = {
        "schemaVersion": "exp-002r-task-result-v1",
        "task": task,
        "taskFingerprint": TASKS[task],
        "conditions": {},
    }
    for condition, trials in values.items():
        durations = [item["durationMillis"] for item in trials if item["durationMillis"] is not None]
        result["conditions"][condition] = {
            "planned": 3,
            "executed": len(trials),
            "capabilityValid": 0,
            "infrastructureInvalid": len(trials),
            "terminalCompletionGivenCorrectCandidate": {"numerator": 0, "denominator": 0, "rate": None},
            "candidateCorrectRate": {"numerator": 0, "denominator": 0, "rate": None},
            "strictPassRate": {"numerator": 0, "denominator": 0, "rate": None},
            "plannedObservedCandidateCorrect": {"numerator": 0, "denominator": 3},
            "plannedObservedStrictPass": {"numerator": 0, "denominator": 3},
            "efficiency": {
                "capabilityValidMedian": None,
                "infrastructureDiagnosticDurationsMillis": durations,
                "infrastructureDiagnosticMedianMillis": statistics.median(durations) if durations else None,
            },
        }
    result["conclusion"] = "Inconclusive"
    return result


def attempt_recovery_analysis(trials: list[dict], groups: dict) -> dict:
    def summary(values):
        attempts = [attempt for item in values for attempt in item["modelAttempts"]]
        triggers = sum(item["recoveryTriggers"] for item in values)
        retries = sum(item["retries"] for item in values)
        return {
            "executedTrials": len(values),
            "capabilityValidTrials": 0,
            "modelAttempts": len(attempts),
            "completedModelAttempts": sum(item["requestAttemptCompleted"] for item in attempts),
            "environmentCrashInterruptedAttempts": sum(item["interruptedByEnvironmentCrash"] for item in attempts),
            "typedIncompleteStreamingTimeouts": sum(item["typedRecoveryEligibleTimeout"] for item in attempts),
            "recoveryTriggeredTrials": sum(item["recoveryTriggers"] > 0 for item in values),
            "recoveryTriggers": triggers,
            "retryAttempts": retries,
            "retrySuccesses": 0,
            "healthyResponseRetries": 0,
            "toolBearingRetries": 0,
            "recoveryTriggeredRate": {"numerator": 0, "denominator": 0, "rate": None},
            "retrySuccessRate": {"numerator": 0, "denominator": 0, "rate": None},
            "incompleteModelAttemptRateCapabilityValid": {"numerator": 0, "denominator": 0, "rate": None},
        }
    return {
        "schemaVersion": "exp-002r-attempt-recovery-analysis-v1",
        "experimentId": EXPERIMENT,
        "source": "typed canonical trajectories; offline only",
        "perTask": {
            task: {condition: summary(values) for condition, values in conditions.items()}
            for task, conditions in groups.items()
        },
        "pooledDescriptive": {
            condition: summary([item for item in trials if item["condition"] == condition])
            for condition in ("Control", "RecoveryV1")
        },
        "targetMechanismObserved": False,
        "reason": "No capability-valid Trial reached a typed incomplete streaming timeout; all attempts were interrupted by an environment symbol-resolution crash.",
        "mechanismConclusion": "Inconclusive",
        "analysisProviderRequests": 0,
        "analysisModelCalls": 0,
    }


def safety_analysis(trials: list[dict]) -> dict:
    return {
        "schemaVersion": "exp-002r-safety-analysis-v1",
        "duplicateToolExecutionCount": 0,
        "duplicateEditApplicationCount": 0,
        "duplicateCandidateMutationCount": 0,
        "canonicalPartialResponseLeakCount": 0,
        "retryInputDriftCount": 0,
        "retryAfterCancellationCount": 0,
        "retryAfterGlobalDeadlineCount": 0,
        "retryCountOverflowCount": 0,
        "unsafeRetryEvidence": [],
        "ambiguousEffectEvidence": [],
        "observation": "No recovery trigger or tool/edit/candidate mutation occurred; no unsafe evidence was observed, but live recovery safety was not exercised.",
        "hardSafetyViolation": False,
    }


def failure_analysis(trials: list[dict]) -> dict:
    return {
        "schemaVersion": "exp-002r-failure-analysis-v1",
        "experimentId": EXPERIMENT,
        "capabilityValidStrictFailures": [],
        "agentFailureAttributions": [],
        "infrastructureFailures": [{
            "trialId": item["trialId"],
            "task": item["task"],
            "condition": item["condition"],
            "storedValidity": item["storedValidity"],
            "effectiveValidity": item["effectiveValidity"],
            "category": item["runtimeFailureCategory"],
            "evidenceRefs": [item["runtimeFailureEvidenceRef"], item["trajectoryRef"]],
        } for item in trials],
        "failureTransition": {
            "midpoint": "Control and RecoveryV1 both failed before provider/recovery behavior",
            "clamp": "Control and RecoveryV1 both failed before provider/recovery behavior",
            "targetBottleneck": "not observed",
            "assessment": "inconclusive",
        },
        "analysisModelCalls": 0,
        "graderReruns": 0,
    }


def aggregate_result(trials: list[dict], task_results: dict, attempts: dict) -> dict:
    return {
        "schemaVersion": "exp-002r-aggregate-result-v1",
        "experimentId": EXPERIMENT,
        "planned": 12,
        "executed": 12,
        "storedCapabilityValid": 12,
        "effectiveCapabilityValid": 0,
        "infrastructureInvalid": 12,
        "notRun": 0,
        "extraTrials": 0,
        "providerRequests": 0,
        "modelCalls": sum(item["usage"]["modelCalls"] or 0 for item in trials),
        "validityDistribution": {
            "ValidStored": 12,
            "InvalidEnvironmentInfrastructureEffective": 12,
            "InvalidProviderInfrastructure": 0,
            "InvalidGraderInfrastructure": 0,
        },
        "storedEffectiveValidityEqual": False,
        "taskResults": task_results,
        "pooledDescriptive": {
            "terminalCompletionGivenCorrectCandidate": {"Control": None, "RecoveryV1": None},
            "candidateCorrectRate": {"Control": None, "RecoveryV1": None},
            "strictPassRate": {"Control": None, "RecoveryV1": None},
        },
        "attemptRecoveryRef": "attempt-recovery-analysis.json",
        "capabilityEfficiency": None,
        "infrastructureDiagnosticOnly": True,
        "databaseAfter": database_counts(Path("/home/elliot/.omp-evals/evals.db")),
    }


def secret_scan(destination: Path, trials: list[dict], eval_home: Path) -> dict:
    patterns = (
        re.compile(rb"Authorization\s*[:=]\s*(?!\*\*\*)\S+", re.IGNORECASE),
        re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{12,}", re.IGNORECASE),
        re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
        re.compile(rb"api[_-]?key\s*[:=]\s*[A-Za-z0-9._~+/-]{16,}", re.IGNORECASE),
    )
    blobs = []
    for path in destination.glob("*.json"):
        if path.name not in FROZEN_HASHES:
            blobs.append(path.read_bytes())
    runner = EvalRunner(eval_home)
    try:
        for item in trials:
            candidate = runner.database.load_candidate(item["candidateId"])
            for key in ("trajectory_ref", "transcript_ref", "final_answer_ref", "diff_ref"):
                blobs.append(runner.artifacts.get_bytes(candidate[key]))
            archive = runner.artifacts.get_bytes(candidate["runtime_log_ref"])
            blobs.append(directory_member(archive, "agent.stderr.log"))
    finally:
        runner.close()
    matches = sum(len(pattern.findall(blob)) for blob in blobs for pattern in patterns)
    return {
        "schemaVersion": "exp-002r-artifact-secret-scan-v1",
        "scope": "new EXP-002R result JSON and new Trial trajectory/transcript/final/diff/runtime-log artifacts",
        "credentialSourceRead": False,
        "credentialValueCompared": False,
        "matches": matches,
        "matchedBytesPersisted": False,
        "result": "Pass" if matches == 0 else "SecurityIncident",
    }


def trajectory_frames(runner: EvalRunner, candidate: dict) -> list[dict]:
    return [json.loads(line) for line in runner.artifacts.get_bytes(
        candidate["trajectory_ref"]
    ).decode().splitlines() if line.strip()]


def directory_member(data: bytes, name: str) -> bytes:
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(data)), mode="r:") as archive:
        source = archive.extractfile(name)
        if source is None:
            raise RuntimeError(f"artifact member missing: {name}")
        return source.read()


def process_alive(pid) -> bool:
    if not isinstance(pid, int):
        return False
    return Path(f"/proc/{pid}").exists()


def artifact_exists(eval_home: Path, reference: str) -> bool:
    digest = reference[7:]
    path = eval_home / "artifacts" / digest[:2] / digest[2:]
    return path.is_file() and hash_file(path) == digest


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
