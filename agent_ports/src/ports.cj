package agent_ports

import yjson_support.*

import yjson.*

import agent_domain.*

public interface ModelPort {
    // Pure configuration/policy diagnostics before Core resolves thinking or
    // creates an Attempt. This grants no dispatch authority or provider I/O.
    // None supports internal calls whose selected model differs from the parent.
    func validatePolicySnapshot(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        let _ = model; let _ = snapshot
        Result.Ok(())
    }

    func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply>

    // Provider adapters may expose the exact immutable llm4cj transcript used for this request.
    // Domain-only test ports return None and do not fabricate a provider snapshot.
    func transcriptSnapshot(request: ModelRequest): ?String {
        let _ = request
        None
    }

    // Recovery validates the persisted provider-neutral transcript without
    // making domain-only ports invent a wire representation.
    func validateTranscriptSnapshot(snapshot: String): Bool {
        let _ = snapshot
        false
    }

    func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        Result.Ok(())
    }
}

public interface RunRepository {
    // Read-only canonical input of one already consumed continuation claim.
    // This cannot mint an owner, start a Run or authorize another Thread.
    func continuationModelInput(item: ThreadItem): Result<ModelMessage> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "continuation.input_unavailable",
            "repository cannot verify the actual consumed continuation input"))
    }

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

    // Data-only Accepted-phase seed. This does not fabricate a model Attempt,
    // approval, or permission to replay a pending host preparation after restart.
    func bindAcceptedContextRequest(run: RunId, thread: SessionId, epoch: Int64,
        initiator: ThreadItemContent, request: AgentValue, observedAtMillis: Int64): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "context.initial_persistence_unavailable",
            "repository cannot bind initial context data to an Accepted Run"))
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

    // Independent data projection for a new-format, settled context cut.
    func contextBoundary(runId: RunId): Result<?RunContextBoundary> { Result.Ok(None) }
    func contextBoundaryPressureItem(runId: RunId): Result<Bool> { Result.Ok(false) }
    func pendingContextBoundary(sessionId: SessionId): Result<?RunContextBoundary> { Result.Ok(None) }
    func reserveContextBoundaryTurn(expected: RunContextBoundary, event: AgentEvent,
        replacement: AgentValue): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_atomic_reservation_unavailable",
            "repository cannot atomically preserve a charged turn"))
    }
    func prepareContextBoundaryModelAttempt(expected: RunContextBoundary, attempt: DurableModelAttempt,
        event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_attempt_prepare_unavailable",
            "repository cannot atomically claim this new context boundary"))
    }

    func pendingRecoveryContinuation(sessionId: SessionId): Result<?RunContinuation> {
        let _ = sessionId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "run.recovery_scan_unavailable",
            "run repository cannot discover running model continuations"
        ))
    }

    func prepareInternalModelAttempt(attempt: DurableModelAttempt, event: AgentEvent,
        input: InternalModelAttemptInput): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.internal_attempt_unavailable",
            "repository cannot atomically prepare an internal model Attempt"))
    }
    func settleInternalModelAttempt(attempt: ModelAttemptId, input: InternalModelAttemptInput,
        outcome: Result<ModelReply>, completedAtMillis: Int64): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.internal_settlement_unavailable",
            "repository cannot atomically settle an internal model Attempt"))
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
    func reserveOperation(operationId: OperationId): Unit { let _ = operationId }
    func releaseOperation(operationId: OperationId): Unit { let _ = operationId }
    func execute(request: ProcessRequest): Result<ProcessResult>
    // Fixed package worker backend for an already admitted canonical child.
    // No source or approval authority is minted here. Implementations must
    // retain the package-only, denied-network legacy worker projection;
    // ordinary execute and channel policy are not interchangeable with it.
    func executePackageReadOnly(request: ProcessRequest, workspaceRoot: String): Result<ProcessResult> {
        let _ = request
        let _ = workspaceRoot
        Result.Err(AgentError(AgentErrorKind.Configuration,
            "process.package_readonly_unsupported", "this process port does not support the fixed package readonly worker profile",
            retryable: false, fallbackAllowed: false))
    }
    // Bounded raw I/O for a caller that already owns a process operation.
    // Default ports fail closed; this does not authorize a service lifecycle.
    func openChannel(request: ProcessRequest, cancellation: CancellationToken): Result<ProcessChannel> {
        openChannel(request, cancellation, 1048576)
    }
    func openChannel(request: ProcessRequest, cancellation: CancellationToken,
        maxInputBytes: Int64): Result<ProcessChannel> {
        let _ = request
        let _ = cancellation
        let _ = maxInputBytes
        Result.Err(AgentError(AgentErrorKind.Configuration,
            "process.channel_unsupported", "this process port does not support raw channels",
            retryable: false, fallbackAllowed: false))
    }
    // A cancellation request is not a cleanup acknowledgement. This succeeds
    // only when this operation retains no raw-channel resources, including a
    // failed/pending open that never returned a ProcessChannel handle.
    func closeChannelOperation(operationId: OperationId): Result<Unit> {
        let _ = operationId
        Result.Err(AgentError(AgentErrorKind.Configuration,
            "process.channel_unsupported", "this process port does not support raw channel cleanup",
            retryable: false, fallbackAllowed: false))
    }
    func closeChannelResource(owner: ProcessResourceOwner): Result<Unit> {
        match (owner) {
            case ProcessResourceOwner.Operation(id) => closeChannelOperation(id)
            case ProcessResourceOwner.ModelAttempt(_, _) => Result.Err(AgentError(AgentErrorKind.Configuration,
                "process.resource_unsupported", "this process port cannot close ModelAttempt resources"))
        }
    }
    func cancelResource(owner: ProcessResourceOwner): Result<Unit> {
        match (owner) {
            case ProcessResourceOwner.Operation(id) => cancel(id)
            case ProcessResourceOwner.ModelAttempt(_, _) => Result.Err(AgentError(AgentErrorKind.Configuration,
                "process.resource_unsupported", "this process port cannot cancel ModelAttempt resources"))
        }
    }
    func cancel(operationId: OperationId): Result<Unit>
}

public class NetworkGatewayLease {
    public let resourceOwner: ProcessResourceOwner
    public prop operationId: OperationId { get() { resourceOwner.requireOperation() } }
    public let proxyHost: String
    public let proxyPort: UInt16
    public let proxyCredential: String
    public let caBundle: String
    // The proxy endpoint is local to the sandbox bridge. The bridge socket and
    // executable are host-selected composition values, not model input.
    public let bridgeSocket: String
    public let bridgeExecutable: String

    public init(
        operationId: OperationId,
        proxyHost: String,
        proxyPort: UInt16,
        proxyCredential: String,
        caBundle!: String = "",
        bridgeSocket!: String = "",
        bridgeExecutable!: String = ""
    ) {
        if (proxyHost.trimAscii() == "" || proxyPort == 0u16) {
            throw IllegalArgumentException("network gateway endpoint is invalid")
        }
        if (!validNetworkGatewayCredential(proxyCredential)) {
            throw IllegalArgumentException("network gateway credential is invalid")
        }
        if ((bridgeSocket.trimAscii() == "") != (bridgeExecutable.trimAscii() == "")) {
            throw IllegalArgumentException("network gateway bridge values must be provided together")
        }
        this.resourceOwner = ProcessResourceOwner.Operation(operationId)
        this.proxyHost = proxyHost.trimAscii()
        this.proxyPort = proxyPort
        this.proxyCredential = proxyCredential
        this.caBundle = caBundle.trimAscii()
        this.bridgeSocket = bridgeSocket.trimAscii()
        this.bridgeExecutable = bridgeExecutable.trimAscii()
    }
    public init(
        resourceOwner: ProcessResourceOwner,
        proxyHost: String,
        proxyPort: UInt16,
        proxyCredential: String,
        caBundle!: String = "",
        bridgeSocket!: String = "",
        bridgeExecutable!: String = ""
    ) {
        if (proxyHost.trimAscii() == "" || proxyPort == 0u16) {
            throw IllegalArgumentException("network gateway endpoint is invalid")
        }
        if (!validNetworkGatewayCredential(proxyCredential)) {
            throw IllegalArgumentException("network gateway credential is invalid")
        }
        if ((bridgeSocket.trimAscii() == "") != (bridgeExecutable.trimAscii() == "")) {
            throw IllegalArgumentException("network gateway bridge values must be provided together")
        }
        resourceOwner.validate()
        this.resourceOwner = resourceOwner
        this.proxyHost = proxyHost.trimAscii()
        this.proxyPort = proxyPort
        this.proxyCredential = proxyCredential
        this.caBundle = caBundle.trimAscii()
        this.bridgeSocket = bridgeSocket.trimAscii()
        this.bridgeExecutable = bridgeExecutable.trimAscii()
    }
}
func validNetworkGatewayCredential(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return false
        }
    }
    true
}

// The gateway owns all mediated egress. A process in NetworkPolicyMode.Mediated
// is never allowed to fall back to HostNetwork when this port is unavailable.
public interface NetworkGatewayPort {
    func acquire(
        operationId: OperationId,
        policy: NetworkPolicy
    ): Result<NetworkGatewayLease>
    func acquireResource(owner: ProcessResourceOwner, policy: NetworkPolicy): Result<NetworkGatewayLease> {
        match (owner) {
            case ProcessResourceOwner.Operation(id) => acquire(id, policy)
            case ProcessResourceOwner.ModelAttempt(_, _) => Result.Err(AgentError(AgentErrorKind.Configuration,
                "network.gateway_resource_unsupported", "gateway does not support ModelAttempt resources"))
        }
    }
    func release(lease: NetworkGatewayLease): Result<Unit>
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
