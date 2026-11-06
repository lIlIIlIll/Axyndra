package agent_runtime

import agent_domain.*
import std.sync.*

private let ownedSnapshotIdentities159 = OwnedSnapshotIdentities159()

// Independently copied DATA only. This text is not a Source, grant or catalog.
// A borrowed callback return alone cannot retire it; the concrete consumer
// must first let its complete copying helper return with no text aliases.
public class OwnedToolSnapshotIdentity159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var text: ?String = None<String>
    private var producerReturned = false
    private var borrowers: Int64 = 0
    private var held = false
    var next159: ?OwnedToolSnapshotIdentity159 = None<OwnedToolSnapshotIdentity159>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); ownedSnapshotIdentities159.add159(this)
    }
    func install159(value: String): Unit { text = Some(String.fromUtf8(value.toArray())) }
    func producerReturned159(): Unit { producerReturned = true }
    public func withText159<T>(body: (String) -> T): T {
        let actual = try { lock.lock()
            if (!producerReturned || payment.isNone() || borrowers == Int64.Max) {
                throw IllegalStateException("snapshot identity DATA is unavailable") }
            borrowers++; text.getOrThrow()
        } finally { lock.unlock() }
        try { body(actual) }
        catch (error: Exception) { retainHistorical159(); throw error }
        finally { lock.lock(); try { borrowers-- } finally { lock.unlock() } }
    }
    public func retainHistorical159(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    public func returnCopiedFrame159(): Unit {
        let paid = try { lock.lock()
            if (!producerReturned || borrowers != 0) { throw IllegalStateException("snapshot identity consumer has not returned") }
            if (held || payment.isNone()) { None<LogicalJsonOwnerReservation> }
            else { text = None<String>; let actual = payment; payment = None<LogicalJsonOwnerReservation>; actual }
        } finally { lock.unlock() }
        match (paid) { case Some(value) => ownedSnapshotIdentities159.remove159(this); value.close(); case None => () }
    }
}
private class OwnedSnapshotIdentities159 {
    private let lock = Mutex()
    private var first: ?OwnedToolSnapshotIdentity159 = None<OwnedToolSnapshotIdentity159>
    func add159(value: OwnedToolSnapshotIdentity159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedToolSnapshotIdentity159): Unit {
        lock.lock(); try {
            var previous: ?OwnedToolSnapshotIdentity159 = None<OwnedToolSnapshotIdentity159>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(parent) => parent.next159 = current.next159; case None => first = current.next159 }
                    current.next159 = None<OwnedToolSnapshotIdentity159>; return
                }
                previous = cursor; cursor = current.next159
            }
            throw IllegalStateException("actual snapshot identity DATA debt is missing")
        } finally { lock.unlock() }
    }
}
