package agent_extension_runtime

import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*

func providerSequenceRequest(selected!: Bool = false, content!: Bool = true,
    capabilities!: Array<String> = [], pure!: Bool = false): JavaScriptHostLaunchRequest {
    JavaScriptHostLaunchRequest("/tmp/pure-sequence-contract", "worker",
        extensionId: "mixed-sequence", extensionVersion: "1.0.0",
        profile: JavaScriptHostLaunchProfile.NativeExecutable,
        contributions: if (pure) { [PluginContributionDefinition("propose", PluginContributionKind.Provider)] }
            else { [PluginContributionDefinition("propose", PluginContributionKind.Provider),
                PluginContributionDefinition("todo", PluginContributionKind.Tool),
                PluginContributionDefinition("todo", PluginContributionKind.Command)] },
        grantedCapabilities: capabilities, contentPayload: content, providerSequence: selected)
}

@Test
class PureMixedProviderSequenceTests {
    @TestCase
    func defaultMixedHandshakeRemainsUnextended(): Unit {
        @Expect(!purePolicySequenceOffered(providerSequenceRequest()))
        @Expect(purePolicySequenceOffered(providerSequenceRequest(pure: true)))
        @Expect(purePolicySequenceOffered(providerSequenceRequest(selected: true)))
    }
    @TestCase
    func explicitMixedSequenceRequiresEmptyActualCapabilitiesBeforeLaunch(): Unit {
        var denied = false
        try { let _ = providerSequenceRequest(selected: true, capabilities: ["document.store"]) }
        catch (_: Exception) { denied = true }
        @Expect(denied)
        // Manifest declarations do not supply this grant array.
        @Expect(providerSequenceRequest(selected: true).grantedCapabilities.isEmpty())
    }
    @TestCase
    func explicitSequenceRequiresTheFrozenContentProfile(): Unit {
        var denied = false
        try { let _ = providerSequenceRequest(selected: true, content: false) }
        catch (_: Exception) { denied = true }
        @Expect(denied)
    }
}
