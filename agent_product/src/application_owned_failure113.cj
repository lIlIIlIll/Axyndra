package agent_product

import agent_core.*
import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import std.collection.ArrayList
import std.sync.Mutex

// Fixed rejection metadata is never a handoff key. Each actual invocation
// creates its own paid marker only after its precise outcome is installed.
let APPLICATION_OWNED_FAILURE_MARKER113 = AgentError(AgentErrorKind.RecoveryRequired,
    "application.owned_failure_pending", "an actual failure awaits its paid caller")
func applicationOwnedFailurePending113(): Result<Unit> {
    Result<Unit>.Err(APPLICATION_OWNED_FAILURE_MARKER113)
}

class ApplicationOwnedEventSink113 <: OwnedAgentEventSink & OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let ordinary: (OwnedAgentEvent) -> Result<Unit>
    private let failures: (OwnedFailureRunPublication113) -> OwnedFailureEventAdmissionOutcome113
    init(ordinary: (OwnedAgentEvent) -> Result<Unit>,
        failures: (OwnedFailureRunPublication113) -> OwnedFailureEventAdmissionOutcome113) {
        this.ordinary = ordinary; this.failures = failures
    }
    public func emit(value: OwnedAgentEvent): Result<Unit> { ordinary(value) }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        failures(value)
    }
    // This Result port cannot transfer a paid secondary failure. Admission
    // uses the typed port; an unconsumed Result call cannot promise delivery.
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        if (value.isAcknowledged()) { Result<Unit>.Ok(()) } else { applicationOwnedFailurePending113() }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case OwnedFailureEventAdmissionOutcome113.Failed(error) => OwnedFailureDataOutcome113<Unit>.Failure(error)
            case OwnedFailureEventAdmissionOutcome113.Held =>
                throw OwnedCanonicalDataFailure113(APPLICATION_OWNED_FAILURE_MARKER113)
        }
    }
}

// Reference cells keep indirect Cangjie callbacks from capturing mutable
// local variables. They are control metadata inside the already paid slot.
class ApplicationOwnedFailureKind113 { var value = AgentErrorKind.RecoveryRequired }

// Session lock owns these state transitions. The original native allocator
// pays BEFORE copying Run identity, allocating a slot or creating a marker.
// No source authority or independent budget is created. Transferring a result
// keeps this slot paid until that exact caller consumer actually acknowledges.
class ApplicationOwnedCheckpointSlot113 {
    private var owner: ?LogicalJsonOwnerReservation
    private var run: ?RunId
    private var marker: ?AgentError = None<AgentError>
    private var value = OwnedAgentRunResult113.Held
    private var invoking = true
    private var transferred = false
    private var handingOff = false
    init(run: RunId, owner: LogicalJsonOwnerReservation) {
        this.owner = Some(owner)
        this.run = Some(RunId(String.fromUtf8(run.value.toArray())))
    }
    func matches(run: RunId): Bool { this.run.isSome() && this.run.getOrThrow().value == run.value }
    func matches(marker: AgentError): Bool {
        this.marker.isSome() && refEq(this.marker.getOrThrow(), marker)
    }
    func blockingMarker(): AgentError {
        match (marker) { case Some(actual) => actual; case None => APPLICATION_OWNED_FAILURE_MARKER113 }
    }
    func isInvoking(): Bool { invoking }
    func isHandingOff(): Bool { handingOff }
    func isTransferred(): Bool { transferred }
    func heldValue(): OwnedAgentRunResult113 { value }
    func isHeld(): Bool { match (value) { case OwnedAgentRunResult113.Held => true; case _ => false } }
    func install(actual: OwnedAgentRunResult113): Result<Unit> {
        // Install first: even a failed metadata/loan operation leaves the
        // original paid consumer in this reserved slot, never in a raw Err.
        value = actual; invoking = false
        let kind = ApplicationOwnedFailureKind113()
        let borrowed = match (actual) {
            case OwnedAgentRunResult113.Failed(publication) =>
                publication.withError({ error, _ => kind.value = error.kind; Result<Unit>.Ok(()) })
            case OwnedAgentRunResult113.Pending(consumer) =>
                consumer.withError({ error, _ => kind.value = error.kind })
            case _ => Result<Unit>.Ok(())
        }
        match (borrowed) {
            case Result.Err(error) =>
                // The exact metadata/loan error is returned explicitly. It
                // is not presented as the original failure's classification.
                // Its paid original result is already in this same slot.
                marker = Some(error); return Result<Unit>.Err(error)
            case Result.Ok(_) => () }
        marker = Some(AgentError(kind.value, "application.owned_failure_pending", "an actual failure awaits its paid caller"))
        Result<Unit>.Ok(())
    }
    // Only the Session-held poll uses this loan. Its handingOff guard
    // keeps the actual copied run and reservation alive outside its mutex.
    func getRunData113(): RunId {
        if (!handingOff || transferred || invoking) { throw IllegalStateException("held checkpoint poll is not active") }
        run.getOrThrow()
    }
    // Only ApplicationSession invokes this while its lock prevents slot
    // retirement. This is a short DATA loan from the actual reserved owner.
    func withRunIdentity113(consume: (RunId) -> Result<Unit>): Result<Unit> {
        if (invoking || handingOff || owner.isNone() || run.isNone()) { return applicationOwnedFailurePending113() }
        consume(run.getOrThrow())
    }

    func installHeldOutcome113(actual: OwnedAgentRunResult113): Result<Unit> {
        if (handingOff || transferred || !isHeld()) { throw IllegalStateException("held checkpoint outcome changed") }
        let identity = marker
        try { install(actual) }
        finally { marker = identity }
    }
    func beginHandoff(): ?OwnedAgentRunResult113 {
        if (invoking || transferred || handingOff || isHeld()) { return None<OwnedAgentRunResult113> }
        handingOff = true; Some(value)
    }
    func beginHeldPoll(): Bool {
        if (invoking || transferred || handingOff || !isHeld()) { return false }
        handingOff = true; true
    }
    func finishHandoff(accepted: Bool): Unit {
        if (accepted) { transferred = true }
        handingOff = false
    }
    func isConsumed(): Bool {
        if (!transferred || invoking || handingOff) { return false }
        match (value) {
            case OwnedAgentRunResult113.Failed(publication) => publication.isAcknowledged()
            case OwnedAgentRunResult113.Pending(consumer) => consumer.isAcknowledged()
            case _ => false
        }
    }
    // Existing has no new paid caller, or a transferred consumer is really
    // ACKed. Drop all slot references before returning this control custody.
    func retireMetadata(): Unit {
        value = OwnedAgentRunResult113.Held
        marker = None<AgentError>; run = None<RunId>
        let actual = owner; owner = None<LogicalJsonOwnerReservation>
        match (actual) { case Some(paid) => paid.close(); case None => () }
    }
}

// Accepted admission and acknowledged consumption are independent states.
// A partially offered/unknown delivery keeps its original share paid. A fully
// accepted asynchronous delivery settles only after every real child ACK.
class ApplicationOwnedFailureEventGroup113 {
    private let lock = Mutex()
    private var primary: ?OwnedFailureRunPublication113
    private let children = ArrayList<OwnedFailureRunPublication113>()
    private var dispatched = false
    init(value: OwnedFailureRunPublication113) { primary = Some(value) }
    func matchesRun113(run: RunId): Bool {
        lock.lock(); try { match (primary) { case Some(value) => value.matchesRun(run); case None => false } }
        finally { lock.unlock() }
    }

    func add(value: OwnedFailureRunPublication113): Unit {
        lock.lock(); try { children.add(value) } finally { lock.unlock() }
    }
    func finishDispatch(): Unit {
        lock.lock(); try { dispatched = true } finally { lock.unlock() }
    }
    func settle(): Result<Unit> {
        lock.lock()
        try {
            if (primary.isNone()) { return Result<Unit>.Ok(()) }
            if (!dispatched) { return applicationOwnedFailurePending113() }
            for (child in children) { if (!child.isAcknowledged()) { return applicationOwnedFailurePending113() } }
            children.clear()
            match (primary.getOrThrow().acknowledgeAfterConsumption()) {
                case Result.Err(error) => Result<Unit>.Err(error)
                case Result.Ok(_) => primary = None<OwnedFailureRunPublication113>; Result<Unit>.Ok(())
            }
        } finally { lock.unlock() }
    }
    func isRetired(): Bool { lock.lock(); try { primary.isNone() } finally { lock.unlock() } }
}
