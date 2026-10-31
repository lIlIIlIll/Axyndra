package agent_runtime

import agent_domain.*
import std.sync.*

// These are DATA consumer contracts. They neither finish a Run nor change an
// already-canonical operation. Implementations retain a distinct consumer if
// they queue data, and ACK only after their actual aliases/callbacks retire.
public interface OwnedFailureRunRepository113 {
    func saveOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit>
    func appendOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit>
    func saveOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit>
    func appendOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit>
}
public interface OwnedFailureEventSink113 {
    func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit>
    func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit>
}
public class CallbackOwnedFailureEventSink113 <: OwnedFailureEventSink113 {
    private let consume: (OwnedFailureRunPublication113) -> Result<Unit>
    public init(consume: (OwnedFailureRunPublication113) -> Result<Unit>) { this.consume = consume }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        match (consume(value)) {
            case Result.Err(error) => Result<Unit>.Err(error)
            case Result.Ok(_) => if (value.isAcknowledged()) { Result<Unit>.Ok(()) }
                else { ownedFailureDataError113<Unit>("data.failure_event_consumption_pending") }
        }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        // capture happens before the callback's actual raw Err frame retires;
        // no ordinary Ok and no typed capture implicitly ACKs this input.
        match (consume(value)) {
            case Result.Err(error) => value.captureFailure113<Unit>(error)
            case Result.Ok(_) => if (value.isAcknowledged()) { OwnedFailureDataOutcome113<Unit>.Value(()) }
                else { throw OwnedCanonicalDataFailure113(ownedFailureDataError113<Unit>(
                    "data.failure_event_consumption_pending").error().getOrThrow()) }
        }
    }
}
public class OwnedFailureRunPublication113 {
    private let lock = Mutex()
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var snapshot: ?RunSnapshot = None<RunSnapshot>
    private var event: ?EventMeta = None<EventMeta>
    private var borrowing: Int64 = 0
    private var closing = false
    private var acknowledged = false
    private let metadataPeak: Int64
    public init(consumer: OwnedFailureDataConsumer113, snapshot: RunSnapshot, event: EventMeta) {
        if (snapshot.error.isSome() || snapshot.summary != "" || snapshot.structuredOutput.isSome() ||
            (snapshot.status != RunState.RecoveryRequired && snapshot.status != RunState.Failed &&
                snapshot.status != RunState.Cancelled) || snapshot.runId.value != event.runId.value) {
            throw IllegalArgumentException("failure publication requires actual empty same-Run metadata") }
        let peak = ownedFailurePublicationMetadata113(snapshot, event)
        // The constructor retains its OWN real share. An external reference
        // to the supplied consumer cannot ACK this publication's metadata.
        let actual = match (consumer.retainConsumer()) { case Result.Ok(value) => value
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error) }
        try {
            match (ownedFailurePublicationCellPayment113(actual)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
            let paid = OwnedFailurePublicationUnitCell113()
            match (actual.withError({ _, fund => paid.value = fund(peak) })) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
            match (paid.value) { case Result.Err(error) => throw OwnedCanonicalDataFailure113(error); case Result.Ok(_) => () }
            this.consumer = Some(actual); this.snapshot = Some(ownedFailureMetadataCopy113(snapshot));
            this.event = Some(ownedFailureEventMetadataCopy113(event)); this.metadataPeak = peak
        } catch (failure: Exception) { let _ = actual.acknowledgeAfterConsumption(); throw failure }

    }
    public func matchesRun(run: RunId): Bool {
        lock.lock(); try { !closing && snapshot.isSome() && snapshot.getOrThrow().runId.value == run.value }
        finally { lock.unlock() }
    }
    public func retainConsumer(): Result<OwnedFailureRunPublication113> {
        lock.lock()
        try {
            if (closing || consumer.isNone() || snapshot.isNone() || event.isNone()) {
                return ownedFailureDataError113<OwnedFailureRunPublication113>("data.failure_publication_closed") }
            try { Result.Ok(OwnedFailureRunPublication113(consumer.getOrThrow(), snapshot.getOrThrow(), event.getOrThrow())) }
            catch (failure: OwnedCanonicalDataFailure113) { Result<OwnedFailureRunPublication113>.Err(failure.error) }
        } finally { lock.unlock() }
    }
    // Short forward from this publication's actual borrowed consumer. The
    // independently copied display is paid BEFORE allocation and remains paid
    // under its own real handles after this publication's eventual ACK.
    public func deriveCopiedDisplayAllocation113(totalInvoice:Int64):Result<LogicalJsonCopiedDisplayAllocation>{
        lock.lock()
        try{
            if(closing || consumer.isNone() || borrowing==0){
                return ownedFailureDataError113<LogicalJsonCopiedDisplayAllocation>("data.failure_publication_closed")}
            consumer.getOrThrow().deriveCopiedDisplayAllocation113(totalInvoice)
        }finally{lock.unlock()}
    }
    public func captureFailure113<T>(error: AgentError): OwnedFailureDataOutcome113<T> {
        lock.lock()
        try {
            if (closing || consumer.isNone()) { throw OwnedCanonicalDataFailure113(ownedFailureDataError113<Unit>(
                "data.failure_publication_closed").error().getOrThrow()) }
            consumer.getOrThrow().captureFailure113<T>(error)
        } finally { lock.unlock() }
    }
    public func withError(consume: (AgentError, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
        var selected: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
        lock.lock()
        try {
            if (closing || consumer.isNone()) { return ownedFailureDataError113<Unit>("data.failure_publication_closed") }
            borrowing++; selected = consumer
        } finally { lock.unlock() }
        try { ownedFailurePublicationErrorLoan113(selected.getOrThrow(), consume) }
        finally {
            selected = None<OwnedFailureDataConsumer113>
            lock.lock(); try { borrowing-- } finally { lock.unlock() }
        }
    }
    public func withSnapshot(consume: (RunSnapshot, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
        withError({ error, fund =>
            match (fund(metadataPeak)) { case Result.Err(value) => return Result<Unit>.Err(value); case Result.Ok(_) => () }
            // withError holds this publication's real borrowing guard, so ACK
            // cannot clear these references while the actual frame is active.
            ownedFailureSnapshotLoan113(snapshot.getOrThrow(), error, fund, consume)
        })
    }
    public func withDiagnostic(consume: (AgentEvent, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
        withError({ error, fund =>
            if (error.fields.size > Int64.Max / 3072) { throw IllegalStateException("failure Diagnostic nodes overflow") }
            // The ordinary AgentEvent constructor builds its original six-
            // field detail DOM. Charge those actual extra field/list nodes
            // BEFORE construction, in addition to the immutable error root.
            // Observation stays encoded and is not decoded by that detail.
            let extra = ownedFailureDataAdd113(metadataPeak, ownedFailureDataAdd113(
                ownedFailureDataPeak113(error), ownedFailureDataAdd113(1048576,error.fields.size * 3072)))
            match (fund(extra)) { case Result.Err(value) => return Result<Unit>.Err(value); case Result.Ok(_) => () }
            ownedFailureDiagnosticLoan113(event.getOrThrow(), error, fund, consume)
        })
    }
    public func acknowledgeAfterConsumption(): Result<Unit> {
        lock.lock()
        try {
            if (acknowledged) { return Result<Unit>.Ok(()) }
            if (borrowing != 0) { return ownedFailureDataError113<Unit>("data.failure_publication_borrow_pending") }
            closing = true
            // Drop all held Snapshot/Event aliases BEFORE the corresponding
            // original-bank consumer can retire and refund its metadata.
            snapshot = None<RunSnapshot>; event = None<EventMeta>
            let actual = consumer.getOrThrow()
            match (actual.acknowledgeAfterConsumption()) {
                case Result.Err(error) => Result<Unit>.Err(error)
                case Result.Ok(_) => consumer = None<OwnedFailureDataConsumer113>; acknowledged = true; Result<Unit>.Ok(()) }
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { acknowledged } finally { lock.unlock() } }

}

// A constant reference cell is supported by actual Cangjie callbacks. Its
// temporary metadata is explicitly charged to the original consumer before
// allocation. This conservative charge remains paid until that consumer ACK;
// no helper return or GC is used as a refund.
class OwnedFailurePublicationUnitCell113 {
    var value = Result<Unit>.Ok(())
}
func ownedFailurePublicationCellPayment113(consumer: OwnedFailureDataConsumer113): Result<Unit> {
    try {
        consumer.withError({ _, fund =>
            match (fund(4096)) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => ()
            }
        })
    } catch (failure: OwnedCanonicalDataFailure113) { Result<Unit>.Err(failure.error) }
}

func ownedFailurePublicationErrorLoan113(consumer: OwnedFailureDataConsumer113,
    consume: (AgentError, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
    match (ownedFailurePublicationCellPayment113(consumer)) {
        case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
    let answer = OwnedFailurePublicationUnitCell113()
    let borrowed = consumer.withError({ error, fund => answer.value = consume(error, fund) })
    match (borrowed) { case Result.Err(error) => Result<Unit>.Err(error); case Result.Ok(_) => answer.value }
}

// Keep the generated naked Snapshot/Event inside these Unit-consumer frames.
// Their frames physically return before the owner's borrow can end and ACK.
func ownedFailureSnapshotLoan113(metadata: RunSnapshot, error: AgentError, fund: (Int64) -> Result<Unit>,
    consume: (RunSnapshot, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
    let value = RunSnapshot(metadata.runId, metadata.sessionId, metadata.status, sequence: metadata.sequence,
        summary: error.message, error: Some(error), modelRequests: metadata.modelRequests, usage: Some(metadata.usage),
        lastInputTokens: metadata.lastInputTokens, lastOutputTokens: metadata.lastOutputTokens,
        lastRequestDurationMillis: metadata.lastRequestDurationMillis, toolCalls: metadata.toolCalls,
        turns: metadata.turns, kind: metadata.kind)
    consume(value, fund)
}
func ownedFailureDiagnosticLoan113(metadata: EventMeta, error: AgentError, fund: (Int64) -> Result<Unit>,
    consume: (AgentEvent, (Int64) -> Result<Unit>) -> Result<Unit>): Result<Unit> {
    consume(AgentEvent(metadata, AgentEventPayload.Diagnostic(error)), fund)
}
func ownedFailurePublicationMetadata113(snapshot: RunSnapshot, event: EventMeta): Int64 {
    var bytes = ownedFailureDataAdd113(snapshot.runId.value.size, snapshot.sessionId.value.size)
    bytes = ownedFailureDataAdd113(bytes, ownedOuterErrorEventMetadataBytes333(event))
    if (bytes > Int64.Max / 8) { throw IllegalStateException("failure metadata payment overflow") }
    ownedFailureDataAdd113(32768, bytes * 8)
}
func ownedFailureMetadataCopy113(value: RunSnapshot): RunSnapshot {
    RunSnapshot(RunId(String.fromUtf8(value.runId.value.toArray())),
        SessionId(String.fromUtf8(value.sessionId.value.toArray())), value.status,
        sequence: value.sequence, modelRequests: value.modelRequests, usage: Some(value.usage),
        lastInputTokens: value.lastInputTokens, lastOutputTokens: value.lastOutputTokens,
        lastRequestDurationMillis: value.lastRequestDurationMillis, toolCalls: value.toolCalls,
        turns: value.turns, kind: value.kind)
}
func ownedFailureEventMetadataCopy113(value: EventMeta): EventMeta {
    EventMeta(value.sequence, TraceId(String.fromUtf8(value.traceId.value.toArray())),
        RunId(String.fromUtf8(value.runId.value.toArray())), occurredAtMillis: value.occurredAtMillis,
        turnId: match (value.turnId) { case Some(id) => Some(TurnId(String.fromUtf8(id.value.toArray()))); case None => None<TurnId> },
        requestId: match (value.requestId) { case Some(id) => Some(RequestId(String.fromUtf8(id.value.toArray()))); case None => None<RequestId> },
        semanticRequestId: match (value.semanticRequestId) { case Some(id) => Some(SemanticModelRequestId(String.fromUtf8(id.value.toArray()))); case None => None<SemanticModelRequestId> },
        attemptId: match (value.attemptId) { case Some(id) => Some(ModelAttemptId(String.fromUtf8(id.value.toArray()))); case None => None<ModelAttemptId> },
        toolBatchId: match (value.toolBatchId) { case Some(id) => Some(ToolBatchId(String.fromUtf8(id.value.toArray()))); case None => None<ToolBatchId> },
        toolCallId: match (value.toolCallId) { case Some(id) => Some(ToolCallId(String.fromUtf8(id.value.toArray()))); case None => None<ToolCallId> },
        operationId: match (value.operationId) { case Some(id) => Some(OperationId(String.fromUtf8(id.value.toArray()))); case None => None<OperationId> })
}
