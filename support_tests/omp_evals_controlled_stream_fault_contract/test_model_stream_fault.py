from __future__ import annotations

import unittest

from omp_evals.model_stream_fault import (
    canonical_model_stream_fault_profile, model_stream_fault_profile_digest,
)


def profile() -> dict:
    return {
        "schemaVersion": "omp-evals-model-stream-fault-v1",
        "id": "IncompleteStreamFaultProfileV1",
        "boundary": "ModelPortTransportBoundary",
        "triggerAttemptOrdinal": 1,
        "partialItemTypes": ["TextDelta"],
        "partialText": "controlled incomplete stream",
        "faultDelayMillis": 50,
        "typedFailure": "IncompleteStreamingModelAttemptTimeout",
        "implementationFailureKind": "StreamIdleTimeout",
        "faultedAttemptDownstreamPolicy": "BypassConfiguredProvider",
        "healthyRetryPolicy": "DelegateToConfiguredModelPort",
    }


class ModelStreamFaultProfileContract(unittest.TestCase):
    def test_profile_is_canonical_and_stable(self) -> None:
        value = profile()
        self.assertEqual(canonical_model_stream_fault_profile(value), value)
        self.assertEqual(len(model_stream_fault_profile_digest(value)), 64)

    def test_fault_profile_rejects_timing_or_scope_drift(self) -> None:
        for field, changed in (
            ("triggerAttemptOrdinal", 2),
            ("faultDelayMillis", 51),
            ("partialItemTypes", ["ToolCall"]),
            ("implementationFailureKind", "GenericTimeout"),
        ):
            value = profile()
            value[field] = changed
            with self.assertRaises(ValueError):
                canonical_model_stream_fault_profile(value)


if __name__ == "__main__":
    unittest.main()
