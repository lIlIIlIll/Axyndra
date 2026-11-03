package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.collection.*
import std.sync.*

// Complete ordered canonical data, never a source/approval/effect grant.
// A live consumer must retain actual alias custody before retaining an item,
// and clear its own item/value/request/frame references before acknowledging
// that custody. Ordinary raw snapshot APIs remain a distinct legacy route.
public interface OwnedCanonicalThreadReadback {
    func visit(thread: ThreadId, revision: Int64, afterOrdinal: Int64, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit>
    func visitItem(thread: ThreadId, revision: Int64, item: ItemId, guard: () -> Result<Unit>,
        consume: (ThreadItem, OwnedCanonicalThreadItemCustody) -> Result<Unit>): Result<Unit>
}

func ownedCanonicalDataError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "canonical data still requires its actual paid owner and alias retirement",
        retryable: false, fallbackAllowed: false))
}

// This private actual-state witness cannot be constructed from a wire
// Bool/digest/ID. It attests only retirement of this exact readback DOM;
// detached storage allocations may still keep the original ledger paid.
public class OwnedCanonicalThreadItemRetirementWitness {
    private let state: OwnedCanonicalThreadItemState
    init(state: OwnedCanonicalThreadItemState) { this.state = state }
    public func isItemRetired(): Bool { state.isItemRetired() }
}

// One original whole-cell allocation. All actual consumers of the same DOM
// share this private backing and the original pool's real high-water charge.
// No callback completion or physical provider ACK alone retires its aliases.
class OwnedCanonicalThreadItemState {
    private let lock = Mutex()
    private let owner: LogicalJsonOwnerReservation
    private var item: ?ThreadItem
    private let aliases = HashSet<Int64>()
    private var nextAlias: Int64 = 1
    private var borrowing = false
    private var rootClosed = false
    private var released = false
    private var retirement: ?OwnedCanonicalThreadItemRetirementWitness = None
    init(item: ThreadItem, owner: LogicalJsonOwnerReservation) { this.item = Some(item); this.owner = owner }
    func retain(fromAlias: Int64): Result<OwnedCanonicalThreadItemAliasCustody> {
        lock.lock()
        try {
            if (released || nextAlias == Int64.Max || (fromAlias == 0 && rootClosed) ||
                (fromAlias != 0 && !aliases.contains(fromAlias))) { return ownedCanonicalDataError("thread.readback_alias_closed") }
            let child = try { owner.deriveRetainedLease() }
                catch (_: Exception) { return ownedCanonicalDataError("thread.readback_alias_pressure") }
            try { child.ensureRetainedPeak(8192) }
            catch (_: Exception) { child.close(); return ownedCanonicalDataError("thread.readback_alias_pressure") }
            let id = nextAlias; nextAlias++; aliases.add(id)
            Result.Ok(OwnedCanonicalThreadItemAliasCustody(this, child, id))
        } finally { lock.unlock() }
    }
    func acquireCopiedDisplayAllocation(alias: Int64, actual: LogicalJsonOwnerReservation,
        totalInvoice: Int64): Result<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (released || item.isNone() || !aliases.contains(alias)) {
                return ownedCanonicalDataError("thread.readback_alias_closed") }
            actual.acquireCopiedDisplayAllocation(totalInvoice)
        } finally { lock.unlock() }
    }
    func retirementWitness(alias: Int64): Result<OwnedCanonicalThreadItemRetirementWitness> {
        lock.lock()
        try {
            if (released || !aliases.contains(alias)) { return ownedCanonicalDataError("thread.readback_alias_closed") }
            match (retirement) {
                case Some(actual) => Result.Ok(actual)
                case None => let actual = OwnedCanonicalThreadItemRetirementWitness(this)
                    retirement = Some(actual); Result.Ok(actual) }
        } finally { lock.unlock() }
    }
    func isItemRetired(): Bool {
        lock.lock()
        try { released && item.isNone() && rootClosed && aliases.isEmpty() && !borrowing }
        finally { lock.unlock() }
    }
    func withItem(alias: Int64, consume: (ThreadItem) -> Result<Unit>): Result<Unit> {
        lock.lock()
        var selected: ?ThreadItem = None
        try {
            if (released || borrowing || (alias == 0 && rootClosed) || (alias != 0 && !aliases.contains(alias))) {
                return ownedCanonicalDataError("thread.readback_borrow_closed") }
            borrowing = true; selected = item
        } finally { lock.unlock() }
        try { consume(selected.getOrThrow()) }
        catch (_: Exception) { ownedCanonicalDataError("thread.readback_consumer_failed") }
        finally {
            selected = None
            lock.lock(); try { borrowing = false } finally { lock.unlock() }
        }
    }
    func acknowledgeRoot(): Result<Unit> {
        lock.lock()
        try {
            if (borrowing) { return ownedCanonicalDataError("thread.readback_borrow_pending") }
            rootClosed = true
            if (aliases.isEmpty() && !released) {
                item = None
                owner.close(); released = true
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func acknowledgeAlias(id: Int64, child: LogicalJsonOwnerReservation): Result<Unit> {
        lock.lock()
        try {
            if (borrowing) { return ownedCanonicalDataError("thread.readback_borrow_pending") }
            if (!aliases.contains(id)) { return Result.Ok(()) }
            // The holder already cleared its own extracted item/value/frame.
            // Clear the shared final reference before either actual lease closes.
            aliases.remove(id)
            if (rootClosed && aliases.isEmpty() && !released) {
                item = None; owner.close(); released = true
            }
            child.close()
            Result.Ok(())
        } finally { lock.unlock() }
    }
}

public class OwnedCanonicalThreadItemCustody {
    private let state: OwnedCanonicalThreadItemState
    public init(item: ThreadItem, owner: LogicalJsonOwnerReservation) { this.state = OwnedCanonicalThreadItemState(item, owner) }
    public func retainAliasCustody(): Result<OwnedCanonicalThreadItemAliasCustody> { state.retain(0) }
    public func withItem(consume: (ThreadItem) -> Result<Unit>): Result<Unit> { state.withItem(0, consume) }
    public func closeAfterConsumption(): Result<Unit> { state.acknowledgeRoot() }
}

public class OwnedCanonicalThreadItemAliasCustody {
    private let lock = Mutex()
    private let state: OwnedCanonicalThreadItemState
    private let child: LogicalJsonOwnerReservation
    private let id: Int64
    private var closed = false
    init(state: OwnedCanonicalThreadItemState, child: LogicalJsonOwnerReservation, id: Int64) {
        this.state = state; this.child = child; this.id = id
    }
    public func withItem(consume: (ThreadItem) -> Result<Unit>): Result<Unit> {
        lock.lock(); let unavailable = try { closed } finally { lock.unlock() }
        if (unavailable) { return ownedCanonicalDataError("thread.readback_alias_closed") }
        state.withItem(id, consume)
    }
    public func retainAliasCustody(): Result<OwnedCanonicalThreadItemAliasCustody> {
        lock.lock()
        try {
            if (closed) { return ownedCanonicalDataError("thread.readback_alias_closed") }
            state.retain(id)
        } finally { lock.unlock() }
    }
    // The actual observer measures its simultaneous serialization/transport
    // allocations without constructing them, then pays this alias's share of
    // the SAME original row ledger before allocation. Other aliases' shares
    // and the complete original row backing are still added independently.
    public func retirementWitness(): Result<OwnedCanonicalThreadItemRetirementWitness> {
        lock.lock()
        try {
            if (closed) { return ownedCanonicalDataError("thread.readback_alias_closed") }
            state.retirementWitness(id)
        } finally { lock.unlock() }
    }
    public func ensureAdditionalRetainedPeak(additional: Int64): Result<Unit> {
        lock.lock()
        try {
            if (closed || additional < 0 || additional > Int64.Max - 8192) {
                return ownedCanonicalDataError("thread.readback_alias_payment_invalid") }
            try { child.ensureRetainedPeak(8192 + additional); Result.Ok(()) }
            catch (_: Exception) { ownedCanonicalDataError("thread.readback_alias_pressure") }
        } finally { lock.unlock() }
    }
    // Detached serialization/spool storage is not a DOM alias. The real
    // derived allocation may outlive this alias after every item/event DOM
    // reference is retired, and keeps the SAME original pool/high-water/slot
    // until its actual storage/transport owner clears and closes it.
    // Only a real live DOM alias can fund a copied preview. The independent
    // fixed tickets stay in the same bank after this row truly retires.
    public func acquireCopiedDisplayAllocation(totalInvoice: Int64): Result<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (closed) { return ownedCanonicalDataError("thread.readback_alias_closed") }
            state.acquireCopiedDisplayAllocation(id, child, totalInvoice)
        } finally { lock.unlock() }
    }
    public func deriveRetainedAllocation(additional: Int64): Result<LogicalJsonOwnerReservation> {
        lock.lock()
        try {
            if (closed || additional < 0 || additional > Int64.Max - 8192) {
                return ownedCanonicalDataError("thread.readback_alias_payment_invalid") }
            let derived = try { child.deriveRetainedLease() }
                catch (_: Exception) { return ownedCanonicalDataError("thread.readback_alias_pressure") }
            try { derived.ensureRetainedPeak(8192 + additional); Result.Ok(derived) }
            catch (_: Exception) { derived.close(); ownedCanonicalDataError("thread.readback_alias_pressure") }
        } finally { lock.unlock() }
    }
    public func withPaidItem(additional: Int64, consume: (ThreadItem) -> Result<Unit>): Result<Unit> {
        match (ensureAdditionalRetainedPeak(additional)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => withItem(consume) }
    }
    public func closeAfterAliasRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result.Ok(()) }
            match (state.acknowledgeAlias(id, child)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => closed = true; Result.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}
