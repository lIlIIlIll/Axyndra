package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func peerResumeSelection111(f:WorkflowChildFixture111,mapped!:Bool=true):Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    let hub=objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
        ValueField("services",listValue([textValue("peer.send"),textValue("peer.receive")])),
        ValueField("preparation_provider",textValue("prepare_child"))])
    if(mapped){hub.put("invocation_capability",objectValue([ValueField("catalog",textValue("workspace.read")),
        ValueField("services",objectValue([ValueField("peer.send",textValue("peer.message")),
            ValueField("peer.receive",textValue("workspace.read"))]))]))}
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
            ValueField("tools",listValue([objectValue([ValueField("name",textValue("task")),
                ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("child.start")])),
                ValueField("preparation_provider",textValue("prepare_child"))]),hub]))])]))])).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func peerResumeInput111(id:String,body:String):AgentValue {
    objectValue([ValueField("op",textValue("send")),ValueField("to",textValue(id)),ValueField("message",textValue(body))])
}
private func peerResumeStart111(f:WorkflowChildFixture111,thread:SessionId):ProductSubagentState {
    let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),f.call(thread.value),budget:f.budget()))
    try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
    let saved=ProductTaskPersistence(f.database).loadAll()
    @Expect(saved.size,1);@Expect(saved[0].subagents.size,1);@Expect(saved[0].subagents[0].pluginCompletionDone111)
    saved[0].subagents[0]
}
private func peerResumePayload111(f:WorkflowChildFixture111):String {
    f.database.transaction{tx:SqliteTransaction=>
        let rows=tx.query("SELECT payload FROM task_snapshots ORDER BY root_thread_id")
        @Expect(rows.size,1);rows[0].required(0)}
}
private func peerResumeRejected111(result:Result<ToolInvocationResult>):Unit {
    match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
        case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
        case _=>@Expect(false)}
}
private func peerResumeSettled111(f:WorkflowChildFixture111,oldRun:RunId):ProductSubagentState {
    let until=MonoTime.now()+Duration.second*5
    while(MonoTime.now()<until){
        let roots=ProductTaskPersistence(f.database).loadAll()
        if(roots.size==1 && roots[0].subagents.size==1){let child=roots[0].subagents[0]
            if(child.runId.value!=oldRun.value && child.status=="completed" && child.pluginCompletionDone111){return child}}
        sleep(Duration.millisecond*5)
    }
    throw IllegalStateException("actual resumed child did not settle its frozen completion")
}

private class OptionalReadProbe111 <: ToolExecutor {
    let effects=AtomicInt64(0)
    public func execute(_:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult> {
        effects.fetchAdd(1);Result.Ok(ToolResult(prepared.call.callId,textValue("original one-stage result")))
    }
}

@Test
class InstalledWorkflowPeerResumeTests111 {
    @TestCase
    func completedWorkerCannotBeReincarnatedWhileActualSettledCallbackStillOwnsItsStack():Unit {
        peerResumePhysicalWorkerControl111(false)
    }
    @TestCase
    func approvedWorkerCannotBeReincarnatedUsingTheAlreadyReturnedInitialApprovalFuture():Unit {
        peerResumePhysicalWorkerControl111(true)
    }
    @TestCase
    func completedMemberUsesNewCanonicalRunButKeepsOriginalMainAndBudgetParentIdentity():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("actual-peer-incarnation")
        try {
            peerResumeSelection111(f)
            let old=peerResumeStart111(f,thread)
            let originalRuns=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            let body=String.fromUtf8(Array<Byte>(70000,repeat:b'x'))+" 雪"
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("resumed-to-main","plugin."+f.namespace+".hub",
                peerResumeInput111("Main","new incarnation, original Main"))
            let budget=f.budget()
            let sent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                ToolCall("resume-member","plugin."+f.namespace+".hub",peerResumeInput111(old.id,body)),budget:budget))
            try{@Expect(!sent.isError);expectCanonicalReturnedReceipt(f.database,sent)}finally{sent.releasePayload()}
            let current=peerResumeSettled111(f,old.runId)
            @Expect(current.id,old.id);@Expect(current.sessionId.value,old.sessionId.value)
            @Expect(current.parentRunId.value,old.parentRunId.value);@Expect(current.parentToolCallId,old.parentToolCallId)
            @Expect(current.parentSessionId.value,old.parentSessionId.value)
            @Expect(current.runId.value!=old.runId.value)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),originalRuns+2)
            @Expect(budget.snapshot().activeTools,0);@Expect(budget.snapshot().toolCalls,3)
            let saved=ProductTaskPersistence(f.database).loadAll()[0]
            @Expect(saved.messages.size,2);@Expect(saved.messageCounter,2)
            @Expect(saved.messages[0].snapshot.message,body);@Expect(saved.messages[0].snapshot.to,old.id)
            @Expect(saved.messages[1].snapshot.to,"Main");@Expect(saved.messages[1].waitCallId,"")
            var mainCopies:Int64=0
            for(item in lifecycleTestRequire(f.product.messages(thread))){for(block in item.blocks){
                if(block.kind==ModelBlockKind.Text && block.text==saved.messages[1].deliveryText111.getOrThrow()){mainCopies+=1}}}
            @Expect(mainCopies,1)
            f.database.transaction{tx:SqliteTransaction=>
                let rows=tx.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",
                    [SqlParameter.Text("plugin."+f.namespace+".hub")])
                var resumed:Int64=0
                for(row in rows){let plan=decodeOperationPlan(row.required(0))
                    let input=plan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].field("input").getOrThrow()
                    if(input.field("resume").isSome()){
                        resumed+=1;@Expect(plan.contextReadFacts.size,1)
                        @Expect(pluginPeerResumeParentMatches111(plan.canonicalArguments,input))
                        let link=plan.contextReadFacts[0]
                        let read=tx.query("SELECT r.outcome,e.tool_id FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE r.id=?",
                            [SqlParameter.Text(link.receiptId)])
                        @Expect(read.size,1);@Expect(read[0].required(0),"completed");@Expect(read[0].required(1),HOST_CONTEXT_READ_TOOL)
                    }}
                @Expect(resumed,1)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
        }finally{f.close()}
    }
    @TestCase
    func optionalNonePreservesOneDecisionAndSomeRefusesBeforeAnyReadOrParentAdmission():Unit {
        for(mode in ["default","none","some"]){
            let f=WorkflowChildFixture111(selected:false);let probe=OptionalReadProbe111();let resolutions=AtomicInt64(0)
            let budget=f.budget()
            try {
                let digest=modelPolicySha256Text("optional-read-fixture")
                lifecycleTestRequire(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.optional.read",
                    "actual optional preparation decision control",objectValue([ValueField("type",textValue("object"))])),
                    Capability(CapabilityKind.WorkspaceRead),sideEffecting:true,
                    preparationReadMayBeAbsent:mode!="default",
                    preparationReadResolver:Some({_,_=>
                        resolutions.fetchAdd(1)
                        if(mode=="none"){return Result<?ToolPreparationRead>.Ok(Option<ToolPreparationRead>.None)}
                        Result<?ToolPreparationRead>.Ok(Some(ToolPreparationRead("fixture","sha256:"+digest,digest,objectValue([]),
                            {_,_=>Result<AgentValue>.Ok(objectValue([]))}))) })),probe))
                let origin=HostServiceOrigin("fixture","fixture","sha256:"+digest,digest,"optional-read",HostServiceAction.Start,"optional-read")
                let result=f.product.vnext.executeHostServiceTool(SessionId("optional-read"),origin,
                    CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),
                    ToolCall("optional-read","fixture.optional.read",objectValue([])),
                    approvalDecision:Some(ApprovalDecision.Approve),budget:budget)
                if(mode=="none"){
                    let value=hostServiceEntryCompleted(result)
                    try{@Expect(!value.isError);@Expect(value.output.text,"original one-stage result");expectCanonicalReturnedReceipt(f.database,value)}finally{value.releasePayload()}
                    @Expect(probe.effects.load(),1);@Expect(budget.snapshot().toolCalls,1)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),1)
                }else{
                    @Expect(match(result){case Result.Err(error)=>error.code=="context.read_separate_approval_required";case _=>false})
                    @Expect(probe.effects.load(),0);@Expect(budget.snapshot().toolCalls,0)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                }
                @Expect(resolutions.load(),if(mode=="default"){0}else{1})
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),if(mode=="default"){0}else{1})
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"),0)
                @Expect(budget.snapshot().activeTools,0)
            }finally{f.close()}
        }
    }
    @TestCase
    func actualInstalledSomeWithBareApprovalPreservesAllOriginalTaskBytesAndCounters():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("bare-peer-read")
        try {
            peerResumeSelection111(f);let old=peerResumeStart111(f,thread)
            let prior=peerResumePayload111(f);let operations=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let receipts=f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
            let models=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts");let budget=f.budget()
            let origin=HostServiceOrigin("fixture",f.namespace,f.digest,modelPolicySha256Text("bare-peer-read"),"peer-read",HostServiceAction.Start,"peer-read")
            let result=f.product.vnext.executeHostServiceTool(thread,origin,f.capabilities(),
                ToolCall("bare-peer-read","plugin."+f.namespace+".hub",peerResumeInput111(old.id,"not approved for reading")),
                approvalDecision:Some(ApprovalDecision.Approve),budget:budget)
            @Expect(match(result){case Result.Err(error)=>error.code=="context.read_separate_approval_required";case _=>false})
            @Expect(peerResumePayload111(f),prior);@Expect(budget.snapshot().toolCalls,0);@Expect(budget.snapshot().activeTools,0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),operations)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),models)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state IN ('running','waiting_approval','recovery_required')"),0)
        }finally{f.close()}
    }
    @TestCase
    func actualIncarnationSnapshotSqliteFailureRollsBackMailCounterAndCannotStartNewChild():Unit {
        let f=WorkflowChildFixture111();let thread=SessionId("peer-resume-rollback");var trigger=false
        try {
            peerResumeSelection111(f);let old=peerResumeStart111(f,thread)
            let original=peerResumePayload111(f);let runs=f.database.scalarInt("SELECT COUNT(*) FROM runs")
            let models=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            f.database.execute("CREATE TRIGGER deny_peer_resume_111 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'new-resume-persist-fault')>0 BEGIN SELECT RAISE(ABORT,'actual Task CAS denied'); END")
            trigger=true
            peerResumeRejected111(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                ToolCall("failed-incarnation","plugin."+f.namespace+".hub",peerResumeInput111(old.id,"new-resume-persist-fault")),budget:f.budget()))
            @Expect(peerResumePayload111(f),original)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),runs+1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),models)
            let saved=ProductTaskPersistence(f.database).loadAll()[0]
            @Expect(saved.messageCounter,0);@Expect(saved.messages.size,0);@Expect(saved.subagents[0].runId.value,old.runId.value)
            f.database.transaction{tx:SqliteTransaction=>
                let rows=tx.query("SELECT r.outcome FROM operation_receipts r JOIN operations o ON o.id=r.operation_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id='host.child.start' AND instr(o.normalized_plan,?)>0",
                    [SqlParameter.Text("\"resume\"")])
                @Expect(rows.size,1);@Expect(rows[0].required(0),"unknown")
            }
        }finally{if(trigger){f.database.execute("DROP TRIGGER deny_peer_resume_111")};f.close()}
    }
    @TestCase
    func revokedActualReadApprovalCannotReuseOldTerminalSourceOrCreateNewIncarnation():Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk);let thread=SessionId("peer-resume-revoke")
        let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try {
            peerResumeSelection111(f,mapped:false)
            let start=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),f.call(thread.value),owner,cancellation.token,budget:f.budget())
            @Expect(match(start){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
            let started=hostServiceEntryCompleted(owner.decide(owner.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
            try{@Expect(!started.isError)}finally{started.releasePayload()}
            let old=ProductTaskPersistence(f.database).loadAll()[0].subagents[0];let original=peerResumePayload111(f)
            let nextOwner=ProductDirectPreparationOwner({=>cancellation.token.check()});let budget=f.budget()
            try {
                let result=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                    ToolCall("revoked-resume","plugin."+f.namespace+".hub",peerResumeInput111(old.id,"not after revocation")),nextOwner,cancellation.token,budget:budget)
                @Expect(match(result){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
                let read=nextOwner.approval().getOrThrow();@Expect(read.toolName,HOST_CONTEXT_READ_TOOL)
                let models=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
                @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
                peerResumeRejected111(nextOwner.decide(read.operationId.value,ApprovalDecision.Approve))
                @Expect(nextOwner.decide(read.operationId.value,ApprovalDecision.Approve).isError())
                @Expect(peerResumePayload111(f),original);@Expect(budget.snapshot().activeTools,0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),models)
                @Expect(ProductTaskPersistence(f.database).loadAll()[0].subagents[0].runId.value,old.runId.value)
            }finally{let _=nextOwner.cancel()}
        }finally{let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
    }
}

private func peerResumePhysicalWorkerControl111(approval:Bool):Unit {
    let f=WorkflowChildFixture111(mode:if(approval){ApprovalMode.AlwaysAsk}else{ApprovalMode.Yolo},asynchronous:true)
    let thread=SessionId(if(approval){"peer-worker-approval-return"}else{"peer-worker-initial-return"})
    let probe=ChildControlledTool111(!approval)
    let entered=AtomicBool(false);let release=AtomicBool(false)
    let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
    var deciding: ?Future<Result<Unit>>=Option<Future<Result<Unit>>>.None
    try {
        peerResumeSelection111(f)
        childInstallProbe111(f,probe,approval)
        let _=f.product.subscribeAsyncJobs({event=>
            if(event.kind=="settled" && event.snapshot.sessionId.value==thread.value && !release.load()) {
                entered.store(true)
                while(!release.load()){sleep(Duration.millisecond)}
            }
        })
        let parent=if(approval){
            let started=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),owner,cancellation.token,budget:f.budget())
            @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
            hostServiceEntryCompleted(owner.decide(owner.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
        }else{
            hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
        }
        try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
        if(approval){
            let blocked=childObserve111(f,thread,"blocked")
            deciding=Some(spawn{f.product.decideSubagentApproval(thread,blocked.id,ApprovalDecision.Approve)})
        }else{probe.released.store(true)}
        let until=MonoTime.now()+Duration.second*5
        while(!entered.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
        @Expect(entered.load())
        let old=ProductTaskPersistence(f.database).loadAll()[0].subagents[0]
        @Expect(old.status,"completed");@Expect(old.pluginCompletionDone111)
        @Expect(!old.executionInProgress);@Expect(!old.launchInProgress)
        if(approval){@Expect(deciding.getOrThrow().tryGet().isNone())}
        let before=peerResumePayload111(f)
        let models=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
        let launches=f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'")
        let budget=f.budget()
        // The previous Run/Receipt/finalizer are already complete. The actual
        // Future is not: the real public subscriber above still owns its frame.
        let rejectedOwner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try {
            var rejected=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                ToolCall("peer-too-early","plugin."+f.namespace+".hub",peerResumeInput111(old.id,"must not enter the next incarnation")),
                rejectedOwner,cancellation.token,budget:budget)
            if(let Some(actual)<-rejectedOwner.approval()) {
                @Expect(actual.toolName,HOST_CONTEXT_READ_TOOL)
                rejected=rejectedOwner.decide(actual.operationId.value,ApprovalDecision.Approve)
            }
            @Expect(rejectedOwner.approval().isNone())
            peerResumeRejected111(rejected)
        }finally{let _=rejectedOwner.cancel()}
        @Expect(peerResumePayload111(f),before)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),models)
        @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),launches)
        @Expect(budget.snapshot().activeTools,0);@Expect(budget.snapshot().toolCalls,1)
        let still=ProductTaskPersistence(f.database).loadAll()[0]
        @Expect(still.messageCounter,0);@Expect(still.messages.size,0)
        @Expect(still.subagents[0].runId.value,old.runId.value)
        @Expect(still.subagents[0].parentRunId.value,old.parentRunId.value)
        @Expect(still.subagents[0].parentToolCallId,old.parentToolCallId)
        f.database.transaction{tx:SqliteTransaction=>
            let rows=tx.query("SELECT COUNT(*) FROM runs WHERE thread_id=?",[SqlParameter.Text(old.sessionId.value)])
            @Expect(rows.size,1);@Expect(rows[0].required(0),"1")
            let prior=tx.query("SELECT state FROM runs WHERE id IN (?,?) ORDER BY id",
                [SqlParameter.Text(old.runId.value),SqlParameter.Text(old.parentRunId.value)])
            @Expect(prior.size,2);for(row in prior){@Expect(row.required(0),"completed")}
        }
        release.store(true)
        if(approval){@Expect(deciding.getOrThrow().get().isOk())}
        // Existing public wait uses the exact same supervisor Future proof;
        // no fixture sleep, worker-finally flag or manufactured ACK is used.
        let jobs=f.product.waitForAsyncJobs(thread,[old.id],0)
        @Expect(jobs.size,1);@Expect(jobs[0].status,"completed");@Expect(jobs[0].result.isSome())
        let jobResult=encodeAgentValue(jobs[0].result.getOrThrow())
        let nextOwner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try {
            var answer=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                ToolCall("peer-after-physical-return","plugin."+f.namespace+".hub",peerResumeInput111(old.id,"one real new incarnation")),
                nextOwner,cancellation.token,budget:f.budget())
            var stages:Int64=0
            while(nextOwner.approval().isSome() && stages<2) {
                let actual=nextOwner.approval().getOrThrow()
                answer=nextOwner.decide(actual.operationId.value,ApprovalDecision.Approve)
                stages+=1
            }
            @Expect(nextOwner.approval().isNone())
            let sent=hostServiceEntryCompleted(answer)
            try{@Expect(!sent.isError);expectCanonicalReturnedReceipt(f.database,sent)}finally{sent.releasePayload()}
        }finally{let _=nextOwner.cancel()}
        let current=peerResumeSettled111(f,old.runId)
        @Expect(current.parentRunId.value,old.parentRunId.value)
        @Expect(current.parentSessionId.value,old.parentSessionId.value)
        @Expect(current.parentToolCallId,old.parentToolCallId)
        @Expect(current.runId.value!=old.runId.value)
        let after=ProductTaskPersistence(f.database).loadAll()[0]
        @Expect(after.messageCounter,1);@Expect(after.messages.size,1)
        @Expect(after.messages[0].snapshot.message,"one real new incarnation")
        let oldJob=f.product.asyncJobs(thread)
        @Expect(oldJob.size,1);@Expect(encodeAgentValue(oldJob[0].result.getOrThrow()),jobResult)
        f.database.transaction{tx:SqliteTransaction=>
            let rows=tx.query("SELECT COUNT(*) FROM runs WHERE thread_id=?",[SqlParameter.Text(old.sessionId.value)])
            @Expect(rows.size,1);@Expect(rows[0].required(0),"2")
        }
    }finally{
        release.store(true);probe.released.store(true)
        if(let Some(value)<-deciding){let _=value.get()}
        let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()
    }
}
