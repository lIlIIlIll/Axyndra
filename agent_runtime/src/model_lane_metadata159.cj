package agent_runtime

import agent_domain.LogicalJsonOwnerReservation
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let modelLaneMetadataDebts159 = ModelLaneMetadataDebts159()

// No catalog/snapshot/Source reference. The metadata reservation is a real
// independently retained lease on the same original Native/Registry bank.
class ModelLaneMetadataCustody159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var value: ?ModelLane = None<ModelLane>
    var next159: ?ModelLaneMetadataCustody159 = None<ModelLaneMetadataCustody159>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment)
        modelLaneMetadataDebts159.retain159(this)
    }
    func bind159(value: ModelLane): Unit {
        lock.lock(); try { this.value = Some(value) } finally { lock.unlock() }
    }
    func returnMetadataFrame159(): Unit {
        let actual = clearMetadataFrame159()
        match (actual) { case Some(value) => value.close(); case None => () }
    }
    private func clearMetadataFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            // ModelLane already cleared every private copied String/capability
            // field in a completed helper; this drops the remaining carrier.
            value = None<ModelLane>
            let actual = payment; payment = None<LogicalJsonOwnerReservation>
            modelLaneMetadataDebts159.remove159(this)
            actual
        } finally { lock.unlock() }
    }
}
private class ModelLaneMetadataDebts159 {
    private let lock = Mutex()
    private var head: ?ModelLaneMetadataCustody159 = None<ModelLaneMetadataCustody159>
    func retain159(value: ModelLaneMetadataCustody159): Unit {
        lock.lock(); try { value.next159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: ModelLaneMetadataCustody159): Unit {
        lock.lock()
        try {
            var prior: ?ModelLaneMetadataCustody159 = None<ModelLaneMetadataCustody159>
            var cursor = head
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (refEq(item, value)) {
                    match (prior) { case Some(p) => p.next159 = item.next159; case None => head = item.next159 }
                    item.next159 = None<ModelLaneMetadataCustody159>
                    return
                }
                prior = cursor; cursor = item.next159
            }
        } finally { lock.unlock() }
    }
}
