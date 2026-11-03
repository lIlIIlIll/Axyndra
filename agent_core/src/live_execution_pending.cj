package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

// Run-local routing of actual private Tools output. No decoded Source,
// custody, approval or effect authority is created here.
class CoreOwnedResumeClaim {
    private let lock=Mutex()
    private var claimed=false
    func claim():Bool { lock.lock();try {
        if (claimed) { false } else { claimed=true;true }
    } finally { lock.unlock() } }
}
class CorePendingOwnedExecution {
    let work:CorePreparedTool
    let publication:OwnedToolExecutionPublication
    let remaining:CoreToolBatchPreparation
    private let resumeClaim=CoreOwnedResumeClaim()
    init(work:CorePreparedTool,publication:OwnedToolExecutionPublication,remaining:CoreToolBatchPreparation) {
        this.work=work;this.publication=publication;this.remaining=remaining
    }
    func claim():Bool { resumeClaim.claim() }
    func matches(context:ToolInvocationContext,approval:ApprovalRequest):Bool {
        if(publication.isPreparedPhase()){
            return publication.matchesPreparedParent(context,work.prepared,approval) &&
                work.prepared.source.kind==PreparedInvocationSourceKind.Committed && work.prepared.source.operationRoot.isSome() &&
                match(work.prepared.source.operationRoot.getOrThrow()){
                    case OperationRootSource.Committed(value)=>refEq(value,work.committed);case _=>false}}

        publication.matchesContext(context) && refEq(work.prepared,publication.continuation.parent) &&
            publication.continuation.approval.operationId.value==approval.operationId.value &&
            publication.continuation.approval.callId==approval.callId &&
            publication.continuation.approval.toolName==approval.toolName &&
            publication.continuation.approval.sessionId==approval.sessionId &&
            publication.continuation.approval.argumentHash==approval.argumentHash &&
            work.prepared.source.kind==PreparedInvocationSourceKind.Committed &&
            work.prepared.source.operationRoot.isSome() &&
            match (work.prepared.source.operationRoot.getOrThrow()) {
                case OperationRootSource.Committed(value) => refEq(value,work.committed)
                case _ => false
            }
    }
}
class CorePendingOwnedParentApproval {
    let work:CorePreparedTool
    private let resumeClaim=CoreOwnedResumeClaim()
    init(work:CorePreparedTool) { this.work=work }
    func claim():Bool { resumeClaim.claim() }
}
func coreOwnedLiveBusy():AgentError {
    AgentError(AgentErrorKind.Conflict,"tool.live_pending_slot_unavailable",
        "the same original Run already has another pending owner or is no longer running")
}
func coreOwnedLiveOwnerMissing():AgentError {
    AgentError(AgentErrorKind.RecoveryRequired,"tool.live_owner_missing",
        "approval cannot recreate a lost original prepared parent or physical execution custody")
}
func coreOwnedPublicationFailure(error:AgentError):AgentError {
    AgentError(AgentErrorKind.RecoveryRequired,"tool.live_publication_unsettled",
        "the same parent and prepared child remain owned after approval publication failed",
        fields:[ErrorField("cause",error.code)])
}
func coreOwnedCounter(snapshot:RunSnapshot):BudgetCounter {
    BudgetCounter(modelRequests:snapshot.modelRequests,inputTokens:snapshot.inputTokens,
        outputTokens:snapshot.outputTokens,reasoningTokens:snapshot.reasoningTokens,
        cacheReadTokens:snapshot.cacheReadTokens,cacheWriteTokens:snapshot.cacheWriteTokens,
        costMicros:snapshot.costMicros,lastInputTokens:snapshot.lastInputTokens,
        lastOutputTokens:snapshot.lastOutputTokens,lastRequestDurationMillis:snapshot.lastRequestDurationMillis,
        toolCalls:snapshot.toolCalls,turns:snapshot.turns)
}

// Scheduler accounting only. A lease grants no Source, approval, admission
// or process permission. Nested work continues to use the existing ledger.
class CoreOwnedResumeSlotLease {
    private let control:CoreRunControl
    private let operation:OperationId
    private let lock=Mutex()
    private var released=false
    init(control:CoreRunControl,operation:OperationId) { this.control=control;this.operation=operation }
    func release():Result<Unit> {
        lock.lock();try {
            if (released) { return Result.Ok(()) };released=true
        } finally { lock.unlock() }
        // A yielded/in-flight child still owns its actual ledger slot. The
        // parent return cannot erase or release that child's accounting.
        if (!control.unregisterScheduledToolSlot(operation)) { return Result.Ok(()) }
        match (control.ledger.releaseTools()) {case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(())}
    }
}
func coreAcquireOwnedResumeSlot(control:CoreRunControl,operation:OperationId,tool:String):Result<CoreOwnedResumeSlotLease> {
    match (control.source.token.check()) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match (control.reserve(BudgetCharge(toolsStarted:1))) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match (control.registerScheduledToolSlot(operation,tool)) {
        case Result.Err(error)=>
            match(control.ledger.releaseTools()){case Result.Err(failure)=>return Result.Err(failure);case Result.Ok(_)=>()}
            return Result.Err(error)
        case Result.Ok(_)=>()
    }
    Result.Ok(CoreOwnedResumeSlotLease(control,operation))
}

// Preserve both returned physical debt and a later scheduler/event/commit
// error. This error carrier neither acknowledges nor closes Host custody.
func coreOwnedMergeSettlementError(error:AgentError,settlement:?AgentError):AgentError {
    match (settlement) {
        case None => error
        case Some(other) =>
            if (refEq(error,other)) { error } else {
                AgentError(AgentErrorKind.RecoveryRequired,"tool.live_completion_unsettled",
                    "known owned completion has more than one unsettled failure",
                    fields:[ErrorField("completion_cause",error.code),
                        ErrorField("completion_detail",error.describe()),
                        ErrorField("settlement_cause",other.code),
                        ErrorField("settlement_detail",other.describe())])
            }
    }
}

class CoreOwnedSlotProgress {
    let progress:Result<OwnedToolPipelineProgress>
    let settlementError:?AgentError
    init(progress:Result<OwnedToolPipelineProgress>,settlementError!:?AgentError=None) {
        match (progress) {
            case Result.Ok(OwnedToolPipelineProgress.RetainedWithDebt(result,error)) =>
                this.progress=Result.Ok(OwnedToolPipelineProgress.Retained(result))
                this.settlementError=Some(coreOwnedMergeSettlementError(error,settlementError))
            case Result.Ok(OwnedToolPipelineProgress.CompletedWithDebt(result,error)) =>
                let debt=Some(coreOwnedMergeSettlementError(error,settlementError))
                match (result) {
                    // Only an already known terminal result enters the
                    // original canonical Parent persistence/ACK path.
                    case Result.Ok(ToolInvocationResult.Completed(_)) =>
                        this.progress=Result.Ok(OwnedToolPipelineProgress.Completed(result))
                    case Result.Err(failure) =>
                        this.progress=Result.Err(coreOwnedMergeSettlementError(failure,debt))
                    case _ =>
                        this.progress=Result.Err(coreOwnedMergeSettlementError(AgentError(
                            AgentErrorKind.RecoveryRequired,"tool.live_completed_debt_result_invalid",
                            "owned completion debt did not carry a known terminal result"),debt))
                }
                this.settlementError=debt
            case _ => this.progress=progress;this.settlementError=settlementError
        }
    }
}
