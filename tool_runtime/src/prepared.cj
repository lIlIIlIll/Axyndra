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
    private var callData204: ?ToolCall
    public prop call: ToolCall { get() {
        match (detachedMetadata204) { case Some(value) => value.holdUnknown204(); case None => () }
        callData204.getOrThrow()
    } }
    private var concurrencyData204: ?ToolConcurrencyProfile = None<ToolConcurrencyProfile>
    public prop concurrency: ToolConcurrencyProfile {
        get() { requireMetadataExport204(); concurrencyData204.getOrThrow() }
    }
    public let authorization: PreparedAuthorization
    private var planStepIdData204: ?String = None<String>
    private var planActionIdData204: ?String = None<String>
    public prop planStepId: String { get() { requireMetadataExport204(); planStepIdData204.getOrThrow() } }
    public prop planActionId: String { get() { requireMetadataExport204(); planActionIdData204.getOrThrow() } }
    private var approvalData204: ?ApprovalRequest = None<ApprovalRequest>
    public prop approval: ?ApprovalRequest {
        get() { if (approvalData204.isSome()) { requireMetadataExport204() }; approvalData204 }
    }
    private var operationPlanData204: ?NormalizedOperationPlan = None<NormalizedOperationPlan>
    public prop operationPlan: NormalizedOperationPlan {
        get() { requireMetadataExport204(); operationPlanData204.getOrThrow() }
    }

    private var catalogConsumer204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
    private var detachedMetadata204: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
    private var metadataReturned204 = false
    public func retainMetadataConsumer204(): ?PreparedMetadataConsumer204 {
        match (detachedMetadata204) { case Some(value) => Some(value.retain204()); case None => None<PreparedMetadataConsumer204> }
    }
    public func withCall204<T>(body: (ToolCall) -> T): T {
        if (metadataReturned204) { throw IllegalStateException("prepared DATA has returned") }
        try { body(callData204.getOrThrow()) }
        catch (error: Exception) {
            match (detachedMetadata204) { case Some(value) => value.holdUnknown204(); case None => () }; throw error
        }
    }
    public func withApproval204<T>(body: (?ApprovalRequest) -> T): T {
        requireMetadataBorrow204()
        try { body(approvalData204) }
        catch (error: Exception) {
            match (detachedMetadata204) { case Some(value) => value.holdUnknown204()
                case None => match (catalogConsumer204) { case Some(value) => value.holdUnknown204(); case None => () } }
            throw error
        }
    }
    public func borrowCallForCore204(actual: PaidExecutionFailureSink173): ToolCall {
        if (metadataReturned204) { throw IllegalStateException("prepared DATA has returned") }
        // The legacy display call had no Catalog metadata export hook. Only
        // the new independently copied call requires the exact Core owner.
        match (detachedMetadata204) { case Some(value) => value.requireCore204(actual); case None => () }
        callData204.getOrThrow()
    }
    // Only the unpublished constructor/copy producer may use this accessor.
    func borrowUnpublishedCall204(): ToolCall {
        if (detachedMetadata204.isSome() || metadataReturned204) { throw IllegalStateException("prepared DATA is already published") }
        callData204.getOrThrow()
    }
    func borrowDetachedCall204(): ToolCall { callData204.getOrThrow() }
    public func withOperationPlan204<T>(body: (NormalizedOperationPlan) -> T): T {
        requireMetadataBorrow204()
        try { body(operationPlanData204.getOrThrow()) }
        catch (error: Exception) {
            match (detachedMetadata204) { case Some(value) => value.holdUnknown204()
                case None => match (catalogConsumer204) { case Some(value) => value.holdUnknown204(); case None => () } }
            throw error
        }
    }
    // Only the independently prepaid copy may be borrowed by the exact Core
    // DATA consumer which owns its whole Run frame. No Source is exported.
    public func borrowOperationPlanForCore204(actual: PaidExecutionFailureSink173): NormalizedOperationPlan {
        requireCoreMetadata204(actual); operationPlanData204.getOrThrow()
    }
    public func borrowConcurrencyForCore204(actual: PaidExecutionFailureSink173): ToolConcurrencyProfile {
        requireCoreMetadata204(actual); concurrencyData204.getOrThrow()
    }
    public func borrowApprovalForCore204(actual: PaidExecutionFailureSink173): ?ApprovalRequest {
        requireCoreMetadata204(actual); approvalData204
    }
    public func borrowPlanStepIdForCore204(actual: PaidExecutionFailureSink173): String {
        requireCoreMetadata204(actual); planStepIdData204.getOrThrow()
    }
    public func borrowPlanActionIdForCore204(actual: PaidExecutionFailureSink173): String {
        requireCoreMetadata204(actual); planActionIdData204.getOrThrow()
    }
    private func requireCoreMetadata204(actual: PaidExecutionFailureSink173): Unit {
        if (metadataReturned204) { throw IllegalStateException("prepared metadata has returned") }
        match (detachedMetadata204) { case Some(value) => value.requireCore204(actual)
            case None => requireMetadataExport204() }
    }
    func hasDetachedMetadata204(): Bool { detachedMetadata204.isSome() }
    func installDetachedMetadata204(owner: PreparedMetadataOwner204, call: ToolCall, plan: NormalizedOperationPlan,
        concurrency: ToolConcurrencyProfile, approval: ?ApprovalRequest): Unit {
        if (detachedMetadata204.isSome() || metadataReturned204) { throw IllegalStateException("prepared DATA already has an owner") }
        callData204 = Some(call)
        operationPlanData204 = Some(plan); concurrencyData204 = Some(concurrency); approvalData204 = approval
        detachedMetadata204 = Some(owner)
    }
    func borrowDetachedPlan204(): NormalizedOperationPlan { operationPlanData204.getOrThrow() }
    // Only the private freshly loaded approval coordinator may consume this
    // wrapper. The paid owner checks exact producer, Core, exports and loans.
    // Move fields, not DATA or authority; the old wrapper becomes unreadable.
    func tryMovePrivateAuthorization204(actual: PlanCopyDataConsumer204,
        headerPayment: LogicalJsonOwnerReservation, headerInvoice: Int64,
        authorization: PreparedAuthorization): ?PreparedToolInvocation {
        match (detachedMetadata204) {
            case Some(owner) => owner.movePrivateAuthorization204(this, actual, headerPayment, headerInvoice, authorization)
            case None => None<PreparedToolInvocation>
        }
    }
    func privateAuthorizationShell204(owner: PreparedMetadataOwner204,
        authorization: PreparedAuthorization): PreparedToolInvocation {
        if (metadataReturned204 || catalogConsumer204.isSome() || nextPrepared204.isSome() ||
            !refEq(detachedMetadata204.getOrThrow(), owner)) {
            throw IllegalStateException("private approval metadata producer changed")
        }
        let next = PreparedToolInvocation(operationId, callData204.getOrThrow(),
            concurrencyData204.getOrThrow(), authorization, operationPlanData204.getOrThrow(),
            source, approval: approvalData204)
        // These are already privately copied immutable identifiers. Do not
        // materialize another String merely to change an authorization tag.
        next.planStepIdData204 = planStepIdData204
        next.planActionIdData204 = planActionIdData204
        next.detachedMetadata204 = Some(owner)
        next
    }
    func clearDetachedMetadata204(): Unit {
        callData204 = None<ToolCall>
        operationPlanData204 = None<NormalizedOperationPlan>; concurrencyData204 = None<ToolConcurrencyProfile>
        approvalData204 = None<ApprovalRequest>; planStepIdData204 = None<String>; planActionIdData204 = None<String>
        detachedMetadata204 = None<PreparedMetadataOwner204>; metadataReturned204 = true
    }
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
        match (detachedMetadata204) { case Some(value) => value.holdUnknown204()
            case None => match (catalogConsumer204) { case Some(value) => value.holdPreparedExport204(this); case None => () } }
    }
    func borrowPlanStepIdFrame204(): String { requireMetadataBorrow204(); planStepIdData204.getOrThrow() }
    func borrowPlanActionIdFrame204(): String { requireMetadataBorrow204(); planActionIdData204.getOrThrow() }
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
        if (detachedMetadata204.isNone()) {
            match (catalogConsumer204) { case Some(value) => value.requirePreparedBorrow204(this); case None => () }
        }
    }
    func clearCatalogMetadataFrame204(): ?PreparedToolInvocation {
        operationPlanData204 = None<NormalizedOperationPlan>
        planStepIdData204 = None<String>; planActionIdData204 = None<String>
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
        approval!: ?ApprovalRequest = None,
        planStepId!: String = "", planActionId!: String = ""
    ) {
        this.operationId = operationId
        this.callData204 = Some(call)
        this.concurrencyData204 = Some(concurrency)
        this.authorization = authorization
        this.approvalData204 = approval
        this.operationPlanData204 = Some(operationPlan)
        this.source = source
        this.planStepIdData204 = Some(String.fromUtf8(planStepId.toArray()))
        this.planActionIdData204 = Some(String.fromUtf8(planActionId.toArray()))
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
    fields.add(ValueField("failure_class", textValue(operationFailureClass(error))))
    fields.add(ValueField("error_detail", operationErrorValue(error)))
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
