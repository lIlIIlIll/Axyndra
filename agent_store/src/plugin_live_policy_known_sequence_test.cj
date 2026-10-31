package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

private func knownSequenceCommitted68(value:SemanticCommitDecision):Bool{
    match(value){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false}
}
private func knownSequenceRequire<T>(result:Result<T>):T{
    match(result){case Result.Ok(value)=>value;case Result.Err(error)=>
        throw IllegalStateException("actual known sequence fixture: "+error.code)}
}
class KnownSequenceEstimator <: ThreadTokenEstimator {
    public init(){}
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
class KnownSequenceAbsentFixture {
    let directory:String
    let database:SqliteDatabase
    let root:OperationRootSource
    let run=RunId("known-sequence-run")
    let parent=OperationId("known-sequence-parent")
    init(){
        let path=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(path+"/known.sqlite")
        let sink=SqliteThreadCommitSink(db)
        let thread=ThreadId("known-sequence-thread")
        let turn=SemanticTurnId("known-sequence-turn")
        let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("known",KnownSequenceEstimator()),{=>10})
        let lane=ModelLane(ModelLaneRole.Main,"provider","model","responses",ModelLaneCapabilitiesSnapshot(),
            100,10,5,"estimator","retry","cache",ToolSetSnapshot("tools",[]),"system")
        let active=knownSequenceRequire(runtime.startTurn(turn,run,ItemId("known-sequence-user"),
            ThreadItemContent.UserMessage(textMessageParts("inspect the selected proposal")),lane,InvocationContextProjection()))
        let item=ItemId("known-sequence-call-item")
        let call=ToolCall("known-sequence-call","plugin.axyndra:memory.retain",objectValue([]))
        if(!knownSequenceCommitted68(runtime.commitResult(ResultEnvelope(thread,turn,run,active.epoch,1,
            ThreadItemDraft(item,ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId),call.name,call.arguments),
                ItemProvenance("direct_tool",runId:Some(run),operationId:Some(parent))))))){
            throw IllegalStateException("actual known sequence parent call did not commit")}
        this.directory=path;this.database=db
        this.root=OperationRootSource.Direct(knownSequenceRequire(runtime.attestDirectToolCall(item,parent,run,active.epoch)))
    }
    func rejects(parentId:OperationId,runId:RunId,sequence:Int64):Bool{
        try{database.readTransaction<Unit>({tx=>
            let _=livePolicyKnownSequenceAdmission(tx,root,parentId,runId,sequence)});false}
        catch(_:Exception){true}
    }
    func unchanged():Unit{
        for(table in ["operations","derived_operation_admissions","operation_receipts","audit_events"]){
            @Expect(database.scalarInt("SELECT COUNT(*) FROM "+table),0)}
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"),1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"),0)
    }
    func close():Unit{database.close();remove(directory,recursive:true)}
}

@Test
class LivePolicyKnownSequenceAdmissionTests {
    @TestCase
    func actualCommittedRootCannotInventASettledChildOrReservedReceipt():Unit{
        let f=KnownSequenceAbsentFixture()
        try{@Expect(f.rejects(f.parent,f.run,1),true);f.unchanged()}finally{f.close()}
    }
    @TestCase
    func foreignParentRunAndEverySignedSequenceRemainAbsentWithoutARealAdmission():Unit{
        let f=KnownSequenceAbsentFixture()
        try{
            for(sequence in [Int64.Min,Int64(-1),Int64(0),Int64(1),Int64.Max]){
                @Expect(f.rejects(f.parent,f.run,sequence),true)}
            @Expect(f.rejects(OperationId("foreign-parent"),f.run,1),true)
            @Expect(f.rejects(f.parent,RunId("foreign-run"),1),true);f.unchanged()
        }finally{f.close()}
    }
    @TestCase
    func repeatedMissingReceiptsNeverAppendAnItemOrAuditOrRetainAnotherOwnersAllocation():Unit{
        let f=KnownSequenceAbsentFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        try{
            for(_ in 0..32){
                @Expect(f.rejects(f.parent,f.run,1),true)
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)}
            f.unchanged()
        }finally{held.close();f.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
