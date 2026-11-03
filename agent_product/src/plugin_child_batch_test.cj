package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class ChildWaveBarrier111 <: ToolExecutor {
    let calls=AtomicInt64(0)
    let simultaneous=AtomicBool(false)
    public func execute(context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult> {
        calls.fetchAdd(1)
        let until=MonoTime.now()+Duration.second*10
        while(calls.load()<4 && MonoTime.now()<until){
            match(context.cancellation.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            sleep(Duration.millisecond)
        }
        if(calls.load()!=4){return Result.Err(AgentError(AgentErrorKind.Timeout,"fixture.child_wave_serialized",
            "four real child tool executions never held the same first wave"))}
        simultaneous.store(true)
        Result.Ok(ToolResult(prepared.call.callId,textValue("actual four-child wave released")))
    }
}
func childBatchCall111(f:WorkflowChildFixture111,thread:String,count:Int64):ToolCall {
    let tasks=ArrayList<AgentValue>()
    for(i in 0..count){tasks.add(objectValue([ValueField("agent",textValue("scout")),
        ValueField("name",textValue("slot-"+i.toString())),ValueField("task",textValue("actual bounded child "+i.toString()))]))}
    ToolCall(thread+"-call","plugin."+f.namespace+".task",objectValue([ValueField("tasks",listValue(tasks.toArray()))]))
}
func childBatchBudget111():ExecutionBudget {
    ExecutionBudget(maxToolCalls:64,maxConcurrentTools:1,maxChildren:8,maxConcurrentChildren:4,maxDepth:4)
}

@Test
class InstalledWorkflowChildBatchTests111 {
    @TestCase
    func actualFourChildWaveMustReachItsBarrierBeforeAnyInlineWaitCompletes():Unit {
        let f=WorkflowChildFixture111(waitService:true);let probe=ChildWaveBarrier111()
        try{
            lifecycleTestRequire(f.product.registerTool(ToolDescriptor(ModelToolDefinition("fixture.child.wave",
                "actual four-child barrier",objectValue([ValueField("type",textValue("object"))])),
                Capability(CapabilityKind.WorkspaceRead),neverReplay:true),probe))
            for(i in 0..4){f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("wave-"+i.toString(),"fixture.child.wave",objectValue([]))}
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("child-wave-111"),
                f.capabilities(),childBatchCall111(f,"child-wave-111",4),budget:childBatchBudget111()))
            try{
                @Expect(!result.isError);@Expect(probe.calls.load(),4);@Expect(probe.simultaneous.load())
                let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,4)
                for(i in 0..4){@Expect(httpIntentText(rows[i],"agent"),"slot-"+i.toString())
                    @Expect(httpIntentText(rows[i],"status"),"completed");@Expect(rows[i].field("exitCode").getOrThrow().asNumberText(),"0")}
                @Expect(result.output.field("progress").getOrThrow().items.size,0)
                @Expect(result.output.field("async").isNone());expectCanonicalReturnedReceipt(f.database,result)
            }finally{result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),5)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),8)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),13)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            @Expect(f.product.asyncJobs(SessionId("child-wave-111")).size,0)
        }finally{f.close()}
    }
    @TestCase
    func originalEightTaskBoundUsesSixteenExactOperationsAndNoBackgroundJobs():Unit {
        let f=WorkflowChildFixture111(waitService:true)
        try{
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("child-eight-111"),
                f.capabilities(),childBatchCall111(f,"child-eight-111",8),budget:childBatchBudget111()))
            try{
                @Expect(!result.isError);let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,8)
                for(i in 0..8){@Expect(httpIntentText(rows[i],"agent"),"slot-"+i.toString());@Expect(httpIntentText(rows[i],"status"),"completed")}
                @Expect(result.output.field("progress").getOrThrow().items.size,0);expectCanonicalReturnedReceipt(f.database,result)
            }finally{result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),9)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),16)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),17)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            @Expect(f.product.asyncJobs(SessionId("child-eight-111")).size,0)
        }finally{f.close()}
    }
    @TestCase
    func selectingOnlyStartDoesNotGrantWaitOrCreateTheFirstBatchChild():Unit {
        let f=WorkflowChildFixture111(waitService:false)
        try{
            let result=f.product.vnext.executeCanonicalTool(SessionId("child-wait-denied-111"),f.capabilities(),
                childBatchCall111(f,"child-wait-denied-111",2),budget:childBatchBudget111())
            match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                case _=>@Expect(false)}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{f.close()}
    }
}
