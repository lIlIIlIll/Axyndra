package agent_store

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

// Every case starts a real disk-backed Runtime, commits its canonical call,
// attests that call, and prepares the actual Direct operation. SQL changes
// below are negative fault injection, never sources of a successful grant.
class WaitingFailureFixture {
    let root: String
    let database: SqliteDatabase
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let operations: DurableOperationStore
    let plan: NormalizedOperationPlan
    let thread=ThreadId("waiting-failure-thread")
    let turn=SemanticTurnId("waiting-failure-turn")
    let run=RunId("waiting-failure-run")
    let operation=OperationId("waiting-failure-operation")
    let call=CanonicalToolCallId("waiting-failure-call")
    let callItem=ItemId("waiting-failure-call-item")
    let resultItem: ItemId
    let receiptId: String
    init(waiting!:Bool=true){
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database=SqliteDatabase(root+"/state.sqlite")
        let sink=SqliteThreadCommitSink(database)
        let thread=ThreadId("waiting-failure-thread");let turn=SemanticTurnId("waiting-failure-turn")
        let run=RunId("waiting-failure-run");let operation=OperationId("waiting-failure-operation")
        let call=CanonicalToolCallId("waiting-failure-call");let callItem=ItemId("waiting-failure-call-item")
        let coordinator=ThreadCoordinator(sink.createThread(thread,"workspace"),sink)
        let runtime=AgentThreadRuntime(coordinator,ContextProjector("waiting-failure",WaitingFailureEstimator()),{=>100})
        let lane=ModelLane(ModelLaneRole.Main,"fixture","fixture","responses",ModelLaneCapabilitiesSnapshot(),
            100,10,5,"estimator","retry","cache",ToolSetSnapshot("tools",[]),"system-v1")
        let started=runtime.startTurn(turn,run,ItemId("waiting-failure-user"),
            ThreadItemContent.UserMessage(textMessageParts("review the real read")),lane,InvocationContextProjection(),createdAtMillis:1).value().getOrThrow()
        let snapshot=runtime.threadSnapshot()
        let committed=runtime.commitResult(ResultEnvelope(thread,turn,run,started.epoch,snapshot.nextResultSequence,
            ThreadItemDraft(callItem,ThreadItemContent.ToolCall(call,"read",objectValue([])),
                ItemProvenance("direct_tool",runId:Some(run),operationId:Some(operation)),createdAtMillis:2)))
        if(!waitingFailureCommitted(committed)){throw IllegalStateException("fixture canonical call failed")}
        let source=runtime.attestDirectToolCall(callItem,operation,run,started.epoch).value().getOrThrow()
        let plan=NormalizedOperationPlan("read",objectValue([]),[Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly,OperationRetryDisposition.Safe,"waiting-failure-binding")
        let operations=DurableOperationStore(database)
        operations.prepareDirectOperation(source,plan).value().getOrThrow()
        if(waiting){operations.waitForApproval(operation,run).value().getOrThrow()
            runtime.pauseForApproval().value().getOrThrow();runtime.resumeAfterApproval().value().getOrThrow()}
        let reserved=database.query("SELECT reserved_receipt_id,reserved_result_item_id FROM operation_effect_records WHERE operation_id=? AND run_id=?",
            [SqlParameter.Text(operation.value),SqlParameter.Text(run.value)])
        if(reserved.size!=1){throw IllegalStateException("fixture lost its actual reserved slots")}
        this.root=root;this.database=database;this.coordinator=coordinator;this.runtime=runtime
        this.operations=operations;this.plan=plan;this.receiptId=reserved[0].required(0);this.resultItem=ItemId(reserved[0].required(1))
    }
    func terminal(stage!:OperationAttemptStage=OperationAttemptStage.Prepared,
        kind!:AgentErrorKind=AgentErrorKind.Configuration):OperationTerminalResolution{
        match(resolveOperationAttempt(operation,call,plan,stage,
            Result<ToolInvocationResult>.Err(AgentError(kind,"fixture.preparation_changed","actual preparation changed")),receiptId,4)){
            case OperationResolution.Terminal(value)=>value
            case _=>throw IllegalStateException("fixture expected terminal preparation")
        }
    }
    func commit(value:OperationTerminalResolution,verification!:?AgentValue=None):SemanticCommitDecision{
        let result=value.toolResult.getOrThrow();let original=value.receipt
        let receipt=match(verification){case Some(v)=>VNextOperationReceipt(original.receiptId,original.operationId,
            original.outcome,original.detail,v,original.observedAtMillis);case None=>original}
        let snapshot=runtime.threadSnapshot();let active=runtime.activeRun().getOrThrow()
        coordinator.commitOperationResult(ResultEnvelope(thread,turn,run,active.epoch,snapshot.nextResultSequence,
            ThreadItemDraft(resultItem,ThreadItemContent.ToolResult(call,operation,receipt.receiptId,result.output,result.isError),
                ItemProvenance("operation",runId:Some(run),operationId:Some(operation)),createdAtMillis:4)),receipt,"running")
    }
    func close():Unit{database.close();remove(root,recursive:true)}
}
class WaitingFailureEstimator <: ThreadTokenEstimator{
    public func estimateSystemInstructions(_:String):Int64{1}
    public func estimateToolSet(_:ToolSetSnapshot):Int64{1}
    public func estimateCheckpoint(_:ContextCheckpoint):Int64{1}
    public func estimateItem(_:ThreadItem):Int64{1}
    public func estimateDynamicState(_:AgentValue):Int64{1}
}
func waitingFailureCommitted(value:SemanticCommitDecision):Bool{
    match(value){case SemanticCommitDecision.Committed(_,_)=>true;case _=>false}
}

@Test
class WaitingPreparationFailureTests{
    @TestCase
    func waitingPreparationFailureCommitsOnlyActualPreparedEvidenceWithoutHandoff():Unit{
        for(waiting in [false,true]){
            let f=WaitingFailureFixture(waiting:waiting)
            try{
                let resolution=f.terminal()
                @Expect(resolution.receipt.outcome,OperationOutcome.Failed)
                @Expect(waitingFailureCommitted(f.commit(resolution)))
                let rows=f.database.query("SELECT receipt.id,receipt.verification,result.payload FROM operations o "+
                    "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id "+
                    "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id "+
                    "JOIN items result ON result.id=e.reserved_result_item_id AND result.kind='tool_result' "+
                    "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND receipt.outcome='failed'",
                    [SqlParameter.Text(f.operation.value),SqlParameter.Text(f.run.value)])
                @Expect(rows.size,1);@Expect(rows[0].required(0),f.receiptId)
                @Expect(canonicalAgentValue(decodeStoredValue(rows[0].required(1))),canonicalAgentValue(resolution.receipt.verification))
                match(decodeStoredThreadContent(rows[0].required(2))){case ThreadItemContent.ToolResult(id,op,receipt,output,isError)=>
                    @Expect(id.value,f.call.value);@Expect(op.value,f.operation.value);@Expect(receipt,f.receiptId);@Expect(isError)
                    @Expect(canonicalAgentValue(output),canonicalAgentValue(resolution.toolResult.getOrThrow().output))
                    case _=>@Expect(false)}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approval_decisions"),0)
                @Expect(f.runtime.finish(RunState.Failed,1000).isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='failed'"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
            }finally{f.close()}
        }
    }
    @TestCase
    func missingOrChangedPreparationProofCannotSettleWaitingApproval():Unit{
        for(fault in ["missing_stage","executing_stage","wrong_epoch","inactive_turn","missing_call","handoff","unknown"]){
            let f=WaitingFailureFixture()
            try{
                let actual=f.terminal();var verification:?AgentValue=None
                if(fault=="missing_stage"){verification=Some(objectValue([]))}
                else if(fault=="executing_stage"){verification=Some(objectValue([ValueField("stage",textValue("executing"))]))}
                else if(fault=="wrong_epoch"){f.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id=?",[SqlParameter.Text(f.run.value)])}
                else if(fault=="inactive_turn"){f.database.execute("UPDATE turns SET active_run_id=NULL WHERE id=?",[SqlParameter.Text(f.turn.value)])}
                else if(fault=="missing_call"){f.database.execute("UPDATE items SET kind='system_note' WHERE id=?",[SqlParameter.Text(f.callItem.value)])}
                else if(fault=="handoff"){
                    f.operations.recordApproval("approval-"+f.operation.value,f.operation,f.run,f.plan,
                        CapabilitySet(values:f.plan.requiredCapabilities),true,"user").value().getOrThrow()
                    f.operations.markExecuting(f.operation,f.run,f.plan,3,true).value().getOrThrow()
                    f.operations.markExecutionHandoff(f.operation,f.run,f.thread,3).value().getOrThrow()
                    // A corrupt state rollback cannot hide a real handoff.
                    f.database.execute("UPDATE operations SET state='waiting_approval' WHERE id=?",[SqlParameter.Text(f.operation.value)])
                    f.database.execute("UPDATE operation_state_registers SET state='waiting_approval' WHERE operation_id=?",[SqlParameter.Text(f.operation.value)])
                }
                let terminal=if(fault=="unknown"){f.terminal(kind:AgentErrorKind.RecoveryRequired)}else{actual}
                let before=f.runtime.threadSnapshot()
                @Expect(match(f.commit(terminal,verification:verification)){case SemanticCommitDecision.Rejected(_)=>true;case _=>false})
                @Expect(f.runtime.threadSnapshot().thread.revision,before.thread.revision)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"),0)
                @Expect(f.database.query("SELECT state FROM operations WHERE id=?",[SqlParameter.Text(f.operation.value)])[0].required(0),"waiting_approval")
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
            }finally{f.close()}
        }
    }
    @TestCase
    func actualExecutionUnknownKeepsItsReconciliationDebt():Unit{
        let f=WaitingFailureFixture()
        try{
            f.operations.recordApproval("approval-"+f.operation.value,f.operation,f.run,f.plan,
                CapabilitySet(values:f.plan.requiredCapabilities),true,"user").value().getOrThrow()
            f.operations.markExecuting(f.operation,f.run,f.plan,3,true).value().getOrThrow()
            f.operations.markExecutionHandoff(f.operation,f.run,f.thread,3).value().getOrThrow()
            let terminal=f.terminal(stage:OperationAttemptStage.Executing,kind:AgentErrorKind.RecoveryRequired)
            @Expect(terminal.receipt.outcome,OperationOutcome.Unknown)
            @Expect(waitingFailureCommitted(f.commit(terminal)))
            @Expect(f.database.query("SELECT state FROM operations WHERE id=?",[SqlParameter.Text(f.operation.value)])[0].required(0),"recovery_required")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='failed'"),0)
            @Expect(f.runtime.finish(RunState.Completed,1000).isError())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='completed'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
        }finally{f.close()}
    }
}
