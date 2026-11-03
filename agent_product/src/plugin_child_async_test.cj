package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ChildControlledTool111 <: ToolExecutor {
    let entered=AtomicBool(false)
    let released=AtomicBool(false)
    let calls=AtomicInt64(0)
    private let hold:Bool
    init(hold:Bool){this.hold=hold}
    public func execute(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult>{
        calls.fetchAdd(1);entered.store(true)
        let deadline=MonoTime.now()+Duration.second*10
        while(hold && !released.load() && MonoTime.now()<deadline){
            match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            sleep(Duration.millisecond)
        }
        if(hold && !released.load()){return Result.Err(AgentError(AgentErrorKind.Timeout,"fixture.child_wait_expired","test release was not observed"))}
        Result.Ok(ToolResult(prepared.call.callId,textValue("actual child work completed")))
    }
}
func childBackgroundCall111(f:WorkflowChildFixture111,thread:String):ToolCall{
    ToolCall(thread+"-call","plugin."+f.namespace+".task",objectValue([
        ValueField("agent",textValue("task")),ValueField("task",textValue("one actual background task"))]))
}
func childObserve111(f:WorkflowChildFixture111,thread:SessionId,status:String):ProductSubagentSnapshot{
    let until=MonoTime.now()+Duration.second*5
    while(MonoTime.now()<until){
        let children=f.product.allSubagents(thread)
        if(children.size==1 && children[0].status==status){return children[0]}
        sleep(Duration.millisecond*5)
    }
    throw IllegalStateException("actual child did not reach "+status)
}
func childJob111(f:WorkflowChildFixture111,thread:SessionId,status:String):ProductAsyncJobSnapshot{
    let until=MonoTime.now()+Duration.second*5
    while(MonoTime.now()<until){
        let jobs=f.product.asyncJobs(thread)
        if(jobs.size==1 && jobs[0].status==status && !jobs[0].executing){return jobs[0]}
        sleep(Duration.millisecond*5)
    }
    throw IllegalStateException("actual child job did not settle as "+status)
}
func childInstallProbe111(f:WorkflowChildFixture111,probe:ChildControlledTool111,approval:Bool):Unit{
    lifecycleTestRequire(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.child.work",
        "actual child execution boundary",objectValue([ValueField("type",textValue("object"))])),
        Capability(CapabilityKind.WorkspaceRead),sideEffecting:approval,neverReplay:true),probe))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-child-work","fixture.child.work",objectValue([]))
}

@Test
class InstalledWorkflowAsyncChildTests111 {
    @TestCase
    func parentReceiptFollowsActualAdmissionAndChildCompletionPersistsBeforeBudgetSettlement():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=ChildControlledTool111(true)
        let thread=SessionId("actual-background-111")
        try{
            childInstallProbe111(f,probe,false)
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{
                @Expect(!result.isError);@Expect(result.output.field("async").isSome());@Expect(result.output.field("results").getOrThrow().items.size,0)
                expectCanonicalReturnedReceipt(f.database,result)
            }finally{result.releasePayload()}
            let entered=MonoTime.now()+Duration.second*5
            while(!probe.entered.load() && MonoTime.now()<entered){sleep(Duration.millisecond*5)}
            @Expect(probe.entered.load());@Expect(probe.calls.load(),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
            let jobs=f.product.asyncJobs(thread);@Expect(jobs.size,1);@Expect(jobs[0].executing)
            @Expect(jobs[0].result.isNone())
            probe.released.store(true)
            let job=childJob111(f,thread,"completed");@Expect(job.result.isSome())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            let restored=ProductTaskPersistence(f.database).loadAll()
            @Expect(restored.size,1);@Expect(restored[0].subagents.size,1)
            let child=restored[0].subagents[0]
            @Expect(child.status,"completed");@Expect(child.pluginCompletionDone111)
            @Expect(child.pluginCompletion111.isSome());@Expect(child.pluginAdmission111.isNone())
            @Expect(child.pendingRequest.isNone());@Expect(child.pendingApproval.isNone())
            @Expect(encodeAgentValue(child.pluginCompletion111.getOrThrow()),encodeAgentValue(job.result.getOrThrow()))
        }finally{probe.released.store(true);f.close()}
    }

    @TestCase
    func childApprovalAndCancellationReuseOriginalChildRunAfterParentCompletion():Unit{
        for(action in ["approve","cancel"]){
            let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk,asynchronous:true)
            let probe=ChildControlledTool111(false);let thread=SessionId("actual-child-approval-"+action)
            let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
            try{
                childInstallProbe111(f,probe,true)
                let started=f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                    childBackgroundCall111(f,thread.value),owner,cancellation.token,budget:f.budget())
                @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
                let rootApproval=owner.approval().getOrThrow()
                let parent=hostServiceEntryCompleted(owner.decide(rootApproval.operationId.value,ApprovalDecision.Approve))
                try{expectCanonicalReturnedReceipt(f.database,parent);@Expect(!parent.isError)}finally{parent.releasePayload()}
                let child=childObserve111(f,thread,"blocked")
                @Expect(probe.calls.load(),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),1)
                if(action=="approve"){
                    @Expect(f.product.decideSubagentApproval(thread,child.id,ApprovalDecision.Approve).isOk())
                    let settled=childObserve111(f,thread,"completed")
                    @Expect(settled.runId.value,child.runId.value);@Expect(probe.calls.load(),1)
                    @Expect(childJob111(f,thread,"completed").result.isSome())
                }else{
                    @Expect(f.product.cancelSubagent(thread,child.id).isOk())
                    let settled=childObserve111(f,thread,"cancelled")
                    @Expect(settled.runId.value,child.runId.value);@Expect(probe.calls.load(),0)
                    @Expect(childJob111(f,thread,"cancelled").result.isSome())
                }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            }finally{probe.released.store(true);let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
        }
    }

    @TestCase
    func realCompletionJournalFailureRetainsRecoveryAndCannotPublishSuccessfulJob():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=ChildControlledTool111(true)
        let thread=SessionId("actual-child-finalizer-fault")
        try{
            childInstallProbe111(f,probe,false)
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
            let entered=MonoTime.now()+Duration.second*5
            while(!probe.entered.load() && MonoTime.now()<entered){sleep(Duration.millisecond*5)}
            @Expect(probe.entered.load())
            f.database.execute("CREATE TRIGGER reject_plugin_completion_111 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"pluginCompletionDone111\":true')>0 BEGIN SELECT RAISE(ABORT,'fixture completion journal refused'); END")
            probe.released.store(true)
            let state=childObserve111(f,thread,"recovery_required")
            @Expect(state.error.contains("frozen child completion"))
            let job=childJob111(f,thread,"recovery_required");@Expect(job.result.isNone())
            let restored=ProductTaskPersistence(f.database).loadAll()
            @Expect(restored.size,1);@Expect(!restored[0].subagents[0].pluginCompletionDone111)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),2)
            @Expect(f.product.close().isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            f.database.execute("DROP TRIGGER reject_plugin_completion_111")
            // Retrying a read of the existing jobs observes the still-live
            // owner and terminal Run. It cannot launch any replacement Run.
            @Expect(childJob111(f,thread,"completed").result.isSome())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.product.close().isOk())
        }finally{probe.released.store(true);f.close()}
    }
}
