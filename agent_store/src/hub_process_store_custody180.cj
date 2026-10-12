package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*

// Registered before the actual SQL/codec producer. Capture pressure leaves the
// exact original Exception and any secondary exception reachable; no synthetic
// short terminal error or retry can stand in for that original data.
public class HubProcessStoreFailure180 <: Exception {
    private let lock = Mutex()
    private var paid: ?LogicalJsonOwnerReservation
    private var allocate: ?(Int64) -> LogicalJsonOwnerReservation
    private var original: ?Exception = None<Exception>
    private var captureFailure: ?Exception = None<Exception>
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var ending = false
    private var retiring = false
    private let peak: Int64
    public init(payment: LogicalJsonOwnerReservation,
        allocate: (Int64) -> LogicalJsonOwnerReservation, peak: Int64) {
        super("original process SQL producer remains in its registered paid cell")
        paid = Some(payment); this.allocate = Some(allocate); this.peak = peak
    }
    public func fundExpected180(bytes: Int64): Unit {
        lock.lock(); try { paid.getOrThrow().ensureRetainedPeak(max(peak, bytes)) }
        finally { lock.unlock() }
    }
    public func captureOriginal180(error: Exception): Unit {
        lock.lock()
        try {
            if (original.isSome()) { throw IllegalStateException("original process SQL cell is occupied") }
            original = Some(error)
            tryCaptureLocked180()
        } finally { lock.unlock() }
    }
    private func tryCaptureLocked180(): Unit {
        if (consumer.isSome() || original.isNone()) { return }
        try {
            let source = original.getOrThrow()
            match (source as OwnedCanonicalPaidFailure113) {
                case Some(value) => consumer = Some(value.takeConsumer()); return
                case None => () }
            let size = source.message.size
            if (size > (Int64.Max - peak - 65536) / 16) {
                throw LogicalJsonPayloadError("original process SQL error extent overflow") }
            paid.getOrThrow().ensureRetainedPeak(peak + 65536 + size * 16)
            let full = match (source as OwnedCanonicalDataFailure113) {
                case Some(value) => value.error
                case None => AgentError(AgentErrorKind.RecoveryRequired,
                    "hub.process_canonical_store_failed", source.message) }
            match (captureOwnedFailureData113<Unit>(full, allocate.getOrThrow())) {
                case OwnedFailureDataOutcome113.Failure(value) => consumer = Some(value)
                case _ => throw IllegalStateException("actual process SQL error had no full consumer") }
        } catch (error: Exception) { captureFailure = Some(error) }
    }
    public func producerFrameEnding180(): Unit {
        lock.lock(); try { ending = true } finally { lock.unlock() }
    }
    public func admitFailure180(accept: (OwnedFailureDataConsumer113) -> Bool): Bool {
        lock.lock()
        try { if (!ending || original.isNone()) { return false }
            tryCaptureLocked180(); match (consumer) { case Some(value) => accept(value); case None => false } }
        finally { lock.unlock() }
    }
    public func withOriginal180(consume: (Exception) -> Unit): Unit {
        lock.lock(); try { consume(original.getOrThrow()) } finally { lock.unlock() }
    }
    // A returned cell can be reused only after its dynamic fields and its
    // independent payment have actually retired. Its fixed object is still
    // paid by the same Store registry; unknown/error cells never qualify.
    public func isReusableAfterReturnedHelper180(): Bool {
        lock.lock(); try { ending && !retiring && paid.isNone() && allocate.isNone() &&
            original.isNone() && captureFailure.isNone() && consumer.isNone() }
        finally { lock.unlock() }
    }
    public func installBeforeProducer180(payment: LogicalJsonOwnerReservation,
        allocate: (Int64) -> LogicalJsonOwnerReservation): Unit {
        lock.lock()
        try {
            if (!ending || retiring || paid.isSome() || this.allocate.isSome() ||
                original.isSome() || captureFailure.isSome() || consumer.isSome()) {
                throw IllegalStateException("actual process SQL cell has not retired") }
            paid = Some(payment); this.allocate = Some(allocate); ending = false
        } finally { lock.unlock() }
    }
    private func closeRegisteredPaymentHelper180(): Unit {
        // Only this whole helper owns a transient payment alias. The outer
        // method cannot clear the registered field before this helper returns.
        let value = borrowRegisteredPayment180(); value.close()
    }
    private func borrowRegisteredPayment180(): LogicalJsonOwnerReservation {
        lock.lock(); try { paid.getOrThrow() } finally { lock.unlock() }
    }
    public func retireReturnedPayment180(): Bool {
        lock.lock()
        try {
            if (retiring || !ending) { return false }
            if (paid.isNone()) { return original.isNone() && captureFailure.isNone() && consumer.isNone() }
            if (original.isSome() && (consumer.isNone() || !consumer.getOrThrow().isAcknowledged())) { return false }
            retiring = true
            // This is called only after the full codec/SQL helper returned;
            // error aliases separately require the actual consumer's ACK.
            original = None<Exception>; captureFailure = None<Exception>
            consumer = None<OwnedFailureDataConsumer113>
        } finally { lock.unlock() }
        try {
            closeRegisteredPaymentHelper180()
            lock.lock(); try { paid = None<LogicalJsonOwnerReservation>; allocate = None<(Int64) -> LogicalJsonOwnerReservation>; true }
            finally { lock.unlock() }
        } catch (error: Exception) {
            // A failed close is not retirement. Keep the exact payment and
            // exception in this already registered cell, without a fresh bank.
            lock.lock(); try { original = Some(error); captureFailure = None<Exception>; false }
            finally { lock.unlock() }
        } finally { lock.lock(); try { retiring = false } finally { lock.unlock() } }
    }
}
