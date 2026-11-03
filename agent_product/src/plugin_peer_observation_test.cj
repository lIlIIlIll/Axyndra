package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerConfigure111(f: WorkflowChildFixture111): Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
            ValueField("tools",listValue([
                objectValue([ValueField("name",textValue("task")),ValueField("profile",textValue("frozen-primitives-v1")),
                    ValueField("services",listValue([textValue("child.start")])),ValueField("preparation_provider",textValue("prepare_child"))]),
                objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
                    ValueField("services",listValue([textValue("peer.list")])),ValueField("preparation_provider",textValue("prepare_child"))])]))])]))])).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func peerCall111(f: WorkflowChildFixture111,id: String): ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("list"))]))
}
private func peerExpectRefused111(result: Result<ToolInvocationResult>): Unit {
    match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
        case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
        case _=>@Expect(false)}
}
@Test
class InstalledWorkflowPeerObservationTests111 {
    @TestCase
    func originalWorkspaceReadCanListWithTwoReadonlyReceiptsAndNoDelegation(): Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk)
        try {
            peerConfigure111(f)
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("peer-root"),
                f.capabilities(delegate:false),peerCall111(f,"peer-list"),budget:f.budget()))
            try {
                @Expect(!result.isError)
                @Expect(encodeAgentValue(result.output),"{\"op\":\"list\",\"peers\":[{\"id\":\"Main\",\"kind\":\"main\",\"status\":\"running\"}]}")
                expectCanonicalReturnedReceipt(f.database,result)
            } finally {result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            f.database.transaction{tx:SqliteTransaction=>
                let rows=tx.query("SELECT normalized_plan FROM operations ORDER BY id")
                @Expect(rows.size,2)
                for(row in rows){let plan=decodeOperationPlan(row.required(0))
                    @Expect(plan.effectClass,OperationEffectClass.ReadOnly)
                    @Expect(plan.requiredCapabilities.size,2)
                    for(cap in plan.requiredCapabilities){@Expect(cap.kind!=CapabilityKind.Delegate);@Expect(cap.kind!=CapabilityKind.PeerMessage)}
                }
            }
        } finally {f.close()}
    }
    @TestCase
    func anotherActualThreadCannotObserveAnOwnedChildFromTheFirstRoot(): Unit {
        let f=WorkflowChildFixture111()
        try {
            peerConfigure111(f)
            let started=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("peer-owner"),
                f.capabilities(),f.call("peer-child"),budget:f.budget()))
            try{@Expect(!started.isError)}finally{started.releasePayload()}
            for(thread in ["peer-owner","peer-foreign"]){
                let listed=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId(thread),
                    f.capabilities(delegate:false),peerCall111(f,thread+"-list"),budget:f.budget()))
                try {
                    @Expect(!listed.isError)
                    @Expect(listed.output.field("peers").getOrThrow().items.size,if(thread=="peer-owner"){2}else{1})
                } finally {listed.releasePayload()}
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),3)
        } finally {f.close()}
    }
    @TestCase
    func peerMessageOrDelegateCannotSubstituteForOriginalWorkspaceRead(): Unit {
        for(kind in [CapabilityKind.PeerMessage,CapabilityKind.Delegate]){
            let f=WorkflowChildFixture111()
            try {
                peerConfigure111(f)
                peerExpectRefused111(f.product.vnext.executeCanonicalTool(SessionId("peer-denied"),
                    CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:f.namespace),Capability(kind)]),
                    peerCall111(f,"peer-denied"),budget:f.budget()))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            } finally {f.close()}
        }
    }
    @TestCase
    func approvedReadonlyObservationStillRejectsRevokedContributionWithoutChildReceipt(): Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.Write)
        let cancellation=CancellationSource()
        let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try {
            peerConfigure111(f)
            let started=f.product.vnext.executeDeferredCanonicalTool(SessionId("peer-approval"),f.capabilities(delegate:false),
                peerCall111(f,"peer-approval"),owner,cancellation.token,budget:f.budget())
            @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
            let pending=owner.approval().getOrThrow()
            @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
            peerExpectRefused111(owner.decide(pending.operationId.value,ApprovalDecision.Approve))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
        } finally {let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
    }
}
