package tool_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import std.collection.*
import std.deriving.*
import std.sync.*

@Derive[Equatable]
public enum PreparedAuthorization {
    StaticPolicy | SessionGrant | ApprovalRequired | Approved
}

// This is the durable hand-off between preparation/approval and execution.
// Batch coordinators can collect these values, finish every approval decision,
// calculate conflict-free waves, and only then call executePrepared.
public class PreparedToolInvocation {
    public let operationId: OperationId
    public let call: ToolCall
    public let capability: Capability
    public let concurrency: ToolConcurrencyProfile
    public let authorization: PreparedAuthorization
    public let approval: ?ApprovalRequest
    public let requiredCapabilities: Array<Capability>
    public let bindingHash: String
    public let operationPlan: NormalizedOperationPlan

    init(
        operationId: OperationId,
        call: ToolCall,
        capability: Capability,
        concurrency: ToolConcurrencyProfile,
        authorization: PreparedAuthorization,
        approval!: ?ApprovalRequest = None,
        requiredCapabilities!: Array<Capability> = [],
        bindingHash!: String = "",
        operationPlan!: ?NormalizedOperationPlan = None
    ) {
        this.operationId = operationId
        this.call = call
        this.capability = capability
        this.concurrency = concurrency
        this.authorization = authorization
        this.approval = approval
        this.requiredCapabilities = if (requiredCapabilities.isEmpty()) {
            [capability]
        } else {
            requiredCapabilities
        }
        this.bindingHash = bindingHash
        this.operationPlan = match (operationPlan) {
            case Some(value) => value
            case None => throw IllegalArgumentException(
                "prepared tool invocation requires a normalized Operation plan"
            )
        }
    }
}

public enum ToolPreparation {
    Ready(PreparedToolInvocation)
    | NeedsApproval(PreparedToolInvocation, ApprovalRequest)
    | Completed(ToolResult)
    | Denied(ToolDenial)
}

public enum ToolAuthorization {
    Ready(PreparedToolInvocation)
    | Completed(ToolResult)
    | Denied(ToolDenial)
}

public class ToolOutputChunk {
    public let callId: String
    public let channel: ToolOutputChannel
    public let content: String
    public let truncated: Bool

    public init(
        callId: String,
        channel: ToolOutputChannel,
        content: String,
        truncated!: Bool = false
    ) {
        if (callId.trimAscii() == "") {
            throw IllegalArgumentException("tool output call id must not be empty")
        }
        this.callId = callId
        this.channel = channel
        this.content = content
        this.truncated = truncated
    }
}

public interface ToolOutputSink {
    func emit(chunk: ToolOutputChunk): Result<Unit>
}

public class NoopToolOutputSink <: ToolOutputSink {
    public init() {}

    public func emit(chunk: ToolOutputChunk): Result<Unit> {
        let _ = chunk
        Result.Ok(())
    }
}

// A deterministic sink for executor/adapter contract tests. Production
// frontends provide their own bounded sink and map chunks to AgentEvent.
public class MemoryToolOutputSink <: ToolOutputSink {
    private let lock = Mutex()
    private let chunks = ArrayList<ToolOutputChunk>()

    public init() {}

    public func emit(chunk: ToolOutputChunk): Result<Unit> {
        lock.lock()
        try {
            chunks.add(chunk)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func snapshot(): Array<ToolOutputChunk> {
        lock.lock()
        try {
            chunks.toArray()
        } finally {
            lock.unlock()
        }
    }
}

public func recoverableToolResult(
    call: ToolCall,
    error: AgentError,
    receiptId!: String = ""
): ToolResult {
    let fields = ArrayList<ValueField>()
    // Keep the stable, model-facing error code at the top level. Additional
    // typed detail is additive, so existing consumers do not need to parse a
    // nested implementation-specific error envelope.
    fields.add(ValueField("error", textValue(error.code)))
    fields.add(ValueField("error_kind", textValue(toolErrorKindName(error.kind))))
    fields.add(ValueField("message", textValue(error.message)))
    fields.add(ValueField("retryable", boolValue(error.retryable)))
    let details = ArrayList<AgentValue>()
    for (field in error.fields) {
        details.add(objectValue([
            ValueField("name", textValue(field.name)),
            ValueField("value", textValue(field.value))
        ]))
    }
    fields.add(ValueField("fields", listValue(details.toArray())))
    ToolResult(
        call.callId,
        objectValue(fields.toArray()),
        isError: true,
        receiptId: receiptId
    )
}

func toolErrorKindName(kind: AgentErrorKind): String {
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

func recoverableExecutorError(error: AgentError): Bool {
    match (error.kind) {
        case AgentErrorKind.Configuration | AgentErrorKind.Cancelled | AgentErrorKind.BudgetExceeded
            | AgentErrorKind.RecoveryRequired | AgentErrorKind.Internal => false
        case _ => true
    }
}
