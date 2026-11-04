package agent_core

import agent_domain.*
import agent_runtime.*
import std.sync.*

private let planRequestDebts204 = PlanRequestDebts204()

func withPlanRequestCustodyFrame204(custody: ?PlanRequestCustody204,
    invoke: () -> OwnedAgentRunResult113): OwnedAgentRunResult113 {
    match (custody) { case Some(value) => value.beginCoreFrame204(); case None => () }
    let answer = try { invoke() }
    catch (failure: OwnedCanonicalPaidFailure113) {
        // This typed synchronous carrier owns an independent full error
        // clone. Its producing query/root frame has returned; the real
        // handler transfers its consumer and still owes the actual ACK.
        // No accepted Run/task/control debt is waived by this frame return.
        match (custody) { case Some(value) => value.returnCoreFrame204(true); case None => () }
        throw failure
    }
    catch (error: Exception) {
        match (custody) { case Some(value) => value.returnCoreFrame204(false); case None => () }
        throw error
    }
    match (custody) { case Some(value) => value.returnCoreFrame204(true); case None => () }
    answer
}

// The Product transfers its independently copied prompt/system/facts DATA
// allocation here. Both metadata and consumer leases derive from that SAME
// private bank. Neither terminal state nor garbage collection refunds DATA.
public class PlanRequestCustody204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var metadata: ?LogicalJsonOwnerReservation
    private var applicationReturned = false
    private var coreFrames: Int64 = 0
    private var coreReturned = false
    private var coreVisited = false
    private var neverSubmittedProof = false
    private var notAcceptedProof = false
    private var acceptedReturnProof = false
    private var consumers: Int64 = 0
    private var held = false
    private var run: ?RunId = None<RunId>
    var next204: ?PlanRequestCustody204 = None<PlanRequestCustody204>

    public init(payment: LogicalJsonOwnerReservation) {
        let own = payment.deriveRetainedLease()
        try { own.ensureRetainedPeak(16384) }
        catch (error: Exception) { own.close(); throw error }
        this.payment = Some(payment)
        this.metadata = Some(own)
        planRequestDebts204.retain204(this)
    }

    // Only the actual Product owner calls this AFTER clearing currentRequest
    // and after its complete request helper returns. A raw exported request
    // has no such return proof and must conservatively remain paid.
    public func returnApplicationFrame204(): Unit {
        lock.lock(); try { applicationReturned = true } finally { lock.unlock() }
        collect204()
    }
    public func isDataReturned204(): Bool {
        lock.lock(); try { payment.isNone() } finally { lock.unlock() }
    }
    // Caller proof of no submission, never a substitute for a Run witness.
    public func returnUnsubmittedApplicationFrame204(): Result<Unit> {
        lock.lock(); try {
            if (payment.isNone() || coreVisited || coreFrames != 0 || consumers != 0 || run.isSome() ||
                coreReturned || notAcceptedProof || acceptedReturnProof || held || applicationReturned) {
                return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "plan.request_already_submitted", "the actual request has already entered its Core lifecycle")) }
            neverSubmittedProof = true; notAcceptedProof = true; applicationReturned = true
        } finally { lock.unlock() }
        collect204(); Result<Unit>.Ok(())
    }
    func visitCore204(): Unit {
        lock.lock(); try {
            if (payment.isNone() || applicationReturned) {
                throw IllegalStateException("request custody is no longer open for Core") }
            coreVisited = true
        } finally { lock.unlock() }
    }
    func coreFramesReturned204(): Bool {
        lock.lock(); try { !held && coreReturned && coreFrames == 0 } finally { lock.unlock() }
    }

    func beginCoreFrame204(): Unit {
        lock.lock(); try {
            if (payment.isNone() || applicationReturned || coreFrames == Int64.Max) {
                throw IllegalStateException("request custody cannot admit a new Core frame") }
            coreVisited = true; coreFrames++
        } finally { lock.unlock() }
    }
    // Only a branch which has not called runtime admission may state this.
    // A generic start/commit error is not a non-acceptance certificate.
    func rejectedBeforeRuntimeInvocation204(): Unit {
        lock.lock(); try { notAcceptedProof = true } finally { lock.unlock() }
    }
    func returnCoreFrame204(knownReturned: Bool): Unit {
        lock.lock(); try {
            if (coreFrames < 1) { held = true; return }
            coreFrames--; coreReturned = true
            if (!knownReturned) { held = true }
        } finally { lock.unlock() }
        collect204()
    }

    func retainControl204(actualRun: RunId): CorePlanRequestConsumer204 {
        lock.lock(); try {
            if (payment.isNone() || applicationReturned || consumers == Int64.Max) {
                throw IllegalStateException("request custody cannot admit a control consumer") }
            coreVisited = true
            match (run) { case Some(value) => if (value.value != actualRun.value) {
                held = true; throw IllegalArgumentException("request custody belongs to another Run") }
                case None =>
                    if (actualRun.value.size > (Int64.Max - 16384) / 16) {
                        throw IllegalArgumentException("request Run identity invoice overflow") }
                    metadata.getOrThrow().ensureRetainedPeak(16384 + actualRun.value.size * 16)
                    run = Some(RunId(String.fromUtf8(actualRun.value.toArray()))) }
            let own = metadata.getOrThrow().deriveRetainedLease()
            try { own.ensureRetainedPeak(8192) }
            catch (error: Exception) { own.close(); throw error }
            consumers++
            CorePlanRequestConsumer204(this, own)
        } finally { lock.unlock() }
    }
    func returnedControl204(acceptedReturned: Bool): Unit {
        lock.lock(); try {
            if (consumers < 1) { held = true; return }
            consumers--
            if (acceptedReturned) { acceptedReturnProof = true } else { notAcceptedProof = true }
        } finally { lock.unlock() }
        collect204()
    }
    private func collect204(): Unit {
        let paid = detachReturnedFrame204()
        match (paid[0]) { case Some(value) => value.close(); case None => () }
        match (paid[1]) { case Some(value) => value.close(); case None => () }
    }
    private func detachReturnedFrame204(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock(); try {
            if (held || !applicationReturned || (!coreReturned && !neverSubmittedProof) || (!notAcceptedProof && !acceptedReturnProof) ||
                coreFrames != 0 || consumers != 0 || payment.isNone()) {
                return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            run = None<RunId>
            let data = payment; let own = metadata
            payment = None<LogicalJsonOwnerReservation>; metadata = None<LogicalJsonOwnerReservation>
            planRequestDebts204.remove204(this)
            (data, own)
        } finally { lock.unlock() }
    }
}

// A control's independent consumer is returned only after its real accepted
// Run task witness and every other control consumer have returned. It holds
// no request alias and cannot manufacture a task-return witness.
class CorePlanRequestConsumer204 {
    private let lock = Mutex()
    private var owner: ?PlanRequestCustody204
    private var payment: ?LogicalJsonOwnerReservation
    private var witness: ?OwnedTaskReturnWitness113 = None<OwnedTaskReturnWitness113>
    var next204: ?CorePlanRequestConsumer204 = None<CorePlanRequestConsumer204>
    init(owner: PlanRequestCustody204, payment: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.payment = Some(payment)
    }
    func matches204(actual: PlanRequestCustody204): Bool {
        lock.lock(); try { match (owner) { case Some(value) => refEq(value, actual); case None => false } }
        finally { lock.unlock() }
    }
    func coreFramesReturned204(): Bool {
        let actual = try { lock.lock(); owner } finally { lock.unlock() }
        match (actual) { case Some(value) => value.coreFramesReturned204(); case None => false }
    }
    func bindWitness204(actual: ?OwnedTaskReturnWitness113): Unit {
        lock.lock(); try { witness = actual } finally { lock.unlock() }
    }
    func tasksReturnedFrame204(): Bool {
        let actual = try { lock.lock(); witness } finally { lock.unlock() }
        match (actual) { case Some(value) => value.allOwnedProducersReturned113(); case None => false }
    }
    // Called after this node is removed from the live control list, and after
    // the witness query's entire frame returns. The caller holds no request.
    func returnConsumerFrame204(acceptedReturned!: Bool = true): Unit {
        let actual = owner; let own = payment
        owner = None<PlanRequestCustody204>; payment = None<LogicalJsonOwnerReservation>
        witness = None<OwnedTaskReturnWitness113>; next204 = None<CorePlanRequestConsumer204>
        match (actual) { case Some(value) => value.returnedControl204(acceptedReturned); case None => () }
        match (own) { case Some(value) => value.close(); case None => () }
    }
}

private class PlanRequestDebts204 {
    private let lock = Mutex()
    private var head: ?PlanRequestCustody204 = None<PlanRequestCustody204>
    func retain204(value: PlanRequestCustody204): Unit {
        lock.lock(); try { value.next204 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: PlanRequestCustody204): Unit {
        lock.lock(); try {
            var prior: ?PlanRequestCustody204 = None<PlanRequestCustody204>
            var cursor = head
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (prior) { case Some(previous) => previous.next204 = actual.next204
                        case None => head = actual.next204 }
                    actual.next204 = None<PlanRequestCustody204>; return
                }
                prior = cursor; cursor = actual.next204
            }
        } finally { lock.unlock() }
    }
}
