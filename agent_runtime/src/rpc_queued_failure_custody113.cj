package agent_runtime

import agent_domain.*
import std.sync.*

// A serial Store working frame can borrow the actual queued worker's prepaid
// DATA extent. An independently retained SQL/error producer owns its child.
// Neither alternative supplies execution authority or a consumption witness.
public enum RpcQueuedStorePayment113 {
    Owned(LogicalJsonOwnerReservation) | Borrowed(LogicalJsonOwnerReservation, Int64)
}

// A fixed, same-bank cell registered by the actual RPC input owner BEFORE
// any codec, query, transaction or SQL error producer. It is not a Source,
// receipt, retry permission or a successful settlement witness.
public class RpcQueuedStoreFailure113 <: Exception {
    private let lock = Mutex()
    private var value: ?QueuedRunInitiatorData113
    private let payment: LogicalJsonOwnerReservation
    private let ownsPayment: Bool
    private let basePeak: Int64
    private var original: ?Exception = None<Exception>
    private var captureFailure: ?Exception = None<Exception>
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var producing = true
    private var retired = false
    public var previous113: ?RpcQueuedStoreFailure113 = None<RpcQueuedStoreFailure113>
    public init(value: QueuedRunInitiatorData113, funding: RpcQueuedStorePayment113, basePeak: Int64) {
        super("original queued SQL producer remains in its registered paid cell")
        this.value = Some(value)
        match (funding) {
            case RpcQueuedStorePayment113.Owned(actual) =>
                this.payment = actual; this.basePeak = basePeak; this.ownsPayment = true
            case RpcQueuedStorePayment113.Borrowed(actual, prepaidPeak) =>
                if (prepaidPeak < basePeak) { throw IllegalArgumentException("queued Store working extent is not prepaid") }
                this.payment = actual; this.basePeak = prepaidPeak; this.ownsPayment = false
        }
    }
    public func matches113(actual: QueuedRunInitiatorData113): Bool {
        lock.lock(); try { value.isSome() && refEq(value.getOrThrow(), actual) } finally { lock.unlock() }
    }
    public func captureOriginal113(error: Exception): Unit {
        lock.lock()
        try {
            if (retired || original.isSome()) { throw IllegalStateException("queued SQL failure cell is occupied") }
            // No allocator, clone, message getter or classification can run
            // before the exact original exception is reachable from RPC.
            original = Some(error)
            tryCaptureLocked113()
        } finally { lock.unlock() }
    }
    private func tryCaptureLocked113(): Unit {
        if (consumer.isSome() || original.isNone()) { return }
        try {
            let source = original.getOrThrow()
            match (source as OwnedCanonicalPaidFailure113) {
                case Some(actual) =>
                    // The cell is already reachable and checked before moving
                    // the exact pre-existing full consumer, with no allocator.
                    consumer = Some(actual.takeConsumer()); captureFailure = None<Exception>; return
                case None => () }
            let size = source.message.size
            if (size > (Int64.Max - basePeak - 65536) / 16) {
                throw IllegalStateException("queued original SQL error invoice overflow") }
            payment.ensureRetainedPeak(basePeak + 65536 + size * 16)
            let error = match (source as OwnedCanonicalDataFailure113) {
                case Some(actual) => actual.error
                case None => AgentError(AgentErrorKind.RecoveryRequired,
                    "inbox.rpc_queued_settlement_failed", source.message,
                    fields: [ErrorField("inbox_entry_id", value.getOrThrow().entryId.value)]) }
            match (captureOwnedFailureData113<Unit>(error, { bytes => allocateFailureCopy113(bytes) })) {
                case OwnedFailureDataOutcome113.Failure(actual) => consumer = Some(actual); captureFailure = None<Exception>
                case _ => throw IllegalStateException("queued SQL full failure capture returned no consumer") }
        } catch (failure: Exception) {
            // Pressure/unknown capture cannot replace the original exception.
            // Both remain in this already-registered cell; no terminal output,
            // settlement retry or producer refund is inferred from this catch.
            captureFailure = Some(failure)
        }
    }
    private func allocateFailureCopy113(bytes: Int64): LogicalJsonOwnerReservation {
        let child = payment.deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes); child }
        catch (error: Exception) { child.close(); throw error }
    }
    public func admitConsumer113(accept: (OwnedFailureDataConsumer113) -> Bool): Bool {
        lock.lock()
        try {
            if (retired || producing || original.isNone()) { return false }
            tryCaptureLocked113()
            match (consumer) { case Some(actual) => accept(actual); case None => false }
        } finally { lock.unlock() }
    }
    // Tests/explicit recovery may borrow the exact retained SQL exception.
    // It cannot ACK it, manufacture an error consumer or release this cell.
    public func withOriginal113(consume: (Exception) -> Unit): Unit {
        lock.lock()
        try { if (retired || producing) { throw IllegalStateException("queued SQL producer is still active") }
            consume(original.getOrThrow()) }
        finally { lock.unlock() }
    }
    // Numeric/Bool observation only. Producer-ending alone is not return;
    // RPC independently queries the real whole worker Future before testing.
    public func observedOriginalWithoutConsumer113(): Bool {
        lock.lock()
        try { !retired && !producing && original.isSome() && consumer.isNone() }
        finally { lock.unlock() }
    }
    public func noteProducerFrameEnding113(): Unit {
        lock.lock(); try { producing = false } finally { lock.unlock() }
    }
    // Called by RPC only AFTER the whole synchronous App/Store helper has
    // actually returned. The flag is an additional gate, not a return ACK.
    // A true error consumer ACK is separately required before raw aliases clear.
    public func takeRetirementPaymentAfterReturned113(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (!ownsPayment || !canRetireLocked113()) { return None<LogicalJsonOwnerReservation> }
            clearReturnedDataLocked113()
            Some(payment)
        } finally { lock.unlock() }
    }
    // Only the actual queued worker calls this after its WHOLE App/Store
    // helper returns. Clearing this borrowed cell never closes/refunds the
    // original worker payment; its aliases and Future still own that extent.
    public func retireBorrowedAfterReturned113(): Bool {
        lock.lock()
        try {
            if (ownsPayment || !canRetireLocked113()) { return false }
            clearReturnedDataLocked113(); true
        } finally { lock.unlock() }
    }
    private func canRetireLocked113(): Bool {
        !retired && !producing && (original.isNone() ||
            (consumer.isSome() && consumer.getOrThrow().isAcknowledged()))
    }
    private func clearReturnedDataLocked113(): Unit {
        original = None<Exception>; captureFailure = None<Exception>
        consumer = None<OwnedFailureDataConsumer113>; previous113 = None<RpcQueuedStoreFailure113>
        value = None<QueuedRunInitiatorData113>; retired = true
    }
}
