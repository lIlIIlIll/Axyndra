package model_fixture_runtime

import agent_domain.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

private let fixtureRequestDebts159 = FixtureRequestDebts159()

// Only allocator calls in the private PRE-execute copy frame construct this
// marker. It carries no source input or dynamic allocator diagnostic.
class FixtureRequestCapacity159 <: Exception {
    init() { super("fixture input copy capacity unavailable") }
}

// Prepay each copied field/container BEFORE constructing it. This is a
// structural copy, not a second whole-request JSON encode/decode pipeline.
class FixtureRequestCopy159 {
    private let payment: LogicalJsonOwnerReservation
    private var invoice: Int64 = 65536
    init(payment: LogicalJsonOwnerReservation) { this.payment = payment }
    func add159(count: Int64, factor!: Int64 = 1): Unit {
        if (count < 0 || count > (Int64.Max - invoice) / factor) {
            throw IllegalArgumentException("fixture request copy invoice overflow") }
        invoice += count * factor
        try { payment.ensureRetainedPeak(invoice) }
        catch (_: LogicalJsonPayloadError) { throw FixtureRequestCapacity159() }
    }
    func text159(value: String): String {
        add159(1024); add159(value.size, factor: 16)
        String.fromUtf8(value.toArray())
    }
    private func shallowValue159(value: AgentValue): AgentValue {
        add159(1024)
        if (value.unifiedKind == ValueKind.Text) { return textValue(text159(value.text)) }
        if (value.unifiedKind == ValueKind.Number) {
            // Numeric materialize(1) preserves the original scalar subtype.
            // Its only variable spelling is funded before formatter/copy work.
            add159(16384)
            let spelling = value.asNumberText(); add159(spelling.size, factor: 16)
            return value.materialize(1)
        }
        if (value.unifiedKind == ValueKind.Boolean) { return boolValue(value.asBool()) }
        if (value.unifiedKind == ValueKind.Null) { return nullValue() }
        if (value.unifiedKind == ValueKind.List) {
            let source = value.asArray(); add159(source.size(), factor: 512)
            return JsonArray()
        }
        if (value.unifiedKind == ValueKind.Object) {
            let source = value.asObject(); add159(source.size(), factor: 1024)
            return JsonObject()
        }
        throw IllegalArgumentException("fixture request contains an unsupported JSON node")
    }
    func value159(value: AgentValue): AgentValue {
        let result = shallowValue159(value)
        if (value.unifiedKind != ValueKind.List && value.unifiedKind != ValueKind.Object) { return result }
        var head: ?FixtureJsonCopyFrame159 = Some(FixtureJsonCopyFrame159(value, result, None<FixtureJsonCopyFrame159>))
        try {
            while (head.isSome()) {
                let frame = head.getOrThrow(); let source = frame.source.getOrThrow(); let target = frame.target.getOrThrow()
                let count = if (source.unifiedKind == ValueKind.List) { source.asArray().size() } else { source.asObject().size() }
                if (frame.index == count) {
                    head = frame.previous; frame.source = None<AgentValue>; frame.target = None<AgentValue>
                    frame.previous = None<FixtureJsonCopyFrame159>; continue
                }
                let child = if (source.unifiedKind == ValueKind.List) { source.asArray().get(frame.index).getOrThrow() }
                    else { source.asObject().valueAt(frame.index) }
                let container = child.unifiedKind == ValueKind.List || child.unifiedKind == ValueKind.Object
                if (container) {
                    var ancestor = head
                    while (ancestor.isSome()) {
                        let prior = ancestor.getOrThrow()
                        if (refEq(prior.source.getOrThrow(), child)) { throw IllegalArgumentException("cyclic fixture request JSON") }
                        ancestor = prior.previous
                    }
                }
                let copied = shallowValue159(child)
                if (source.unifiedKind == ValueKind.List) { target.asArray().insert(target.asArray().size(), copied) }
                else { target.put(text159(source.asObject().nameAt(frame.index)), copied) }
                frame.index++
                if (container) { head = Some(FixtureJsonCopyFrame159(child, copied, head)) }
            }
            result
        } finally {
            while (head.isSome()) {
                let frame = head.getOrThrow(); head = frame.previous
                frame.source = None<AgentValue>; frame.target = None<AgentValue>; frame.previous = None<FixtureJsonCopyFrame159>
            }
        }
    }
    private func constraints159(source: Array<ResolutionConstraint>): Array<ResolutionConstraint> {
        add159(source.size, factor: 1024)
        let copied = ArrayList<ResolutionConstraint>()
        for (value in source) { copied.add(ResolutionConstraint(value.target, value.kind, value.before, value.after)) }
        copied.toArray()
    }
    private func policy159(value: ResolvedModelRequestPolicy): ResolvedModelRequestPolicy {
        add159(8192)
        ResolvedModelRequestPolicy(ThinkingResolution(value.thinking.requested, value.thinking.effective,
            value.thinking.mode, budgetTokens: value.thinking.budgetTokens, adaptiveEffort: value.thinking.adaptiveEffort,
            constraints: constraints159(value.thinking.constraints)),
            OutputLimitResolution(value.output.requestedHardLimit, value.output.effectiveWireLimit,
                constraints: constraints159(value.output.constraints)),
            policyResolutionVersion: value.policyResolutionVersion, capabilitySnapshotVersion: value.capabilitySnapshotVersion,
            capabilityFingerprint: text159(value.capabilityFingerprint), capabilitySnapshotPayload: text159(value.capabilitySnapshotPayload),
            minVisibleResponseTokens: value.minVisibleResponseTokens, thinkingSource: value.thinkingSource,
            userRequestedThinking: value.userRequestedThinking)
    }
    func request159(source: ModelRequest): ModelRequest {
        add159(source.messages.size, factor: 1024); add159(source.tools.size, factor: 2048)
        let messages = ArrayList<ModelMessage>()
        for (message in source.messages) {
            add159(message.blocks.size, factor: 2048)
            let blocks = ArrayList<ModelBlock>()
            for (block in message.blocks) {
                let image = match (block.image) { case Some(value) =>
                    Some(ModelImage(value.sourceKind, text159(value.data), mediaType: text159(value.mediaType), detail: value.detail))
                    case None => None<ModelImage> }
                let opaque = match (block.opaqueState) { case Some(value) =>
                    Some(OpaqueProviderState(text159(value.providerId), text159(value.protocol), text159(value.payload),
                        itemId: text159(value.itemId), replayRequired: value.replayRequired))
                    case None => None<OpaqueProviderState> }
                blocks.add(ModelBlock(block.kind, text: text159(block.text), callId: text159(block.callId),
                    name: text159(block.name), arguments: value159(block.arguments), isError: block.isError,
                    image: image, receiptId: text159(block.receiptId), opaqueState: opaque))
            }
            messages.add(ModelMessage(message.role, blocks.toArray()))
        }
        let tools = ArrayList<ModelToolDefinition>()
        for (tool in source.tools) { tools.add(ModelToolDefinition(text159(tool.name), text159(tool.description), value159(tool.inputSchema))) }
        let structured = match (source.structuredOutput) { case Some(value) =>
            Some(StructuredOutputSpec(text159(value.name), value159(value.schema), description: text159(value.description), strict: value.strict))
            case None => None<StructuredOutputSpec> }
        let policy = match (source.resolvedPolicy) { case Some(value) => Some(policy159(value))
            case None => None<ResolvedModelRequestPolicy> }
        ModelRequest(text159(source.model), messages.toArray(), system: text159(source.system), tools: tools.toArray(),
            thinking: source.thinking, maxOutputTokens: source.maxOutputTokens, wireMaxOutputTokens: Some(source.wireMaxOutputTokens),
            resolvedPolicy: policy, streaming: source.streaming, parallelToolCalls: source.parallelToolCalls,
            requestId: text159(source.requestId), serviceTier: text159(source.serviceTier), cachePolicy: source.cachePolicy,
            toolChoice: source.toolChoice, structuredOutput: structured, cacheKey: text159(source.cacheKey),
            transportHardTimeoutMillis: source.transportHardTimeoutMillis)
    }
}

private class FixtureJsonCopyFrame159 {
    var source: ?AgentValue
    var target: ?AgentValue
    var previous: ?FixtureJsonCopyFrame159
    var index: Int64 = 0
    init(source: AgentValue, target: AgentValue, previous: ?FixtureJsonCopyFrame159) {
        this.source = Some(source); this.target = Some(target); this.previous = previous
    }
}

func copyFixtureRequest159(request: ModelRequest, funding: ModelInputDataBudget159): FixtureRequestSnapshot159 {
    // The actual input owner already exposes an independent DATA allocation
    // lease in its original bank/slot. This cache is not another transport
    // message: all concurrent copied fields/active leases add to that SAME
    // allocation sum and retire through their own real consumer frames.
    let payment = try { funding.reserveRetainedModelMetadata159(65536) }
        catch (_: LogicalJsonPayloadError) { throw FixtureRequestCapacity159() }
    let owner = FixtureRequestSnapshot159(payment)
    try { owner.install159(FixtureRequestCopy159(payment).request159(request)); owner }
    catch (error: FixtureRequestCapacity159) {
        // The complete private clone helper unwound without publishing its
        // partial fields. No cache/export/execute/observer frame saw them.
        owner.retireUnexported159(); throw error
    }
    catch (error: Exception) { owner.holdUnknown159(); throw error }
}

func prepareFixtureInput159(request: ModelRequest, funding: ModelInputDataBudget159):
    (FixtureRequestSnapshot159, FixtureRequestObservation159) {
    let copied = copyFixtureRequest159(request, funding)
    try { (copied, copied.beginObservation159()) }
    catch (_: LogicalJsonPayloadError) {
        // The active lease was refused before this copy was installed or its
        // source input executed. beginObservation already closed that lease.
        copied.retireUnexported159(); throw FixtureRequestCapacity159()
    }
    catch (error: Exception) { copied.holdUnknown159(); throw error }
}

class FixtureRequestSnapshot159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var request: ?ModelRequest = None<ModelRequest>
    private var exported = false
    private var held = false
    private var retiring = false
    private var observers: Int64 = 0
    var next159: ?FixtureRequestSnapshot159 = None<FixtureRequestSnapshot159>
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment); fixtureRequestDebts159.retain159(this) }
    func install159(value: ModelRequest): Unit { lock.lock(); try { request = Some(value) } finally { lock.unlock() } }
    func holdUnknown159(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    func export159(): ModelRequest {
        lock.lock(); try { exported = true; request.getOrThrow() } finally { lock.unlock() }
    }
    func systemContains159(value: String): Bool {
        lock.lock(); try { request.getOrThrow().system.contains(value) } finally { lock.unlock() }
    }
    func firstMessageTextStartsWith159(value: String): Bool {
        lock.lock(); try {
            let messages = request.getOrThrow().messages
            !messages.isEmpty() && !messages[0].blocks.isEmpty() && messages[0].blocks[0].text.startsWith(value)
        } finally { lock.unlock() }
    }
    func hasTool159(value: String, only: Bool): Bool {
        lock.lock(); try {
            var found = false
            for (tool in request.getOrThrow().tools) {
                if (tool.name == value) { found = true } else if (only) { return false }
            }
            found
        } finally { lock.unlock() }
    }
    func beginObservation159(): FixtureRequestObservation159 {
        lock.lock(); try {
            if (request.isNone() || payment.isNone() || retiring || observers == Int64.Max) {
                throw IllegalStateException("fixture request observation has retired") }
            let own = payment.getOrThrow().deriveRetainedLease()
            try { own.ensureRetainedPeak(4096) } catch (error: Exception) { own.close(); throw error }
            observers++; FixtureRequestObservation159(this, own)
        } finally { lock.unlock() }
    }
    func observationReturned159(): Unit {
        lock.lock(); try { observers-- } finally { lock.unlock() }
        collect159()
    }
    func retireUnexported159(): Unit {
        lock.lock(); try { retiring = true } finally { lock.unlock() }
        collect159()
    }
    private func collect159(): Unit {
        let paid = clearReturnedSnapshotFrame159()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func clearReturnedSnapshotFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (!retiring || exported || held || observers != 0 || payment.isNone()) { return None<LogicalJsonOwnerReservation> }
            request = None<ModelRequest>; let own = payment; payment = None<LogicalJsonOwnerReservation>
            fixtureRequestDebts159.remove159(this); own
        } finally { lock.unlock() }
    }
}

// A revocable, scalar-only observation. No request/String/DOM getter escapes.
// Holding this object after its whole callback returns retains no DATA alias.
public class FixtureRequestObservation159 {
    private let lock = Mutex()
    private var owner: ?FixtureRequestSnapshot159
    private var payment: ?LogicalJsonOwnerReservation
    init(owner: FixtureRequestSnapshot159, payment: LogicalJsonOwnerReservation) { this.owner = Some(owner); this.payment = Some(payment) }
    public func hasRequest159(): Bool { lock.lock(); try { owner.isSome() } finally { lock.unlock() } }
    public func systemContains159(value: String): Bool {
        lock.lock(); try { match (owner) { case Some(actual) => actual.systemContains159(value); case None => false } }
        finally { lock.unlock() }
    }
    public func firstMessageTextStartsWith159(value: String): Bool {
        lock.lock(); try { match (owner) {
            case Some(actual) => actual.firstMessageTextStartsWith159(value); case None => false }
        } finally { lock.unlock() }
    }
    public func hasTool159(value: String): Bool {
        lock.lock(); try { match (owner) { case Some(actual) => actual.hasTool159(value, false); case None => false } }
        finally { lock.unlock() }
    }
    public func hasOnlyTool159(value: String): Bool {
        lock.lock(); try { match (owner) { case Some(actual) => actual.hasTool159(value, true); case None => false } }
        finally { lock.unlock() }
    }
    func returnFrame159(): Unit {
        let actual = clearObservationFrame159()
        match (actual[0]) { case Some(value) => value.observationReturned159(); case None => () }
        match (actual[1]) { case Some(value) => value.close(); case None => () }
    }
    private func clearObservationFrame159(): (?FixtureRequestSnapshot159, ?LogicalJsonOwnerReservation) {
        lock.lock(); try {
            let source = owner; let own = payment
            owner = None<FixtureRequestSnapshot159>; payment = None<LogicalJsonOwnerReservation>
            (source, own)
        } finally { lock.unlock() }
    }
}

private class FixtureRequestDebts159 {
    private let lock = Mutex()
    private var head: ?FixtureRequestSnapshot159 = None<FixtureRequestSnapshot159>
    func retain159(value: FixtureRequestSnapshot159): Unit {
        lock.lock(); try { value.next159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: FixtureRequestSnapshot159): Unit {
        lock.lock(); try {
            var previous: ?FixtureRequestSnapshot159 = None<FixtureRequestSnapshot159>; var cursor = head
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(prior) => prior.next159 = actual.next159; case None => head = actual.next159 }
                    actual.next159 = None<FixtureRequestSnapshot159>; return
                }
                previous = cursor; cursor = actual.next159
            }
        } finally { lock.unlock() }
    }
}
