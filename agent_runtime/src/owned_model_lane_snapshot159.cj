package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let ownedModelLaneSnapshots159 = OwnedModelLaneSnapshots159()

// The production SQLite adapter implements this additional DATA contract.
// Neither an ordinary Result.Ok nor callback/Unit return is a receipt. An
// unknown legacy commit sink keeps the complete snapshot loan charged.
public interface ReturningModelLaneCommitSink159 {
    func commitModelLane159(transition: ThreadTransition, input: OwnedModelLaneSnapshot159): Result<Unit>
}

public class OwnedModelLaneSnapshot159 {
    private let lock = Mutex()
    private var loan: ?SharedToolSnapshotLoan159
    private var value: ?AgentValue = None<AgentValue>
    private var sqlReturned = false
    private var closed = false
    var next159: ?OwnedModelLaneSnapshot159 = None<OwnedModelLaneSnapshot159>
    init(loan: SharedToolSnapshotLoan159) {
        this.loan = Some(loan)
        ownedModelLaneSnapshots159.retain159(this)
    }
    func install159(lane: ModelLane): Unit {
        lock.lock()
        try {
            if (value.isSome() || closed) { throw IllegalStateException("model lane loan was already installed") }
            value = Some(loan.getOrThrow().modelLaneValue159(lane))
        } finally { lock.unlock() }
    }
    func reserveCopy159(): Unit {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("model lane copy phase has returned") }
            loan.getOrThrow().reserveLaneCopy159(value.getOrThrow())
        } finally { lock.unlock() }
    }
    func reserveClosedValue159(value: AgentValue): Unit {
        lock.lock()
        try {
            if (closed) { throw IllegalStateException("model lane closed comparison has returned") }
            loan.getOrThrow().reserveLaneCopy159(value)
        } finally { lock.unlock() }
    }
    // Package-private, used only by the closed ThreadCoordinator helper below.
    // The public Store adapter never receives a new getter/source/allocator.
    func value159(): AgentValue {
        lock.lock(); try { value.getOrThrow() } finally { lock.unlock() }
    }
    // Closed Runtime scalar comparison, not a fabricated SQL receipt.
    func recordClosedComparisonReturned159(): Unit {
        lock.lock(); try { if (!closed) { sqlReturned = true } } finally { lock.unlock() }
    }
    public func recordSqlCommitReturned159(): Unit {
        lock.lock(); try { if (!closed) { sqlReturned = true } } finally { lock.unlock() }
    }
    // Only after the entire coordinator helper returned successfully. The
    // original transition, SQL closure and rendered DOM frames are then gone.
    func detachReturnedFrame159(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (closed || !sqlReturned) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            value = None<AgentValue>
            let payments = loan.getOrThrow().clear159()
            loan = None<SharedToolSnapshotLoan159>
            closed = true
            ownedModelLaneSnapshots159.remove159(this)
            payments
        } finally { lock.unlock() }
    }
}
func modelLaneReturnedPayments159(values: (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation)): Unit {
    match (values[0]) { case Some(value) => value.close(); case None => () }
    match (values[1]) { case Some(value) => value.close(); case None => () }
    match (values[2]) { case Some(value) => value.close(); case None => () }
}
private class OwnedModelLaneSnapshots159 {
    private let lock = Mutex()
    private var first: ?OwnedModelLaneSnapshot159 = None<OwnedModelLaneSnapshot159>
    func retain159(value: OwnedModelLaneSnapshot159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: OwnedModelLaneSnapshot159): Unit {
        lock.lock()
        try {
            var prior: ?OwnedModelLaneSnapshot159 = None<OwnedModelLaneSnapshot159>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(parent) => parent.next159 = current.next159; case None => first = current.next159 }
                    current.next159 = None<OwnedModelLaneSnapshot159>; return
                }
                prior = cursor; cursor = current.next159
            }
        } finally { lock.unlock() }
    }
}
