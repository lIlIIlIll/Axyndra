package agent_sdk

import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginCommandControlDeclarationTests {
    @TestCase
    func onlyCommandMayDeclareKnownUserControl(): Unit {
        for (kind in [PluginContributionKind.Tool, PluginContributionKind.Provider, PluginContributionKind.Service,
            PluginContributionKind.ContextProvider, PluginContributionKind.ModelProvider]) {
            var rejected = false
            try { let _ = PluginContributionDefinition("entry", kind, allowedUserControls: ["continuation"]) }
            catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected)
        }
        for (controls in [["unknown"], ["continuation", "continuation"]]) {
            var rejected = false
            try { let _ = PluginContributionDefinition("entry", PluginContributionKind.Command, allowedUserControls: controls) }
            catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected)
        }
        @Expect(PluginContributionDefinition("legacy", PluginContributionKind.Command).allowedUserControls().isEmpty())
    }

    @TestCase
    func declarationDefensivelyFreezesBothDirections(): Unit {
        let input = ["continuation"]
        let definition = PluginContributionDefinition("goal", PluginContributionKind.Command, allowedUserControls: input)
        input[0] = "changed"
        let returned = definition.allowedUserControls()
        returned[0] = "changed-again"
        @Expect(definition.allowedUserControls().size, 1)
        @Expect(definition.allowedUserControls()[0], "continuation")
    }
}
