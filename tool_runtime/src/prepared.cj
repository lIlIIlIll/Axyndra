package tool_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.deriving.*
import std.sync.*

@Derive[Equatable]
public enum PreparedAuthorization {
    StaticPolicy | SessionGrant | ApprovalRequired | Approved | ParentIntent | ManagedJob
}

@Derive[Equatable]
public enum PreparedInvocationSourceKind {
    Direct | Committed | Derived
}

// Minted only by ToolPipeline. Direct identifies a host-prepared plan without
// a model Decision; it does not grant trusted-control authority. Derived keeps
// the canonical root attestation but cannot be reused as a committed root.
public class PreparedInvocationSource {
    public let kind: PreparedInvocationSourceKind
    public let runId: RunId
    public let sessionId: SessionId
    public let epoch: Int64
    public let operationRoot: ?OperationRootSource
    public prop rootToolCall: ?CommittedToolCallRef {
        get() {
            match (operationRoot) {
                case Some(OperationRootSource.Committed(value)) => Some(value)
                case _ => None
            }
        }
    }
    public let parentOperationId: ?OperationId
    public let requestKey: String
    // Immediate sealed parent identity; the canonical root call remains in operationRoot.
    public let parentCallId: String
    let contextReadFacts: Array<ContextReadFactLink>
    let contextReadAdmission: ?ContextReadAdmission
    public let contextReadPreparation: ?ToolPreparationRead
    let managedJobCeiling: ?CapabilitySet

    init(
        kind: PreparedInvocationSourceKind,
        context: ToolInvocationContext,
        rootToolCall!: ?CommittedToolCallRef = None,
        operationRoot!: ?OperationRootSource = None,
        parentOperationId!: ?OperationId = None,
        requestKey!: String = "", parentCallId!: String = "", contextReadAdmission!: ?ContextReadAdmission = None,
        contextReadFacts!: Array<ContextReadFactLink> = [],
        contextReadPreparation!: ?ToolPreparationRead = None, managedJobCeiling!: ?CapabilitySet = None
    ) {
        this.kind = kind
        this.runId = context.runId
        this.sessionId = context.sessionId
        this.epoch = context.epoch
        this.operationRoot = match (operationRoot) {
            case Some(value) => Some(value)
            case None => match (rootToolCall) {
                case Some(value) => Some(OperationRootSource.Committed(value))
                case None => None
            }
        }
        this.parentOperationId = parentOperationId
        this.requestKey = requestKey
        this.parentCallId = parentCallId
        this.contextReadAdmission = contextReadAdmission
        this.contextReadPreparation = contextReadPreparation
        this.managedJobCeiling = match (managedJobCeiling) { case Some(value) => Some(CapabilitySet(values: value.values.clone())); case None => None }
        this.contextReadFacts = validatedContextReadFactLinks(contextReadFacts)
    }
}

// This is the durable hand-off between preparation/approval and execution.
// Batch coordinators can collect these values, finish every approval decision,
// calculate conflict-free waves, and only then call the executor.
public class PreparedToolInvocation {
    public let operationId: OperationId
    // Identity/display only. Authority-relevant arguments live in
    // operationPlan.canonicalArguments.
    public let call: ToolCall
    private var concurrencyData204: ?ToolConcurrencyProfile = None<ToolConcurrencyProfile>
    public prop concurrency: ToolConcurrencyProfile {
        get() { requireMetadataExport204(); concurrencyData204.getOrThrow() }
    }
    public let authorization: PreparedAuthorization
    private var approvalData204: ?ApprovalRequest = None<ApprovalRequest>
    public prop approval: ?ApprovalRequest {
        get() { if (approvalData204.isSome()) { requireMetadataExport204() }; approvalData204 }
    }
    private var operationPlanData204: ?NormalizedOperationPlan = None<NormalizedOperationPlan>
    public prop operationPlan: NormalizedOperationPlan {
        get() { requireMetadataExport204(); operationPlanData204.getOrThrow() }
    }

    private var catalogConsumer204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
    private var metadataReturned204 = false
    var nextPrepared204: ?PreparedToolInvocation = None<PreparedToolInvocation>
    func ownCatalogConsumer204(value: ToolCatalogHostConsumer204): Bool {
        if (metadataReturned204) { throw IllegalStateException("prepared metadata has returned") }
        match (catalogConsumer204) {
            case Some(existing) =>
                if (!refEq(existing, value)) { throw IllegalStateException("prepared metadata already belongs to another live consumer") }
                false
            case None => catalogConsumer204 = Some(value); true
        }
    }
    private func requireMetadataExport204(): Unit {
        if (metadataReturned204) { throw IllegalStateException("prepared metadata has returned") }
        match (catalogConsumer204) { case Some(value) => value.holdPreparedExport204(this); case None => () }
    }
    func borrowOperationPlanFrame204(): NormalizedOperationPlan {
        requireMetadataBorrow204(); operationPlanData204.getOrThrow()
    }
    func borrowConcurrencyFrame204(): ToolConcurrencyProfile {
        requireMetadataBorrow204(); concurrencyData204.getOrThrow()
    }
    func borrowApprovalFrame204(): ?ApprovalRequest {
        requireMetadataBorrow204(); approvalData204
    }
    private func requireMetadataBorrow204(): Unit {
        if (metadataReturned204) { throw IllegalStateException("prepared metadata has returned") }
        match (catalogConsumer204) { case Some(value) => value.requirePreparedBorrow204(this); case None => () }
    }
    func clearCatalogMetadataFrame204(): ?PreparedToolInvocation {
        operationPlanData204 = None<NormalizedOperationPlan>
        concurrencyData204 = None<ToolConcurrencyProfile>; approvalData204 = None<ApprovalRequest>
        catalogConsumer204 = None<ToolCatalogHostConsumer204>; metadataReturned204 = true
        let next = nextPrepared204; nextPrepared204 = None<PreparedToolInvocation>; next
    }

    public let source: PreparedInvocationSource

    // Compatibility view: a derived child is never a top-level committed call.
    public prop committedToolCall: ?CommittedToolCallRef {
        get() {
            if (source.kind == PreparedInvocationSourceKind.Committed) {
                source.rootToolCall
            } else { None }
        }
    }
    init(
        operationId: OperationId,
        call: ToolCall,
        concurrency: ToolConcurrencyProfile,
        authorization: PreparedAuthorization,
        operationPlan: NormalizedOperationPlan,
        source: PreparedInvocationSource,
        approval!: ?ApprovalRequest = None
    ) {
        this.operationId = operationId
        this.call = call
        this.concurrencyData204 = Some(concurrency)
        this.authorization = authorization
        this.approvalData204 = approval
        this.operationPlanData204 = Some(operationPlan)
        this.source = source
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
    if (error.code == "network.address_denied" ||
        error.code == "network.mode_denied" ||
        error.code == "network.policy_invalid" ||
        error.code == "network.gateway_unavailable") {
        return false
    }
    match (error.kind) {
        case AgentErrorKind.Configuration | AgentErrorKind.Cancelled | AgentErrorKind.BudgetExceeded
            | AgentErrorKind.RecoveryRequired | AgentErrorKind.Internal => false
        case _ => true
    }
}
