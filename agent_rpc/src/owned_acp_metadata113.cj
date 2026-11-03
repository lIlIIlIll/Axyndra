package agent_rpc

import agent_domain.*
import std.sync.*

// The controller registers the original derived share before this holder,
// its callback, any record or a factory invocation can allocate. A requested
// retirement is not an ACK: the real caller and guard helpers must return.
class AcpOwnedMetadata113 {
    private var paid: ?LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var guard: ?(() -> Bool) = None<() -> Bool>
    private var helperReturned = false
    private var requested = false
    private var collecting = false
    private var peak: Int64
    init(paid: LogicalJsonOwnerReservation, bytes: Int64) {
        this.paid = Some(paid); this.peak = bytes
    }
    func ensure113(bytes: Int64): Unit {
        lock.lock()
        try {
            let wanted = max(peak, bytes)
            paid.getOrThrow().ensureRetainedPeak(wanted); peak = wanted
        } finally { lock.unlock() }
    }
    func setGuard113(value: () -> Bool): Unit { lock.lock(); try { guard = Some(value) } finally { lock.unlock() } }
    func observeHelperReturned113(): Unit { lock.lock(); try { helperReturned = true } finally { lock.unlock() } }
    func requestRetirement113(): Unit { lock.lock(); try { requested = true } finally { lock.unlock() } }
    private func detachGuardAfterReturn113(): Bool {
        lock.lock()
        let actual = try {
            if (paid.isNone()) { return true }
            if (!helperReturned || !requested || collecting) { return false }
            collecting = true; guard
        } finally { lock.unlock() }
        let ready = try { match (actual) { case None => true; case Some(check) => check() } }
            catch (_: Exception) { false }
        lock.lock()
        try {
            collecting = false
            if (ready) { guard = None<() -> Bool> }
            ready
        } finally { lock.unlock() }
    }
    func collectAfterGuardHelperReturn113(): Bool {
        // Its complete guard invocation and its local callback reference are
        // gone before this helper attempts the actual Native child close.
        if (!detachGuardAfterReturn113()) { return false }
        lock.lock()
        try {
            match (paid) {
                case None => true
                case Some(actual) =>
                    actual.close(); paid = None<LogicalJsonOwnerReservation>; true }
        } finally { lock.unlock() }
    }
    func isRetired113(): Bool { lock.lock(); try { paid.isNone() } finally { lock.unlock() } }
}
