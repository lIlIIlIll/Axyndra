from __future__ import annotations

from typing import Any, Mapping

from .util import hash_json


MODEL_STREAM_FAULT_SCHEMA_VERSION = "omp-evals-model-stream-fault-v1"


def canonical_model_stream_fault_profile(value: Mapping[str, Any]) -> dict[str, Any]:
    expected = {
        "schemaVersion", "id", "boundary", "triggerAttemptOrdinal",
        "partialItemTypes", "partialText", "faultDelayMillis", "typedFailure",
        "implementationFailureKind", "faultedAttemptDownstreamPolicy",
        "healthyRetryPolicy",
    }
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        raise ValueError("missing model stream fault fields: " + ", ".join(sorted(missing)))
    if unknown:
        raise ValueError("unknown model stream fault fields: " + ", ".join(sorted(unknown)))
    if value["schemaVersion"] != MODEL_STREAM_FAULT_SCHEMA_VERSION:
        raise ValueError("unsupported model stream fault schema")
    if value["id"] != "IncompleteStreamFaultProfileV1":
        raise ValueError("unsupported model stream fault profile")
    if value["boundary"] != "ModelPortTransportBoundary":
        raise ValueError("fault must be injected at the model transport boundary")
    if int(value["triggerAttemptOrdinal"]) != 1:
        raise ValueError("V1 must fault attempt one only")
    if list(value["partialItemTypes"]) != ["TextDelta"] or not str(value["partialText"]):
        raise ValueError("V1 requires one non-empty text delta")
    if int(value["faultDelayMillis"]) != 50:
        raise ValueError("V1 deterministic fault delay drift")
    if value["typedFailure"] != "IncompleteStreamingModelAttemptTimeout":
        raise ValueError("fault must reach the frozen incomplete-stream failure family")
    if value["implementationFailureKind"] != "StreamIdleTimeout":
        raise ValueError("fault implementation failure kind drift")
    if value["faultedAttemptDownstreamPolicy"] != "BypassConfiguredProvider":
        raise ValueError("faulted attempt must not depend on a live provider")
    if value["healthyRetryPolicy"] != "DelegateToConfiguredModelPort":
        raise ValueError("healthy retry must use the ordinary configured model path")
    return {
        "schemaVersion": MODEL_STREAM_FAULT_SCHEMA_VERSION,
        "id": "IncompleteStreamFaultProfileV1",
        "boundary": "ModelPortTransportBoundary",
        "triggerAttemptOrdinal": 1,
        "partialItemTypes": ["TextDelta"],
        "partialText": str(value["partialText"]),
        "faultDelayMillis": 50,
        "typedFailure": "IncompleteStreamingModelAttemptTimeout",
        "implementationFailureKind": "StreamIdleTimeout",
        "faultedAttemptDownstreamPolicy": "BypassConfiguredProvider",
        "healthyRetryPolicy": "DelegateToConfiguredModelPort",
    }


def model_stream_fault_profile_digest(value: Mapping[str, Any]) -> str:
    return hash_json(canonical_model_stream_fault_profile(value))
