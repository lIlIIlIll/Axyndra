package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*

// A fixed, same-bank cell registered by the actual RPC input owner BEFORE
// any codec, query, transaction or SQL error producer. It is not a Source,
// receipt, retry permission or a successful settlement witness.
public class RpcQueuedStoreFailure113 <: Exception {
    private let lock = Mutex()
    private var value: ?QueuedRunInitiatorData113
    private let payment: LogicalJsonOwnerReservation
    private var allocate: ?(Int64) -> LogicalJsonOwnerReservation
    private let basePeak: Int64
    private var original: ?Exception = None<Exception>
    private var captureFailure: ?Exception = None<Exception>
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var producing = true
    private var retired = false
    public var previous113: ?RpcQueuedStoreFailure113 = None<RpcQueuedStoreFailure113>
    public init(value: QueuedRunInitiatorData113, payment: LogicalJsonOwnerReservation,
        allocate: (Int64) -> LogicalJsonOwnerReservation, basePeak: Int64) {
        super("original queued SQL producer remains in its registered paid cell")
        this.value = Some(value); this.payment = payment; this.allocate = Some(allocate); this.basePeak = basePeak
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
            match (captureOwnedFailureData113<Unit>(error, allocate.getOrThrow())) {
                case OwnedFailureDataOutcome113.Failure(actual) => consumer = Some(actual); captureFailure = None<Exception>
                case _ => throw IllegalStateException("queued SQL full failure capture returned no consumer") }
        } catch (failure: Exception) {
            // Pressure/unknown capture cannot replace the original exception.
            // Both remain in this already-registered cell; no terminal output,
            // settlement retry or producer refund is inferred from this catch.
            captureFailure = Some(failure)
        }
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
            if (retired || producing || (original.isSome() &&
                (consumer.isNone() || !consumer.getOrThrow().isAcknowledged()))) {
                return None<LogicalJsonOwnerReservation> }
            original = None<Exception>; captureFailure = None<Exception>
            consumer = None<OwnedFailureDataConsumer113>; previous113 = None<RpcQueuedStoreFailure113>
            value = None<QueuedRunInitiatorData113>; allocate = None<(Int64) -> LogicalJsonOwnerReservation>
            retired = true; Some(payment)
        } finally { lock.unlock() }
    }
}

func prepareRpcQueuedStoreCell113(value: QueuedRunInitiatorData113,
    allocate: (Int64) -> LogicalJsonOwnerReservation,
    retain: (RpcQueuedStoreFailure113) -> Unit): RpcQueuedStoreFailure113 {
    var bytes: Int64 = 0
    for (size in [value.entryId.value.size, value.threadId.value.size, value.laneId.value.size,
        value.correlationId.size, value.kind.size, value.input.size]) {
        if (size > Int64.Max - bytes) { throw IllegalStateException("queued expected input extent overflow") }
        bytes += size }
    if (bytes > (Int64.Max - 131072) / 64) { throw IllegalStateException("queued expected codec invoice overflow") }
    // The original envelope policy pays the expected StoredValue codec and
    // SQL-bound parameter copies, not a claimed exact maximum of SQLite errmsg.
    let peak = 131072 + bytes * 64
    let paid = allocate(peak)
    let cell = RpcQueuedStoreFailure113(value, paid, allocate, peak)
    // Unknown registration keeps caller-provided payment alive. Production
    // retain checks/assigns only; no take-before-accept or after-SQL holder.
    retain(cell)
    cell
}
