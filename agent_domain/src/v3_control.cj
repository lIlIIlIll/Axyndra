package agent_domain

import std.collection.*
import std.deriving.*
import std.sync.*
import std.time.*
import process4cj as process

// Strong identifiers keep correlation keys from being accidentally exchanged
// across provider, runtime, tool, and persistence boundaries.
public class TraceId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("trace", value)
    }
}

public class TurnId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("turn", value)
    }
}

public class RequestId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("request", value)
    }
}

public class ToolBatchId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("tool batch", value)
    }
}

public class ToolCallId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("tool call", value)
    }
}

func validatedIdentifier(kind: String, value: String): String {
    let normalized = value.trimAscii()
    if (normalized == "") {
        throw IllegalArgumentException(kind + " id must not be empty")
    }
    normalized
}

@Derive[Equatable]
public enum RunState {
    Created
    | Running
    | WaitingApproval
    | WaitingExternal
    | Cancelling
    | Cancelled
    | Completed
    | Failed
    | RecoveryRequired
}

public func runStateName(state: RunState): String {
    match (state) {
        case RunState.Created => "created"
        case RunState.Running => "running"
        case RunState.WaitingApproval => "waiting_approval"
        case RunState.WaitingExternal => "waiting_external"
        case RunState.Cancelling => "cancelling"
        case RunState.Cancelled => "cancelled"
        case RunState.Completed => "completed"
        case RunState.Failed => "failed"
        case RunState.RecoveryRequired => "recovery_required"
    }
}

public func isTerminalRunState(state: RunState): Bool {
    match (state) {
        case RunState.Cancelled | RunState.Completed |
             RunState.Failed | RunState.RecoveryRequired => true
        case _ => false
    }
}

public func runStateFromName(value: String): RunState {
    match (value) {
        case "created" => RunState.Created
        case "running" => RunState.Running
        case "waiting_approval" => RunState.WaitingApproval
        case "waiting_external" => RunState.WaitingExternal
        case "cancelling" => RunState.Cancelling
        case "cancelled" => RunState.Cancelled
        case "completed" => RunState.Completed
        case "failed" => RunState.Failed
        case "recovery_required" => RunState.RecoveryRequired
        case _ => throw IllegalStateException("unknown durable Run state: " + value)
    }
}

public class EventMeta {
    public let sequence: Int64
    public let occurredAtMillis: Int64
    public let traceId: TraceId
    public let runId: RunId
    public let turnId: ?TurnId
    public let requestId: ?RequestId
    public let semanticRequestId: ?SemanticModelRequestId
    public let attemptId: ?ModelAttemptId
    public let toolBatchId: ?ToolBatchId
    public let toolCallId: ?ToolCallId
    public let operationId: ?OperationId

    public init(
        sequence: Int64,
        traceId: TraceId,
        runId: RunId,
        occurredAtMillis!: Int64 = 0,
        turnId!: ?TurnId = None,
        requestId!: ?RequestId = None,
        semanticRequestId!: ?SemanticModelRequestId = None,
        attemptId!: ?ModelAttemptId = None,
        toolBatchId!: ?ToolBatchId = None,
        toolCallId!: ?ToolCallId = None,
        operationId!: ?OperationId = None
    ) {
        if (sequence < 1) {
            throw IllegalArgumentException("event sequence must be positive")
        }
        if (occurredAtMillis < 0) {
            throw IllegalArgumentException("event timestamp must not be negative")
        }
        this.sequence = sequence
        this.occurredAtMillis = occurredAtMillis
        this.traceId = traceId
        this.runId = runId
        this.turnId = turnId
        this.requestId = requestId
        this.semanticRequestId = semanticRequestId
        this.attemptId = attemptId
        this.toolBatchId = toolBatchId
        this.toolCallId = toolCallId
        this.operationId = operationId
    }
}

@Derive[Equatable]
public enum ToolOutputChannel {
    Stdout | Stderr | Artifact | Summary
}

@Derive[Equatable]
public enum ModelRequestOutcome {
    Succeeded | Failed | Cancelled
}

// One record is emitted for every provider wire attempt, including retries
// and auxiliary model calls. Successful attempts carry their final usage;
// failed/cancelled attempts intentionally do not invent usage or cost.
public class ModelRequestAttempt {
    public let requestId: RequestId
    public let model: String
    public let attempt: Int64
    public let outcome: ModelRequestOutcome
    public let usage: ?ModelUsage
    public let errorCode: String

    public init(
        requestId: RequestId,
        model: String,
        attempt: Int64,
        outcome: ModelRequestOutcome,
        usage!: ?ModelUsage = None,
        errorCode!: String = ""
    ) {
        if (model.trimAscii() == "" || attempt < 1) {
            throw IllegalArgumentException(
                "model request attempt requires a model and positive attempt"
            )
        }
        match (outcome) {
            case ModelRequestOutcome.Succeeded =>
                if (usage.isNone() || errorCode != "") {
                    throw IllegalArgumentException(
                        "successful model request attempt requires usage and no error"
                    )
                }
            case ModelRequestOutcome.Failed | ModelRequestOutcome.Cancelled =>
                if (usage.isSome() || errorCode.trimAscii() == "") {
                    throw IllegalArgumentException(
                        "unsuccessful model request attempt requires an error and no usage"
                    )
                }
        }
        this.requestId = requestId
        this.model = model
        this.attempt = attempt
        this.outcome = outcome
        this.usage = usage
        this.errorCode = errorCode
    }
}

// AgentEventPayload is the provider/UI/persistence-neutral event vocabulary.
// Extension is an explicit escape hatch for independently versioned features;
// core lifecycle state never needs to fall back to an untyped payload.
public enum AgentEventPayload {
    RunStarted
    | RunStateChanged(RunState, RunState, String)
    | AssistantStarted(RequestId)
    | TextDelta(String)
    | ReasoningDelta(String)
    | ModelUsageUpdated(ModelUsage)
    | ModelRequestAttemptCompleted(ModelRequestAttempt)
    | ToolStarted(ToolCallId, String, Int64)
    | ToolOutput(ToolCallId, ToolOutputChannel, String)
    | ToolCompleted(ToolCallId, Bool, Int64)
    | ApprovalRequested(OperationId, ToolCallId)
    | BudgetUpdated(ExecutionUsage)
    | ContextCompacted(Int64, Int64)
    | Diagnostic(AgentError)
    | Audit(String, AgentValue)
    | Transcript(AgentValue)
    | StructuredOutputCompleted(AgentValue)
    | TurnCompleted(TurnId)
    | RunCompleted
    | Extension(AgentEventKind, AgentValue)
}

public func eventKind(payload: AgentEventPayload): AgentEventKind {
    match (payload) {
        case AgentEventPayload.RunStarted => AgentEventKind.RunStarted
        case AgentEventPayload.RunStateChanged(_, _, _) => AgentEventKind.RunStateChanged
        case AgentEventPayload.AssistantStarted(_) |
             AgentEventPayload.TextDelta(_) |
             AgentEventPayload.ReasoningDelta(_) |
             AgentEventPayload.ModelUsageUpdated(_) |
             AgentEventPayload.ModelRequestAttemptCompleted(_) => AgentEventKind.Model
        case AgentEventPayload.ToolStarted(_, _, _) |
             AgentEventPayload.ToolOutput(_, _, _) |
             AgentEventPayload.ToolCompleted(_, _, _) => AgentEventKind.Tool
        case AgentEventPayload.ApprovalRequested(_, _) => AgentEventKind.Approval
        case AgentEventPayload.BudgetUpdated(_) => AgentEventKind.Budget
        case AgentEventPayload.ContextCompacted(_, _) |
             AgentEventPayload.Diagnostic(_) => AgentEventKind.Diagnostic
        case AgentEventPayload.Audit(_, _) => AgentEventKind.Audit
        case AgentEventPayload.Transcript(_) |
             AgentEventPayload.TurnCompleted(_) => AgentEventKind.Transcript
        case AgentEventPayload.StructuredOutputCompleted(_) => AgentEventKind.Model
        case AgentEventPayload.RunCompleted => AgentEventKind.Completed
        case AgentEventPayload.Extension(kind, _) => kind
    }
}

public func eventDetail(payload: AgentEventPayload): AgentValue {
    let detail = match (payload) {
        case AgentEventPayload.RunStarted => objectValue([])
        case AgentEventPayload.RunStateChanged(from, to, reason) => objectValue([
            ValueField("from", textValue(runStateName(from))),
            ValueField("to", textValue(runStateName(to))),
            ValueField("reason", textValue(reason))
        ])
        case AgentEventPayload.AssistantStarted(requestId) => objectValue([
            ValueField("request_id", textValue(requestId.value))
        ])
        case AgentEventPayload.TextDelta(delta) => objectValue([
            ValueField("text", textValue(delta))
        ])
        case AgentEventPayload.ReasoningDelta(delta) => objectValue([
            ValueField("reasoning", textValue(delta))
        ])
        case AgentEventPayload.ModelUsageUpdated(usage) => usageValue(usage)
        case AgentEventPayload.ModelRequestAttemptCompleted(attempt) => objectValue([
            ValueField("request_id", textValue(attempt.requestId.value)),
            ValueField("model", textValue(attempt.model)),
            ValueField("attempt", integerValue(attempt.attempt)),
            ValueField(
                "outcome",
                textValue(modelRequestOutcomeName(attempt.outcome))
            ),
            ValueField("usage", match (attempt.usage) {
                case Some(value) => usageValue(value)
                case None => nullValue()
            }),
            ValueField("error_code", textValue(attempt.errorCode))
        ])
        case AgentEventPayload.ToolStarted(callId, name, callIndex) => objectValue([
            ValueField("call_id", textValue(callId.value)),
            ValueField("name", textValue(name)),
            ValueField("call_index", integerValue(callIndex))
        ])
        case AgentEventPayload.ToolOutput(callId, channel, delta) => objectValue([
            ValueField("call_id", textValue(callId.value)),
            ValueField("channel", textValue(toolOutputChannelName(channel))),
            ValueField("delta", textValue(delta))
        ])
        case AgentEventPayload.ToolCompleted(callId, succeeded, callIndex) => objectValue([
            ValueField("call_id", textValue(callId.value)),
            ValueField("succeeded", boolValue(succeeded)),
            ValueField("call_index", integerValue(callIndex))
        ])
        case AgentEventPayload.ApprovalRequested(operationId, callId) => objectValue([
            ValueField("operation_id", textValue(operationId.value)),
            ValueField("call_id", textValue(callId.value))
        ])
        case AgentEventPayload.BudgetUpdated(usage) => executionUsageValue(usage)
        case AgentEventPayload.ContextCompacted(beforeTokens, afterTokens) => objectValue([
            ValueField("before_tokens", integerValue(beforeTokens)),
            ValueField("after_tokens", integerValue(afterTokens))
        ])
        case AgentEventPayload.Diagnostic(error) => eventErrorValue(error)
        case AgentEventPayload.Audit(action, detail) => objectValue([
            ValueField("action", textValue(action)),
            ValueField("detail", detail)
        ])
        case AgentEventPayload.Transcript(detail) => detail
        case AgentEventPayload.StructuredOutputCompleted(value) => objectValue([
            ValueField("value", value)
        ])
        case AgentEventPayload.TurnCompleted(turnId) => objectValue([
            ValueField("turn_id", textValue(turnId.value))
        ])
        case AgentEventPayload.RunCompleted => objectValue([])
        case AgentEventPayload.Extension(_, detail) => detail
    }
    match (typedEventCode(payload)) {
        case Some(code) =>
            // Diagnostic and independently versioned semantic payloads may
            // already expose a more specific code. JSON objects are canonical
            // and cannot contain duplicate keys, so preserve that code.
            for (field in detail.fields where field.name == "code") {
                return detail
            }
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("code", textValue(code)))
            fields.add(all: detail.fields)
            objectValue(fields.toArray())
        case None => detail
    }
}

// `code` is part of the stable App Protocol envelope, not provider state.
// Keeping it here gives JSON, ACP, SDK and TUI projections one vocabulary.
// Extension producers already version and encode their own code.
func typedEventCode(payload: AgentEventPayload): ?String {
    match (payload) {
        case AgentEventPayload.RunStarted => Some("run.started")
        case AgentEventPayload.RunStateChanged(_, _, _) => Some("run.state_changed")
        case AgentEventPayload.AssistantStarted(_) => Some("model.started")
        case AgentEventPayload.TextDelta(_) => Some("model.text_delta")
        case AgentEventPayload.ReasoningDelta(_) => Some("model.reasoning_delta")
        case AgentEventPayload.ModelUsageUpdated(_) => Some("model.usage")
        case AgentEventPayload.ModelRequestAttemptCompleted(_) =>
            Some("model.request_attempt_completed")
        case AgentEventPayload.ToolStarted(_, _, _) => Some("tool.execution_started")
        case AgentEventPayload.ToolOutput(_, _, _) => Some("tool.output_delta")
        case AgentEventPayload.ToolCompleted(_, _, _) => Some("tool.execution_completed")
        case AgentEventPayload.ApprovalRequested(_, _) => Some("approval.requested")
        case AgentEventPayload.BudgetUpdated(_) => Some("budget.updated")
        case AgentEventPayload.ContextCompacted(_, _) => Some("context.compacted")
        case AgentEventPayload.Diagnostic(_) => Some("diagnostic")
        case AgentEventPayload.Audit(_, _) => Some("audit")
        case AgentEventPayload.Transcript(_) => Some("transcript.item")
        case AgentEventPayload.StructuredOutputCompleted(_) =>
            Some("model.structured_output_completed")
        case AgentEventPayload.TurnCompleted(_) => Some("turn.completed")
        case AgentEventPayload.RunCompleted => Some("run.completed")
        case AgentEventPayload.Extension(_, _) => None
    }
}

// Project a typed event into the stable command/event protocol vocabulary.
// Typed domain payloads deliberately do not carry transport field names, but
// every external event consumer still needs the same non-empty `code`.
public func eventProtocolDetail(event: AgentEvent): AgentValue {
    for (field in event.detail.fields where field.name == "code") {
        return event.detail
    }
    let code = match (event.payload) {
        case AgentEventPayload.RunStarted => "run.started"
        case AgentEventPayload.RunStateChanged(_, _, _) => "run.state_changed"
        case AgentEventPayload.AssistantStarted(_) => "model.started"
        case AgentEventPayload.TextDelta(_) => "model.text_delta"
        case AgentEventPayload.ReasoningDelta(_) => "model.reasoning_delta"
        case AgentEventPayload.ModelUsageUpdated(_) => "model.usage"
        case AgentEventPayload.ModelRequestAttemptCompleted(_) =>
            "model.request_attempt_completed"
        case AgentEventPayload.ToolStarted(_, _, _) => "tool.execution_started"
        case AgentEventPayload.ToolOutput(_, _, _) => "tool.output_delta"
        case AgentEventPayload.ToolCompleted(_, _, _) => "tool.execution_completed"
        case AgentEventPayload.ApprovalRequested(_, _) => "approval.requested"
        case AgentEventPayload.BudgetUpdated(_) => "budget.updated"
        case AgentEventPayload.ContextCompacted(_, _) => "context.compacted"
        case AgentEventPayload.Diagnostic(_) => "diagnostic"
        case AgentEventPayload.Audit(_, _) => "audit"
        case AgentEventPayload.Transcript(_) => "transcript.item"
        case AgentEventPayload.StructuredOutputCompleted(_) =>
            "model.structured_output_completed"
        case AgentEventPayload.TurnCompleted(_) => "turn.completed"
        case AgentEventPayload.RunCompleted => "run.completed"
        case AgentEventPayload.Extension(_, _) => return event.detail
    }
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("code", textValue(code)))
    fields.add(all: event.detail.fields)
    objectValue(fields.toArray())
}

func usageValue(usage: ModelUsage): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("input_tokens", integerValue(usage.inputTokens)))
    fields.add(ValueField("output_tokens", integerValue(usage.outputTokens)))
    fields.add(ValueField("reasoning_tokens", integerValue(usage.reasoningTokens)))
    fields.add(ValueField("cache_read_tokens", integerValue(usage.cacheReadTokens)))
    fields.add(ValueField("cache_write_tokens", integerValue(usage.cacheWriteTokens)))
    fields.add(ValueField("cost_micros", match (usage.costMicros) {
        case Some(value) => integerValue(value)
        case None => nullValue()
    }))
    fields.add(ValueField("source", textValue(modelUsageSourceName(usage.source))))
    fields.add(ValueField("evidence", match (usage.evidence) {
        case Some(value) => objectValue([
            ValueField("protocol", textValue(value.protocol)),
            ValueField("event_kind", textValue(value.eventKind)),
            ValueField("provider_response_id", textValue(value.providerResponseId))
        ])
        case None => nullValue()
    }))
    objectValue(fields.toArray())
}

public func modelRequestOutcomeName(outcome: ModelRequestOutcome): String {
    match (outcome) {
        case ModelRequestOutcome.Succeeded => "succeeded"
        case ModelRequestOutcome.Failed => "failed"
        case ModelRequestOutcome.Cancelled => "cancelled"
    }
}

func eventErrorValue(error: AgentError): AgentValue {
    let fields = ArrayList<AgentValue>()
    for (field in error.fields) {
        fields.add(objectValue([
            ValueField("name", textValue(field.name)),
            ValueField("value", textValue(field.value))
        ]))
    }
    objectValue([
        ValueField("kind", textValue(eventErrorKindName(error.kind))),
        ValueField("code", textValue(error.code)),
        ValueField("message", textValue(error.message)),
        ValueField("retryable", boolValue(error.retryable)),
        ValueField("fallback_allowed", boolValue(error.fallbackAllowed)),
        ValueField("fields", listValue(fields.toArray()))
    ])
}

func eventErrorKindName(kind: AgentErrorKind): String {
    match (kind) {
        case AgentErrorKind.Configuration => "configuration"
        case AgentErrorKind.Authentication => "authentication"
        case AgentErrorKind.PermissionDenied => "permission_denied"
        case AgentErrorKind.InvalidInput => "invalid_input"
        case AgentErrorKind.RateLimited => "rate_limited"
        case AgentErrorKind.Timeout => "timeout"
        case AgentErrorKind.Transport => "transport"
        case AgentErrorKind.Provider => "provider"
        case AgentErrorKind.Protocol => "protocol"
        case AgentErrorKind.Cancelled => "cancelled"
        case AgentErrorKind.BudgetExceeded => "budget_exceeded"
        case AgentErrorKind.Conflict => "conflict"
        case AgentErrorKind.RecoveryRequired => "recovery_required"
        case AgentErrorKind.Internal => "internal"
    }
}

func executionUsageValue(usage: ExecutionUsage): AgentValue {
    objectValue([
        ValueField("turns", integerValue(usage.turns)),
        ValueField("tool_calls", integerValue(usage.toolCalls)),
        ValueField("active_tools", integerValue(usage.activeTools)),
        ValueField("input_tokens", integerValue(usage.inputTokens)),
        ValueField("output_tokens", integerValue(usage.outputTokens)),
        ValueField("cost_micros", integerValue(usage.costMicros))
    ])
}

func toolOutputChannelName(channel: ToolOutputChannel): String {
    match (channel) {
        case ToolOutputChannel.Stdout => "stdout"
        case ToolOutputChannel.Stderr => "stderr"
        case ToolOutputChannel.Artifact => "artifact"
        case ToolOutputChannel.Summary => "summary"
    }
}

@Derive[Equatable]
public enum CancellationReasonKind {
    User | Deadline | Budget | Parent | Shutdown | Failure
}

public class CancellationReason {
    public let kind: CancellationReasonKind
    public let code: String
    public let message: String
    public let cancelledAtMillis: Int64

    public init(
        kind: CancellationReasonKind,
        code: String,
        message: String,
        cancelledAtMillis!: Int64 = 0
    ) {
        if (code.trimAscii() == "" || message.trimAscii() == "") {
            throw IllegalArgumentException("cancellation code and message must not be empty")
        }
        if (cancelledAtMillis < 0) {
            throw IllegalArgumentException("cancellation timestamp must not be negative")
        }
        this.kind = kind
        this.code = code
        this.message = message
        this.cancelledAtMillis = cancelledAtMillis
    }
}

public type CancellationCallback = (CancellationReason) -> Unit

public class CancellationRegistration {
    private let inner: process.CancellationRegistration
    init(inner: process.CancellationRegistration) { this.inner = inner }
    public func dispose(): Unit { inner.dispose() }
}

public class CancellationToken {
    private let inner: process.CancellationToken
    init(inner: process.CancellationToken) { this.inner = inner }

    public prop deadlineMillis: Int64 {
        get() { inner.deadlineMillis }
    }

    public func isCancelled(nowMillis!: Int64 = agentUtcMillis()): Bool {
        inner.isCancelled(nowMillis: nowMillis)
    }

    public func reason(nowMillis!: Int64 = agentUtcMillis()): ?CancellationReason {
        match (inner.cause(nowMillis: nowMillis)) {
            case Some(value) => Some(agentCancellationReason(value))
            case None => None
        }
    }

    public func check(nowMillis!: Int64 = agentUtcMillis()): Result<Unit> {
        match (reason(nowMillis: nowMillis)) {
            case Some(value) => Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                value.code,
                value.message,
                fields: [
                    ErrorField("reason_kind", cancellationReasonKindName(value.kind)),
                    ErrorField("cancelled_at_millis", value.cancelledAtMillis.toString())
                ]
            ))
            case None => Result.Ok(())
        }
    }

    public func onCancel(
        callback: CancellationCallback,
        nowMillis!: Int64 = agentUtcMillis()
    ): CancellationRegistration {
        CancellationRegistration(inner.onCancel(
            { cause => invokeCancellationCallback(callback, agentCancellationReason(cause)) },
            nowMillis: nowMillis
        ))
    }

    func primitive(): process.CancellationToken { inner }
}

public class CancellationSource {
    private let inner: process.CancellationSource
    public let token: CancellationToken

    public init(
        parent!: ?CancellationToken = None,
        deadlineMillis!: Int64 = 0
    ) {
        inner = process.CancellationSource(
            parent: match (parent) {
                case Some(value) => Some(value.primitive())
                case None => None
            },
            deadlineMillis: deadlineMillis
        )
        token = CancellationToken(inner.token)
    }

    public func child(deadlineMillis!: Int64 = 0): CancellationSource {
        CancellationSource(parent: Some(token), deadlineMillis: deadlineMillis)
    }

    public func cancel(reason!: ?CancellationReason = None): Bool {
        let resolved = match (reason) {
            case Some(value) => value
            case None => CancellationReason(
                CancellationReasonKind.User,
                "run.cancelled",
                "execution was cancelled",
                cancelledAtMillis: agentUtcMillis()
            )
        }
        inner.cancel(cause: Some(processCancellationCause(resolved)))
    }

    public func close(): Unit { inner.close() }
}

func invokeCancellationCallback(
    callback: CancellationCallback,
    reason: CancellationReason
): Unit {
    try {
        callback(reason)
    } catch (_: Exception) {
        // Cancellation must remain observable even when one observer fails.
    }
}

func processCancellationCause(reason: CancellationReason): process.CancellationCause {
    process.CancellationCause(
        match (reason.kind) {
            case CancellationReasonKind.User => process.CancellationKind.Explicit
            case CancellationReasonKind.Deadline => process.CancellationKind.Deadline
            case CancellationReasonKind.Budget => process.CancellationKind.Budget
            case CancellationReasonKind.Parent => process.CancellationKind.Parent
            case CancellationReasonKind.Shutdown => process.CancellationKind.Shutdown
            case CancellationReasonKind.Failure => process.CancellationKind.Failure
        },
        reason.code,
        reason.message,
        occurredAtMillis: reason.cancelledAtMillis
    )
}

func agentCancellationReason(cause: process.CancellationCause): CancellationReason {
    CancellationReason(
        match (cause.kind) {
            case process.CancellationKind.Explicit => CancellationReasonKind.User
            case process.CancellationKind.Deadline => CancellationReasonKind.Deadline
            case process.CancellationKind.Budget => CancellationReasonKind.Budget
            case process.CancellationKind.Parent => CancellationReasonKind.Parent
            case process.CancellationKind.Shutdown => CancellationReasonKind.Shutdown
            case process.CancellationKind.Failure => CancellationReasonKind.Failure
            case process.CancellationKind.TransportDisconnect => CancellationReasonKind.Failure
            case process.CancellationKind.ProcessExit => CancellationReasonKind.Failure
            case process.CancellationKind.Remote => CancellationReasonKind.Failure
        },
        if (let process.CancellationKind.Deadline <- cause.kind) {
            "run.deadline_exceeded"
        } else if (let process.CancellationKind.Parent <- cause.kind) {
            "run.parent_cancelled"
        } else {
            cause.code
        },
        cause.message,
        cancelledAtMillis: cause.occurredAtMillis
    )
}

func cancellationReasonKindName(kind: CancellationReasonKind): String {
    match (kind) {
        case CancellationReasonKind.User => "user"
        case CancellationReasonKind.Deadline => "deadline"
        case CancellationReasonKind.Budget => "budget"
        case CancellationReasonKind.Parent => "parent"
        case CancellationReasonKind.Shutdown => "shutdown"
        case CancellationReasonKind.Failure => "failure"
    }
}

public func agentUtcMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

public class ExecutionBudget {
    private let usageLock = Mutex()
    private var usedTurns: Int64 = 0
    private var usedToolCalls: Int64 = 0
    private var activeTools: Int64 = 0
    private var usedInputTokens: Int64 = 0
    private var usedOutputTokens: Int64 = 0
    private var usedCostMicros: Int64 = 0
    public let maxTurns: Int64
    public let maxToolCalls: Int64
    public let maxConcurrentTools: Int64
    public let maxInputTokens: Int64
    public let maxOutputTokens: Int64
    public let maxTotalInputTokens: Int64
    public let maxTotalOutputTokens: Int64
    // Zero means unpriced/unbounded rather than a free budget.
    public let maxCostMicros: Int64
    public let maxChildren: Int64
    public let maxDepth: Int64
    public let maxConcurrentChildren: Int64
    // Absolute UTC epoch milliseconds. Zero disables the deadline.
    public let deadlineMillis: Int64

    public init(
        maxTurns!: Int64 = 32,
        maxToolCalls!: Int64 = 64,
        maxConcurrentTools!: Int64 = 4,
        maxInputTokens!: Int64 = 100000,
        maxOutputTokens!: Int64 = 100000,
        maxTotalInputTokens!: Int64 = 0,
        maxTotalOutputTokens!: Int64 = 0,
        maxCostMicros!: Int64 = 0,
        deadlineMillis!: Int64 = 0,
        maxChildren!: Int64 = 8,
        maxDepth!: Int64 = 4,
        maxConcurrentChildren!: Int64 = 4
    ) {
        if (maxTurns < 1 || maxToolCalls < 1 || maxConcurrentTools < 1 ||
            maxInputTokens < 1 || maxOutputTokens < 1 || maxCostMicros < 0 ||
            deadlineMillis < 0 || maxChildren < 0 || maxDepth < 1 ||
            maxTotalInputTokens < 0 || maxTotalOutputTokens < 0 ||
            maxConcurrentChildren < 1) {
            throw IllegalArgumentException("execution budget values are out of range")
        }
        this.maxTurns = maxTurns
        this.maxToolCalls = maxToolCalls
        this.maxConcurrentTools = maxConcurrentTools
        this.maxInputTokens = maxInputTokens
        this.maxOutputTokens = maxOutputTokens
        this.maxTotalInputTokens = maxTotalInputTokens
        this.maxTotalOutputTokens = maxTotalOutputTokens
        this.maxCostMicros = maxCostMicros
        this.deadlineMillis = deadlineMillis
        this.maxChildren = maxChildren
        this.maxDepth = maxDepth
        this.maxConcurrentChildren = maxConcurrentChildren
    }

    public func snapshot(): ExecutionUsage {
        usageLock.lock()
        try { usage() } finally { usageLock.unlock() }
    }

    public func reserve(
        charge: BudgetCharge,
        nowMillis!: Int64 = agentUtcMillis()
    ): Result<ExecutionUsage> {
        usageLock.lock()
        try {
            if (deadlineMillis > 0 && nowMillis >= deadlineMillis) {
                return executionBudgetFailure(BudgetViolation(
                    BudgetDimension.Deadline,
                    deadlineMillis,
                    nowMillis,
                    "budget.deadline_exceeded"
                ))
            }
            let nextTurns = saturatedExecutionBudgetAdd(usedTurns, charge.turns)
            let nextToolCalls = saturatedExecutionBudgetAdd(
                usedToolCalls, charge.toolCalls
            )
            let nextActiveTools = saturatedExecutionBudgetAdd(
                activeTools, charge.toolsStarted
            )
            let nextInputTokens = saturatedExecutionBudgetAdd(
                usedInputTokens, charge.inputTokens
            )
            let nextOutputTokens = saturatedExecutionBudgetAdd(
                usedOutputTokens, charge.outputTokens
            )
            let nextCostMicros = saturatedExecutionBudgetAdd(
                usedCostMicros, charge.costMicros
            )
            match (executionBudgetViolation(
                this,
                nextTurns,
                nextToolCalls,
                nextActiveTools,
                nextInputTokens,
                nextOutputTokens,
                nextCostMicros
            )) {
                case Some(violation) => return executionBudgetFailure(violation)
                case None => ()
            }
            usedTurns = nextTurns
            usedToolCalls = nextToolCalls
            activeTools = nextActiveTools
            usedInputTokens = nextInputTokens
            usedOutputTokens = nextOutputTokens
            usedCostMicros = nextCostMicros
            Result.Ok(usage())
        } finally {
            usageLock.unlock()
        }
    }

    public func releaseTools(count!: Int64 = 1): Result<ExecutionUsage> {
        if (count < 1) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "budget.invalid_release",
                "released tool count must be positive"
            ))
        }
        usageLock.lock()
        try {
            if (count > activeTools) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "budget.concurrent_release_underflow",
                    "released tool count exceeds active tool count",
                    fields: [
                        ErrorField("active", activeTools.toString()),
                        ErrorField("released", count.toString())
                    ]
                ))
            }
            activeTools -= count
            Result.Ok(usage())
        } finally {
            usageLock.unlock()
        }
    }

    public func checkDeadline(
        nowMillis!: Int64 = agentUtcMillis()
    ): Result<ExecutionUsage> {
        reserve(BudgetCharge(), nowMillis: nowMillis)
    }

    private func usage(): ExecutionUsage {
        ExecutionUsage(
            turns: usedTurns,
            toolCalls: usedToolCalls,
            activeTools: activeTools,
            inputTokens: usedInputTokens,
            outputTokens: usedOutputTokens,
            costMicros: usedCostMicros
        )
    }
}

public func executionBudgetFrom(resource: ResourceBudget): ExecutionBudget {
    ExecutionBudget(
        maxTurns: resource.maxTurns,
        maxToolCalls: resource.maxToolCalls,
        maxConcurrentTools: resource.maxConcurrentTools,
        maxInputTokens: resource.maxInputTokens,
        maxOutputTokens: resource.maxOutputTokens,
        maxTotalInputTokens: resource.maxTotalInputTokens,
        maxTotalOutputTokens: resource.maxTotalOutputTokens,
        maxCostMicros: resource.maxCostMicros,
        deadlineMillis: resource.deadlineMillis,
        maxChildren: resource.maxChildren,
        maxDepth: resource.maxDepth,
        maxConcurrentChildren: resource.maxConcurrentChildren
    )
}

public class ExecutionUsage {
    public let turns: Int64
    public let toolCalls: Int64
    public let activeTools: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let costMicros: Int64

    public init(
        turns!: Int64 = 0,
        toolCalls!: Int64 = 0,
        activeTools!: Int64 = 0,
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        costMicros!: Int64 = 0
    ) {
        if (turns < 0 || toolCalls < 0 || activeTools < 0 || inputTokens < 0 ||
            outputTokens < 0 || costMicros < 0) {
            throw IllegalArgumentException("execution usage values must not be negative")
        }
        this.turns = turns
        this.toolCalls = toolCalls
        this.activeTools = activeTools
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.costMicros = costMicros
    }
}

public class BudgetCharge {
    public let turns: Int64
    public let toolCalls: Int64
    public let toolsStarted: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let costMicros: Int64

    public init(
        turns!: Int64 = 0,
        toolCalls!: Int64 = 0,
        toolsStarted!: Int64 = 0,
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        costMicros!: Int64 = 0
    ) {
        if (turns < 0 || toolCalls < 0 || toolsStarted < 0 || inputTokens < 0 ||
            outputTokens < 0 || costMicros < 0) {
            throw IllegalArgumentException("budget charge values must not be negative")
        }
        this.turns = turns
        this.toolCalls = toolCalls
        this.toolsStarted = toolsStarted
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.costMicros = costMicros
    }
}

@Derive[Equatable]
public enum BudgetDimension {
    Turns | ToolCalls | ConcurrentTools | InputTokens | OutputTokens | Cost | Deadline
}

public class BudgetViolation {
    public let dimension: BudgetDimension
    public let limit: Int64
    public let observed: Int64
    public let code: String

    public init(
        dimension: BudgetDimension,
        limit: Int64,
        observed: Int64,
        code: String
    ) {
        this.dimension = dimension
        this.limit = limit
        this.observed = observed
        this.code = code
    }
}

public enum BudgetDecision {
    Accepted(ExecutionUsage) | Rejected(BudgetViolation)
}

func executionBudgetViolation(
    budget: ExecutionBudget,
    turns: Int64,
    toolCalls: Int64,
    activeTools: Int64,
    inputTokens: Int64,
    outputTokens: Int64,
    costMicros: Int64
): ?BudgetViolation {
    let checks = [
        (BudgetDimension.Turns, budget.maxTurns, turns, "budget.turns_exceeded"),
        (BudgetDimension.ToolCalls, budget.maxToolCalls, toolCalls,
            "budget.tool_calls_exceeded"),
        (BudgetDimension.ConcurrentTools, budget.maxConcurrentTools, activeTools,
            "budget.concurrent_tools_exceeded")
    ]
    for ((dimension, limit, observed, code) in checks where observed > limit) {
        return Some(BudgetViolation(dimension, limit, observed, code))
    }
    if (budget.maxTotalInputTokens > 0 && inputTokens > budget.maxTotalInputTokens) {
        return Some(BudgetViolation(
            BudgetDimension.InputTokens,
            budget.maxTotalInputTokens,
            inputTokens,
            "budget.total_input_tokens_exceeded"
        ))
    }
    if (budget.maxTotalOutputTokens > 0 && outputTokens > budget.maxTotalOutputTokens) {
        return Some(BudgetViolation(
            BudgetDimension.OutputTokens,
            budget.maxTotalOutputTokens,
            outputTokens,
            "budget.total_output_tokens_exceeded"
        ))
    }
    if (budget.maxCostMicros > 0 && costMicros > budget.maxCostMicros) {
        return Some(BudgetViolation(
            BudgetDimension.Cost,
            budget.maxCostMicros,
            costMicros,
            "budget.cost_exceeded"
        ))
    }
    None
}

func executionBudgetFailure<T>(violation: BudgetViolation): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.BudgetExceeded,
        violation.code,
        "execution budget exceeded",
        fields: [
            ErrorField("dimension", budgetDimensionName(violation.dimension)),
            ErrorField("limit", violation.limit.toString()),
            ErrorField("observed", violation.observed.toString())
        ]
    ))
}

func budgetDimensionName(value: BudgetDimension): String {
    match (value) {
        case BudgetDimension.Turns => "turns"
        case BudgetDimension.ToolCalls => "tool_calls"
        case BudgetDimension.ConcurrentTools => "concurrent_tools"
        case BudgetDimension.InputTokens => "input_tokens"
        case BudgetDimension.OutputTokens => "output_tokens"
        case BudgetDimension.Cost => "cost"
        case BudgetDimension.Deadline => "deadline"
    }
}

func saturatedExecutionBudgetAdd(left: Int64, right: Int64): Int64 {
    if (right > Int64.Max - left) { Int64.Max } else { left + right }
}

@Derive[Equatable]
public enum ModelFeature {
    ToolCalling | ParallelToolCalling | Reasoning | Vision | StructuredOutput | PromptCache
}

public class ModelCapabilities {
    public let toolCalling: Bool
    public let parallelToolCalling: Bool
    public let reasoning: Bool
    public let vision: Bool
    public let structuredOutput: Bool
    public let promptCache: Bool
    public let contextWindowTokens: Int64
    public let maxOutputTokens: Int64
    public let thinking: ThinkingCapabilities

    public init(
        toolCalling!: Bool = false,
        parallelToolCalling!: Bool = false,
        reasoning!: Bool = false,
        vision!: Bool = false,
        structuredOutput!: Bool = false,
        promptCache!: Bool = false,
        contextWindowTokens!: Int64 = 1,
        maxOutputTokens!: Int64 = 1,
        thinking!: ?ThinkingCapabilities = None
    ) {
        if (parallelToolCalling && !toolCalling) {
            throw IllegalArgumentException("parallel tool calling requires tool calling")
        }
        if (contextWindowTokens < 1 || maxOutputTokens < 1 ||
            maxOutputTokens > contextWindowTokens) {
            throw IllegalArgumentException("model token capabilities are out of range")
        }
        this.toolCalling = toolCalling
        this.parallelToolCalling = parallelToolCalling
        this.reasoning = reasoning
        this.vision = vision
        this.structuredOutput = structuredOutput
        this.promptCache = promptCache
        this.contextWindowTokens = contextWindowTokens
        this.maxOutputTokens = maxOutputTokens
        this.thinking = match (thinking) {
            case Some(value) => value
            case None => if (reasoning) {
                ThinkingCapabilities(
                    ThinkingControlMode.Effort,
                    supportedLevels: canonicalNonOffThinkingLevels()
                )
            } else {
                ThinkingCapabilities(ThinkingControlMode.NoThinking)
            }
        }
    }

    public func supports(feature: ModelFeature): Bool {
        match (feature) {
            case ModelFeature.ToolCalling => toolCalling
            case ModelFeature.ParallelToolCalling => parallelToolCalling
            case ModelFeature.Reasoning => reasoning
            case ModelFeature.Vision => vision
            case ModelFeature.StructuredOutput => structuredOutput
            case ModelFeature.PromptCache => promptCache
        }
    }

    public func require(feature: ModelFeature): Result<Unit> {
        if (supports(feature)) {
            return Result.Ok(())
        }
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "model.capability_unsupported",
            "model does not support the requested capability",
            fields: [ErrorField("feature", modelFeatureName(feature))]
        ))
    }

    public func validate(request: ModelRequest): Result<Unit> {
        if (requestContainsImages(request)) {
            match (require(ModelFeature.Vision)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        if (request.structuredOutput.isSome()) {
            match (require(ModelFeature.StructuredOutput)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        if (!request.tools.isEmpty()) {
            match (require(ModelFeature.ToolCalling)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        if (request.parallelToolCalls && !request.tools.isEmpty()) {
            match (require(ModelFeature.ParallelToolCalling)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        if (request.thinking != ThinkingLevel.Off) {
            match (require(ModelFeature.Reasoning)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => ()
            }
        }
        match (request.cachePolicy) {
            case ModelCachePolicy.StablePrefix =>
                if (request.cacheKey == "") {
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "model.cache_key_required",
                        "stable-prefix prompt caching requires a non-empty cache key"
                    ))
                }
                match (require(ModelFeature.PromptCache)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
            case _ => ()
        }
        if (request.maxOutputTokens > maxOutputTokens) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.output_limit_exceeded",
                "requested output tokens exceed model capability",
                fields: [
                    ErrorField("requested", request.maxOutputTokens.toString()),
                    ErrorField("limit", maxOutputTokens.toString())
                ]
            ))
        }
        Result.Ok(())
    }
}

func requestContainsImages(request: ModelRequest): Bool {
    for (message in request.messages) {
        for (block in message.blocks) {
            if (block.kind == ModelBlockKind.Image) {
                return true
            }
        }
    }
    false
}

func modelFeatureName(feature: ModelFeature): String {
    match (feature) {
        case ModelFeature.ToolCalling => "tool_calling"
        case ModelFeature.ParallelToolCalling => "parallel_tool_calling"
        case ModelFeature.Reasoning => "reasoning"
        case ModelFeature.Vision => "vision"
        case ModelFeature.StructuredOutput => "structured_output"
        case ModelFeature.PromptCache => "prompt_cache"
    }
}
