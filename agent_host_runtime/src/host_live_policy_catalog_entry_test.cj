package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HostLivePolicyCatalogEntryTests {
    @TestCase
    func actualMountedExecutorKeepsItsOwnedObjectIdentity(){
        let host=HostJavaScriptPluginHost({path=>HostLocalReadTargetInspector(path)})
        try{
            let actual=HostJavaScriptPluginToolExecutor(host,"axyndra:memory","recall")
            let entry=ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition("plugin.axyndra:memory.recall",
                "actual mounted executor",objectValue([])),Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:memory")),actual)
            let owned=entry.executor as OwnedToolExecutor
            @Expect(owned.isSome(),true)
            let objectIdentity=owned.getOrThrow() as Object
            @Expect(objectIdentity.isSome(),true)
            @Expect(refEq(actual,objectIdentity.getOrThrow()),true)
            let catalog=ToolCatalog()
            @Expect(catalog.registerBatch([entry]).isOk(),true)
            @Expect(catalog.publishedDescriptor("plugin.axyndra:memory.recall").isSome(),true)
        }finally{let _=host.close()}
    }
    @TestCase
    func actualResolverKeepsLiveParentMutationAndOldReadonlySeparate(){
        let host=HostJavaScriptPluginHost({path=>HostLocalReadTargetInspector(path)})
        try{
            let actual=HostJavaScriptPluginToolExecutor(host,"axyndra:memory","recall")
            let catalog=ToolCatalog()
            let selected=ToolDescriptor(ModelToolDefinition("plugin.axyndra:memory.recall","live",objectValue([])),
                Capability(CapabilityKind.ExtensionInvoke,resource:"axyndra:memory"),sideEffecting:true,
                neverReplay:true,sideEffectResolver:Some({call=>true}))
            let old=ToolDescriptor(ModelToolDefinition("plugin.old.recall","old",objectValue([])),
                Capability(CapabilityKind.ExtensionInvoke,resource:"old"),sideEffecting:true,
                sideEffectResolver:Some({call=>false}))
            @Expect(catalog.registerBatch([ToolCatalogRegistration(selected,actual),ToolCatalogRegistration(old,actual)]).isOk(),true)
            @Expect(catalog.isReadOnly(ToolCall("live-call","plugin.axyndra:memory.recall",objectValue([]))),false)
            @Expect(catalog.isReadOnly(ToolCall("old-call","plugin.old.recall",objectValue([]))),true)
        }finally{let _=host.close()}
    }
    @TestCase
    func initialRejectedParentUsesOriginalBlankReasonError(){
        let call=ToolCall("original-parent","plugin.axyndra:memory.retain",objectValue([]))
        let error=hostLivePolicyParentUserRejection(call,ApprovalDecision.RejectWithReason(" "))
        @Expect(error.kind,AgentErrorKind.PermissionDenied)
        @Expect(error.code,"tool.approval_rejected")
        @Expect(error.message,"user rejected the pending tool operation")
        @Expect(error.fields.size,1)
        @Expect(error.fields[0].value,call.name)
    }
    @TestCase
    func initialRejectedParentPreservesOriginalCompleteReasonAndOutput(){
        let call=ToolCall("original-parent","plugin.axyndra:memory.retain",objectValue([]))
        let error=hostLivePolicyParentUserRejection(call,ApprovalDecision.RejectWithReason("保留原说明 "))
        @Expect(error.message,"user rejected the pending tool operation: 保留原说明 ")
        @Expect(error.fields.size,2)
        @Expect(error.fields[1].value,"保留原说明 ")
        let result=recoverableToolResult(call,error,receiptId:"actual-parent-operation")
        @Expect(result.callId,call.callId)
        @Expect(result.receiptId,"actual-parent-operation")
        @Expect(result.isError,true)
        @Expect(result.output.field("error").getOrThrow().text,error.code)
    }
}
