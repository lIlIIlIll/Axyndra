package agent_runtime

import agent_domain.*
import std.collection.*

// Resource retirement only. Runtime constructs this after the existing
// canonical commit has actually succeeded and the coordinator removed its
// original result DOM. It grants no Source, Known result or external effect.
public class OwnedCanonicalResultRetirement {
    public let thread: ThreadId
    public let item: ItemId
    public let revision: Int64
    private let lease: ToolResultPayloadLease
    private let readback: OwnedCanonicalThreadReadback
    init(thread: ThreadId, item: ItemId, revision: Int64, lease: ToolResultPayloadLease,
        readback: OwnedCanonicalThreadReadback) {
        this.thread = thread; this.item = item; this.revision = revision; this.lease = lease; this.readback = readback
    }
    public func matches(actual: ToolResultPayloadLease): Bool { refEq(lease, actual) }
    public func visitCommittedItem(guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit> {
        readback.visitItem(thread, revision, item, guard, consume)
    }
}

class OwnedCanonicalRetirementIndex {
    let readback: OwnedCanonicalThreadReadback
    let owner: LogicalJsonOwnerReservation
    let records = ArrayList<OwnedCanonicalResultRetirement>()
    var retainedBytes: Int64 = 0
    init(readback: OwnedCanonicalThreadReadback, owner: LogicalJsonOwnerReservation) {
        this.readback = readback; this.owner = owner
    }
    func prepay(item: ItemId, thread: ThreadId): Unit {
        let bytes = ownedProjectionAdd(retainedBytes, ownedProjectionAdd(item.value.size, thread.value.size))
        if (bytes > Int64.Max / 8 || records.size > (Int64.Max - 8192) / 512) {
            throw IllegalStateException("canonical retirement metadata payment overflow") }
        owner.ensureRetainedPeak(ownedProjectionAdd(8192,
            ownedProjectionAdd(bytes * 8, (records.size + 1) * 512)))
        retainedBytes = bytes
    }
}
