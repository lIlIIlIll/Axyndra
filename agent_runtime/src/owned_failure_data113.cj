package agent_runtime

import agent_domain.*
import std.collection.*
import std.sync.*

// Failure has an actual paid consumer instead of a detached raw Err alias.
// Consumers must complete their real persistence/display/event loans before
// ACK; a Value here is data, not a Tool invocation completion.
public enum OwnedFailureDataOutcome113<T> {
    Value(T) | Failure(OwnedFailureDataConsumer113)
}

// A transport for the original complete error across a synchronous DATA
// stack. Its producer still owns its source; capture below must precede that
// producer's finally/ACK. It neither classifies an operation nor authorizes a
// retry. Store/Core/Product use the same type instead of losing fields in an
// exception containing only error.code.
public class OwnedCanonicalDataFailure113 <: Exception {
    public let error: AgentError
    public init(error: AgentError) { super("canonical paid data failed"); this.error = error }
}
// A real independent consumer, captured while its producing SQL/query/row
// frame is still live. A single handler moves it out; no detached raw error
// crosses producer retirement and no duplicate handler can acquire its claim.
public class OwnedCanonicalPaidFailure113 <: Exception {
    private let lock = Mutex()
    private var consumer: ?OwnedFailureDataConsumer113
    public init(error: AgentError, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        super("canonical paid failure has a consumer")
        this.consumer = match (captureOwnedFailureData113<Unit>(error, allocate)) {
            case OwnedFailureDataOutcome113.Failure(value) => Some(value)
            case OwnedFailureDataOutcome113.Value(_) => throw IllegalStateException("failure capture returned a value") }
    }
    public func takeConsumer(): OwnedFailureDataConsumer113 {
        lock.lock(); try {
            let actual = consumer.getOrThrow(); consumer = None<OwnedFailureDataConsumer113>; actual
        } finally { lock.unlock() }
    }
}
public func captureOwnedFailureData113<T>(error: AgentError,
    allocate: (Int64) -> LogicalJsonOwnerReservation): OwnedFailureDataOutcome113<T> {
    let root = OwnedFailureData113(error, allocate)
    try {
        match (root.retainConsumer()) {
            case Result.Ok(consumer) => OwnedFailureDataOutcome113<T>.Failure(consumer)
            case Result.Err(failure) => throw OwnedCanonicalDataFailure113(failure) }
    } finally {
        match (root.closeAfterProducerRetirement()) { case Result.Ok(_) => ()
            case Result.Err(_) => throw IllegalStateException("paid failure producer has an active consumer frame") }
    }
}

// Neutral DATA ownership. This cannot authorize a Source, retry, operation,
// cut or known outcome. It also cannot turn an outer Err into Completed.
// Existing public Result/AgentError paths are unchanged. The opt-in consumer
// receives no raw getter and must retain a real consumer before storing aliases.
public class OwnedFailureData113 {
    private let state: OwnedFailureDataState113
    public init(error: AgentError, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        this.state = OwnedFailureDataState113(error, allocate)
    }
    public func retainConsumer(): Result<OwnedFailureDataConsumer113> { state.retain(0) }
    public func withError(consume: (AgentError, (Int64) -> Result<Unit>) -> Unit): Result<Unit> {
        state.withError(0, consume)
    }
    public func closeAfterProducerRetirement(): Result<Unit> { state.retireRoot() }
    public func isRetired(): Bool { state.isRetired() }
}

public class OwnedFailureDataConsumer113 {
    private let lock = Mutex()
    private let state: OwnedFailureDataState113
    private let owner: LogicalJsonOwnerReservation
    private let id: Int64
    private var closed = false
    init(state: OwnedFailureDataState113, owner: LogicalJsonOwnerReservation, id: Int64) {
        this.state = state; this.owner = owner; this.id = id
    }
    public func retainConsumer(): Result<OwnedFailureDataConsumer113> {
        lock.lock()
        try { if (closed) { return ownedFailureDataError113<OwnedFailureDataConsumer113>("data.failure_consumer_closed") }
            state.retain(id) }
        finally { lock.unlock() }
    }
    // Same original private bank, independent copied-display DATA only.
    // Acquire BEFORE copying, while this exact error loan is active. Success
    // neither ACKs this consumer nor grants execution/Source authority.
    public func deriveCopiedDisplayAllocation113(totalInvoice:Int64):Result<LogicalJsonCopiedDisplayAllocation>{
        lock.lock()
        try{if(closed){return ownedFailureDataError113<LogicalJsonCopiedDisplayAllocation>("data.failure_consumer_closed")}
            state.deriveCopiedDisplay(id,totalInvoice)}
        finally{lock.unlock()}
    }
    public func captureFailure113<T>(error: AgentError): OwnedFailureDataOutcome113<T> {
        lock.lock()
        try {
            if (closed) { throw OwnedCanonicalDataFailure113(ownedFailureDataError113<Unit>(
                "data.failure_consumer_closed").error().getOrThrow()) }
            state.captureFailure<T>(id,error)
        } finally { lock.unlock() }
    }
    public func withError(consume: (AgentError, (Int64) -> Result<Unit>) -> Unit): Result<Unit> {
        lock.lock(); let unavailable = try { closed } finally { lock.unlock() }
        if (unavailable) { return ownedFailureDataError113<Unit>("data.failure_consumer_closed") }
        state.withError(id, consume)
    }
    public func acknowledgeAfterConsumption(): Result<Unit> {
        lock.lock()
        try {
            if (closed) { return Result<Unit>.Ok(()) }
            match (state.retireConsumer(id, owner)) {
                case Result.Err(error) => Result<Unit>.Err(error)
                case Result.Ok(_) => closed = true; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }
}

class OwnedFailureDataState113 {
    private let lock = Mutex()
    private let owner: LogicalJsonOwnerReservation
    private let retainedPeak: Int64
    private var error: ?AgentError = None<AgentError>
    private let consumers = HashMap<Int64, LogicalJsonOwnerReservation>()
    private let paidExtras = HashMap<Int64, Int64>()
    private let borrowing = HashSet<Int64>()
    private var next: Int64 = 1
    private var rootClosed = false
    private var released = false
    private var rootAdditional: Int64 = 0
    init(error: AgentError, allocate: (Int64) -> LogicalJsonOwnerReservation) {
        let actual = allocate(65536)
        this.owner = actual
        this.retainedPeak = try { ownedFailureDataPeak113(error) }
            catch (failure: Exception) { actual.close(); throw failure }
        try {
            actual.ensureRetainedPeak(retainedPeak)
            // Full independent UTF8 strings/field containers are constructed
            // only after the original-bank invoice, while the source is paid.
            this.error = Some(ownedFailureDataClone113(error))
        } catch (failure: Exception) { actual.close(); throw failure }
    }
    func available(id: Int64): Bool {
        !released && error.isSome() && ((id == 0 && !rootClosed) || (id != 0 && consumers.get(id).isSome()))
    }
    func retain(from: Int64): Result<OwnedFailureDataConsumer113> {
        lock.lock()
        try {
            if (!available(from) || next == Int64.Max) {
                return ownedFailureDataError113<OwnedFailureDataConsumer113>("data.failure_consumer_closed") }
            let child = try { owner.deriveRetainedLease() }
                catch (_: Exception) { return ownedFailureDataError113<OwnedFailureDataConsumer113>("data.failure_consumer_pressure") }
            try {
                child.ensureRetainedPeak(8192)
                let id = next; next++; consumers[id] = child; paidExtras[id] = 0
                Result.Ok(OwnedFailureDataConsumer113(this, child, id))
            } catch (failure: Exception) { child.close(); throw failure }
        } finally { lock.unlock() }
    }
    func deriveCopiedDisplay(id:Int64,totalInvoice:Int64):Result<LogicalJsonCopiedDisplayAllocation>{
        lock.lock()
        try{
            if(!available(id) || !borrowing.contains(id)){
                return ownedFailureDataError113<LogicalJsonCopiedDisplayAllocation>("data.failure_borrow_closed")}
            let actual=if(id==0){owner}else{consumers.get(id).getOrThrow()}
            // Existing inherited Domain DATA interface, no orphan extension,
            // new allocation pool, error reconstruction or early source ACK.
            actual.acquireCopiedDisplayAllocation(totalInvoice)
        }finally{lock.unlock()}
    }
    func captureFailure<T>(id: Int64, error: AgentError): OwnedFailureDataOutcome113<T> {
        lock.lock()
        try {
            if (!available(id)) { throw OwnedCanonicalDataFailure113(ownedFailureDataError113<Unit>(
                "data.failure_consumer_closed").error().getOrThrow()) }
            let actual = if (id == 0) { owner } else { consumers.get(id).getOrThrow() }
            // The same original allocation bank funds a new independent
            // complete error clone BEFORE the producer's raw Err frame ends.
            // The original consumer is untouched on pressure/throw; callers
            // cannot ACK it until this actual transfer succeeds and the old
            // Snapshot/Event/SQL/Err frames have really returned.
            captureOwnedFailureData113<T>(error,{ _ => actual.deriveRetainedLease() })
        } finally { lock.unlock() }
    }
    func pay(id: Int64, additional: Int64): Result<Unit> {
        lock.lock()
        try {
            if (!available(id) || !borrowing.contains(id) || additional < 0 || additional > Int64.Max - retainedPeak) {
                return ownedFailureDataError113<Unit>("data.failure_payment_invalid") }
            try {
                if (id == 0) {
                    let total = ownedFailureDataAdd113(rootAdditional, additional)
                    owner.ensureRetainedPeak(ownedFailureDataAdd113(retainedPeak, total)); rootAdditional = total
                } else {
                    let total = ownedFailureDataAdd113(paidExtras.get(id).getOrThrow(), additional)
                    consumers.get(id).getOrThrow().ensureRetainedPeak(ownedFailureDataAdd113(8192, total)); paidExtras[id] = total
                }
                Result<Unit>.Ok(())
            } catch (_: Exception) { ownedFailureDataError113<Unit>("data.failure_consumer_pressure") }
        } finally { lock.unlock() }
    }
    func withError(id: Int64, consume: (AgentError, (Int64) -> Result<Unit>) -> Unit): Result<Unit> {
        var selected: ?AgentError = None<AgentError>
        lock.lock()
        try {
            if (!available(id) || borrowing.contains(id)) {
                return ownedFailureDataError113<Unit>("data.failure_borrow_closed") }
            borrowing.add(id); selected = error
        } finally { lock.unlock() }
        try {
            consume(selected.getOrThrow(), { additional: Int64 => pay(id, additional) })
            Result<Unit>.Ok(())
        } finally {
            // Unit callback frame and its selected reference end before ACK.
            selected = None<AgentError>
            lock.lock(); try { borrowing.remove(id) } finally { lock.unlock() }
        }
    }
    func releaseIfRetired(): Unit {
        if (rootClosed && consumers.isEmpty() && borrowing.isEmpty() && !released) {
            error = None<AgentError>; owner.close(); released = true
        }
    }
    func retireRoot(): Result<Unit> {
        lock.lock()
        try {
            if (borrowing.contains(0)) { return ownedFailureDataError113<Unit>("data.failure_borrow_pending") }
            rootClosed = true; releaseIfRetired(); Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    func retireConsumer(id: Int64, child: LogicalJsonOwnerReservation): Result<Unit> {
        lock.lock()
        try {
            if (borrowing.contains(id)) { return ownedFailureDataError113<Unit>("data.failure_borrow_pending") }
            if (consumers.get(id).isNone()) { return Result<Unit>.Ok(()) }
            consumers.remove(id)
            paidExtras.remove(id)
            releaseIfRetired()
            child.close(); Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    func isRetired(): Bool {
        lock.lock(); try { released && error.isNone() && rootClosed && consumers.isEmpty() && borrowing.isEmpty() }
        finally { lock.unlock() }
    }
}

func ownedFailureDataError113<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "error data requires its real paid producer and consumer retirement"))
}
func ownedFailureDataAdd113(a: Int64, b: Int64): Int64 {
    if (a < 0 || b < 0 || a > Int64.Max - b) { throw IllegalStateException("error data payment overflow") }
    a + b
}
func ownedFailureDataPeak113(error: AgentError): Int64 {
    var bytes = ownedFailureDataAdd113(error.code.size, error.message.size)
    var containers: Int64 = 16384
    for (field in error.fields) {
        bytes = ownedFailureDataAdd113(bytes, ownedFailureDataAdd113(field.name.size, field.value.size))
        containers = ownedFailureDataAdd113(containers, 1024)
    }
    if (bytes > Int64.Max / 8) { throw IllegalStateException("error data payment overflow") }
    var peak = ownedFailureDataAdd113(containers, bytes * 8)
    if (error.attemptFailure.isSome()) { peak = ownedFailureDataAdd113(peak, 4096) }
    // OperationObservation is already immutable independent encoded DATA, at
    // most its ORIGINAL 65536 bytes. No DOM is constructed here; a consumer
    // must pay its actual observation.toValue()/serialization before doing so.
    if (error.observation.isSome()) { peak = ownedFailureDataAdd113(peak, 540672) }
    peak
}
func ownedFailureDataClone113(error: AgentError): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) {
        fields.add(ErrorField(String.fromUtf8(field.name.toArray()), String.fromUtf8(field.value.toArray()))) }
    let attempt: ?AttemptFailure = match (error.attemptFailure) {
        case Some(value) =>
            let d = value.diagnostics
            Some(AttemptFailure(value.kind, diagnostics: AttemptFailureDiagnostics(elapsedMillis: d.elapsedMillis,
                softDeadlineMillis: d.softDeadlineMillis, hardDeadlineMillis: d.hardDeadlineMillis,
                enteredCompletionGrace: d.enteredCompletionGrace, lastProgressKind: d.lastProgressKind,
                lastProgressAgeMillis: d.lastProgressAgeMillis, providerTerminalObserved: d.providerTerminalObserved,
                openContentBlockCount: d.openContentBlockCount, toolCallsStarted: d.toolCallsStarted,
                toolCallsCompleted: d.toolCallsCompleted)))
        case None => None<AttemptFailure> }
    AgentError(error.kind, String.fromUtf8(error.code.toArray()), String.fromUtf8(error.message.toArray()),
        retryable: error.retryable, fallbackAllowed: error.fallbackAllowed, fields: fields.toArray(),
        attemptFailure: attempt, observation: error.observation)
}
