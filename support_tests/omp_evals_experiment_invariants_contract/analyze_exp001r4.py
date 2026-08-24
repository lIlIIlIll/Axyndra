from __future__ import annotations

import argparse
import json
import statistics
from collections import Counter
from pathlib import Path

from omp_evals.benchmark import aggregate_experiment
from omp_evals.edit_causal import (
    extract_historical_edit_attempts, rejection_cause, syntax_violation,
)
from omp_evals.failure_analysis import OfflineFailureAnalyzer, candidate_diagnostic, strict_outcome
from omp_evals.model import jsonable
from omp_evals.runner import EvalRunner


EXPERIMENT = "EXP-001R4-canonical-experiment-invariants-refreeze"
A3 = "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9"
B3 = "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363"
LABELS = {A3: "A3", B3: "B3"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    options = parser.parse_args()
    destination = options.root.resolve() / "eval_experiments" / EXPERIMENT
    runner = EvalRunner(options.eval_home)
    try:
        aggregate = aggregate_experiment(runner.database, EXPERIMENT)
        rows = runner.database.experiment_trials(EXPERIMENT)
        annotations_path = destination / "failure-annotations.json"
        annotations = json.loads(annotations_path.read_text()) if annotations_path.exists() else {}
        failure = OfflineFailureAnalyzer(runner.database, runner.artifacts).analyze(
            EXPERIMENT, annotations=annotations, persist=True,
        )
        rows = runner.database.experiment_trials(EXPERIMENT)
        trial_values = []
        by_condition = {"A3": [], "B3": []}
        for row in rows:
            trial = row.get("trial_json") or {}
            result = row.get("result_json") or {}
            effective = row.get("effective_validity") or trial.get("validity")
            candidate_id = trial.get("candidate_snapshot_id")
            candidate = runner.database.load_candidate(candidate_id) if candidate_id else None
            grader_results = result.get("grader_results", [])
            diagnostic = candidate_diagnostic(candidate_id, grader_results)
            strict = strict_outcome(effective, trial.get("termination", ""), diagnostic)
            attempts = extract_historical_edit_attempts(
                str(row.get("trial_id")), tuple(candidate.get("operation_refs", ())), runner.artifacts,
            ) if candidate else ()
            attempt_values = []
            for attempt in attempts:
                violation = syntax_violation(
                    attempt.raw_edit_payload,
                    error_code=attempt.historical_outcome.error_code,
                    error_message=attempt.historical_outcome.error_message,
                )
                cause = rejection_cause(attempt)
                attempt_values.append({
                    "attemptOrdinal": attempt.attempt_ordinal,
                    "trajectorySequence": attempt.trajectory_sequence,
                    "completionSequence": attempt.completion_sequence,
                    "operationId": attempt.operation_id,
                    "startedArtifactRef": attempt.started_artifact_ref,
                    "completedArtifactRef": attempt.completed_artifact_ref,
                    "rawPayload": attempt.raw_edit_payload,
                    "commandKind": attempt.command_kind.value,
                    "parserOutcome": attempt.historical_outcome.parser_outcome,
                    "applicationOutcome": attempt.historical_outcome.application_outcome,
                    "errorCode": attempt.historical_outcome.error_code,
                    "errorMessage": attempt.historical_outcome.error_message,
                    "candidateChanged": attempt.historical_outcome.candidate_changed,
                    "syntaxViolation": violation.value if violation else None,
                    "rejectionCause": cause.value if cause else None,
                })
            metrics = row.get("metrics_json") or result.get("trajectory_metrics") or {}
            value = {
                "slot": int(row["ordinal"]),
                "trialId": row.get("trial_id"),
                "condition": LABELS[row["condition_fingerprint"]],
                "conditionFingerprint": row["condition_fingerprint"],
                "repetitionIndex": row["repetition_index"],
                "pid": trial.get("worker_pid"),
                "termination": trial.get("termination", "NotStarted"),
                "storedValidity": trial.get("validity"),
                "effectiveValidity": effective,
                "candidateId": candidate_id,
                "candidateOutcome": diagnostic.outcome.value,
                "strict": strict.value if strict else None,
                "gradingRunId": row.get("grading_run_id"),
                "evalResultPresent": bool(result),
                "candidateMutated": bool(candidate and candidate["final_workspace_digest"] != candidate["base_fixture_digest"]),
                "editAttempts": attempt_values,
                "usage": {
                    "durationMillis": result.get("timing", {}).get("agentMillis"),
                    "modelCalls": metrics.get("model_calls"),
                    "toolCalls": metrics.get("tool_calls"),
                    "inputTokens": metrics.get("input_tokens"),
                    "cachedInputTokens": metrics.get("cached_tokens"),
                    "outputTokens": metrics.get("output_tokens"),
                    "costMicros": metrics.get("cost_micros"),
                },
            }
            trial_values.append(value)
            by_condition[value["condition"]].append(value)

        mechanism = {
            "schemaVersion": "exp-001r4-mechanism-analysis-v1",
            "experimentId": EXPERIMENT,
            "source": "immutable operation artifacts and canonical parser grammar",
            "modelCalls": 0,
            "graderExecutions": 0,
            "conditions": {
                label: summarize_mechanism(values) for label, values in by_condition.items()
            },
            "trials": [{
                "slot": item["slot"], "trialId": item["trialId"],
                "condition": item["condition"], "effectiveValidity": item["effectiveValidity"],
                "attempts": item["editAttempts"],
            } for item in trial_values],
        }
        index = {
            "schemaVersion": "exp-001r4-trial-index-v1",
            "experimentId": EXPERIMENT,
            "planned": 6,
            "slots": trial_values,
        }
        write_json(destination / "trial-index.json", index)
        write_json(destination / "aggregate-result.json", jsonable(aggregate))
        write_json(destination / "mechanism-analysis.json", mechanism)
        write_json(destination / "failure-analysis.json", jsonable(failure))
        print(json.dumps({
            "experimentId": EXPERIMENT,
            "rows": len(rows),
            "conditions": mechanism["conditions"],
            "aggregate": jsonable(aggregate)["overall"],
            "failureSummary": jsonable(failure)["summary"],
        }, separators=(",", ":")))
    finally:
        runner.close()
    return 0


def summarize_mechanism(values: list[dict]) -> dict:
    valid = [item for item in values if item["effectiveValidity"] == "Valid"]
    attempts = [attempt for item in valid for attempt in item["editAttempts"]]
    violations = Counter(
        attempt["syntaxViolation"] for attempt in attempts if attempt["syntaxViolation"]
    )
    causes = Counter(
        attempt["rejectionCause"] for attempt in attempts if attempt["rejectionCause"]
    )
    usage_fields = (
        "durationMillis", "modelCalls", "toolCalls", "inputTokens",
        "cachedInputTokens", "outputTokens", "costMicros",
    )
    return {
        "plannedTrials": len(values),
        "executedTrials": sum(item["trialId"] is not None for item in values),
        "capabilityValidTrials": len(valid),
        "infrastructureInvalidTrials": len(values) - len(valid),
        "trialsWithEdits": sum(bool(item["editAttempts"]) for item in valid),
        "trialsWithMissingRequiredColon": sum(any(
            attempt["syntaxViolation"] == "MissingRequiredColon"
            for attempt in item["editAttempts"]
        ) for item in valid),
        "totalEditAttempts": len(attempts),
        "successfulEditAttempts": sum(
            attempt["applicationOutcome"] == "Applied" for attempt in attempts
        ),
        "rejectedEditAttempts": sum(
            attempt["parserOutcome"] == "Rejected" or attempt["applicationOutcome"] == "Rejected"
            for attempt in attempts
        ),
        "syntaxViolations": dict(violations),
        "rejectionCauses": dict(causes),
        "strictPass": sum(item["strict"] == "Pass" for item in valid),
        "candidateCorrect": sum(item["candidateOutcome"] == "Correct" for item in valid),
        "terminations": dict(Counter(item["termination"] for item in values)),
        "rawUsage": [item["usage"] for item in valid],
        "medianUsage": {
            field: median([item["usage"].get(field) for item in valid]) for field in usage_fields
        },
    }


def median(values: list) -> float | int | None:
    numbers = [value for value in values if isinstance(value, (int, float))]
    return statistics.median(numbers) if numbers else None


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
