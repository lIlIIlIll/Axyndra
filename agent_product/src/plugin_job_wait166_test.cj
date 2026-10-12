package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real canonical background child and actual installed Native hub. The only
// fixture Tool is a real held child executor; no job/Receipt/Source is seeded.
func jobWaitSelection166(f: WorkflowChildFixture111): Unit {
    jobSnapshotSelection165(f)
    let bytes=File.readFrom(f.root+"/settings/plugins/primitives.json")
    let value=parseUnifiedJson(String.fromUtf8(bytes))
    let tool=value.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items[1]
    tool.put("services",listValue([textValue("job.list"),textValue("job.wait")]))
    File.writeTo(f.root+"/settings/plugins/primitives.json",stringifyUnifiedJson(value).toArray())
}
func jobWaitCall166(f:WorkflowChildFixture111,id:String,ids:Array<String>,timeout:Int64):ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("wait")),
        ValueField("ids",listValue(ids.map{value=>textValue(value)})),ValueField("timeoutMs",integerValue(timeout))]))
}
func jobWaitActualDerived166(f:WorkflowChildFixture111,minimum:Int64):Unit {
    let until=MonoTime.now()+Duration.second*5
    while(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")<minimum && MonoTime.now()<until){
        sleep(Duration.millisecond*5)}
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),minimum)
}
func jobWaitActualExecuting166(f:WorkflowChildFixture111,callId:String):Unit {
    let sql="SELECT COUNT(*) FROM operations o JOIN derived_operation_admissions d ON d.operation_id=o.id "+
        "WHERE o.state='executing' AND d.request_key='child-service:"+callId+":hub-1'"
    let until=MonoTime.now()+Duration.second*5
    while(f.database.scalarInt(sql)!=1 && MonoTime.now()<until){sleep(Duration.millisecond*5)}
    @Expect(f.database.scalarInt(sql),1)
}
class JobWaitHeldTool166 <: ToolExecutor {
    let entered=AtomicBool(false)
    let released=AtomicBool(false)
    let returned=AtomicBool(false)
    let calls=AtomicInt64(0)
    public func execute(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult>{
        calls.fetchAdd(1);entered.store(true)
        // Test-only guard below is inside the unchanged sixty-second case cap;
        // no production waiting timeout is introduced or enlarged.
        let until=MonoTime.now()+Duration.second*45
        try{
            while(!released.load() && MonoTime.now()<until){
                match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                sleep(Duration.millisecond*5)}
            if(!released.load()){return Result.Err(AgentError(AgentErrorKind.Timeout,"fixture.job_wait_unreleased","real held worker did not receive its test release"))}
            Result.Ok(ToolResult(prepared.call.callId,textValue("actual long child returned")))
        }finally{returned.store(true)}
    }
}
func jobWaitInstall166(f:WorkflowChildFixture111,probe:JobWaitHeldTool166):Unit {
    lifecycleTestRequire(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.child.work",
        "actual controlled long child",objectValue([ValueField("type",textValue("object"))])),
        Capability(CapabilityKind.WorkspaceRead),sideEffecting:false,neverReplay:true),probe))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-child-work","fixture.child.work",objectValue([]))
}
func jobWaitEntered166(probe:JobWaitHeldTool166):Unit {
    let until=MonoTime.now()+Duration.second*5
    while(!probe.entered.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
    @Expect(probe.entered.load());@Expect(probe.calls.load(),1)
}

@Test
class InstalledWorkflowActualJobWait166Tests {
    @TestCase
    func zeroTimeoutWaitOutlivesOriginalNativeWatchdogAndReturnsOnlyAfterRealChild166():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-long-job-wait-166")
        try{
            jobWaitSelection166(f);jobWaitInstall166(f,probe)
            let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
            jobWaitEntered166(probe)
            let original=f.product.asyncJobs(thread);@Expect(original.size,1)
            let admitted=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let modelAttempts=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let finished=AtomicBool(false)
            let work=spawn {
                try{f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                    jobWaitCall166(f,"actual-long-wait-call-166",[original[0].id],0),budget:f.budget())}
                finally{finished.store(true)}
            }
            var joined=false
            try{
                jobWaitActualDerived166(f,admitted+1)
                // Native's original default call watchdog is 30,000 ms. The
                // real wait is already admitted and stays held beyond it.
                sleep(Duration.second*31)
                @Expect(!finished.load());@Expect(!probe.returned.load());@Expect(probe.calls.load(),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),modelAttempts)
                probe.released.store(true)
                let result=work.get();joined=true
                let answer=hostServiceEntryCompleted(result)
                try{
                    @Expect(!answer.isError);@Expect(answer.payloadLease.isSome())
                    expectCanonicalReturnedReceipt(f.database,answer)
                    let rows=answer.output.field("jobs").getOrThrow().items
                    @Expect(httpIntentText(answer.output,"op"),"wait");@Expect(rows.size,1)
                    @Expect(httpIntentText(rows[0],"id"),original[0].id)
                    @Expect(httpIntentText(rows[0],"status"),"completed")
                    @Expect(rows[0].field("result").isSome());@Expect(probe.returned.load())
                    let actual=childJob111(f,thread,"completed")
                    @Expect(canonicalAgentValue(answer.output),canonicalAgentValue(objectValue([
                        ValueField("op",textValue("wait")),ValueField("jobs",asyncJobsValue([actual]))])))
                }finally{answer.releasePayload()}
            }finally{probe.released.store(true);if(!joined){let _=work.get()}}
            @Expect(probe.calls.load(),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),admitted+1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
        }finally{probe.released.store(true);f.close()}
    }

    @TestCase
    func finiteWaitAndForeignSelectionDoNotRetireOrRelaunchOriginalHeldChild166():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-finite-job-wait-166")
        try{
            jobWaitSelection166(f);jobWaitInstall166(f,probe)
            let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
            jobWaitEntered166(probe);let source=f.product.asyncJobs(thread);@Expect(source.size,1)
            let attempts=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let timed=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                jobWaitCall166(f,"finite-job-wait-call-166",[source[0].id],20),budget:f.budget()))
            try{
                @Expect(!timed.isError);expectCanonicalReturnedReceipt(f.database,timed)
                let rows=timed.output.field("jobs").getOrThrow().items;@Expect(rows.size,1)
                @Expect(httpIntentText(timed.output,"op"),"wait");@Expect(httpIntentText(rows[0],"id"),source[0].id)
                @Expect(httpIntentText(rows[0],"status"),"running");@Expect(rows[0].field("result").isNone())
                @Expect(!probe.returned.load());@Expect(!probe.released.load());@Expect(timed.payloadLease.isSome())
            }finally{timed.releasePayload()}
            let foreignWait166=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("foreign-job-wait-166"),f.capabilities(),
                jobWaitCall166(f,"foreign-wait-call-166",[source[0].id],0),budget:f.budget()))
            try{
                @Expect(!foreignWait166.isError);expectCanonicalReturnedReceipt(f.database,foreignWait166)
                @Expect(canonicalAgentValue(foreignWait166.output),canonicalAgentValue(objectValue([
                    ValueField("op",textValue("wait")),ValueField("jobs",listValue([]))])))
            }finally{foreignWait166.releasePayload()}
            @Expect(probe.calls.load(),1);@Expect(!probe.returned.load())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),attempts)
            probe.released.store(true);let actual=childJob111(f,thread,"completed");@Expect(actual.result.isSome())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
        }finally{probe.released.store(true);f.close()}
    }

    @TestCase
    func realCallerCancellationJoinsWaitWithoutReplayingOrClosingOriginalJob166():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-cancel-job-wait-166")
        let cancel=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancel.token.check()})
        try{
            jobWaitSelection166(f);jobWaitInstall166(f,probe)
            let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
            jobWaitEntered166(probe);let source=f.product.asyncJobs(thread)
            let admitted=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let work=spawn { f.product.vnext.executeDeferredCanonicalTool(thread,f.capabilities(),
                jobWaitCall166(f,"cancel-job-wait-call-166",[source[0].id],0),owner,cancel.token,budget:f.budget()) }
            var joined=false
            try{
                jobWaitActualDerived166(f,admitted+1);jobWaitActualExecuting166(f,"cancel-job-wait-call-166")
                let _=cancel.cancel()
                let returned=work.get();joined=true
                match(returned){case Result.Ok(ToolInvocationResult.Completed(value))=>
                    try{@Expect(value.isError)}finally{value.releasePayload()}
                    case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>();case _=>@Expect(false)}
                @Expect(!probe.returned.load());@Expect(!probe.released.load());@Expect(probe.calls.load(),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),admitted+1)
                // Original post-handoff policy conservatively records unknown;
                // cancellation is not a manufactured known no-effect outcome.
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")>0)
            }finally{let _=cancel.cancel();if(!joined){let _=work.get()}}
            probe.released.store(true);let _=childJob111(f,thread,"completed")
            @Expect(probe.calls.load(),1)
        }finally{probe.released.store(true);let _=owner.cancel();cancel.close();f.close()}
    }

    @TestCase
    func actualRegistryRevocationJoinsTheExistingWaitWithoutRelaunchOrChildRetirement166():Unit{
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobWaitHeldTool166()
        let thread=SessionId("actual-revoked-job-wait-166")
        try{
            jobWaitSelection166(f);jobWaitInstall166(f,probe)
            let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                childBackgroundCall111(f,thread.value),budget:f.budget()))
            try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
            jobWaitEntered166(probe);let source=f.product.asyncJobs(thread)
            let admitted=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let work=spawn{f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                jobWaitCall166(f,"revoke-job-wait-call-166",[source[0].id],0),budget:f.budget())}
            var joined=false
            try{
                jobWaitActualDerived166(f,admitted+1);jobWaitActualExecuting166(f,"revoke-job-wait-call-166")
                match(f.product.setPluginEnabled(f.namespace,false)){
                    case agent_plugin_registry.PluginRegistryResult.Ok(_)=>()
                    case agent_plugin_registry.PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
                let result=work.get();joined=true
                match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Completed(value))=>
                    try{@Expect(value.isError)}finally{value.releasePayload()};case _=>@Expect(false)}
                @Expect(!probe.returned.load());@Expect(!probe.released.load());@Expect(probe.calls.load(),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),admitted+1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'")>0)
                // Revocation is no permission to manufacture a child terminal.
                // Release the real Tool only after the waiting worker joined.
                probe.released.store(true)
                let until=MonoTime.now()+Duration.second*5
                while(!probe.returned.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
                @Expect(probe.returned.load());@Expect(probe.calls.load(),1)
            }finally{probe.released.store(true);if(!joined){let _=work.get()}}
        }finally{probe.released.store(true);f.close()}
    }
}
