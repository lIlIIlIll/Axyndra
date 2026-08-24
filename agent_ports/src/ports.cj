package agent_ports

import agent_domain.*

public interface ModelPort {
    func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply>

    func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        Result.Ok(())
    }
}

public interface RunRepository {
    func save(snapshot: RunSnapshot): Result<Unit>
    func find(runId: RunId): Result<RunSnapshot>
    func events(runId: RunId, after: Int64): Result<EventPage>
    func append(event: AgentEvent): Result<Unit>

    // Durable repositories override this to commit the exact model Attempt
    // policy row and its audit event in one transaction before provider I/O.
    // Ephemeral repositories retain event ordering; ModelDecisionRuntimePort
    // separately mirrors the Attempt for in-memory lifecycle bookkeeping.
    func persistAttemptPolicy(
        attempt: DurableModelAttempt,
        event: AgentEvent
    ): Result<Unit> {
        let _ = attempt
        append(event)
    }

    func saveContinuation(value: RunContinuation): Result<Unit> {
        let _ = value
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.continuation_unavailable",
            "run repository does not support durable approval continuation"
        ))
    }

    func continuation(runId: RunId): Result<RunContinuation> {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.continuation_missing",
            "pending run continuation is unavailable",
            fields: [ErrorField("run_id", runId.value)]
        ))
    }

    func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        let _ = sessionId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.pending_scan_unavailable",
            "run repository cannot discover durable pending approvals"
        ))
    }

    func compareAndSwapContinuation(
        expected: ?RunContinuation,
        next: RunContinuation
    ): Result<RunContinuation> {
        let _ = expected
        let _ = next
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.continuation_cas_unavailable",
            "run repository does not support continuation compare-and-swap"
        ))
    }

    func pendingRecoveryContinuation(sessionId: SessionId): Result<?RunContinuation> {
        let _ = sessionId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.recovery_scan_unavailable",
            "run repository cannot discover running model continuations"
        ))
    }

    func prepareModelAttempt(
        attempt: DurableModelAttempt,
        event: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        let _ = attempt
        let _ = event
        let _ = continuation
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.attempt_prepare_unavailable",
            "run repository cannot atomically prepare a model attempt"
        ))
    }

    // Restart recovery has a stronger boundary than an ordinary prepare: the
    // claimed parent is abandoned, the child/continuation are installed, and
    // both audit events are committed atomically before any provider I/O.
    func prepareRestartModelAttempt(
        parent: DurableModelAttempt,
        attempt: DurableModelAttempt,
        policyEvent: AgentEvent,
        duplicateEvent: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        let _ = parent
        let _ = attempt
        let _ = policyEvent
        let _ = duplicateEvent
        let _ = continuation
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.restart_attempt_prepare_unavailable",
            "run repository cannot atomically prepare a restart model attempt"
        ))
    }

    func modelAttempt(attemptId: ModelAttemptId): Result<DurableModelAttempt> {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.attempt_read_unavailable",
            "run repository cannot read durable model attempts",
            fields: [ErrorField("attempt_id", attemptId.value)]
        ))
    }

    func claimModelAttemptDispatch(
        attemptId: ModelAttemptId,
        event: AgentEvent
    ): Result<Bool> {
        let _ = attemptId
        let _ = event
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.dispatch_claim_unavailable",
            "run repository cannot claim model dispatch"
        ))
    }

    func markModelAttemptReplayBarrier(
        attemptId: ModelAttemptId,
        barrier: ModelAttemptReplayBarrier,
        event: AgentEvent
    ): Result<Unit> {
        let _ = attemptId
        let _ = barrier
        let _ = event
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.replay_barrier_unavailable",
            "run repository cannot persist model replay barriers"
        ))
    }

    func clearModelExecutionContinuation(
        runId: RunId,
        activeAttemptId: ModelAttemptId
    ): Result<Unit> {
        let _ = runId
        let _ = activeAttemptId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.model_continuation_clear_unavailable",
            "run repository cannot clear model execution continuation"
        ))
    }

    func saveDecision(receipt: ApprovalDecisionReceipt): Result<Unit> {
        let _ = receipt
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.decision_receipt_unavailable",
            "run repository does not support durable approval decisions"
        ))
    }

    func decision(operationId: OperationId): Result<ApprovalDecisionReceipt> {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "persistence.not_found",
            "approval decision receipt was not found",
            fields: [ErrorField("operation_id", operationId.value)]
        ))
    }

    // Atomically validates the current run state and records the first
    // approval decision. Implementations must serialize this with run status
    // updates; a non-pending run must never gain a new decision receipt.
    func recordDecision(receipt: ApprovalDecisionReceipt): Result<RunSnapshot> {
        let _ = receipt
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.atomic_decision_unavailable",
            "run repository does not support atomic approval decisions"
        ))
    }
}

public interface OperationRepository {
    func prepare(record: OperationRecord): Result<Unit>
    func transition(
        operationId: OperationId,
        expected: OperationStatus,
        next: OperationStatus
    ): Result<Unit>
    func find(operationId: OperationId): Result<OperationRecord>
    func receipt(operationId: OperationId): Result<OperationReceipt>
    func saveReceipt(receipt: OperationReceipt): Result<Unit>
}

public interface PermissionRepository {
    func allows(sessionId: SessionId, scope: ApprovalGrantScope): Result<Bool>
    func grant(sessionId: SessionId, scope: ApprovalGrantScope): Result<Unit>
}

public interface WorkspacePort {
    func read(request: WorkspaceReadRequest): Result<WorkspaceReadResult>
    func prepare(mutation: WorkspaceMutation): Result<AgentValue>
    func commit(mutation: WorkspaceMutation): Result<OperationReceipt>

    func commitAll(mutations: Array<WorkspaceMutation>): Result<Array<OperationReceipt>> {
        if (mutations.size != 1) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "workspace.transactions_unavailable",
                    "workspace does not support multi-file transactions"
                )
            )
        }
        match (commit(mutations[0])) {
            case Result.Ok(receipt) => Result.Ok([receipt])
            case Result.Err(error) => Result.Err(error)
        }
    }
}

public interface ProcessPort {
    func execute(request: ProcessRequest): Result<ProcessResult>
    func cancel(operationId: OperationId): Result<Unit>
}

public interface AuditPort {
    func append(event: AgentEvent): Result<Unit>
}

public interface ClockPort {
    func monotonicMillis(): Int64
}

public interface IdGenerator {
    func nextRunId(): RunId
    func nextSessionId(): SessionId
    func nextOperationId(): OperationId
}
