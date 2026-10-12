package agent_host_runtime

import agent_sdk.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginInputAttachmentTests {
    @TestCase
    func AbsentDeclarationPreservesDefaultAndBrokeredToolCarriesOnlyMetadata(): Unit {
        let old = PluginContributionDefinition("run", PluginContributionKind.Tool)
        @Expect(old.inputAttachmentField, ""); @Expect(old.inputAttachmentMaxBytes, 0)
        let selected = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144)
        @Expect(selected.inputAttachmentField, "code"); @Expect(selected.inputAttachmentMaxBytes, 262144)
    }
    @TestCase
    func ServiceDataOnlyAndMalformedDeclarationsCannotOptIntoHostInputPersistence(): Unit {
        var refused: Int64 = 0
        try { let _ = PluginContributionDefinition("endpoint", PluginContributionKind.Service,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("pure", PluginContributionKind.Tool, executionProfile: PluginToolExecutionProfile.DataOnly,
            inputAttachmentField: "code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "../code", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        try { let _ = PluginContributionDefinition("run", PluginContributionKind.Tool,
            inputAttachmentField: "", inputAttachmentMaxBytes: 262144) } catch (_: IllegalArgumentException) { refused++ }
        @Expect(refused, 4)
    }
}
