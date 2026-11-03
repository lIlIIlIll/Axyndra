package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let ownedToolSetSnapshots159 = OwnedToolSetSnapshots159()

// No public raw borrow callback: callback return cannot prove escaped-alias
// retirement. The only retiring consumer is this closed scalar comparison.
// Public/historical export marks the original share Held before returning it.
public class OwnedToolSetSnapshot159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var snapshot: ?ToolSetSnapshot = Option<ToolSetSnapshot>.None
    private var producerReturned = false
    private var held = false
    private var comparisonPending = false
    var next159: ?OwnedToolSetSnapshot159 = Option<OwnedToolSetSnapshot159>.None
    public init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment)
        ownedToolSetSnapshots159.retain159(this)
    }
    public func installSnapshot159(value: ToolSetSnapshot): Unit {
        lock.lock()
        try {
            if (producerReturned || snapshot.isSome() || payment.isNone()) {
                throw IllegalStateException("tool snapshot producer is already installed")
            }
            snapshot = Some(value)
        } finally { lock.unlock() }
    }
    public func returnedSnapshotProducer159(): Unit {
        lock.lock()
        try {
            if (snapshot.isNone() || payment.isNone()) {
                throw IllegalStateException("tool snapshot producer has not installed its data")
            }
            producerReturned = true
        } finally { lock.unlock() }
    }
    // Transfer only private DATA after the complete catalog producer returned.
    // The new state is registered before the original holder clears any field.
    public func transferSharedSnapshot159(): SharedToolSetSnapshot159 {
        let result = transferSharedSnapshotFrame159()
        ownedToolSetSnapshots159.remove159(this)
        result
    }
    private func transferSharedSnapshotFrame159(): SharedToolSetSnapshot159 {
        lock.lock()
        try {
            if (!producerReturned || comparisonPending || held || payment.isNone() || snapshot.isNone()) {
                throw IllegalStateException("snapshot cannot transfer from an active or historical producer")
            }
            let metadata = sharedSnapshotPhase159(payment.getOrThrow(), 8192)
            let state = SharedToolSnapshotState159(snapshot.getOrThrow(), payment.getOrThrow(), metadata)
            let result = state.newShare159()
            snapshot = Option<ToolSetSnapshot>.None
            payment = Option<LogicalJsonOwnerReservation>.None
            producerReturned = false
            result
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    public func matchesSharedContent159(expected: SharedToolSetSnapshot159): Bool {
        lock.lock()
        try {
            if (!producerReturned || held || payment.isNone() || snapshot.isNone()) {
                throw IllegalStateException("tool snapshot producer has not returned")
            }
            // The final closed scalar helper returns no snapshot/entry alias.
            expected.contentEquals159(snapshot.getOrThrow())
        } finally { lock.unlock() }
    }
    public func identifyCatalogCut159(run: RunId): Unit {
        lock.lock()
        try {
            if (!producerReturned || held || comparisonPending || payment.isNone() || snapshot.isNone()) {
                throw IllegalStateException("tool snapshot producer cannot be reidentified")
            }
            let meter = ToolSnapshotMeasure159(payment.getOrThrow())
            meter.addSnapshot159(snapshot.getOrThrow()); meter.addText159(run.value)
            meter.addText159("catalog-0000000000000000000000000000000000000000000000000000000000000000")
            meter.fund159()
            identifyCatalogCutFrame159(run)
        } finally { lock.unlock() }
    }
    private func identifyCatalogCutFrame159(run: RunId): Unit {
        let original = snapshot.getOrThrow()
        let digest = toolSetSnapshotContentDigest(original)
        snapshot = Some(ToolSetSnapshot("catalog-" + run.value + "-" + digest,
            original.entries, hookHandlers: original.hookHandlers, threadId: original.threadId))
    }
    public func matchesContent159(expected: ToolSetSnapshot): Bool {
        lock.lock()
        try {
            if (!producerReturned || comparisonPending || payment.isNone() || snapshot.isNone()) {
                throw IllegalStateException("tool snapshot data is unavailable")
            }
            // Measure both real inputs before the original full digest codec.
            // No user callback, array, String or schema leaves this helper.
            comparisonPending = true
            ownedToolSnapshotCompareFrame159(snapshot.getOrThrow(), expected, payment.getOrThrow())
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    // Called only by the closed consumer AFTER matchesContent159 returned.
    // The comparison's receiver and its private digest/meter frames are gone.
    public func returnedComparisonHelper159(): Unit {
        lock.lock()
        try {
            if (!comparisonPending || held) {
                throw IllegalStateException("tool snapshot comparison has not returned normally")
            }
            comparisonPending = false
        } finally { lock.unlock() }
    }
    public func exportHistoricalSnapshot159(): ToolSetSnapshot {
        lock.lock()
        try {
            if (!producerReturned || snapshot.isNone() || payment.isNone()) {
                throw IllegalStateException("tool snapshot producer has not returned")
            }
            held = true
            snapshot.getOrThrow()
        } finally { lock.unlock() }
    }
    // No refund here. Caller first lets its entire comparison helper return,
    // detaches, clears its carrier reference, and then closes only this lease.
    public func detachReturnedSnapshot159(): ?LogicalJsonOwnerReservation {
        let value = clearReturnedSnapshot159()
        if (value.isSome()) { ownedToolSetSnapshots159.remove159(this) }
        value
    }
    private func clearReturnedSnapshot159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (!producerReturned || comparisonPending || held || payment.isNone()) { return Option<LogicalJsonOwnerReservation>.None }
            snapshot = Option<ToolSetSnapshot>.None
            let value = payment; payment = Option<LogicalJsonOwnerReservation>.None
            value
        } finally { lock.unlock() }
    }
}
private func ownedToolSnapshotCompareFrame159(actual: ToolSetSnapshot, expected: ToolSetSnapshot,
    payment: LogicalJsonOwnerReservation): Bool {
    let meter = ToolSnapshotMeasure159(payment)
    meter.addSnapshot159(actual); meter.addSnapshot159(expected); meter.fund159()
    toolSetSnapshotContentDigest(actual) == toolSetSnapshotContentDigest(expected)
}
private class OwnedToolSetSnapshots159 {
    private let lock = Mutex()
    private var first: ?OwnedToolSetSnapshot159 = Option<OwnedToolSetSnapshot159>.None
    func retain159(value: OwnedToolSetSnapshot159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedToolSetSnapshot159): Unit {
        lock.lock()
        try {
            var previous: ?OwnedToolSetSnapshot159 = Option<OwnedToolSetSnapshot159>.None
            var current = first
            while (current.isSome()) {
                let entry = current.getOrThrow()
                if (refEq(entry, value)) {
                    match (previous) {
                        case Some(parent) => parent.next159 = entry.next159
                        case None => first = entry.next159
                    }
                    entry.next159 = Option<OwnedToolSetSnapshot159>.None
                    return
                }
                previous = current; current = entry.next159
            }
        } finally { lock.unlock() }
    }
}
