package tool_runtime

import agent_domain.*
import std.sync.*

// DATA-only immutable identity fields. This is neither a descriptor nor an
// executor/permission/registration or an approval authority.
public class ToolCatalogIdentity204 {
    public let name: String
    public let version: String
    public let fingerprint: String
    public let schemaDigest: String
    public init(name: String, version: String, fingerprint: String, schemaDigest: String) {
        this.name = name; this.version = version
        this.fingerprint = fingerprint; this.schemaDigest = schemaDigest
    }
}
private let catalogIdentityDebts204 = CatalogIdentityDebts204()

public class ToolCatalogIdentityOwner204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var identities: ?Array<ToolCatalogIdentity204> = None<Array<ToolCatalogIdentity204>>
    private var producerReturned = false
    private var callerReturned = false
    private var consumers: Int64 = 0
    private var held = false
    var next204: ?ToolCatalogIdentityOwner204 = None<ToolCatalogIdentityOwner204>
    public init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); catalogIdentityDebts204.retain204(this)
    }
    func installFrame204(entries: Array<ToolCatalogIdentity204>): Unit {
        lock.lock(); try {
            if (producerReturned || identities.isSome() || payment.isNone()) {
                throw IllegalStateException("catalog identity producer already installed") }
            identities = Some(entries)
        } finally { lock.unlock() }
    }
    func producerFrameReturned204(): Unit {
        lock.lock(); try {
            if (producerReturned || identities.isNone() || payment.isNone()) {
                throw IllegalStateException("catalog identity producer has not installed its data") }
            producerReturned = true
        } finally { lock.unlock() }
    }
    public func deriveRetainedAllocation204(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (!producerReturned || callerReturned || held || payment.isNone()) {
                throw IllegalStateException("catalog identity data is unavailable") }
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(invoice); child }
            catch (error: Exception) { child.close(); throw error }
        } finally { lock.unlock() }
    }
    public func beginConsumer204(): ToolCatalogIdentityConsumer204 {
        lock.lock(); try {
            if (!producerReturned || callerReturned || held || identities.isNone() ||
                payment.isNone() || consumers == Int64.Max) {
                throw IllegalStateException("catalog identity consumer cannot be admitted") }
            let metadata = payment.getOrThrow().deriveRetainedLease()
            try {
                metadata.ensureRetainedPeak(4096)
                let consumer = ToolCatalogIdentityConsumer204(this, metadata)
                consumers++; consumer
            } catch (error: Exception) { metadata.close(); throw error }
        } finally { lock.unlock() }
    }
    func borrowFrame204(): Array<ToolCatalogIdentity204> {
        lock.lock(); try {
            if (!producerReturned || held || consumers < 1 || identities.isNone()) {
                throw IllegalStateException("catalog identity loan is unavailable") }
            identities.getOrThrow()
        } finally { lock.unlock() }
    }
    func holdUnknown204(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    public func closeAfterCaller204(): Unit {
        let returned = closeCallerFrame204()
        match (returned) { case Some(value) => value.close(); case None => () }
    }
    private func closeCallerFrame204(): ?LogicalJsonOwnerReservation {
        lock.lock(); try { callerReturned = true; detach204() } finally { lock.unlock() }
    }
    func returnedConsumer204(): ?LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (consumers < 1) { throw IllegalStateException("catalog identity consumer count underflow") }
            consumers--; detach204()
        } finally { lock.unlock() }
    }
    private func detach204(): ?LogicalJsonOwnerReservation {
        if (!producerReturned || !callerReturned || held || consumers != 0 || payment.isNone()) {
            return None<LogicalJsonOwnerReservation> }
        identities = None<Array<ToolCatalogIdentity204>>
        let returned = payment; payment = None<LogicalJsonOwnerReservation>
        catalogIdentityDebts204.remove204(this)
        returned
    }
}

public class ToolCatalogIdentityConsumer204 {
    private let lock = Mutex()
    private var owner: ?ToolCatalogIdentityOwner204
    private var payment: ?LogicalJsonOwnerReservation
    private var borrowing = false
    private var held = false
    init(owner: ToolCatalogIdentityOwner204, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.payment = Some(payment)
    }
    // Trusted closed frame. The result may retain only independently prepaid
    // copies; no entry/String/array alias may escape the actual borrowed body.
    public func withIdentities204<T>(body: (Array<ToolCatalogIdentity204>) -> T): T {
        let source = beginBorrow204()
        let answer = try { consumeIdentityFrame204(source, body) }
        catch (error: Exception) {
            source.holdUnknown204()
            lock.lock(); try { held = true; borrowing = false } finally { lock.unlock() }
            throw error
        }
        lock.lock(); try { borrowing = false } finally { lock.unlock() }
        answer
    }
    private func beginBorrow204(): ToolCatalogIdentityOwner204 {
        lock.lock(); try {
            if (borrowing || held || owner.isNone()) { throw IllegalStateException("catalog identity consumer already borrowed") }
            borrowing = true; owner.getOrThrow()
        } finally { lock.unlock() }
    }
    private func consumeIdentityFrame204<T>(source: ToolCatalogIdentityOwner204,
        body: (Array<ToolCatalogIdentity204>) -> T): T { body(source.borrowFrame204()) }
    public func returnConsumerFrame204(): Unit {
        let detached = detachConsumerFrame204()
        let parent = detached[0].returnedConsumer204()
        detached[1].close()
        match (parent) { case Some(value) => value.close(); case None => () }
    }
    private func detachConsumerFrame204(): (ToolCatalogIdentityOwner204, LogicalJsonOwnerReservation) {
        lock.lock(); try {
            if (borrowing || held || owner.isNone() || payment.isNone()) {
                throw IllegalStateException("catalog identity consumer has not returned") }
            let source = owner.getOrThrow(); let metadata = payment.getOrThrow()
            owner = None<ToolCatalogIdentityOwner204>; payment = None<LogicalJsonOwnerReservation>
            (source, metadata)
        } finally { lock.unlock() }
    }
}
private class CatalogIdentityDebts204 {
    let lock = Mutex()
    var head: ?ToolCatalogIdentityOwner204 = None<ToolCatalogIdentityOwner204>
    func retain204(value: ToolCatalogIdentityOwner204): Unit {
        lock.lock(); try { value.next204 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: ToolCatalogIdentityOwner204): Unit {
        lock.lock(); try {
            var previous: ?ToolCatalogIdentityOwner204 = None<ToolCatalogIdentityOwner204>
            var current = head
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(parent) => parent.next204 = actual.next204; case None => head = actual.next204 }
                    actual.next204 = None<ToolCatalogIdentityOwner204>; return
                }
                previous = current; current = actual.next204
            }
        } finally { lock.unlock() }
    }
}
