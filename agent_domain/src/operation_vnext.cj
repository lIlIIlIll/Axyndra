package agent_domain

import json4cj.*
import std.deriving.*

@Derive[Equatable]
public enum OperationEffectClass {
    ReadOnly | WorkspaceMutation | ExternalMutation
}

@Derive[Equatable]
public enum OperationRetryDisposition {
    Safe | ByIdempotencyKey | VerifyThenRetry | Never
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
        idempotencyKey!: String = ""
    ) {
        if (toolName.trimAscii() == "" || bindingDigest.trimAscii() == "" ||
            canonicalArguments.kind != ValueKind.Object ||
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
    }
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
