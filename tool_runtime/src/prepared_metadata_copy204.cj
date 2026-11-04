package tool_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.sync.*

private let preparedMetadataDebts204 = PreparedMetadataDebts204()

// An independently paid DATA copy. It never substitutes the original Source,
// canonical operation, policy, approval or executor. The Core producer and
// every concrete external consumer must both return before this copy retires.
class PreparedMetadataOwner204 {
    private let lock = Mutex()
    private let payment: LogicalJsonOwnerReservation
    private let core: PlanCopyDataConsumer204
    private var prepared: ?PreparedToolInvocation = None<PreparedToolInvocation>
    private var consumers: Int64 = 0
    private var consumerHeaders: Int64 = 0
    private var producerReturned = false
    private var unknown = false
    private var returned = false
    private var retainedInvoice204: Int64 = 131072
    var next204: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
    var nextDebt204: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
    init(payment: LogicalJsonOwnerReservation, core: PlanCopyDataConsumer204) {
        this.payment = payment; this.core = core
        preparedMetadataDebts204.retain204(this)
    }
    func installFrame204(value: PreparedToolInvocation): Unit {
        let meter = OwnedPreparedReferenceMeasure(payment, 131072)
        meter.metadataCopy204(value)
        retainedInvoice204 = meter.peak()
        payment.ensureRetainedPeak(retainedInvoice204)
        let originalCall = value.borrowUnpublishedCall204()
        value.installDetachedMetadata204(this, ToolCall(copyTextData204(originalCall.callId), copyTextData204(originalCall.name), copyJsonData204(originalCall.arguments)),
            copyPlanData204(value.borrowOperationPlanFrame204()),
            copyConcurrencyData204(value.borrowConcurrencyFrame204()),
            match (value.borrowApprovalFrame204()) { case Some(item) => Some(copyApprovalData204(item)); case None => None })
        prepared = Some(value)
    }
    func retain204(): PreparedMetadataConsumer204 {
        lock.lock(); try {
            if (returned || producerReturned || consumers == Int64.Max) { throw IllegalStateException("prepared DATA producer has returned") }
            if (consumerHeaders > (Int64.Max - 131072) / 1024 - 1) { throw LogicalJsonPayloadError("prepared consumer invoice overflow") }
            payment.ensureRetainedPeak(retainedInvoice204 + (consumerHeaders + 1) * 1024)
            let consumer = PreparedMetadataConsumer204(this)
            consumerHeaders++; consumers++
            consumer
        } finally { lock.unlock() }
    }
    func requireCore204(actual: PaidExecutionFailureSink173): Unit {
        lock.lock(); try {
            if (returned || producerReturned) { throw IllegalStateException("prepared Core DATA frame has returned") }
            match (actual as PlanCopyDataConsumer204) {
                case Some(value) => if (!samePlanCopyConsumer204(value, core)) { throw IllegalArgumentException("prepared DATA belongs to another Core consumer") }
                case None => throw IllegalArgumentException("prepared DATA requires its actual Core consumer") }
        } finally { lock.unlock() }
    }
    func call204(): ToolCall {
        lock.lock(); try {
            if (returned) { throw IllegalStateException("prepared DATA has returned") }
            prepared.getOrThrow().borrowDetachedCall204()
        } finally { lock.unlock() }
    }
    func plan204(): NormalizedOperationPlan {
        lock.lock(); try {
            if (returned) { throw IllegalStateException("prepared DATA has returned") }
            prepared.getOrThrow().borrowDetachedPlan204()
        } finally { lock.unlock() }
    }
    func holdUnknown204(): Unit { lock.lock(); try { unknown = true } finally { lock.unlock() } }
    func producerReturned204(): Unit {
        lock.lock(); try { producerReturned = true } finally { lock.unlock() }
        collect204()
    }
    func consumerReturned204(): Unit {
        lock.lock(); try {
            if (consumers < 1) { throw IllegalStateException("prepared DATA consumer underflow") }
            consumers--
        } finally { lock.unlock() }
        collect204()
    }
    private func collect204(): Unit {
        lock.lock(); try {
            if (returned || unknown || !producerReturned || consumers != 0) { return }
            prepared.getOrThrow().clearDetachedMetadata204()
            prepared = None<PreparedToolInvocation>
            payment.close(); returned = true
            preparedMetadataDebts204.remove204(this)
        } finally { lock.unlock() }
    }
}

// No Source/Operation authority. A loan's return alone never refunds the owner;
// the concrete enclosing consumer separately acknowledges its whole frame.
public class PreparedMetadataConsumer204 {
    private let lock = Mutex()
    private var owner: ?PreparedMetadataOwner204
    private var loans: Int64 = 0
    init(owner: PreparedMetadataOwner204) { this.owner = Some(owner) }
    public func withOperationPlan204<T>(body: (NormalizedOperationPlan) -> T): T {
        let actual = try { lock.lock(); let value = owner.getOrThrow()
            if (loans == Int64.Max) { throw IllegalStateException("prepared DATA loan count overflow") }
            loans++; value
        } finally { lock.unlock() }
        try { body(actual.plan204()) }
        catch (error: Exception) { actual.holdUnknown204(); throw error }
        finally { lock.lock(); try { loans-- } finally { lock.unlock() } }
    }
    public func withCall204<T>(body: (ToolCall) -> T): T {
        let actual = try { lock.lock(); let value = owner.getOrThrow()
            if (loans == Int64.Max) { throw IllegalStateException("prepared DATA loan count overflow") }
            loans++; value
        } finally { lock.unlock() }
        try { body(actual.call204()) }
        catch (error: Exception) { actual.holdUnknown204(); throw error }
        finally { lock.lock(); try { loans-- } finally { lock.unlock() } }
    }
    public func returnConsumerFrame204(): Unit {
        let actual = try { lock.lock()
            if (loans != 0) { throw IllegalStateException("prepared DATA loan is still active") }
            let value = owner.getOrThrow(); owner = None<PreparedMetadataOwner204>; value
        } finally { lock.unlock() }
        actual.consumerReturned204()
    }
}

func copyTextData204(value: String): String { String.fromUtf8(value.toArray()) }
func copyTextsData204(values: Array<String>): Array<String> { values.map { value => copyTextData204(value) } }
func copyJsonData204(value: AgentValue): AgentValue {
    if (value.unifiedKind == ValueKind.Text) { return textValue(copyTextData204(value.text)) }
    if (value.unifiedKind == ValueKind.Number) { return value.materialize(1) }
    if (value.unifiedKind == ValueKind.Null) { return nullValue() }
    if (value.unifiedKind == ValueKind.Boolean) { return boolValue(value.asBool()) }
    if (value.unifiedKind == ValueKind.List) {
        return listValue(value.items.toArray().map { item => copyJsonData204(item) })
    }
    if (value.unifiedKind == ValueKind.Object) {
        return objectValue(value.fields.map { field => ValueField(copyTextData204(field.name), copyJsonData204(field.value)) })
    }
    throw IllegalArgumentException("unsupported original prepared DATA node")
}
func copyCapabilityData204(value: Capability): Capability { Capability(value.kind, resource: copyTextData204(value.resource)) }
func copyMetadataData204(value: ToolApprovalMetadata): ToolApprovalMetadata {
    let summary = match (value.writeSummary) {
        case Some(item) => Some(WriteApprovalSummary(copyTextData204(item.path), copyTextData204(item.action), item.exists, item.bytes, item.lines,
            language: copyTextData204(item.language), preview: copyTextsData204(item.preview), truncated: item.truncated,
            contentHash: copyTextData204(item.contentHash), beforeBytes: item.beforeBytes, addedLines: item.addedLines, removedLines: item.removedLines))
        case None => None<WriteApprovalSummary> }
    let scope = value.grantScope
    ToolApprovalMetadata(copyTextData204(value.capabilityLabel),
        RiskAssessment(value.assessment.level, flags: copyTextsData204(value.assessment.flags), reasons: copyTextsData204(value.assessment.reasons)),
        ApprovalGrantScope(copyTextData204(scope.capability), pathPrefix: copyTextData204(scope.pathPrefix),
            toolName: copyTextData204(scope.toolName), host: copyTextData204(scope.host), sessionOnly: scope.sessionOnly),
        writeSummary: summary, sessionApprovalAllowed: value.sessionApprovalAllowed)
}
func copyApprovalData204(value: ApprovalRequest): ApprovalRequest {
    let review = match (value.review) { case Some(item) => Some(ApprovalReview(item.decision, copyTextData204(item.reason),
        copyTextData204(item.riskLevel), copyTextData204(item.reviewerModel), latencyMillis: item.latencyMillis,
        approvedCapabilities: copyTextsData204(item.approvedCapabilities), failureType: copyTextData204(item.failureType)))
        case None => None<ApprovalReview> }
    ApprovalRequest(OperationId(copyTextData204(value.operationId.value)), copyTextData204(value.callId), copyTextData204(value.toolName),
        copyCapabilityData204(value.capability), preview: copyJsonData204(value.preview), sessionId: copyTextData204(value.sessionId),
        argumentHash: copyTextData204(value.argumentHash), riskFlags: copyTextsData204(value.riskFlags), review: review,
        metadata: copyMetadataData204(value.metadata), decisionSource: value.decisionSource, sessionApprovalAllowed: value.sessionApprovalAllowed)
}
func copyConcurrencyData204(value: ToolConcurrencyProfile): ToolConcurrencyProfile {
    ToolConcurrencyProfile(mode: value.mode, accesses: value.accesses.map { item => ToolResourceAccess(copyTextData204(item.namespace),
        copyTextData204(item.resource), item.mode, scope: item.scope) })
}
func copyPlanData204(value: NormalizedOperationPlan): NormalizedOperationPlan {
    let network = value.networkPolicy
    let replay = match (value.replayDisposition) {
        case ReplayDisposition.Idempotent(key) => ReplayDisposition.Idempotent(copyTextData204(key))
        case ReplayDisposition.RecoverByProbe(probe) => ReplayDisposition.RecoverByProbe(RecoveryProbeId(copyTextData204(probe.value)))
        case ReplayDisposition.Compensatable(plan) => ReplayDisposition.Compensatable(CompensationPlanId(copyTextData204(plan.value)))
        case _ => value.replayDisposition }
    let facts = value.contextReadFacts.map { item => contextReadFactLinkFromValue(copyJsonData204(item.toValue())) }
    NormalizedOperationPlan(copyTextData204(value.toolName), copyJsonData204(value.canonicalArguments),
        value.requiredCapabilities.map { item => copyCapabilityData204(item) }, value.effectClass, value.retryDisposition,
        copyTextData204(value.bindingDigest), resolvedPaths: copyTextsData204(value.resolvedPaths), resolvedHosts: copyTextsData204(value.resolvedHosts),
        networkPolicy: Some(NetworkPolicy(network.mode,
            egress: network.egress.map { item => NetworkEgressRule(copyTextData204(item.host), item.port, privateAddresses: copyTextsData204(item.privateAddresses)) },
            publish: network.publish.map { item => NetworkPublishRule(item.hostPort, item.targetPort) })),
        cwd: copyTextData204(value.cwd), relevantEnvironment: value.relevantEnvironment.map { field => ValueField(copyTextData204(field.name), copyJsonData204(field.value)) },
        approvalMetadata: Some(copyMetadataData204(value.approvalMetadata)), idempotencyKey: copyTextData204(value.idempotencyKey),
        replayDisposition: Some(replay), toolVersion: copyTextData204(value.implementation.toolVersion),
        implementationFingerprint: copyTextData204(value.implementation.implementationFingerprint), schemaDigest: copyTextData204(value.implementation.schemaDigest),
        effectiveArgumentsDigest: copyTextData204(value.implementation.effectiveArgumentsDigest), replayContractVersion: value.implementation.replayContractVersion,
        contextReadFacts: facts, policyVersion: copyTextData204(value.policyVersion), approvedWriteRoots: copyTextsData204(value.approvedWriteRoots))
}

private class PreparedMetadataDebts204 {
    private let lock = Mutex()
    private var first: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
    func retain204(value: PreparedMetadataOwner204): Unit {
        lock.lock(); try { value.nextDebt204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: PreparedMetadataOwner204): Unit {
        lock.lock(); try {
            var previous: ?PreparedMetadataOwner204 = None<PreparedMetadataOwner204>
            var cursor = first
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(parent) => parent.nextDebt204 = actual.nextDebt204; case None => first = actual.nextDebt204 }
                    actual.nextDebt204 = None<PreparedMetadataOwner204>; return
                }
                previous = cursor; cursor = actual.nextDebt204
            }
            throw IllegalStateException("prepared DATA debt is missing")
        } finally { lock.unlock() }
    }
}
