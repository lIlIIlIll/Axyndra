package operation_domain_vnext_contract

import yjson_support.*

import yjson.*

import agent_domain.*

main(): Int64 {
    let writePlan = NormalizedOperationPlan(
        "write", objectValue([]),
        [Capability(CapabilityKind.WorkspaceWrite, resource: "/repo/file")],
        OperationEffectClass.WorkspaceMutation,
        OperationRetryDisposition.Never,
        "digest",
        resolvedPaths: ["/repo/file"], cwd: "/repo"
    )
    expect(operationRetryDecision(
        OperationOutcome.Unknown,
        OperationRetryDisposition.Never
    ) == OperationRetryDecision.Stop, "unknown side effect is never blindly retried")
    expect(operationRetryDecision(
        OperationOutcome.Unknown,
        OperationRetryDisposition.VerifyThenRetry
    ) == OperationRetryDecision.VerifyFirst, "unknown verifiable effect requires verification")
    expect(operationRetryDecision(
        OperationOutcome.Unknown,
        OperationRetryDisposition.VerifyThenRetry,
        verificationProvedNoEffect: true
    ) == OperationRetryDecision.Retry, "verified no-effect operation may retry")
    expect(operationRetryDecision(
        OperationOutcome.TimedOut,
        OperationRetryDisposition.Safe
    ) == OperationRetryDecision.Retry, "safe operation may retry after timeout")
    expect(operationRetryDecision(
        OperationOutcome.Cancelled,
        OperationRetryDisposition.Safe
    ) == OperationRetryDecision.Stop, "user cancellation is not an automatic retry signal")
    var rejected = false
    try {
        let _ = NormalizedOperationPlan(
            "external", objectValue([]), [Capability(CapabilityKind.NetworkAccess)],
            OperationEffectClass.ExternalMutation,
            OperationRetryDisposition.ByIdempotencyKey,
            "digest"
        )
    } catch (_: Exception) { rejected = true }
    expect(rejected, "idempotency retry requires a key")
    replayDispositionContract()
    operationResolutionContract(writePlan)
    println("vNext operation domain contract passed")
    0
}

func replayDispositionContract(): Unit {
    let frozen = ToolImplementationIdentity(
        "write", "2.0.0", "implementation-a", "schema-a", "arguments-a"
    )
    let same = ToolImplementationIdentity(
        "write", "2.0.0", "implementation-a", "schema-a", "arguments-a"
    )
    let changed = ToolImplementationIdentity(
        "write", "2.0.1", "implementation-b", "schema-a", "arguments-a"
    )
    expect(match (replayRecoveryAction(ReplayDisposition.Pure, frozen, changed)) {
        case ReplayRecoveryAction.Recompute => true; case _ => false
    }, "pure effects may be recomputed independently of implementation generation")
    expect(match (replayRecoveryAction(ReplayDisposition.SafeReplay, frozen, same)) {
        case ReplayRecoveryAction.Replay => true; case _ => false
    }, "safe replay requires the frozen implementation identity")
    expect(match (replayRecoveryAction(ReplayDisposition.SafeReplay, frozen, changed)) {
        case ReplayRecoveryAction.RequireRecovery => true; case _ => false
    }, "implementation drift forbids blind safe replay")
    expect(match (replayRecoveryAction(
        ReplayDisposition.Idempotent("stable-key"), frozen, same
    )) {
        case ReplayRecoveryAction.ReplayWithIdempotencyKey(key) => key == "stable-key"
        case _ => false
    }, "idempotent replay retains its frozen key")
    expect(match (replayRecoveryAction(
        ReplayDisposition.RecoverByProbe(RecoveryProbeId("probe")), frozen, changed
    )) {
        case ReplayRecoveryAction.Probe(value) => value.value == "probe"
        case _ => false
    }, "probe recovery does not invoke a changed implementation")
    expect(match (replayRecoveryAction(
        ReplayDisposition.Compensatable(CompensationPlanId("compensate")), frozen, changed
    )) {
        case ReplayRecoveryAction.Compensate(value) => value.value == "compensate"
        case _ => false
    }, "compensatable effects retain their frozen compensation plan")
    expect(match (replayRecoveryAction(ReplayDisposition.AtMostOnce, frozen, same)) {
        case ReplayRecoveryAction.Interrupt => true; case _ => false
    }, "at-most-once effects become interrupted after uncertainty")
    expect(match (replayRecoveryAction(ReplayDisposition.NeverReplay, frozen, same)) {
        case ReplayRecoveryAction.RequireRecovery => true; case _ => false
    }, "never-replay effects require explicit recovery")
}

func operationResolutionContract(writePlan: NormalizedOperationPlan): Unit {
    let timeout = AgentError(
        AgentErrorKind.Timeout, "process.timeout", "process deadline expired", retryable: true
    )
    let unknown = terminal(resolveOperationAttempt(
        OperationId("write-operation"), CanonicalToolCallId("write-call"),
        writePlan, OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Err(timeout), "write-receipt", 10
    ))
    expect(unknown.receipt.outcome == OperationOutcome.Unknown &&
        unknown.retryDecision == OperationRetryDecision.Stop &&
        unknown.error.getOrThrow().kind == AgentErrorKind.RecoveryRequired &&
        unknown.toolResult.getOrThrow().isError &&
        unknown.toolResult.getOrThrow().output.field(
            "reconciliation_required"
        ).getOrThrow().boolean,
        "executing mutation timeout becomes Unknown and requires reconciliation")

    let readPlan = NormalizedOperationPlan(
        "read", objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "read-digest"
    )
    let timedOutRead = terminal(resolveOperationAttempt(
        OperationId("read-operation"), CanonicalToolCallId("read-call"),
        readPlan, OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Err(timeout), "read-receipt", 11
    ))
    expect(timedOutRead.receipt.outcome == OperationOutcome.TimedOut &&
        timedOutRead.retryDecision == OperationRetryDecision.Retry &&
        timedOutRead.error.getOrThrow().kind == AgentErrorKind.Timeout &&
        timedOutRead.toolResult.getOrThrow().isError,
        "read-only timeout remains a known retryable timeout")

    let completed = terminal(resolveOperationAttempt(
        OperationId("completed-operation"), CanonicalToolCallId("call"),
        writePlan, OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(
            "call", objectValue([ValueField("exit", integerValue(1))]), isError: true
        ))),
        "completed-receipt", 12
    ))
    expect(completed.receipt.outcome == OperationOutcome.Failed &&
        completed.toolResult.getOrThrow().receiptId == "completed-receipt" &&
        completed.toolResult.getOrThrow().isError,
        "known executor failure is Failed rather than an unknown external effect")

    let invalid = terminal(resolveOperationAttempt(
        OperationId("invalid-operation"), CanonicalToolCallId("invalid-call"),
        readPlan, OperationAttemptStage.Prepared,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(
            "invalid-call", objectValue([]), isError: true
        ))),
        "invalid-receipt", 12
    ))
    expect(invalid.receipt.outcome == OperationOutcome.Rejected,
        "known pre-execution validation failure is a rejection")

    let denial = AgentError(
        AgentErrorKind.PermissionDenied, "policy.denied", "denied"
    )
    let rejected = terminal(resolveOperationAttempt(
        OperationId("rejected-operation"), CanonicalToolCallId("call"),
        writePlan, OperationAttemptStage.Prepared,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Denied(ToolDenial("call", "write", denial))),
        "rejected-receipt", 13
    ))
    expect(rejected.receipt.outcome == OperationOutcome.Rejected &&
        rejected.toolResult.getOrThrow().isError,
        "policy rejection becomes a receipted rejected ToolResult without executing")
}

func terminal(resolution: OperationResolution): OperationTerminalResolution {
    match (resolution) {
        case OperationResolution.Terminal(value) => value
        case OperationResolution.WaitingApproval(_) =>
            throw IllegalStateException("expected terminal operation resolution")
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
