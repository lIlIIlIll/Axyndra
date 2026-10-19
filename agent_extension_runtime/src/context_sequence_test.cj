package agent_extension_runtime

import agent_sdk.*
import std.unittest.*
import std.unittest.testmacro.*

func contextSequenceRequest(selected!:Bool=false,content!:Bool=true,policy!:Bool=false,ordinary!:Bool=false,
    capabilities!:Array<String>=[],declared!:Bool=true):JavaScriptHostLaunchRequest{
    JavaScriptHostLaunchRequest("/tmp/context-sequence-contract","worker",extensionId:"context-sequence",extensionVersion:"1.0.0",
        profile:JavaScriptHostLaunchProfile.NativeExecutable,contributions:if(declared){
            [PluginContributionDefinition("observe",PluginContributionKind.ContextProvider),PluginContributionDefinition("propose",PluginContributionKind.Provider),
                PluginContributionDefinition("call",PluginContributionKind.Tool)]}else{[PluginContributionDefinition("propose",PluginContributionKind.Provider)]},
        grantedCapabilities:capabilities,contentPayload:content,ordinaryToolPayload:ordinary,providerSequence:policy,contextSequence:selected)
}
@Test
class PureContextSequenceRequestTests {
    @TestCase
    func defaultActualMixedContentRequestKeepsItsOriginalUnextendedHandshake():Unit{
        let old=contextSequenceRequest();@Expect(old.contextSequence,false);@Expect(purePolicySequenceOffered(old),false)
        let selected=contextSequenceRequest(selected:true);@Expect(selected.contextSequence,true);@Expect(selected.providerSequence,false)
        @Expect(purePolicySequenceOffered(selected),false)
    }
    @TestCase
    func selectedContextWorkerRequiresTheActualTypedDeclarationAndContentOffer():Unit{
        var missing=false;try{let _=contextSequenceRequest(selected:true,declared:false)}catch(_:Exception){missing=true}
        @Expect(missing,true);var noContent=false;try{let _=contextSequenceRequest(selected:true,content:false)}catch(_:Exception){noContent=true}
        @Expect(noContent,true)
    }
    @TestCase
    func selectedContextWorkerCannotCombinePolicySequenceOrOrdinaryToolProfile():Unit{
        var policy=false;try{let _=contextSequenceRequest(selected:true,policy:true)}catch(_:Exception){policy=true};@Expect(policy,true)
        var ordinary=false;try{let _=contextSequenceRequest(selected:true,ordinary:true)}catch(_:Exception){ordinary=true};@Expect(ordinary,true)
    }
    @TestCase
    func manifestCapabilitiesNeverSupplyAnAmbientSequenceWorkerGrant():Unit{
        var denied=false;try{let _=contextSequenceRequest(selected:true,capabilities:["document.store"])}catch(_:Exception){denied=true}
        @Expect(denied,true);@Expect(contextSequenceRequest(selected:true).grantedCapabilities.isEmpty(),true)
    }
}
