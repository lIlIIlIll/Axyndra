package agent_domain

import yjson.*
import yjson_support.*
import std.deriving.*

@Derive[Equatable]
public enum OperationEffectClass {
    ReadOnly | WorkspaceMutation | ExternalMutation
}

@Derive[Equatable]
public enum OperationRetryDisposition {
    Safe | ByIdempotencyKey | VerifyThenRetry | Never
}

public class RecoveryProbeId {
    public let value: String
    public init(value: String) { this.value = operationEffectId("recovery probe", value) }
}

public class CompensationPlanId {
    public let value: String
    public init(value: String) { this.value = operationEffectId("compensation plan", value) }
}

public enum ReplayDisposition {
    Pure
    | SafeReplay
    | Idempotent(String)
    | RecoverByProbe(RecoveryProbeId)
    | Compensatable(CompensationPlanId)
    | AtMostOnce
    | NeverReplay
}

public class ToolImplementationIdentity {
    public let toolId: String
    public let toolVersion: String
    public let implementationFingerprint: String
    public let schemaDigest: String
    public let effectiveArgumentsDigest: String
    public let replayContractVersion: UInt32

    public init(
        toolId: String,
        toolVersion: String,
        implementationFingerprint: String,
        schemaDigest: String,
        effectiveArgumentsDigest: String,
        replayContractVersion!: UInt32 = 1u32
    ) {
        if (toolId.trimAscii() == "" || toolVersion.trimAscii() == "" ||
            implementationFingerprint.trimAscii() == "" || schemaDigest.trimAscii() == "" ||
            effectiveArgumentsDigest.trimAscii() == "" || replayContractVersion == 0u32) {
            throw IllegalArgumentException("tool implementation identity is incomplete")
        }
        this.toolId = toolId.trimAscii()
        this.toolVersion = toolVersion.trimAscii()
        this.implementationFingerprint = implementationFingerprint.trimAscii()
        this.schemaDigest = schemaDigest.trimAscii()
        this.effectiveArgumentsDigest = effectiveArgumentsDigest.trimAscii()
        this.replayContractVersion = replayContractVersion
    }
}

public enum ReplayRecoveryAction {
    Recompute | Replay | ReplayWithIdempotencyKey(String) | Probe(RecoveryProbeId)
    | Compensate(CompensationPlanId) | Interrupt | RequireRecovery
}

public func replayRecoveryAction(
    disposition: ReplayDisposition,
    frozen: ToolImplementationIdentity,
    current: ToolImplementationIdentity
): ReplayRecoveryAction {
    let sameImplementation = frozen.toolId == current.toolId &&
        frozen.toolVersion == current.toolVersion &&
        frozen.implementationFingerprint == current.implementationFingerprint &&
        frozen.schemaDigest == current.schemaDigest &&
        frozen.replayContractVersion == current.replayContractVersion
    match (disposition) {
        case ReplayDisposition.Pure => ReplayRecoveryAction.Recompute
        case ReplayDisposition.SafeReplay => if (sameImplementation) {
            ReplayRecoveryAction.Replay
        } else { ReplayRecoveryAction.RequireRecovery }
        case ReplayDisposition.Idempotent(key) => if (sameImplementation) {
            ReplayRecoveryAction.ReplayWithIdempotencyKey(key)
        } else { ReplayRecoveryAction.RequireRecovery }
        case ReplayDisposition.RecoverByProbe(probe) => ReplayRecoveryAction.Probe(probe)
        case ReplayDisposition.Compensatable(plan) => ReplayRecoveryAction.Compensate(plan)
        case ReplayDisposition.AtMostOnce => ReplayRecoveryAction.Interrupt
        case ReplayDisposition.NeverReplay => ReplayRecoveryAction.RequireRecovery
    }
}

@Derive[Equatable]
public enum OperationOutcome {
    Completed | Rejected | Cancelled | TimedOut | Failed | Unknown
}

@Derive[Equatable]
public enum OperationAttemptStage {
    Prepared | Executing
}

public class OperationTerminalResolution {
    public let receipt: VNextOperationReceipt
    public let toolResult: ?ToolResult
    public let error: ?AgentError
    public let retryDecision: OperationRetryDecision

    public init(
        receipt: VNextOperationReceipt,
        retryDecision: OperationRetryDecision,
        toolResult!: ?ToolResult = None,
        error!: ?AgentError = None
    ) {
        if (toolResult.isNone() && error.isNone()) {
            throw IllegalArgumentException(
                "terminal operation resolution requires a ToolResult or stopping error"
            )
        }
        this.receipt = receipt
        this.toolResult = toolResult
        this.error = error
        this.retryDecision = retryDecision
    }
}

public enum OperationResolution {
    WaitingApproval(ApprovalRequest) | Terminal(OperationTerminalResolution)
}

public class NormalizedOperationPlan {
    public let toolName: String
    public let canonicalArguments: AgentValue
    public let resolvedPaths: Array<String>
    public let resolvedHosts: Array<String>
    public let cwd: String
    public let relevantEnvironment: Array<ValueField>
    public let requiredCapabilities: Array<Capability>
    public let effectClass: OperationEffectClass
    public let retryDisposition: OperationRetryDisposition
    public let idempotencyKey: String
    public let bindingDigest: String
    public let replayDisposition: ReplayDisposition
    public let implementation: ToolImplementationIdentity

    public init(
        toolName: String,
        canonicalArguments: AgentValue,
        requiredCapabilities: Array<Capability>,
        effectClass: OperationEffectClass,
        retryDisposition: OperationRetryDisposition,
        bindingDigest: String,
        resolvedPaths!: Array<String> = [],
        resolvedHosts!: Array<String> = [],
        cwd!: String = "",
        relevantEnvironment!: Array<ValueField> = [],
        idempotencyKey!: String = "",
        replayDisposition!: ?ReplayDisposition = None,
        toolVersion!: String = "legacy-v1",
        implementationFingerprint!: String = "",
        schemaDigest!: String = "",
        effectiveArgumentsDigest!: String = "",
        replayContractVersion!: UInt32 = 1u32
    ) {
        if (toolName.trimAscii() == "" || bindingDigest.trimAscii() == "" ||
            canonicalArguments.unifiedKind != ValueKind.Object ||
            (requiredCapabilities.isEmpty() &&
                (effectClass != OperationEffectClass.ReadOnly ||
                retryDisposition != OperationRetryDisposition.Never))) {
            throw IllegalArgumentException("normalized operation plan is incomplete")
        }
        if (retryDisposition == OperationRetryDisposition.ByIdempotencyKey &&
            idempotencyKey.trimAscii() == "") {
            throw IllegalArgumentException(
                "idempotency-key retry requires a stable idempotency key"
            )
        }
        this.toolName = toolName.trimAscii()
        this.canonicalArguments = canonicalArguments
        this.resolvedPaths = resolvedPaths
        this.resolvedHosts = resolvedHosts
        this.cwd = cwd
        this.relevantEnvironment = relevantEnvironment
        this.requiredCapabilities = requiredCapabilities
        this.effectClass = effectClass
        this.retryDisposition = retryDisposition
        this.idempotencyKey = idempotencyKey.trimAscii()
        this.bindingDigest = bindingDigest.trimAscii()
        let resolvedReplay = match (replayDisposition) {
            case Some(value) => value
            case None => legacyReplayDisposition(retryDisposition, idempotencyKey, bindingDigest)
        }
        requireReplayDisposition(resolvedReplay)
        this.replayDisposition = resolvedReplay
        this.implementation = ToolImplementationIdentity(
            this.toolName,
            toolVersion,
            if (implementationFingerprint.trimAscii() == "") {
                bindingDigest
            } else { implementationFingerprint },
            if (schemaDigest.trimAscii() == "") { bindingDigest } else { schemaDigest },
            if (effectiveArgumentsDigest.trimAscii() == "") {
                bindingDigest
            } else { effectiveArgumentsDigest },
            replayContractVersion: replayContractVersion
        )
    }
}

func legacyReplayDisposition(
    retry: OperationRetryDisposition,
    idempotencyKey: String,
    bindingDigest: String
): ReplayDisposition {
    match (retry) {
        case OperationRetryDisposition.Safe => ReplayDisposition.SafeReplay
        case OperationRetryDisposition.ByIdempotencyKey => ReplayDisposition.Idempotent(idempotencyKey)
        case OperationRetryDisposition.VerifyThenRetry => ReplayDisposition.RecoverByProbe(
            RecoveryProbeId("legacy-probe-" + bindingDigest)
        )
        case OperationRetryDisposition.Never => ReplayDisposition.NeverReplay
    }
}

func requireReplayDisposition(value: ReplayDisposition): Unit {
    match (value) {
        case ReplayDisposition.Idempotent(key) => if (key.trimAscii() == "") {
            throw IllegalArgumentException("idempotent replay requires a frozen key")
        }
        case _ => ()
    }
}

func operationEffectId(kind: String, value: String): String {
    if (value.trimAscii() == "") {
        throw IllegalArgumentException(kind + " id must not be empty")
    }
    value.trimAscii()
}

public class VNextOperationReceipt {
    public let receiptId: String
    public let operationId: OperationId
    public let outcome: OperationOutcome
    public let detail: AgentValue
    public let verification: AgentValue
    public let observedAtMillis: Int64

    public init(
        receiptId: String,
        operationId: OperationId,
        outcome: OperationOutcome,
        detail: AgentValue,
        verification: AgentValue,
        observedAtMillis: Int64
    ) {
        if (receiptId.trimAscii() == "" || observedAtMillis < 0) {
            throw IllegalArgumentException("operation receipt identity is invalid")
        }
        this.receiptId = receiptId.trimAscii()
        this.operationId = operationId
        this.outcome = outcome
        this.detail = detail
        this.verification = verification
        this.observedAtMillis = observedAtMillis
    }
}

@Derive[Equatable]
public enum OperationRetryDecision {
    Retry | VerifyFirst | Stop
}

public func operationRetryDecision(
    outcome: OperationOutcome,
    disposition: OperationRetryDisposition,
    verificationProvedNoEffect!: Bool = false
): OperationRetryDecision {
    if (outcome == OperationOutcome.Completed ||
        outcome == OperationOutcome.Rejected ||
        outcome == OperationOutcome.Cancelled) {
        return OperationRetryDecision.Stop
    }
    match (disposition) {
        case OperationRetryDisposition.Never => OperationRetryDecision.Stop
        case OperationRetryDisposition.Safe => OperationRetryDecision.Retry
        case OperationRetryDisposition.ByIdempotencyKey => OperationRetryDecision.Retry
        case OperationRetryDisposition.VerifyThenRetry =>
            if (verificationProvedNoEffect) {
                OperationRetryDecision.Retry
            } else {
                OperationRetryDecision.VerifyFirst
            }
    }
}

public func operationOutcomeName(outcome: OperationOutcome): String {
    match (outcome) {
        case OperationOutcome.Completed => "completed"
        case OperationOutcome.Rejected => "rejected"
        case OperationOutcome.Cancelled => "cancelled"
        case OperationOutcome.TimedOut => "timed_out"
        case OperationOutcome.Failed => "failed"
        case OperationOutcome.Unknown => "unknown"
    }
}

// Resolves the pre-terminal ToolPipeline result into the canonical operation model.
// Once execution of a mutating operation has begun, transport/cancel/timeout
// failures are evidence of an Unknown outcome, never evidence of no effect.
public func resolveOperationAttempt(
    operationId: OperationId,
    callId: CanonicalToolCallId,
    plan: NormalizedOperationPlan,
    stage: OperationAttemptStage,
    attempt: Result<ToolInvocationResult>,
    receiptId: String,
    observedAtMillis: Int64
): OperationResolution {
    match (attempt) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) =>
            OperationResolution.WaitingApproval(approval)
        case Result.Ok(ToolInvocationResult.Completed(result)) =>
            let outcome = if (!result.isError) {
                OperationOutcome.Completed
            } else if (stage == OperationAttemptStage.Prepared) {
                // Validation, lookup and policy failures happen before the
                // executor owns the operation. They are explicit rejections,
                // not evidence that an external action completed or failed.
                OperationOutcome.Rejected
            } else {
                OperationOutcome.Failed
            }
            terminalToolResolution(
                operationId, plan, receiptId, observedAtMillis,
                outcome,
                ToolResult(
                    result.callId, result.output,
                    isError: result.isError, receiptId: receiptId
                ),
                objectValue([
                    ValueField("known_completion", boolValue(true)),
                    ValueField("stage", textValue(match (stage) {
                        case OperationAttemptStage.Prepared => "prepared"
                        case OperationAttemptStage.Executing => "executing"
                    }))
                ])
            )
        case Result.Ok(ToolInvocationResult.Denied(denial)) =>
            terminalToolResolution(
                operationId, plan, receiptId, observedAtMillis,
                OperationOutcome.Rejected,
                ToolResult(
                    denial.callId,
                    operationErrorValue(denial.reason),
                    isError: true,
                    receiptId: receiptId
                ),
                objectValue([ValueField("policy_rejected", boolValue(true))])
            )
        case Result.Err(error) =>
            let outcome = operationFailureOutcome(plan.effectClass, stage, error)
            let stopping = if (outcome == OperationOutcome.Unknown) {
                AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "operation.outcome_unknown",
                    "external effect may have occurred; explicit reconciliation is required",
                    fields: [
                        ErrorField("operation_id", operationId.value),
                        ErrorField("cause", error.code)
                    ]
                )
            } else {
                error
            }
            let receipt = VNextOperationReceipt(
                receiptId,
                operationId,
                outcome,
                operationErrorValue(error),
                objectValue([
                    ValueField("stage", textValue(match (stage) {
                        case OperationAttemptStage.Prepared => "prepared"
                        case OperationAttemptStage.Executing => "executing"
                    })),
                    ValueField("effect", textValue(operationEffectName(plan.effectClass)))
                ]),
                observedAtMillis
            )
            OperationResolution.Terminal(OperationTerminalResolution(
                receipt,
                operationRetryDecision(outcome, plan.retryDisposition),
                toolResult: Some(ToolResult(
                    callId.value,
                    objectValue([
                        ValueField("outcome", textValue(operationOutcomeName(outcome))),
                        ValueField("error", operationErrorValue(stopping)),
                        ValueField("reconciliation_required", boolValue(
                            outcome == OperationOutcome.Unknown
                        ))
                    ]),
                    isError: true,
                    receiptId: receiptId
                )),
                error: Some(stopping)
            ))
    }
}

func terminalToolResolution(
    operationId: OperationId,
    plan: NormalizedOperationPlan,
    receiptId: String,
    observedAtMillis: Int64,
    outcome: OperationOutcome,
    result: ToolResult,
    verification: AgentValue
): OperationResolution {
    OperationResolution.Terminal(OperationTerminalResolution(
        VNextOperationReceipt(
            receiptId, operationId, outcome, result.output, verification, observedAtMillis
        ),
        operationRetryDecision(outcome, plan.retryDisposition),
        toolResult: Some(result)
    ))
}

func operationFailureOutcome(
    effect: OperationEffectClass,
    stage: OperationAttemptStage,
    error: AgentError
): OperationOutcome {
    if (error.kind == AgentErrorKind.RecoveryRequired) {
        return OperationOutcome.Unknown
    }
    if (stage == OperationAttemptStage.Executing && effect != OperationEffectClass.ReadOnly) {
        return OperationOutcome.Unknown
    }
    match (error.kind) {
        case AgentErrorKind.Cancelled => OperationOutcome.Cancelled
        case AgentErrorKind.Timeout => OperationOutcome.TimedOut
        case AgentErrorKind.PermissionDenied => OperationOutcome.Rejected
        case _ => OperationOutcome.Failed
    }
}

func operationErrorValue(error: AgentError): AgentValue {
    objectValue([
        ValueField("code", textValue(error.code)),
        ValueField("message", textValue(error.message)),
        ValueField("retryable", boolValue(error.retryable))
    ])
}

func operationEffectName(effect: OperationEffectClass): String {
    match (effect) {
        case OperationEffectClass.ReadOnly => "read_only"
        case OperationEffectClass.WorkspaceMutation => "workspace_mutation"
        case OperationEffectClass.ExternalMutation => "external_mutation"
    }
}
