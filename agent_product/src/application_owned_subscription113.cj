package agent_product

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*

// This token owns only the three concrete callbacks installed together.
// Cancellation prevents new callback loans; it never acknowledges any Data.
// The caller supplies an original-bank derived lease BEFORE closures/token
// construction. Application removes every registered alias before returning
// true. The token retains its exact lease until the caller observes the whole
// unsubscribe helper return, then explicitly retires this still-reachable token.
public class ApplicationOwnedSubscription113 <: OwnedAgentEventSink &
    OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let lock = Mutex()
    private var paid: ?LogicalJsonOwnerReservation
    private var ordinary: ?AgentEventSink
    private var owned: ?OwnedAgentEventSink
    private var failures: ?OwnedFailureEventSink113
    private var frames: Int64 = 0
    private var closing = false
    private var terminal = false
    private var aliasesRemoved = false
    private var removalStarted = false
    private let toolChildren = ArrayList<OwnedAgentEvent>()
    private let failureChildren = ArrayList<OwnedFailureRunPublication113>()
    private let dispatchPayments = ArrayList<ApplicationSubscriptionDispatchPayment113>()
    private var unregisteredDispatchPaid: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retainedPeak: Int64 = 65536
    var ordinaryIndex: Int64
    var ownedIndex: Int64
    var failureIndex: Int64
    var ordinaryInstalled = false
    var ownedInstalled = false
    var failureInstalled = false

    init(paid: LogicalJsonOwnerReservation, ordinary: AgentEventSink,
        owned: OwnedAgentEventSink, failures: ?OwnedFailureEventSink113,
        ordinaryIndex: Int64, ownedIndex: Int64, failureIndex: Int64) {
        paid.ensureRetainedPeak(65536)
        this.paid = Some(paid); this.ordinary = Some(ordinary)
        this.owned = Some(owned); this.failures = failures
        this.ordinaryIndex = ordinaryIndex; this.ownedIndex = ownedIndex
        this.failureIndex = failureIndex
    }

    private func fundChildRegistrationLocked113(): Unit {
        let count = subscriptionInvoiceAdd113(dispatchPayments.size,
            subscriptionInvoiceAdd113(toolChildren.size, failureChildren.size))
        let peak = subscriptionInvoiceAdd113(65536,
            subscriptionInvoiceMultiply113(subscriptionInvoiceAdd113(count, 1), 512))
        if (peak > retainedPeak) {
            paid.getOrThrow().ensureRetainedPeak(peak)
            retainedPeak = peak
        }
    }
    private func collectAcknowledgedLocked113(): Unit {
        var index: Int64 = 0
        while (index < toolChildren.size) {
            if (toolChildren[index].isAcknowledged()) { toolChildren.remove(at: index) }
            else { index++ }
        }
        index = 0
        while (index < failureChildren.size) {
            if (failureChildren[index].isAcknowledged()) { failureChildren.remove(at: index) }
            else { index++ }
        }
        index = 0
        while (index < dispatchPayments.size) {
            if (dispatchPayments[index].isRetired113()) { dispatchPayments.remove(at: index) }
            else { index++ }
        }
    }
    private func endFrame113(): Unit {
        lock.lock(); try { frames-- } finally { lock.unlock() }
    }
    func deriveDispatchPayment113(bytes: Int64): ApplicationSubscriptionDispatchPayment113 {
        lock.lock()
        try {
            if (terminal || paid.isNone() || unregisteredDispatchPaid.isSome()) {
                throw IllegalStateException("subscription metadata is retired or retains an unknown snapshot")
            }
            collectAcknowledgedLocked113()
            fundChildRegistrationLocked113()
            let child = paid.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(subscriptionInvoiceAdd113(bytes, 4096)) }
            catch (error: Exception) { child.close(); throw error }
            unregisteredDispatchPaid = Some(child)
            let actual = ApplicationSubscriptionDispatchPayment113(child)
            dispatchPayments.add(actual)
            unregisteredDispatchPaid = None<LogicalJsonOwnerReservation>
            actual
        } finally { lock.unlock() }
    }
    func emitOrdinary113(value: AgentEvent): Unit {
        let selected = beginOrdinary113()
        match (selected) {
            case Some(actual) => try { subscriptionOrdinaryLoan113(actual, value) }
                finally { endFrame113() }
            case None => ()
        }
    }
    private func beginOrdinary113(): ?AgentEventSink {
        lock.lock()
        try {
            if (closing || ordinary.isNone()) { return None<AgentEventSink> }
            frames = subscriptionInvoiceAdd113(frames, 1)
            ordinary
        } finally { lock.unlock() }
    }
    public func emit(value: OwnedAgentEvent): Result<Unit> {
        let selected = beginTool113(value)
        match (selected) {
            case None => return subscriptionPending113<Unit>()
            case Some(actual) =>
                try { subscriptionToolLoan113(actual, value) }
                finally { endFrame113() }
        }
    }
    private func beginTool113(value: OwnedAgentEvent): ?OwnedAgentEventSink {
        lock.lock()
        try {
            if (closing || owned.isNone()) { return None<OwnedAgentEventSink> }
            collectAcknowledgedLocked113()
            fundChildRegistrationLocked113()
            // This is the actual App fanout child. Callback return cannot
            // remove it; only its real Data acknowledgement does so.
            toolChildren.add(value)
            frames = subscriptionInvoiceAdd113(frames, 1)
            owned
        } finally { lock.unlock() }
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        let selected = beginFailure113(value)
        match (selected) {
            case None => return OwnedFailureEventAdmissionOutcome113.Held
            case Some(actual) =>
                try { subscriptionFailureLoan113(actual, value) }
                finally { endFrame113() }
        }
    }
    private func beginFailure113(value: OwnedFailureRunPublication113): ?OwnedFailureEventAdmission113 {
        lock.lock()
        try {
            if (closing || failures.isNone()) { return None<OwnedFailureEventAdmission113> }
            let actual = match (failures.getOrThrow() as OwnedFailureEventAdmission113) {
                case Some(admission) => admission
                case None => return None<OwnedFailureEventAdmission113>
            }
            collectAcknowledgedLocked113()
            fundChildRegistrationLocked113()
            failureChildren.add(value)
            frames = subscriptionInvoiceAdd113(frames, 1)
            Some(actual)
        } finally { lock.unlock() }
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        // The Result compatibility port does not run admission a second time.
        if (value.isAcknowledged()) { Result<Unit>.Ok(()) }
        else { subscriptionPending113<Unit>() }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case OwnedFailureEventAdmissionOutcome113.Failed(error) => OwnedFailureDataOutcome113<Unit>.Failure(error)
            case OwnedFailureEventAdmissionOutcome113.Held =>
                throw OwnedCanonicalDataFailure113(subscriptionPending113<Unit>().error().getOrThrow())
        }
    }
    // Application holds its registration lock and has observed every actual
    // dispatch helper return. A pending child or callback blocks this detach.
    func prepareAliasRemoval113(): Bool {
        lock.lock()
        try {
            closing = true
            if (terminal || removalStarted || frames != 0 || unregisteredDispatchPaid.isSome()) { return false }
            collectAcknowledgedLocked113()
            if (!toolChildren.isEmpty() || !failureChildren.isEmpty() || !dispatchPayments.isEmpty()) {
                return false
            }
            removalStarted = true
            true
        } finally { lock.unlock() }
    }
    func commitAliasesRemoved113(): Unit {
        lock.lock()
        try {
            ordinary = None<AgentEventSink>; owned = None<OwnedAgentEventSink>
            failures = None<OwnedFailureEventSink113>
            toolChildren.clear(); failureChildren.clear(); dispatchPayments.clear()
            aliasesRemoved = true
        } finally { lock.unlock() }
    }
    // Called only AFTER Application's entire removal helper returned. The
    // token itself keeps the original lease reachable if close() throws.
    public func retireAfterUnsubscribe113(): Bool {
        lock.lock()
        try {
            if (terminal) { return true }
            if (!aliasesRemoved || frames != 0 || paid.isNone()) { return false }
            subscriptionPaymentCloseHelper113(paid.getOrThrow())
            paid = None<LogicalJsonOwnerReservation>
            terminal = true
            true
        } finally { lock.unlock() }
    }
    public func isRetired113(): Bool {
        lock.lock(); try { terminal } finally { lock.unlock() }
    }
}

// Every simultaneous snapshot has an independent original-bank child. It
// remains registered in its token until actual close-helper return; an
// exception keeps that exact payment reachable, independent of counters.
class ApplicationSubscriptionDispatchPayment113 {
    private let lock = Mutex()
    private var paid: ?LogicalJsonOwnerReservation
    private var retired = false
    init(paid: LogicalJsonOwnerReservation) { this.paid = Some(paid) }
    func ensureBeforeSnapshot113(bytes: Int64): Unit {
        lock.lock()
        try {
            if (retired || paid.isNone()) { throw IllegalStateException("snapshot payment is already retired") }
            paid.getOrThrow().ensureRetainedPeak(bytes)
        } finally { lock.unlock() }
    }
    func retireAfterHelper113(): Unit {
        lock.lock()
        try {
            if (retired) { return }
            subscriptionPaymentCloseHelper113(paid.getOrThrow())
            paid = None<LogicalJsonOwnerReservation>; retired = true
        } finally { lock.unlock() }
    }
    func isRetired113(): Bool { lock.lock(); try { retired } finally { lock.unlock() } }
}
func subscriptionPaymentCloseHelper113(paid: LogicalJsonOwnerReservation): Unit { paid.close() }

// These full helpers return before their caller decrements the callback frame
// witness. No collector closes a lease from inside the borrowed callback.
func subscriptionOrdinaryLoan113(consume: AgentEventSink, value: AgentEvent): Unit { consume(value) }
func subscriptionToolLoan113(consume: OwnedAgentEventSink, value: OwnedAgentEvent): Result<Unit> { consume.emit(value) }
func subscriptionFailureLoan113(consume: OwnedFailureEventAdmission113,
    value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 { consume.admitOwnedFailure113(value) }
func subscriptionInvoiceAdd113(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) {
        throw IllegalArgumentException("subscription retained metadata invoice overflow")
    }
    left + right
}
func subscriptionInvoiceMultiply113(value: Int64, multiplier: Int64): Int64 {
    if (value < 0 || multiplier < 1 || value > Int64.Max / multiplier) {
        throw IllegalArgumentException("subscription retained metadata invoice overflow")
    }
    value * multiplier
}
func subscriptionPending113<T>(): Result<T> {
    Result<T>.Err(AgentError(AgentErrorKind.RecoveryRequired,
        "application.subscription_retirement_pending", "an actual subscription callback or owned consumer remains active"))
}
