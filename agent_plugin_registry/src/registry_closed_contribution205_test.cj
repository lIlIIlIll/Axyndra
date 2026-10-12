package agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*

private func registryClosedContributionFrame205(throwAfterRead: Bool): Unit {
    let custody = PluginRegistryMetadataCustody()
    let paid = custody.openPayment()
    try {
        paid.ensureRetainedPeak(65536)
        let raw = PluginPackageDescriptor("closed-contribution205", "1.0.0", PluginEcosystem.Axyndra,
            PluginManifestFamily.Axyndra, "actual-private-metadata205", entryKind: PluginEntryKind.NativeExecutable,
            contributions: [
                PluginContributionDefinition("plan_write", PluginContributionKind.Tool, executionProfile: PluginToolExecutionProfile.DataOnly),
                PluginContributionDefinition("brokered", PluginContributionKind.Tool),
                PluginContributionDefinition("command", PluginContributionKind.Command)])
        let descriptor = OwnedPluginPackageDescriptor(PluginRegistryOwnedBacking(raw, paid))
        try {
            let before = nativeControlMetadataUsage113()
            for (_ in 0..64) {
                @Expect(descriptor.hasToolExecutionProfile205("plan_write", PluginToolExecutionProfile.DataOnly), true)
                @Expect(descriptor.hasToolExecutionProfile205("plan_write", PluginToolExecutionProfile.Brokered), false)
                @Expect(descriptor.hasToolExecutionProfile205("brokered", PluginToolExecutionProfile.DataOnly), false)
                @Expect(descriptor.hasToolExecutionProfile205("brokered", PluginToolExecutionProfile.Brokered), true)
                @Expect(descriptor.hasToolExecutionProfile205("command", PluginToolExecutionProfile.Brokered), false)
                @Expect(descriptor.hasToolExecutionProfile205("absent", PluginToolExecutionProfile.DataOnly), false)
                let after = nativeControlMetadataUsage113()
                @Expect(after[0], before[0]); @Expect(after[1], before[1])
            }
            if (throwAfterRead) { throw IllegalStateException("actual closed predicate caller failure205") }
        } finally { descriptor.close() }
    } finally { paid.close(); custody.close() }
}

@Test
class RegistryClosedContribution205Tests {
    @TestCase
    func exactKindNameAndProfilePredicateRepeatsWithoutEscapedArrayOrPayment(): Unit {
        let before = nativeControlMetadataUsage113()
        registryClosedContributionFrame205(false)
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func realThrowReturnsPrivateDescriptorAfterCompleteCallerFrameWithoutLegacyRefund(): Unit {
        let before = nativeControlMetadataUsage113()
        var failed = false
        try { registryClosedContributionFrame205(true) }
        catch (error: IllegalStateException) { failed = error.message == "actual closed predicate caller failure205" }
        @Expect(failed, true)
        let after = nativeControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
