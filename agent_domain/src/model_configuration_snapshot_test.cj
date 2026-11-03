package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelConfigurationSnapshotTests {
    @TestCase
    func absentConfigurationDigestPreservesExactHistoricFingerprint(): Unit {
        let thinking = ThinkingCapabilities(ThinkingControlMode.NoThinking)
        let expected = "snapshot_schema_version=1\nmodel_id=7:fixture\nthinking_mode=none\n" +
            "supported_levels=\nbudget_tiers=\nmodel_max_output_tokens=2048\nendpoint_max_output_tokens=-\n"
        let value = ModelExecutionCapabilitiesSnapshot("fixture", thinking, 2048)
        @Expect(canonicalModelCapabilitySnapshotPayload(1u32, "fixture", thinking, 2048, None), expected)
        @Expect(value.capabilityFingerprint, modelPolicySha256Text(expected))
        @Expect(value.configurationDigest, "")
    }
    @TestCase
    func sameCapabilitiesDifferentConfigurationHaveDifferentPolicyWitnesses(): Unit {
        let thinking = ThinkingCapabilities(ThinkingControlMode.NoThinking)
        let left = ModelExecutionCapabilitiesSnapshot("fixture", thinking, 2048,
            configurationDigest: modelPolicySha256Text("configuration-a"))
        let right = ModelExecutionCapabilitiesSnapshot("fixture", thinking, 2048,
            configurationDigest: modelPolicySha256Text("configuration-b"))
        @Expect(left.capabilityFingerprint != right.capabilityFingerprint)
        let policy = resolveModelAttemptPolicy(AttemptPolicyInput(
            RequestedModelPolicy(ThinkingLevel.Off, RequestOutputBudget(2048)), left)).value().getOrThrow()
        @Expect(policy.capabilitySnapshotPayload.contains("configuration_digest=" + left.configurationDigest + "\n"))
        @Expect(policy.capabilityFingerprint, left.capabilityFingerprint)
    }
    @TestCase
    func malformedConfigurationDigestCannotBecomeACapabilityFingerprint(): Unit {
        for (bad in ["x", "sha256:" + modelPolicySha256Text("configuration"),
            "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"]) {
            var rejected = false
            try { let _ = ModelExecutionCapabilitiesSnapshot("fixture", ThinkingCapabilities(ThinkingControlMode.NoThinking),
                2048, configurationDigest: bad) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
}
