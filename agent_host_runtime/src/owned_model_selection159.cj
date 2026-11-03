package agent_host_runtime

import agent_domain.*
import std.sync.*

private let hostModelSelectionDebts159 = HostModelSelectionDebts159()

// Installed selection may outlive a request. Its exact model-name String is
// independently prepaid and copied; the input owner never pays for its cache.
class HostModelSelectionIdentity159 {
    var next159: ?HostModelSelectionIdentity159 = None<HostModelSelectionIdentity159>
    var debtNext159: ?HostModelSelectionIdentity159 = None<HostModelSelectionIdentity159>
    private var payment: ?LogicalJsonOwnerReservation
    private var value = ""
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); hostModelSelectionDebts159.retain159(this)
    }
    func copy159(input: String): Unit { value = copyHostModelSelectionFrame159(input) }
    func matches159(input: String): Bool { value == input }
    func text159(): String { value }
    func clearCacheReferences159(): ?LogicalJsonOwnerReservation {
        let paid = payment
        value = ""; next159 = None<HostModelSelectionIdentity159>
        hostModelSelectionDebts159.remove159(this)
        payment = None<LogicalJsonOwnerReservation>
        paid
    }
}
private func copyHostModelSelectionFrame159(input: String): String { String.fromUtf8(input.toArray()) }
class HostModelSelectionDebts159 {
    private let lock = Mutex()
    private var head: ?HostModelSelectionIdentity159 = None<HostModelSelectionIdentity159>
    func retain159(value: HostModelSelectionIdentity159): Unit {
        lock.lock(); try { value.debtNext159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: HostModelSelectionIdentity159): Unit {
        lock.lock()
        try {
            var previous: ?HostModelSelectionIdentity159 = None<HostModelSelectionIdentity159>
            var cursor = head
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (refEq(item, value)) {
                    match (previous) { case Some(before) => before.debtNext159 = item.debtNext159
                        case None => head = item.debtNext159 }
                    item.debtNext159 = None<HostModelSelectionIdentity159>; return
                }
                previous = cursor; cursor = item.debtNext159
            }
        } finally { lock.unlock() }
    }
}
