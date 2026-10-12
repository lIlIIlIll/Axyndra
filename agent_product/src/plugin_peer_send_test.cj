package agent_product

import agent_domain.*
import agent_core.AgentRunOutcome
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerSendSelection111(f:WorkflowChildFixture111):Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    let selected=objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
        ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),ValueField("tools",listValue([
            objectValue([ValueField("name",textValue("task")),ValueField("profile",textValue("frozen-primitives-v1")),
                ValueField("services",listValue([textValue("child.start")])),ValueField("preparation_provider",textValue("prepare_child"))]),
            objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
                ValueField("services",listValue([textValue("peer.send"),textValue("peer.receive")])),ValueField("preparation_provider",textValue("prepare_child")),
                ValueField("invocation_capability",objectValue([ValueField("catalog",textValue("workspace.read")),
                    ValueField("services",objectValue([ValueField("peer.send",textValue("peer.message")),
                        ValueField("peer.receive",textValue("workspace.read"))]))]))])]))])]))])
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(selected).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func peerSendArguments111(target:String,body:String):AgentValue {
    objectValue([ValueField("op",textValue("send")),ValueField("to",textValue(target)),ValueField("message",textValue(body))])
}
private func peerSendReject111(value:Result<ToolInvocationResult>):Unit {
    match(value){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
        case Result.Ok(ToolInvocationResult.Completed(result))=>try{@Expect(result.isError)}finally{result.releasePayload()}
        case _=>@Expect(false)}
}
private func peerSendTaskPayload111(database:SqliteDatabase):String {
    database.transaction{tx:SqliteTransaction=>
        let rows=tx.query("SELECT payload FROM task_snapshots ORDER BY root_thread_id")
        @Expect(rows.size,1);rows[0].required(0)
    }
}

@Test
class InstalledWorkflowPeerSendTests111 {
    @TestCase
    func allSixActualRolesSendThroughInstalledCanonicalPeerAndPersistNativeDelivery():Unit {
        for(name in ["task","scout","designer","reviewer","librarian","sonic"]){
            let f=WorkflowChildFixture111(mode:if(name=="scout" || name=="reviewer" || name=="sonic"){ApprovalMode.AlwaysAsk}else{ApprovalMode.Write})
            let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
            let thread=SessionId("native-peer-"+name)
            try {
                peerSendSelection111(f)
                let role=lifecycleTestRequire(queryProductWorkflowRole(f.product,name,thread,cancellation.token,"send-role-"+name))
                @Expect(role.ceiling.allows(CapabilityKind.PeerMessage));@Expect(role.ceiling.allows(CapabilityKind.ExtensionInvoke),name=="task")
                var visible=false
                for(definition in f.product.toolsFor(role.ceiling)){if(definition.name=="plugin."+f.namespace+".hub"){visible=true}}
                @Expect(visible);@Expect(role.pin.validateCurrent().isOk())
                let body="actual Native message 雪\n"+name
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("native-send-"+name,"plugin."+f.namespace+".hub",peerSendArguments111("Main",body))
                let call=ToolCall("parent-send-"+name,"plugin."+f.namespace+".task",objectValue([
                    ValueField("agent",textValue(name)),ValueField("task",textValue("Send a message to Main, then finish."))]))
                let first=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),call,owner,cancellation.token,budget:f.budget())
                @Expect(match(first){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
                let pending=owner.approval().getOrThrow()
                let result=hostServiceEntryCompleted(owner.decide(pending.operationId.value,ApprovalDecision.Approve))
                try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
                let saved=ProductTaskPersistence(f.database).loadAll()
                @Expect(saved.size,1);@Expect(saved[0].messages.size,1)
                let message=saved[0].messages[0]
                @Expect(message.snapshot.message,body);@Expect(message.snapshot.to,"Main");@Expect(!message.reviveTarget)
                @Expect(message.deliveryText111.isSome());@Expect(message.waitCallId,call.callId)
                let exact="<hub-message from=\""+message.snapshot.from+"\" id=\""+message.snapshot.id+"\">"+body+"</hub-message>"
                @Expect(message.deliveryText111.getOrThrow(),exact)
                var observed:Int64=0
                for(item in lifecycleTestRequire(f.product.messages(thread))){for(block in item.blocks){
                    if(block.kind==ModelBlockKind.Text && block.text==exact){observed+=1}}}
                @Expect(observed,1)
                f.database.transaction{tx:SqliteTransaction=>
                    let plans=tx.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                        [SqlParameter.Text("plugin."+f.namespace+".hub")])
                    @Expect(plans.size,1)
                    let plan=decodeOperationPlan(plans[0].required(0))
                    @Expect(plan.effectClass,OperationEffectClass.ReadOnly);@Expect(plan.requiredCapabilities.size,1)
                    @Expect(plan.requiredCapabilities[0].kind,CapabilityKind.PeerMessage)
                }
                // Only the actual non-readonly delegation asked. The original
                // readonly peer policy stays unchanged in both approval modes.
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='hub'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),2)
            }finally{let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
        }
    }
    @TestCase
    func actualCommittedCoreParentDrainsTheSameFrozenMailOnlyAfterItsToolResult():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("committed-native-peer")
        try {
            peerSendSelection111(f)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("committed-task","plugin."+f.namespace+".task",objectValue([
                ValueField("agent",textValue("scout")),ValueField("task",textValue("Send to Main, then finish."))]))
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("committed-child-send","plugin."+f.namespace+".hub",
                peerSendArguments111("Main","committed Native delivery"))
            let request=f.product.request("Run the selected child.",sessionId:Some(thread))
            @Expect(match(f.product.client.start(request,{_=>()})){case Result.Ok(AgentRunOutcome.Completed(_))=>true;case _=>false})
            let roots=ProductTaskPersistence(f.database).loadAll()
            @Expect(roots.size,1);@Expect(roots[0].messages.size,1)
            let mail=roots[0].messages[0];@Expect(mail.deliveryText111.isSome());@Expect(mail.waitCallId,"committed-task")
            var delivered:Int64=0
            for(item in lifecycleTestRequire(f.product.messages(thread))){for(block in item.blocks){
                if(block.kind==ModelBlockKind.Text && block.text==mail.deliveryText111.getOrThrow()){delivered+=1}}}
            @Expect(delivered,1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='task' OR tool_id='hub'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),2)
        }finally{f.close()}
    }
    @TestCase
    func actualBackgroundChildSendsAfterParentReceiptWithoutWaitingForAnAlreadyFinishedHook():Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=ChildControlledTool111(true)
        let thread=SessionId("late-native-peer")
        try {
            peerSendSelection111(f);childInstallProbe111(f,probe,false)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("late-native-send","plugin."+f.namespace+".hub",
                peerSendArguments111("Main","after actual parent completion"))
            let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),1)
            probe.released.store(true)
            @Expect(childJob111(f,thread,"completed").result.isSome())
            let saved=ProductTaskPersistence(f.database).loadAll()
            @Expect(saved.size,1);@Expect(saved[0].messages.size,1)
            let mail=saved[0].messages[0];@Expect(mail.waitCallId,"");@Expect(mail.deliveryText111.isSome())
            var count:Int64=0
            for(item in lifecycleTestRequire(f.product.messages(thread))){for(block in item.blocks){
                if(block.kind==ModelBlockKind.Text && block.text==mail.deliveryText111.getOrThrow()){count+=1}}}
            @Expect(count,1);@Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(saved[0].subagents[0].pluginCompletionDone111)
        }finally{probe.released.store(true);f.close()}
    }
    @TestCase
    func ForeignRootOrTerminatedTargetCannotAppendMailOrStartAReplacementRun():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("native-peer-member")
        try {
            peerSendSelection111(f)
            let start=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),f.call("member"),budget:f.budget()))
            let id:String
            try{@Expect(!start.isError);id=httpIntentText(start.output.field("results").getOrThrow().items[0],"id")}finally{start.releasePayload()}
            let original=peerSendTaskPayload111(f.database)
            let models=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            for(ownerThread in [thread,SessionId("foreign-message-root")]){
                let call=ToolCall("send-"+ownerThread.value,"plugin."+f.namespace+".hub",peerSendArguments111(id,"must not revive"))
                let capabilities=CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.PeerMessage)])
                // The former pilot terminal refusal now exercises its real
                // replacement: a bare decision cannot approve a separate read.
                // Foreign membership still follows the original ordinary path.
                let denied=if(ownerThread.value==thread.value){
                    f.product.vnext.executeHostServiceTool(ownerThread,HostServiceOrigin("fixture",f.namespace,f.digest,
                        modelPolicySha256Text("terminal-denial"),"terminal-denial",HostServiceAction.Start,"terminal-denial"),
                        capabilities,call,approvalDecision:Some(ApprovalDecision.Approve),budget:f.budget())
                }else{f.product.vnext.executeCanonicalTool(ownerThread,capabilities,call,budget:f.budget())}
                peerSendReject111(denied)
                @Expect(peerSendTaskPayload111(f.database),original)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),models)
            // The two real Direct caller Runs exist; no replacement child Run.
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs+2)
            @Expect(ProductTaskPersistence(f.database).loadAll()[0].messages.size,0)
        }finally{f.close()}
    }
    @TestCase
    func DelegateOrReadonlyGrantNeverSubstitutesForTheExactPeerMessageCapability():Unit {
        for(kind in [CapabilityKind.WorkspaceRead,CapabilityKind.Delegate]){
            let f=WorkflowChildFixture111()
            try {
                peerSendSelection111(f)
                peerSendReject111(f.product.vnext.executeCanonicalTool(SessionId("no-peer-grant"),CapabilitySet(values:[Capability(kind)]),
                    ToolCall("no-peer","plugin."+f.namespace+".hub",peerSendArguments111("Main","not permitted")),budget:f.budget()))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM task_snapshots"),0)
            }finally{f.close()}
        }
    }
    @TestCase
    func ActualSnapshotFailureKeepsOriginalCounterAndNoFalseCompletedPeerReceipt():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("native-peer-write-fault")
        var trigger=false
        try {
            peerSendSelection111(f)
            f.database.execute("CREATE TRIGGER deny_peer_send_111 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"deliveryText111\"')>0 BEGIN SELECT RAISE(ABORT,'peer publication denied'); END")
            trigger=true
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("native-send-fault","plugin."+f.namespace+".hub",peerSendArguments111("Main","must roll back"))
            peerSendReject111(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),f.call("send-fault"),budget:f.budget()))
            let saved=ProductTaskPersistence(f.database).loadAll()
            @Expect(saved.size,1);@Expect(saved[0].messages.size,0);@Expect(saved[0].messageCounter,0)
            f.database.transaction{tx:SqliteTransaction=>
                let rows=tx.query("SELECT r.outcome FROM operations o JOIN operation_receipts r ON r.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id='host.child.start' AND instr(o.normalized_plan,?)>0",[SqlParameter.Text("\"service\":\"peer.send\"")])
                @Expect(rows.size,1);@Expect(rows[0].required(0),"unknown")
            }
        }finally{if(trigger){f.database.execute("DROP TRIGGER deny_peer_send_111")};f.close()}
    }
}
