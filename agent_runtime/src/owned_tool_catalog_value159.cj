package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let ownedToolCatalogValues159 = OwnedToolCatalogValues159()

// A DATA loan, not a Tool invocation, Source, permission or callback receipt.
// Runtime exposes no raw catalog getter. ContextCompiler alone materializes
// the borrowed DOM. A consumer must retain this loan while any returned
// manifest or serializer frame can still reference that DOM/schema graph.
public class OwnedToolCatalogValue159 {
    private let lock = Mutex()
    private var loan: ?SharedToolSnapshotLoan159
    private var value: ?AgentValue = None<AgentValue>
    private var closed = false
    var next159: ?OwnedToolCatalogValue159 = None<OwnedToolCatalogValue159>
    init(loan: SharedToolSnapshotLoan159) {
        this.loan = Some(loan)
        ownedToolCatalogValues159.retain159(this)
    }
    func materialize159(): AgentValue {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("catalog compiler loan is retired") }
            if (value.isNone()) { value = Some(loan.getOrThrow().manifestCatalogValue159()) }
            value.getOrThrow()
        } finally { lock.unlock() }
    }
    // The production caller invokes this only after its whole private
    // compiler/save/recordContextReady helper returned Result.Ok. Failure and
    // unknown consumer paths leave the globally registered loan charged.
    public func closeAfterManifestStoreFrame159(): Unit {
        let payments = clearReturnedFrame159()
        modelLaneReturnedPayments159(payments)
    }
    private func clearReturnedFrame159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (closed) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            value = None<AgentValue>
            let payments = loan.getOrThrow().clear159()
            loan = None<SharedToolSnapshotLoan159>; closed = true
            ownedToolCatalogValues159.remove159(this)
            payments
        } finally { lock.unlock() }
    }
}
private class OwnedToolCatalogValues159 {
    private let lock = Mutex()
    private var first: ?OwnedToolCatalogValue159 = None<OwnedToolCatalogValue159>
    func retain159(value: OwnedToolCatalogValue159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedToolCatalogValue159): Unit {
        lock.lock()
        try {
            var prior: ?OwnedToolCatalogValue159 = None<OwnedToolCatalogValue159>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(parent) => parent.next159 = current.next159; case None => first = current.next159 }
                    current.next159 = None<OwnedToolCatalogValue159>; return
                }
                prior = cursor; cursor = current.next159
            }
        } finally { lock.unlock() }
    }
}
