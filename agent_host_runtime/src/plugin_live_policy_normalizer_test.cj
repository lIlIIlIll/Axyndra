package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real descriptor -> unchanged common normalizer, with an actually completed
// canonical read from the fixture. This tests classification, not an effect
// execution, approval, Source factory or admitted child.
private func liveNormalizerPlan(f:LivePolicyCanonicalFixture,call:ToolCall,capability:Capability):NormalizedOperationPlan{
    let context=ToolInvocationContext(f.active.runId,SessionId(f.active.threadId.value),CapabilitySet(values:[capability]),
        epoch:f.active.epoch,toolContext:ToolContextDescriptor(workspaceRoot:f.root,cwd:f.root),cancellation:f.cancellation.token)
    let definition=ModelToolDefinition(call.name,"generic live-effect classifier",objectValue([ValueField("type",textValue("object"))]))
    let descriptor=ToolDescriptor(definition,capability,sideEffecting:true,neverReplay:true,
        implementationVersion:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT,implementationFingerprint:HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT)
    normalizedToolOperationPlan(context,call,descriptor.resolved(call))
}
private func liveNormalizerFilesystemCall(f:LivePolicyCanonicalFixture,kind:String):ToolCall{
    let fact=f.latest();let child=f.child(f.parentPlan(fact));let args=child[0].arguments
    args.put("effect",objectValue([ValueField("kind",textValue(kind)),ValueField("root",textValue("managed")),
        ValueField("relative_path",textValue("sample/SKILL.md")),ValueField("canonical_path",textValue(f.root+"/managed/sample/SKILL.md"))]))
    ToolCall(child[0].callId,child[0].name,args)
}

@Test
class PluginLivePolicyRealNormalizerTests{
    @TestCase
    func ActualFilesystemDescriptorHasWorkspaceClassAndStrictStreamingEnvelope():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let call=liveNormalizerFilesystemCall(f,"file.atomic_write")
            let plan=liveNormalizerPlan(f,call,Capability(CapabilityKind.WorkspaceWrite,resource:f.root+"/managed/sample/SKILL.md"))
            @Expect(plan.effectClass,OperationEffectClass.WorkspaceMutation)
            @Expect(plan.requiredCapabilities.size,1)
            @Expect(plan.requiredCapabilities[0].kind,CapabilityKind.WorkspaceWrite)
            @Expect(isPluginLivePolicyStreamingChildPlan(plan),true)
        }finally{f.close()}
    }
    @TestCase
    func ActualJournalDescriptorKeepsExternalClassAndNamespaceCapability():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let call=f.child(f.parentPlan(fact))[0]
            let plan=liveNormalizerPlan(f,call,Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture"))
            @Expect(plan.effectClass,OperationEffectClass.ExternalMutation)
            @Expect(plan.requiredCapabilities.size,1)
            @Expect(isPluginLivePolicyStreamingChildPlan(plan),true)
        }finally{f.close()}
    }
    @TestCase
    func DirectoryCreateAndDeleteUseTheSameActualWorkspaceClassification():Unit{
        for(kind in ["directory.create","directory.delete_tree"]){
            let f=LivePolicyCanonicalFixture()
            try{let call=liveNormalizerFilesystemCall(f,kind)
                let plan=liveNormalizerPlan(f,call,Capability(CapabilityKind.WorkspaceWrite,resource:f.root+"/managed/sample/SKILL.md"))
                @Expect(plan.effectClass,OperationEffectClass.WorkspaceMutation)
                @Expect(isPluginLivePolicyStreamingChildPlan(plan),true)
            }finally{f.close()}
        }
    }
    @TestCase
    func WorkspaceFilesystemPlanDoesNotWidenOriginalClosedV1Family():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let call=liveNormalizerFilesystemCall(f,"file.atomic_write");let args=call.arguments
            args.put("schema",textValue(PLUGIN_LIVE_POLICY_CHILD_SCHEMA));args.put("prior_receipts",listValue([]))
            let oldCall=ToolCall(call.callId,call.name,args)
            let plan=liveNormalizerPlan(f,oldCall,Capability(CapabilityKind.WorkspaceWrite,resource:f.root+"/managed/sample/SKILL.md"))
            @Expect(plan.effectClass,OperationEffectClass.WorkspaceMutation)
            @Expect(isPluginLivePolicyChildPlan(plan),false)
            @Expect(isPluginLivePolicyStreamingChildPlan(plan),false)
        }finally{f.close()}
    }
}
