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

func jobCancelSelection172(f: WorkflowChildFixture111): Unit {
    jobSnapshotSelection165(f)
    let settings=parseUnifiedJson(String.fromUtf8(File.readFrom(f.root+"/settings/plugins/primitives.json")))
    settings.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items[1].put("services",
        listValue([textValue("job.list"),textValue("job.cancel")]))
    File.writeTo(f.root+"/settings/plugins/primitives.json",stringifyUnifiedJson(settings).toArray())
}
func jobCancelCall172(f: WorkflowChildFixture111, id: String, target: String): ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("cancel")),
        ValueField("ids",listValue([textValue(target)]))]))
}
// A real installed child Tool deliberately remains in its actual executing
// frame after receiving cancellation. This separates request ACK from return.
class JobCancelHeldTool172 <: ToolExecutor {
    let entered=AtomicBool(false)
    let cancellationSeen=AtomicBool(false)
    let released=AtomicBool(false)
    let returned=AtomicBool(false)
    let calls=AtomicInt64(0)
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls.fetchAdd(1);entered.store(true)
        let until=MonoTime.now()+Duration.second*45
        try {
            while(!released.load() && MonoTime.now()<until) {
                match(context.cancellation.check()){case Result.Err(_)=>cancellationSeen.store(true);case Result.Ok(_)=>()}
                sleep(Duration.millisecond*5)
            }
            if(!released.load()){return Result.Err(AgentError(AgentErrorKind.Timeout,"fixture.job_cancel_unreleased","actual child release was not supplied"))}
            match(context.cancellation.check()){case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>Result.Ok(ToolResult(prepared.call.callId,textValue("actual uncancelled child returned")))}
        }finally{returned.store(true)}
    }
}
func jobCancelInstall172(f: WorkflowChildFixture111, probe: JobCancelHeldTool172): Unit {
    lifecycleTestRequire(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.child.cancel172",
        "actual held cancellation boundary",objectValue([ValueField("type",textValue("object"))])),
        Capability(CapabilityKind.WorkspaceRead),sideEffecting:false,neverReplay:true),probe))
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-cancel-child172","fixture.child.cancel172",objectValue([]))
}
func jobCancelAwait172(value: AtomicBool): Unit {
    let until=MonoTime.now()+Duration.second*5
    while(!value.load() && MonoTime.now()<until){sleep(Duration.millisecond*5)}
    @Expect(value.load())
}
func jobCancelStart172(f: WorkflowChildFixture111, thread: SessionId, probe: JobCancelHeldTool172): ProductAsyncJobSnapshot {
    jobCancelSelection172(f);jobCancelInstall172(f,probe)
    let parent=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
        childBackgroundCall111(f,thread.value),budget:f.budget()))
    try{@Expect(!parent.isError);expectCanonicalReturnedReceipt(f.database,parent)}finally{parent.releasePayload()}
    jobCancelAwait172(probe.entered);@Expect(probe.calls.load(),1)
    let source=f.product.asyncJobs(thread);@Expect(source.size,1);@Expect(source[0].executing)
    source[0]
}

@Test
class InstalledWorkflowActualJobCancel172Tests {
    @TestCase
    func actualForeignAndRequestOnlyCancellationPreserveCanonicalOwnerAndOriginalFields172(): Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobCancelHeldTool172()
        let thread=SessionId("actual-job-cancel-owner172")
        try {
            let original=jobCancelStart172(f,thread,probe)
            let attempts=f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let foreignResult172=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("foreign-cancel172"),
                f.capabilities(),jobCancelCall172(f,"foreign-cancel172",original.id),budget:f.budget()))
            try{@Expect(!foreignResult172.isError);@Expect(foreignResult172.payloadLease.isSome());expectCanonicalReturnedReceipt(f.database,foreignResult172)
                @Expect(encodeAgentValue(foreignResult172.output),encodeAgentValue(objectValue([ValueField("op",textValue("cancel")),ValueField("jobs",listValue([]))])))}
            finally{foreignResult172.releasePayload()}
            @Expect(!probe.cancellationSeen.load());@Expect(!probe.returned.load())
            let actual=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread,f.capabilities(),
                jobCancelCall172(f,"actual-cancel172",original.id),budget:f.budget()))
            try {
                @Expect(!actual.isError);@Expect(actual.payloadLease.isSome());expectCanonicalReturnedReceipt(f.database,actual)
                @Expect(httpIntentText(actual.output,"op"),"cancel")
                let values=actual.output.field("jobs").getOrThrow().items;@Expect(values.size,1)
                let snapshot=f.product.asyncJobs(thread)[0]
                @Expect(encodeAgentValue(values[0]),encodeAgentValue(asyncJobValue(snapshot)))
                @Expect(snapshot.id,original.id);@Expect(snapshot.agentId,original.agentId)
                @Expect(snapshot.sessionId.value,original.sessionId.value);@Expect(snapshot.ownerRunId.value,original.ownerRunId.value)
                @Expect(snapshot.operationId,original.operationId)
            }finally{actual.releasePayload()}
            jobCancelAwait172(probe.cancellationSeen)
            @Expect(!probe.returned.load());@Expect(!probe.released.load());@Expect(probe.calls.load(),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),attempts)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='hub'"),0)
            probe.released.store(true);jobCancelAwait172(probe.returned)
        }finally{probe.released.store(true);f.close()}
    }
    @TestCase
    func actualSqlRefusalDoesNotCancelPhysicalChildOrInventCompletedReceipt172(): Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobCancelHeldTool172()
        let thread=SessionId("actual-job-cancel-sql172");var trigger=false
        try {
            let original=jobCancelStart172(f,thread,probe)
            let old=ProductTaskPersistence(f.database).loadAll()[0].jobs[0].snapshot()
            let oldPayload=f.database.query("SELECT payload FROM task_snapshots")[0].required(0)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id='host.child.start' AND r.outcome='completed'")
            f.database.execute("CREATE TRIGGER deny_job_cancel172 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'cancellation_requested')>0 BEGIN SELECT RAISE(ABORT,'actual cancellation persistence denied'); END")
            trigger=true
            let result=f.product.vnext.executeCanonicalTool(thread,f.capabilities(),jobCancelCall172(f,"sql-cancel172",original.id),budget:f.budget())
            match(result){case Result.Err(error)=>@Expect(error.code!="")
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)}
            let stored=ProductTaskPersistence(f.database).loadAll()[0].jobs[0].snapshot()
            @Expect(f.database.query("SELECT payload FROM task_snapshots")[0].required(0),oldPayload)
            @Expect(encodeAgentValue(asyncJobValue(stored)),encodeAgentValue(asyncJobValue(old)))
            @Expect(stored.ownerRunId.value,old.ownerRunId.value);@Expect(stored.operationId,old.operationId)
            @Expect(!probe.cancellationSeen.load());@Expect(!probe.returned.load());@Expect(probe.calls.load(),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id='host.child.start' AND r.outcome='completed'"),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id='host.child.start' AND r.outcome='unknown'"),1)
            f.database.execute("DROP TRIGGER deny_job_cancel172");trigger=false
        }finally{if(trigger){f.database.execute("DROP TRIGGER deny_job_cancel172")};probe.released.store(true);f.close()}
    }
    @TestCase
    func actualMissingDelegateFailsBeforePhysicalCancelAndDoesNotLaunchReplacement172(): Unit {
        let f=WorkflowChildFixture111(asynchronous:true);let probe=JobCancelHeldTool172()
        let thread=SessionId("actual-job-cancel-capability172")
        try {
            let original=jobCancelStart172(f,thread,probe)
            let starts=f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'")
            let result=f.product.vnext.executeCanonicalTool(thread,f.capabilities(delegate:false),jobCancelCall172(f,"denied-cancel172",original.id),budget:f.budget())
            match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)}
            @Expect(!probe.cancellationSeen.load());@Expect(!probe.returned.load());@Expect(probe.calls.load(),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),starts)
            let stored=f.product.asyncJobs(thread)[0];@Expect(stored.id,original.id);@Expect(stored.executing)
        }finally{probe.released.store(true);f.close()}
    }
}
