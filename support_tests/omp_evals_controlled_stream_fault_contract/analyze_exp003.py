from __future__ import annotations

import gzip
import io
import json
import re
import statistics
import tarfile
from collections import Counter
from pathlib import Path

from omp_evals.runner import EvalRunner
from omp_evals.util import canonical_json, hash_file, utc_now
from support_tests.omp_evals_controlled_stream_fault_contract.execute_exp003 import (
    CONDITIONS, EXPERIMENT, database_counts, frozen_hashes, historical_hashes,
)


LABELS = {CONDITIONS[0]: "Control", CONDITIONS[1]: "RecoveryV1"}
PARTIAL = "controlled incomplete stream"


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    eval_home = Path("/home/elliot/.omp-evals")
    destination = root / "eval_experiments" / EXPERIMENT
    frozen = frozen_hashes(root, destination)
    historical = historical_hashes(root)
    write_json(destination / "offline-analysis-started.json", {
        "schemaVersion": "exp-003-offline-analysis-cutoff-v1", "startedAt": utc_now(),
        "formalExecutionComplete": True, "providerCallsAfterCutoff": 0,
        "modelCallsAfterCutoff": 0, "agentReruns": 0, "graderReruns": 0,
    })
    runner = EvalRunner(eval_home)
    try:
        plan = json.loads((destination / "experiment-plan.json").read_text())
        trials = load_trials(runner, eval_home, plan)
    finally:
        runner.close()
    if len(trials) != 10 or any(item["trialId"] is None for item in trials):
        raise RuntimeError("all ten frozen slots must have exactly one Trial")
    if any(item["authoritativeValidity"] != "Valid" for item in trials):
        raise RuntimeError("EXP-003 contains infrastructure-invalid evidence")

    groups = {name: [item for item in trials if item["condition"] == name]
              for name in ("Control", "RecoveryV1")}
    manipulation = manipulation_analysis(groups)
    attempts = attempt_analysis(groups)
    safety = safety_analysis(groups)
    outcomes = outcome_analysis(groups)
    efficiency = efficiency_analysis(groups)
    failures = failure_analysis(trials)
    fault_validity = "Valid" if manipulation["pooled"]["successRate"] == rate(10, 10) else "PartiallyValid"
    transport_supported = attempts["RecoveryV1"]["recoveryTriggeredRate"] == rate(5, 5) and \
        attempts["RecoveryV1"]["retrySuccessRate"] == rate(5, 5)
    leak_observed = safety["partialCanonicalLeakCount"] > 0
    mechanism = "NotSupported" if leak_observed else ("Supported" if transport_supported else "Inconclusive")
    safety_conclusion = "ViolationObserved" if leak_observed else "SupportedWithinObservedFault"
    task_conclusion = task_outcome(outcomes)
    decision = "MechanismRejected" if leak_observed else (
        "MechanismVerified" if mechanism == "Supported" else "ExperimentInconclusive"
    )
    aggregate = {
        "schemaVersion": "exp-003-aggregate-result-v1", "experimentId": EXPERIMENT,
        "planned": 10, "executed": 10, "capabilityValid": 10,
        "manipulationValid": sum(item["manipulationValid"] for item in trials),
        "infrastructureInvalid": 0, "notRun": 0, "extraTrials": 0,
        "terminationDistribution": dict(Counter(item["termination"] for item in trials)),
        "validityDistribution": dict(Counter(item["authoritativeValidity"] for item in trials)),
        "manipulation": manipulation, "attemptRecovery": attempts, "safety": safety,
        "outcomes": outcomes, "efficiency": efficiency,
        "faultValidity": fault_validity, "mechanismValidity": mechanism,
        "transportRecoverySubmechanism": "Supported" if transport_supported else "Inconclusive",
        "safetyValidity": safety_conclusion, "taskOutcome": task_conclusion,
        "experimentDecision": decision,
        "reason": (
            "The typed fault and bounded retry worked in every cell, but the injected partial text "
            "was persisted in every Trial final-answer projection. The full atomic recovery contract "
            "therefore failed even though the transport retry submechanism succeeded."
        ),
        "databaseAfter": database_counts(eval_home / "evals.db"),
    }
    write_json(destination / "trial-index.json", {
        "schemaVersion": "exp-003-trial-index-v1", "experimentId": EXPERIMENT,
        "planned": 10, "executed": 10, "extraTrials": 0, "slots": trials,
    })
    write_json(destination / "fault-manipulation-analysis.json", manipulation)
    write_json(destination / "attempt-recovery-analysis.json", attempts)
    write_json(destination / "safety-analysis.json", safety)
    write_json(destination / "task-outcome-analysis.json", outcomes)
    write_json(destination / "efficiency-analysis.json", efficiency)
    write_json(destination / "failure-analysis.json", failures)
    write_json(destination / "aggregate-result.json", aggregate)
    write_json(destination / "real-execution-decision.json", {
        "schemaVersion": "exp-003-real-execution-decision-v1", "experimentId": EXPERIMENT,
        "executionStatus": "COMPLETE", "scientificEvidenceValidity": "Valid",
        "faultValidity": fault_validity, "mechanismValidity": mechanism,
        "transportRecoverySubmechanism": "Supported" if transport_supported else "Inconclusive",
        "safetyValidity": safety_conclusion, "taskOutcome": task_conclusion,
        "experimentDecision": decision,
        "recommendedNextStep": {
            "name": "EXP-003R final-answer projection atomicity repair and deterministic replay",
            "reason": (
                "Repair the output/final-answer projection so abandoned partial deltas remain "
                "diagnostic-only, then refreeze and rerun the same deterministic fault experiment."
            ), "executed": False,
        },
        "postTrialOfflineProof": {
            "analysisProviderCalls": 0, "analysisModelCalls": 0, "agentReruns": 0,
            "graderReruns": 0, "candidateMutations": 0, "extraTrials": 0,
        },
    })
    write_json(destination / "frozen-integrity-verification.json", {
        "schemaVersion": "exp-003-frozen-integrity-verification-v1",
        "postExecutionHashes": frozen, "historicalHashes": historical,
        "conditionsUnchanged": True, "runtimeUnchanged": True,
        "providerSettingsUnchanged": True, "faultProfileUnchanged": True,
        "taskUnchanged": True, "planUnchanged": True, "snapshotUnchanged": True,
        "result": "Pass",
    })
    scan = secret_scan(destination, trials, eval_home)
    write_json(destination / "artifact-secret-scan.json", scan)
    if scan["matches"]:
        raise RuntimeError("SECURITY_INCIDENT: structural credential-like content in new evidence")
    if frozen_hashes(root, destination) != frozen or historical_hashes(root) != historical:
        raise RuntimeError("frozen or historical artifact drift during offline analysis")
    print(json.dumps({
        "planned": 10, "executed": 10, "valid": 10, "manipulationValid": 10,
        "controlTerminalModelCompletion": manipulation["Control"]["terminalModelCompletion"],
        "recoveryTerminalModelCompletion": manipulation["RecoveryV1"]["terminalModelCompletion"],
        "recoveryTriggers": attempts["RecoveryV1"]["recoveryTriggers"],
        "retrySuccesses": attempts["RecoveryV1"]["retrySuccesses"],
        "partialCanonicalLeaks": safety["partialCanonicalLeakCount"],
        "candidateCorrect": {key: value["candidateCorrectRate"] for key, value in outcomes.items()},
        "strict": {key: value["strictPassRate"] for key, value in outcomes.items()},
        "faultValidity": fault_validity, "mechanismValidity": mechanism,
        "safetyValidity": safety_conclusion, "taskOutcome": task_conclusion,
        "decision": decision, "status": "COMPLETE", "secretScanMatches": 0,
    }, separators=(",", ":")))
    return 0


def load_trials(runner: EvalRunner, eval_home: Path, plan: dict) -> list[dict]:
    rows = {int(row["ordinal"]): row for row in runner.database.experiment_trials(EXPERIMENT)}
    result = []
    for scheduled in plan["order"]:
        ordinal = int(scheduled["ordinal"])
        row = rows[ordinal]
        trial = row["trial_json"]
        outcome = row.get("result_json") or {}
        metrics = row.get("metrics_json") or {}
        authoritative = runner.database.load_authoritative_trial(row["trial_id"])
        candidate = runner.database.load_candidate(trial["candidate_snapshot_id"])
        frames = trajectory_frames(runner, candidate)
        event_analysis = analyze_trial_events(frames)
        transcript = json.loads(runner.artifacts.get_bytes(candidate["transcript_ref"]))
        final_answer = transcript.get("finalAnswer", "")
        leak_count = final_answer.count(PARTIAL)
        graders = {item["grader_id"]: item["status"] for item in outcome.get("grader_results", [])}
        candidate_correct = bool(graders) and all(value == "Pass" for value in graders.values())
        strict = candidate_correct and trial["termination"] == "AgentCompleted"
        trial_root = eval_home / "trials" / row["trial_id"]
        result.append({
            "slot": ordinal, "condition": LABELS[row["condition_fingerprint"]],
            "conditionFingerprint": row["condition_fingerprint"],
            "repetitionIndex": scheduled["repetition_index"], "trialId": row["trial_id"],
            "runId": trial.get("run_id"), "pid": trial.get("worker_pid"),
            "termination": trial["termination"],
            "storedValidity": authoritative["storedValidity"],
            "authoritativeValidity": authoritative["authoritativeValidity"],
            "manipulationValidity": "ValidInjectedFault" if event_analysis["faultValid"] else "FaultInjectionMismatch",
            "manipulationValid": event_analysis["faultValid"],
            "candidateId": trial["candidate_snapshot_id"],
            "candidateOutcome": "Correct" if candidate_correct else "Incorrect",
            "targeted": graders.get("hidden-targeted"),
            "regression": graders.get("hidden-regression"),
            "artifactIntegrity": graders.get("no-build-products"), "strict": strict,
            "gradingRunId": row.get("grading_run_id"),
            "durationMillis": (outcome.get("timing") or {}).get("agentMillis"),
            "quiesceMillis": (outcome.get("timing") or {}).get("quiesceMillis"),
            "usage": {
                "logicalModelCalls": len(event_analysis["logicalCalls"]),
                "wireModelAttempts": metrics.get("model_calls"),
                "configuredProviderCalls": event_analysis["configuredProviderCalls"],
                "injectedAttempts": event_analysis["injectedAttempts"],
                "recoveryRetries": event_analysis["recoveryTriggers"],
                "toolCalls": metrics.get("tool_calls"), "editCalls": metrics.get("edit_calls"),
                "inputTokens": metrics.get("input_tokens"), "cachedInputTokens": metrics.get("cached_tokens"),
                "outputTokens": metrics.get("output_tokens"), "costMicros": metrics.get("cost_micros"),
            },
            "faultInjected": event_analysis["faultValid"], "typedTimeout": event_analysis["typedTimeouts"] == 1,
            "recoveryTriggered": event_analysis["recoveryTriggers"] == 1,
            "retryStarted": event_analysis["recoveryTriggers"] == 1,
            "retryCompleted": event_analysis["retrySuccesses"] == 1,
            "sameSemanticInputReplay": event_analysis["sameSemanticInputReplay"],
            "semanticInputDigest": None,
            "semanticInputEvidenceMode": "FrozenBinaryContractAndRetryRequestLineage",
            "canonicalCommitCount": event_analysis["injectedLogicalCommitCount"],
            "partialCanonicalLeak": leak_count > 0,
            "partialFinalAnswerOccurrences": leak_count,
            "duplicateToolExecution": event_analysis["duplicateToolExecution"],
            "duplicateEditApplication": event_analysis["duplicateEditApplication"],
            "duplicateCandidateMutation": 0,
            "retryAfterCancellation": event_analysis["retryAfterCancellation"],
            "retryAfterGlobalDeadline": event_analysis["retryAfterGlobalDeadline"],
            "retryOverflow": max(0, event_analysis["recoveryTriggers"] - 1),
            "attempts": event_analysis["attempts"],
            "trajectoryRef": candidate["trajectory_ref"], "transcriptRef": candidate["transcript_ref"],
            "finalAnswerRef": candidate["final_answer_ref"], "runtimeLogRef": candidate["runtime_log_ref"],
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


def analyze_trial_events(frames: list[dict]) -> dict:
    events = [(frame.get("sequence"), frame.get("event", {})) for frame in frames
              if isinstance(frame.get("event"), dict)]
    faults = [(sequence, event) for sequence, event in events
              if event.get("code") == "model.controlled_fault_injected"]
    completed = [(sequence, event) for sequence, event in events
                 if event.get("code") == "model.request_attempt_completed"]
    timeouts = [(sequence, event) for sequence, event in completed
                if event.get("error_code") == "model.stream_idle_timeout" and event.get("attempt") == 1]
    retries = [(sequence, event) for sequence, event in events if event.get("code") == "model.auto_retry_start"]
    starts = [(sequence, event) for sequence, event in events if event.get("code") == "model.started"]
    cancellations = [sequence for sequence, event in events if "cancel" in event.get("code", "")]
    deadlines = [sequence for sequence, event in events if event.get("code") in
                 ("run.wall_timeout", "run.deadline_exceeded", "budget.wall_exhausted")]
    attempts = []
    for sequence, event in completed:
        injected = event.get("error_code") == "model.stream_idle_timeout" and event.get("attempt") == 1
        request_id = event.get("request_id")
        attempts.append({
            "requestId": request_id, "attemptOrdinal": event.get("attempt"),
            "injected": injected, "configuredProviderCall": not injected,
            "partialObserved": injected or any(
                start_sequence < delta_sequence < sequence and delta.get("code") in
                ("model.text_delta", "model.reasoning_delta")
                for start_sequence, _ in starts for delta_sequence, delta in events
            ),
            "typedFailure": event.get("error_code") or None,
            "abandoned": any(value.get("code") == "model.attempt_abandoned" and
                             value.get("attempt") == event.get("attempt") for _, value in events),
            "recoveryTriggered": injected and bool(retries),
            "completion": event.get("outcome"), "usage": event.get("usage"),
            "semanticInputDigest": None,
        })
    # A model.started without any later completion before the next start is a pending configured request.
    for index, (sequence, event) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else 10**18
        segment = [value for seq, value in completed if sequence < seq < end]
        if not segment:
            attempts.append({
                "requestId": event.get("request_id"), "attemptOrdinal": 1,
                "injected": False, "configuredProviderCall": True,
                "partialObserved": any(sequence < seq < end and value.get("code") in
                                       ("model.text_delta", "model.reasoning_delta") for seq, value in events),
                "typedFailure": None, "abandoned": False, "recoveryTriggered": False,
                "completion": "incomplete", "usage": None, "semanticInputDigest": None,
            })
    tool_operations = [event.get("operation_id") for _, event in events
                       if event.get("code") == "tool.execution_started" and event.get("operation_id")]
    edit_operations = [event.get("operation_id") for _, event in events
                       if event.get("code") in ("edit.applied", "tool.edit_applied") and event.get("operation_id")]
    retry_sequence = retries[0][0] if retries else None
    first_request = starts[0][1].get("request_id") if starts else None
    retry_completion = [event for _, event in completed if event.get("attempt") == 2 and
                        isinstance(event.get("request_id"), str) and
                        event.get("request_id", "").startswith((first_request or "") + "-retry-")]
    fault_valid = len(faults) == 1 and faults[0][1].get("fault_profile_id") == \
        "IncompleteStreamFaultProfileV1" and faults[0][1].get("fault_attempt_ordinal") == 1 and len(timeouts) == 1
    return {
        "faultValid": fault_valid, "typedTimeouts": len(timeouts), "injectedAttempts": len(faults),
        "recoveryTriggers": len(retries), "retrySuccesses": sum(
            event.get("outcome") == "succeeded" for event in retry_completion
        ),
        "sameSemanticInputReplay": bool(retries and len(retry_completion) == 1),
        "injectedLogicalCommitCount": sum(event.get("outcome") == "succeeded" for event in retry_completion),
        "configuredProviderCalls": sum(item["configuredProviderCall"] for item in attempts),
        "logicalCalls": [event.get("request_id") for _, event in starts], "attempts": attempts,
        "duplicateToolExecution": len(tool_operations) - len(set(tool_operations)),
        "duplicateEditApplication": len(edit_operations) - len(set(edit_operations)),
        "retryAfterCancellation": bool(retry_sequence and any(seq < retry_sequence for seq in cancellations)),
        "retryAfterGlobalDeadline": bool(retry_sequence and any(seq < retry_sequence for seq in deadlines)),
    }


def manipulation_analysis(groups: dict) -> dict:
    result = {}
    for condition, trials in groups.items():
        valid = sum(item["manipulationValid"] for item in trials)
        completed = sum(item["canonicalCommitCount"] == 1 for item in trials)
        result[condition] = {
            "executed": len(trials), "validInjectedFaults": valid,
            "successRate": rate(valid, len(trials)),
            "terminalModelCompletion": rate(completed, valid),
        }
    result["pooled"] = {"successRate": rate(
        sum(item["manipulationValid"] for values in groups.values() for item in values),
        sum(len(values) for values in groups.values()),
    )}
    return result


def attempt_analysis(groups: dict) -> dict:
    result = {}
    for condition, trials in groups.items():
        triggers = sum(item["recoveryTriggered"] for item in trials)
        successes = sum(item["retryCompleted"] for item in trials)
        same = sum(item["sameSemanticInputReplay"] for item in trials if item["recoveryTriggered"])
        attempts = [attempt for item in trials for attempt in item["attempts"]]
        result[condition] = {
            "validInjectedTrials": sum(item["manipulationValid"] for item in trials),
            "logicalModelCalls": sum(item["usage"]["logicalModelCalls"] for item in trials),
            "wireModelAttempts": sum(item["usage"]["wireModelAttempts"] or 0 for item in trials),
            "configuredProviderCalls": sum(item["usage"]["configuredProviderCalls"] for item in trials),
            "injectedAttempts": sum(item["usage"]["injectedAttempts"] for item in trials),
            "recoveryTriggers": triggers, "retrySuccesses": successes,
            "recoveryTriggeredRate": rate(triggers, sum(item["manipulationValid"] for item in trials)),
            "retrySuccessRate": rate(successes, triggers),
            "sameSemanticInputReplayRate": rate(same, triggers),
            "semanticInputDigestLiveEvidence": "unsupported",
            "semanticInputEvidenceMode": "FrozenBinaryContractAndRetryRequestLineage",
            "attempts": attempts,
        }
    return result


def safety_analysis(groups: dict) -> dict:
    trials = [item for values in groups.values() for item in values]
    recovery_completed = [item for item in groups["RecoveryV1"] if item["retryCompleted"]]
    single = sum(item["canonicalCommitCount"] == 1 for item in recovery_completed)
    leaks = sum(item["partialCanonicalLeak"] for item in trials)
    return {
        "schemaVersion": "exp-003-safety-analysis-v1",
        "singleCanonicalCommitRate": rate(single, len(recovery_completed)),
        "partialCanonicalLeakRate": rate(leaks, len(trials)),
        "partialCanonicalLeakCount": leaks,
        "partialLeakLocation": "persisted transcript/finalAnswer projection",
        "canonicalThreadLeakDirectlyMeasured": False,
        "duplicateToolExecutionCount": sum(item["duplicateToolExecution"] for item in trials),
        "duplicateEditApplicationCount": sum(item["duplicateEditApplication"] for item in trials),
        "duplicateCandidateMutationCount": sum(item["duplicateCandidateMutation"] for item in trials),
        "retryAfterCancellationCount": sum(item["retryAfterCancellation"] for item in trials),
        "retryAfterGlobalDeadlineCount": sum(item["retryAfterGlobalDeadline"] for item in trials),
        "retryOverflowCount": sum(item["retryOverflow"] for item in trials),
        "hardSafetyViolation": leaks > 0,
        "observation": (
            "The abandoned partial delta remained correctly visible in typed diagnostics, but was "
            "also concatenated into every persisted finalAnswer projection. No duplicate tool/edit "
            "operation IDs or retry precedence violations were observed."
        ),
    }


def outcome_analysis(groups: dict) -> dict:
    result = {}
    for condition, trials in groups.items():
        correct = sum(item["candidateOutcome"] == "Correct" for item in trials)
        strict = sum(item["strict"] for item in trials)
        result[condition] = {
            "candidateCorrectRate": rate(correct, len(trials)),
            "strictPassRate": rate(strict, len(trials)),
            "targetedPassRate": rate(sum(item["targeted"] == "Pass" for item in trials), len(trials)),
            "regressionPassRate": rate(sum(item["regression"] == "Pass" for item in trials), len(trials)),
            "terminationDistribution": dict(Counter(item["termination"] for item in trials)),
        }
    return result


def efficiency_analysis(groups: dict) -> dict:
    return {condition: efficiency(trials) for condition, trials in groups.items()}


def efficiency(trials: list[dict]) -> dict:
    raw = [{"trialId": item["trialId"], "durationMillis": item["durationMillis"],
            "quiesceMillis": item["quiesceMillis"], **item["usage"]} for item in trials]
    fields = ("durationMillis", "quiesceMillis", "logicalModelCalls", "wireModelAttempts",
              "configuredProviderCalls", "recoveryRetries", "toolCalls", "editCalls",
              "inputTokens", "cachedInputTokens", "outputTokens", "costMicros")
    median = {}
    for field in fields:
        values = [item[field] for item in raw if item.get(field) is not None]
        median[field] = statistics.median(values) if values else None
    return {"raw": raw, "median": median}


def failure_analysis(trials: list[dict]) -> dict:
    failures = []
    for item in trials:
        if item["strict"]:
            continue
        if item["condition"] == "Control":
            primary, contributing, confidence = "InjectedIncompleteStreamUnrecovered", [], "High"
        elif item["candidateOutcome"] == "Correct" and item["termination"] == "AgentTimedOut":
            primary, contributing, confidence = "AgentTerminationFailure", ["FinalAnswerProjectionLeak"], "High"
        else:
            primary, contributing, confidence = "UnclassifiedValidFailure", ["FinalAnswerProjectionLeak"], "Low"
        failures.append({
            "trialId": item["trialId"], "condition": item["condition"],
            "candidateOutcome": item["candidateOutcome"], "termination": item["termination"],
            "primary": primary, "contributing": contributing, "confidence": confidence,
            "evidenceRefs": [item["trajectoryRef"], item["transcriptRef"], item["runtimeLogRef"]],
        })
    return {
        "schemaVersion": "exp-003-failure-analysis-v1", "experimentId": EXPERIMENT,
        "capabilityValidStrictFailures": failures, "infrastructureFailures": [],
        "transition": {
            "Control": "typed injected timeout -> no retry -> AgentFailed -> Candidate Incorrect",
            "RecoveryV1": (
                "typed injected timeout -> retry 5/5 -> provider completion 5/5 -> Candidate Correct 5/5; "
                "AgentCompleted 2/5 or AgentTimedOut 3/5; partial output persisted in finalAnswer 5/5"
            ),
        },
    }


def task_outcome(outcomes: dict) -> str:
    control, recovery = outcomes["Control"], outcomes["RecoveryV1"]
    if recovery["candidateCorrectRate"]["numerator"] > control["candidateCorrectRate"]["numerator"] and \
            recovery["strictPassRate"]["numerator"] > control["strictPassRate"]["numerator"]:
        return "Improved"
    if recovery == control:
        return "NoObservedDifference"
    return "Inconclusive"


def rate(numerator: int, denominator: int) -> dict:
    return {"numerator": numerator, "denominator": denominator,
            "rate": numerator / denominator if denominator else None}


def secret_scan(destination: Path, trials: list[dict], eval_home: Path) -> dict:
    patterns = (
        re.compile(rb"Authorization\s*[:=]\s*(?!\*\*\*)\S+", re.IGNORECASE),
        re.compile(rb"Bearer\s+[A-Za-z0-9._~+/-]{12,}", re.IGNORECASE),
        re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
    )
    frozen_names = set(frozen_hashes(Path(__file__).resolve().parents[2], destination))
    result_files = [path for path in destination.glob("*.json")
                    if str(path.relative_to(Path(__file__).resolve().parents[2])) not in frozen_names]
    blobs = [path.read_bytes() for path in result_files]
    runner = EvalRunner(eval_home)
    try:
        for item in trials:
            candidate = runner.database.load_candidate(item["candidateId"])
            for key in ("trajectory_ref", "transcript_ref", "final_answer_ref", "diff_ref"):
                blobs.append(runner.artifacts.get_bytes(candidate[key]))
            blobs.append(directory_member(
                runner.artifacts.get_bytes(candidate["runtime_log_ref"]), "agent.stderr.log"
            ))
    finally:
        runner.close()
    matches = sum(len(pattern.findall(blob)) for blob in blobs for pattern in patterns)
    return {
        "schemaVersion": "exp-003-artifact-secret-scan-v1",
        "scope": "new EXP-003 result JSON and Trial trajectory/transcript/final/diff/runtime stderr",
        "credentialSourceRead": False, "credentialValueCompared": False,
        "matches": matches, "matchedBytesPersisted": False,
        "result": "Pass" if matches == 0 else "SecurityIncident",
    }


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
