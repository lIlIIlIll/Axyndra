from __future__ import annotations

from typing import Any, Mapping

from .util import hash_json


MODEL_STREAM_RECOVERY_SCHEMA_VERSION = "omp-evals-model-stream-recovery-v1"
_MODES = {"Disabled", "RecoveryV1"}


def canonical_model_stream_recovery_policy(value: Mapping[str, Any]) -> dict[str, Any]:
    expected = {
        "schemaVersion", "scope", "mode", "attemptTimeoutSemantics",
        "attemptTimeoutMillis", "maxRecoveryRetries", "retryableFailureKinds",
        "reuseSameInput", "partialAttemptCommitPolicy", "toolCallObservedPolicy",
        "wallBudgetBehavior", "cancellationPrecedence",
    }
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        raise ValueError("missing model stream recovery policy fields: " + ", ".join(sorted(missing)))
    if unknown:
        raise ValueError("unknown model stream recovery policy fields: " + ", ".join(sorted(unknown)))
    if value["schemaVersion"] != MODEL_STREAM_RECOVERY_SCHEMA_VERSION:
        raise ValueError("unsupported model stream recovery policy schema")
    mode = str(value["mode"])
    if mode not in _MODES:
        raise ValueError("unsupported model stream recovery mode")
    retries = int(value["maxRecoveryRetries"])
    if retries != (0 if mode == "Disabled" else 1):
        raise ValueError("model stream recovery mode/retry count mismatch")
    timeout = int(value["attemptTimeoutMillis"])
    if timeout != 120000:
        raise ValueError("EXP-002R must enforce the frozen 120000ms attempt timeout")
    if value["scope"] != "AllStreamingModelAttempts":
        raise ValueError("unsupported model stream recovery scope")
    if value["attemptTimeoutSemantics"] != "WholeAttempt":
        raise ValueError("unsupported attempt timeout semantics")
    if list(value["retryableFailureKinds"]) != ["IncompleteStreamingModelAttemptTimeout"]:
        raise ValueError("unsupported retryable failure kinds")
    if value["reuseSameInput"] is not True:
        raise ValueError("recovery must reuse the same semantic input")
    if value["partialAttemptCommitPolicy"] != "DiagnosticOnlyUntilCompleted":
        raise ValueError("partial attempt output must remain diagnostic-only")
    if value["toolCallObservedPolicy"] != "DoNotRetry":
        raise ValueError("attempts with tool-call output must not be retried")
    if value["wallBudgetBehavior"] != "ConsumeRemainingGlobalBudget":
        raise ValueError("recovery must not extend the global wall budget")
    precedence = list(value["cancellationPrecedence"])
    if precedence != ["UserCancellation", "ExperimentCancellation", "GlobalDeadline", "HardBudget", "ProcessShutdown"]:
        raise ValueError("invalid recovery cancellation precedence")
    return {
        "schemaVersion": MODEL_STREAM_RECOVERY_SCHEMA_VERSION,
        "scope": "AllStreamingModelAttempts",
        "mode": mode,
        "attemptTimeoutSemantics": "WholeAttempt",
        "attemptTimeoutMillis": timeout,
        "maxRecoveryRetries": retries,
        "retryableFailureKinds": ["IncompleteStreamingModelAttemptTimeout"],
        "reuseSameInput": True,
        "partialAttemptCommitPolicy": "DiagnosticOnlyUntilCompleted",
        "toolCallObservedPolicy": "DoNotRetry",
        "wallBudgetBehavior": "ConsumeRemainingGlobalBudget",
        "cancellationPrecedence": precedence,
    }


def model_stream_recovery_policy_digest(value: Mapping[str, Any]) -> str:
    return hash_json(canonical_model_stream_recovery_policy(value))
