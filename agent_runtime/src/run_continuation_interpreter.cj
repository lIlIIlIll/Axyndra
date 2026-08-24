package agent_runtime

import agent_domain.*

public enum ContinuationAction {
    CompileAcceptedInput(DurablePhaseState)
    | ResumeContextCompilation(DurablePhaseState)
    | PrepareModelIntent(DurablePhaseState)
    | DispatchModelEffect(DurablePhaseState, ModelAttemptId)
    | SettleModelEffect(DurablePhaseState, ModelAttemptId)
    | CommitModelDecision(DurablePhaseState, ModelDecisionId)
    | PrepareToolBatch(DurablePhaseState, ToolBatchContinuation)
    | AwaitApproval(DurablePhaseState, OperationId, ApprovalId)
    | DispatchToolEffect(DurablePhaseState, OperationId)
    | SettleToolEffect(DurablePhaseState, OperationId)
    | PollExternalEffect(DurablePhaseState, ExternalWaitState)
    | CommitCheckpoint(DurablePhaseState)
    | FinalizeRun(DurablePhaseState)
}

// This is deliberately a total, prior-state-free interpreter. Every branch
// consumes only the current sealed continuation and rejects missing recovery
// identities instead of reconstructing them from journals or projections.
public func interpretRunContinuation(
    continuation: DurableRunContinuationV1
): Result<ContinuationAction> {
    if (!continuation.isSealed()) {
        return continuationRecovery("Run continuation is not sealed")
    }
    match (continuation.phase) {
        case RunExecutionPhase.Accepted(state) =>
            Result.Ok(ContinuationAction.CompileAcceptedInput(state))
        case RunExecutionPhase.ContextCompiling(state) =>
            Result.Ok(ContinuationAction.ResumeContextCompilation(state))
        case RunExecutionPhase.ContextReady(state) =>
            Result.Ok(ContinuationAction.PrepareModelIntent(state))
        case RunExecutionPhase.ModelReady(state) =>
            Result.Ok(ContinuationAction.PrepareModelIntent(state))
        case RunExecutionPhase.ModelEffectPending(state) =>
            match ((continuation.semanticRequestId, continuation.attemptId,
                continuation.reservedDecisionId, continuation.reservedUsageId)) {
                case (Some(_), Some(attempt), Some(_), Some(_)) =>
                    Result.Ok(ContinuationAction.DispatchModelEffect(state, attempt))
                case _ => continuationRecovery(
                    "ModelEffectPending continuation lacks reserved effect identities"
                )
            }
        case RunExecutionPhase.ModelSettling(state) =>
            match ((continuation.attemptId, continuation.reservedDecisionId,
                continuation.reservedUsageId)) {
                case (Some(attempt), Some(_), Some(_)) =>
                    Result.Ok(ContinuationAction.SettleModelEffect(state, attempt))
                case _ => continuationRecovery(
                    "ModelSettling continuation lacks settlement identities"
                )
            }
        case RunExecutionPhase.DecisionReady(state) =>
            match (continuation.reservedDecisionId) {
                case Some(decision) =>
                    Result.Ok(ContinuationAction.CommitModelDecision(state, decision))
                case None => continuationRecovery(
                    "DecisionReady continuation lacks its reserved Decision"
                )
            }
        case RunExecutionPhase.ToolBatchReady(state) =>
            match (continuation.toolBatch) {
                case Some(batch) =>
                    Result.Ok(ContinuationAction.PrepareToolBatch(state, batch))
                case None => continuationRecovery(
                    "ToolBatchReady continuation lacks its batch"
                )
            }
        case RunExecutionPhase.WaitingApproval(state) =>
            match ((continuation.pendingOperationId, continuation.pendingApprovalId)) {
                case (Some(operation), Some(approval)) =>
                    if (!containsApprovalDebt(continuation.workDebt, approval)) {
                        continuationRecovery("WaitingApproval continuation lacks approval work debt")
                    } else {
                        Result.Ok(ContinuationAction.AwaitApproval(state, operation, approval))
                    }
                case _ => continuationRecovery(
                    "WaitingApproval continuation lacks operation or approval identity"
                )
            }
        case RunExecutionPhase.ToolEffectPending(state) =>
            match (continuation.pendingOperationId) {
                case Some(operation) =>
                    Result.Ok(ContinuationAction.DispatchToolEffect(state, operation))
                case None => continuationRecovery(
                    "ToolEffectPending continuation lacks its Operation"
                )
            }
        case RunExecutionPhase.ToolSettling(state) =>
            match (continuation.pendingOperationId) {
                case Some(operation) =>
                    Result.Ok(ContinuationAction.SettleToolEffect(state, operation))
                case None => continuationRecovery(
                    "ToolSettling continuation lacks its Operation"
                )
            }
        case RunExecutionPhase.WaitingExternal(state) =>
            match (continuation.waitingExternal) {
                case Some(wait) =>
                    if (!containsExternalDebt(continuation.workDebt, wait.handleId)) {
                        continuationRecovery("WaitingExternal continuation lacks external work debt")
                    } else {
                        Result.Ok(ContinuationAction.PollExternalEffect(state, wait))
                    }
                case None => continuationRecovery(
                    "WaitingExternal continuation lacks its durable handle"
                )
            }
        case RunExecutionPhase.Checkpoint(state) =>
            Result.Ok(ContinuationAction.CommitCheckpoint(state))
        case RunExecutionPhase.Terminalizing(state) =>
            if (!continuation.workDebt.isEmpty() || continuation.pendingOperationId.isSome() ||
                continuation.pendingApprovalId.isSome() || continuation.waitingExternal.isSome()) {
                continuationRecovery("Terminalizing continuation still owns WorkDebt")
            } else {
                Result.Ok(ContinuationAction.FinalizeRun(state))
            }
    }
}

func containsApprovalDebt(debt: WorkDebtSnapshot, approval: ApprovalId): Bool {
    for (item in debt.pendingApprovals where item.value == approval.value) { return true }
    false
}

func containsExternalDebt(debt: WorkDebtSnapshot, handle: ExternalHandleId): Bool {
    for (item in debt.waitingExternal where item.value == handle.value) { return true }
    false
}

func continuationRecovery<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired,
        "continuation.recovery_required",
        message
    ))
}
