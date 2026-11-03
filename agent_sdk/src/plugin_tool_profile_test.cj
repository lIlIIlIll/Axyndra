package agent_sdk
import std.unittest.*
import std.unittest.testmacro.*
@Test
class PluginToolExecutionProfileDeclarationTests {
    @TestCase
    func absentProfileKeepsOriginalBrokeredSemanticsAndOnlyToolMayReduceServices(): Unit {
        @Expect(PluginContributionDefinition("legacy",PluginContributionKind.Tool).executionProfile==PluginToolExecutionProfile.Brokered)
        @Expect(PluginContributionDefinition("pure",PluginContributionKind.Tool,executionProfile:PluginToolExecutionProfile.DataOnly).executionProfile==PluginToolExecutionProfile.DataOnly)
        for(kind in [PluginContributionKind.Command,PluginContributionKind.Service,PluginContributionKind.Provider,
            PluginContributionKind.ContextProvider,PluginContributionKind.ModelProvider]){
            var rejected=false
            try {let _=PluginContributionDefinition("wrong-kind",kind,executionProfile:PluginToolExecutionProfile.DataOnly)}
            catch(_:IllegalArgumentException){rejected=true}
            @Expect(rejected)
        }
    }
}
