package agent_runtime

import agent_domain.*
import std.collection.*
import std.sync.*

// Data delivery only. This does not admit a Source, effect, or Receipt.
// Each concrete observer must clear its extracted DOM/frame references and
// explicitly acknowledge the actual alias it received. Returning from emit
// alone is not an acknowledgement.
public interface OwnedAgentEventSink {
    func emit(event: OwnedAgentEvent): Result<Unit>
}

public interface OwnedAgentEventSource {
    func ownedEventSink(): OwnedAgentEventSink
}

public interface OwnedRunEventRepository {
    // Consumes a real event alias into a complete fixed-buffer private spool.
    // No complete canonical DOM alias survives in the returned write owner.
    func stageOwned(event: OwnedAgentEvent): Result<OwnedRunEventWrite>
}

public interface OwnedRunEventWrite {
    // Requires the actual private canonical state to have retired every row
    // alias, before paying for SQLite's complete TEXT input and record copies.
    func appendAfterSourceAliasRetirement(): Result<Unit>
    // Failed IO remains under this real owner until physical close/removal
    // succeeds. Callback return, rollback request and GC are never close ACKs.
    func closeAfterStorageRetirement(): Result<Unit>
    func isAcknowledged(): Bool
}

public class CallbackOwnedAgentEventSink <: OwnedAgentEventSink {
    private let consume: (OwnedAgentEvent) -> Result<Unit>
    public init(consume: (OwnedAgentEvent) -> Result<Unit>) { this.consume = consume }
    public func emit(event: OwnedAgentEvent): Result<Unit> { consume(event) }
}

// The factory captures only bounded event metadata. The complete output is
// obtained from the actual canonical row during a paid borrow, never captured
// from an old ToolResult or substituted with a digest/preview.
public class OwnedAgentEvent {
    private let lock = Mutex()
    private let metadataPeak: Int64
    private var meta: ?EventMeta
    private var payload: ?((ThreadItem) -> AgentEventPayload)
    private var held: ?OwnedCanonicalThreadItemAliasCustody
    private let failedAliases = ArrayList<OwnedCanonicalThreadItemAliasCustody>()
    private var borrowing = false
    private var closing = false
    private var closed = false

    public init(meta: EventMeta, payload: (ThreadItem) -> AgentEventPayload,
        held: OwnedCanonicalThreadItemAliasCustody) {
        let bytes = ownedEventMetadataBytes(meta)
        if (bytes > (Int64.Max - 32768) / 4) { throw IllegalStateException("event metadata invoice overflow") }
        let peak = 32768 + bytes * 4
        match (held.ensureAdditionalRetainedPeak(peak)) {
            case Result.Err(error) => throw IllegalStateException(error.code)
            case Result.Ok(_) => () }
        this.metadataPeak = peak
        this.meta = Some(meta); this.payload = Some(payload); this.held = Some(held)
    }

    public func fanout(): Result<OwnedAgentEvent> {
        lock.lock()
        try {
            if (closed || closing) { return ownedCanonicalDataError("event.alias_closed") }
            match (held.getOrThrow().retainAliasCustody()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(alias) =>
                    try { Result.Ok(OwnedAgentEvent(meta.getOrThrow(), payload.getOrThrow(), alias)) }
                    catch (_: Exception) {
                        // Another real borrow may prevent immediate close.
                        // Keep the actual child, so pressure never loses its
                        // paid alias merely because wrapper construction fails.
                        match (alias.closeAfterAliasRetirement()) {
                            case Result.Err(_) => failedAliases.add(alias)
                            case Result.Ok(_) => () }
                        ownedCanonicalDataError("event.alias_pressure") }
            }
        } finally { lock.unlock() }
    }

    public func ensureAdditionalRetainedPeak(additional: Int64): Result<Unit> {
        lock.lock()
        try {
            if (closed || closing || additional < 0 || additional > Int64.Max - metadataPeak) {
                return ownedCanonicalDataError("event.payment_unavailable") }
            held.getOrThrow().ensureAdditionalRetainedPeak(metadataPeak + additional)
        } finally { lock.unlock() }
    }

    public func retirementWitness(): Result<OwnedCanonicalThreadItemRetirementWitness> {
        lock.lock()
        try {
            if (closed || closing) { return ownedCanonicalDataError("event.alias_closed") }
            held.getOrThrow().retirementWitness()
        } finally { lock.unlock() }
    }

    public func acquireCopiedDisplayAllocation(totalInvoice: Int64): Result<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (closed || closing) { return ownedCanonicalDataError("event.alias_closed") }
            held.getOrThrow().acquireCopiedDisplayAllocation(totalInvoice)
        } finally { lock.unlock() }
    }
    public func deriveRetainedAllocation(additional: Int64): Result<LogicalJsonOwnerReservation> {
        lock.lock()
        try {
            if (closed || closing || additional < 0 || additional > Int64.Max - 32768) {
                return ownedCanonicalDataError("event.payment_unavailable") }
            held.getOrThrow().deriveRetainedAllocation(32768 + additional)
        } finally { lock.unlock() }
    }

    public func withEvent(additional: Int64, consume: (AgentEvent) -> Result<Unit>): Result<Unit> {
        lock.lock()
        var selected: ?OwnedCanonicalThreadItemAliasCustody = None
        var selectedMeta: ?EventMeta = None
        var selectedPayload: ?((ThreadItem) -> AgentEventPayload) = None
        try {
            if (closed || closing || borrowing || additional < 0 || additional > Int64.Max - metadataPeak) {
                return ownedCanonicalDataError("event.borrow_unavailable") }
            borrowing = true; selected = held; selectedMeta = meta; selectedPayload = payload
        } finally { lock.unlock() }
        let borrow = OwnedAgentEventBorrow(selectedMeta.getOrThrow(), selectedPayload.getOrThrow(), consume)
        try {
            selected.getOrThrow().withPaidItem(metadataPeak + additional, { item => borrow.consume(item) })
        } finally {
            borrow.clear(); selected = None; selectedMeta = None; selectedPayload = None
            lock.lock(); try { borrowing = false } finally { lock.unlock() }
        }
    }

    public func closeAfterEventRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            if (borrowing) { return ownedCanonicalDataError("event.borrow_pending") }
            closing = true
            while (!failedAliases.isEmpty()) {
                match (failedAliases[0].closeAfterAliasRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => failedAliases.remove(at: 0) }
            }
            // Concrete observers have already cleared their own references.
            // Drop this wrapper's captured metadata/factory before real ACK.
            closing = true; meta = None; payload = None
            match (held.getOrThrow().closeAfterAliasRetirement()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => held = None; closed = true; Result.Ok(()) }
        } finally { lock.unlock() }
    }

    public func isAcknowledged(): Bool {
        lock.lock(); try { closed } finally { lock.unlock() }
    }
}

private func ownedEventMetadataBytes(meta: EventMeta): Int64 {
    var bytes: Int64 = 0
    // Every metadata alias captured by the event is invoiced, including IDs
    // that the historic durable event codec does not serialize.
    bytes = ownedEventAddMetadata(bytes, meta.runId.value.size)
    bytes = ownedEventAddMetadata(bytes, meta.traceId.value.size)
    match (meta.turnId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.requestId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.semanticRequestId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.attemptId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.toolBatchId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.toolCallId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    match (meta.operationId) { case Some(value) => bytes = ownedEventAddMetadata(bytes, value.value.size); case None => () }
    bytes
}
private func ownedEventAddMetadata(previous: Int64, extent: Int64): Int64 {
    if (extent < 0 || extent > Int64.Max - previous) { throw IllegalStateException("event metadata invoice overflow") }
    previous + extent
}

// Immutable closure holder, with mutable fields that are actually retired.
// No immutable large event alias is introduced merely to satisfy capture.
private class OwnedAgentEventBorrow {
    private var meta: ?EventMeta
    private var payload: ?((ThreadItem) -> AgentEventPayload)
    private var target: ?((AgentEvent) -> Result<Unit>)
    private var event: ?AgentEvent = None
    init(meta: EventMeta, payload: (ThreadItem) -> AgentEventPayload, target: (AgentEvent) -> Result<Unit>) {
        this.meta = Some(meta); this.payload = Some(payload); this.target = Some(target)
    }
    func consume(item: ThreadItem): Result<Unit> {
        try {
            event = Some(AgentEvent(meta.getOrThrow(), payload.getOrThrow()(item)))
            target.getOrThrow()(event.getOrThrow())
        } finally { event = None }
    }
    func clear(): Unit { event = None; target = None; payload = None; meta = None }
}

public interface OwnedAgentEventFrameSink {
    func write(frame: OwnedAgentEventFrame): Result<Unit>
}

// A queued transport owns its full encoded bytes and the SAME canonical-row
// alias until its actual writer/queue consumer clears them and closes this.
// A naked (String)->Unit transport is not treated as an owned ACK.
public class OwnedAgentEventFrame {
    private let lock = Mutex()
    private var value: ?String
    private var event: ?OwnedAgentEvent
    private var borrowing = false
    private var closing = false
    private var closed = false
    public init(value: String, event: OwnedAgentEvent) { this.value = Some(value); this.event = Some(event) }
    public func withFrame(consume: (String) -> Result<Unit>): Result<Unit> {
        lock.lock()
        var selected: ?String = None
        try {
            if (closed || closing || borrowing) { return ownedCanonicalDataError("event.frame_closed") }
            borrowing = true; selected = value
        } finally { lock.unlock() }
        try { consume(selected.getOrThrow()) }
        finally {
            selected = None
            lock.lock(); try { borrowing = false } finally { lock.unlock() }
        }
    }
    public func closeAfterFrameRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            if (borrowing) { return ownedCanonicalDataError("event.frame_borrow_pending") }
            closing = true; value = None
            match (event.getOrThrow().closeAfterEventRetirement()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => event = None; closed = true; Result.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}
