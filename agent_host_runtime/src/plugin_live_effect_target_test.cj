package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func liveTargetCeiling(root:String):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CEILING_SCHEMA)),
        ValueField("documents",listValue([])),ValueField("filesystem",listValue([objectValue([
            ValueField("root",textValue("selected")),ValueField("canonical_root",textValue(root)),
            ValueField("operations",listValue([textValue("directory.create"),textValue("file.atomic_write")]))])]))])
}
private func liveTargetEffect(root:String,relative:String,kind!:String="file.atomic_write"):AgentValue{
    objectValue([ValueField("kind",textValue(kind)),ValueField("root",textValue("selected")),
        ValueField("relative_path",textValue(relative)),ValueField("canonical_path",textValue(Path(root).join(relative).toString()))])
}
private func liveTargetHost():HostJavaScriptPluginHost{
    HostJavaScriptPluginHost({root=>HostLocalReadTargetInspector(root)})
}
// This trusted test executor intentionally has no effect implementation. It
// proves catalog interface retention only, not a known Receipt or Native/FS
// acceptance. Preparing a descriptor must never invoke either entry.
private class LiveTargetTypedExecutor <: ToolExecutor & OwnedToolEffectExecutor{
    var calls:Int64=0
    public func execute(_:ToolInvocationContext,_:PreparedToolInvocation):Result<ToolResult>{
        calls++;Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,"test.no_effect","test effect remains unimplemented"))}
    public func executeLiveEffect(context:ToolInvocationContext,child:PreparedToolInvocation):ToolExecutionOutcome{
        ToolExecutionOutcome(execute(context,child))}
}
private class LiveTargetOrdinaryExecutor <: ToolExecutor{
    public func execute(_:ToolInvocationContext,_:PreparedToolInvocation):Result<ToolResult>{
        Result<ToolResult>.Err(AgentError(AgentErrorKind.PermissionDenied,"test.no_effect","ordinary executor cannot enter the live family"))}
}

@Test
class HostPluginLiveEffectTargetTests{
    @TestCase
    func MissingTargetUsesItsRealAncestorWithoutCreatingOrWritingAnything():Unit{
        let root=Directory.createTemp("/tmp")
        try{let selected=canonicalize(root).toString();let effect=liveTargetEffect(selected,"missing/SKILL.md")
            @Expect(hostPluginLiveFilesystemTarget(liveTargetCeiling(selected),effect).value().getOrThrow(),selected+"/missing/SKILL.md")
            @Expect(exists(root.join("missing")),false)
            @Expect(exists(root.join("missing/SKILL.md")),false)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func ClaimedCanonicalPathAndUnknownRootCannotChooseAnotherPhysicalTarget():Unit{
        let root=Directory.createTemp("/tmp")
        try{let selected=canonicalize(root).toString();let effect=liveTargetEffect(selected,"sample/SKILL.md")
            effect.put("canonical_path",textValue(selected+"/another/SKILL.md"))
            @Expect(hostPluginLiveFilesystemTarget(liveTargetCeiling(selected),effect).isError(),true)
            let other=liveTargetEffect(selected,"sample/SKILL.md");other.put("root",textValue("unselected"))
            @Expect(hostPluginLiveFilesystemTarget(liveTargetCeiling(selected),other).isError(),true)
            @Expect(exists(root.join("sample")),false)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func RootItselfTraversalAndUnselectedPrimitiveRemainClosed():Unit{
        let root=Directory.createTemp("/tmp")
        try{let selected=canonicalize(root).toString()
            for(relative in ["",".","..","../outside","sample/../outside","sample//SKILL.md","sample\\SKILL.md"]){
                @Expect(hostPluginLiveFilesystemTarget(liveTargetCeiling(selected),liveTargetEffect(selected,relative)).isError(),true)}
            @Expect(hostPluginLiveFilesystemTarget(liveTargetCeiling(selected),liveTargetEffect(selected,"sample",kind:"directory.delete_tree")).isError(),true)
            @Expect(exists(root),true)
        }finally{remove(root,recursive:true)}
    }
    @TestCase
    func RegistrationRetainsTheActualTypedExecutorAndNeverCallsIt():Unit{
        let f=LivePolicyCanonicalFixture();let host=liveTargetHost()
        try{let catalog=ToolCatalog();let executor=LiveTargetTypedExecutor()
            @Expect(hostRegisterPluginLiveEffect(host,f.store,catalog,executor).isOk(),true)
            let actual=catalog.publishedDescriptor(HOST_PLUGIN_LIVE_EFFECT_TOOL).getOrThrow()
            @Expect(catalog.publicationRetainsExecutor(HOST_PLUGIN_LIVE_EFFECT_TOOL,executor),true)
            @Expect((executor as OwnedToolEffectExecutor).isSome(),true)
            @Expect(actual.hostServiceOnly,true)
            @Expect(actual.neverReplay,true)
            @Expect(actual.additionalCapabilities.isEmpty(),true)
            @Expect(executor.calls,0)
            @Expect(hostRegisterPluginLiveEffect(host,f.store,ToolCatalog(),LiveTargetOrdinaryExecutor()).isError(),true)
        }finally{let _=host.close();f.close()}
    }
    @TestCase
    func RealNormalizerUsesOneExactRequirementAndTheUnchangedClassification():Unit{
        let f=LivePolicyCanonicalFixture();let host=liveTargetHost()
        try{let call=f.child(f.parentPlan(f.latest()))[0]
            let descriptor=hostPluginLiveEffectDescriptor(host,f.store)
            let context=ToolInvocationContext(f.active.runId,SessionId(f.active.threadId.value),
                CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture")]),epoch:f.active.epoch)
            let journal=normalizedToolOperationPlan(context,call,descriptor.resolved(call))
            @Expect(isPluginLivePolicyStreamingChildPlan(journal),true)
            @Expect(journal.effectClass,OperationEffectClass.ExternalMutation)
            @Expect(journal.requiredCapabilities.size,1)
            call.arguments.put("effect",liveTargetEffect(f.root,"sample/SKILL.md"))
            let filesystem=normalizedToolOperationPlan(context,call,descriptor.resolved(call))
            @Expect(isPluginLivePolicyStreamingChildPlan(filesystem),true)
            @Expect(filesystem.effectClass,OperationEffectClass.WorkspaceMutation)
            @Expect(filesystem.requiredCapabilities.size,1)
            @Expect(filesystem.requiredCapabilities[0].resource,f.root+"/sample/SKILL.md")
        }finally{let _=host.close();f.close()}
    }
    @TestCase
    func MissingActualPackageCannotPrepareOrHandoffAnOtherwiseRealReadProposal():Unit{
        let f=LivePolicyCanonicalFixture(committed:true);let host=liveTargetHost()
        try{let call=f.child(f.parentPlan(f.latest()))[0]
            let context=ToolInvocationContext(f.active.runId,SessionId(f.active.threadId.value),
                CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:live-fixture")]),epoch:f.active.epoch)
            let operations=f.count("SELECT COUNT(*) FROM operations")
            let receipts=f.count("SELECT COUNT(*) FROM operation_receipts")
            let handoffs=f.count("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'")
            @Expect(hostPluginLiveEffectDescriptor(host,f.store).canonicalizedCall(context,call).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations"),operations)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts"),receipts)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),handoffs)
        }finally{let _=host.close();f.close()}
    }
}
