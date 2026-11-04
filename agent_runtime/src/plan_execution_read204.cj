package agent_runtime

import agent_domain.*
import std.sync.*

// Read-only DATA custody. The caller supplies its existing private bank; no
// Store, authority, allocator source or new resource pool is created here.
public interface PlanExecutionReadDataPort204 {
    func openRequest204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
    func openBinding204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
    func openInspection204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
    func openSessionInspection204(sessionId: String, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
    func openSessionScope204(sessionId: String, payer: LogicalJsonOwnerReservation): Result<?PlanExecutionReadOwner204>
    func openRunScope204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
    func canContinue204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Bool>
    func requireComplete204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Unit>
    func finish204(runId: RunId, payer: LogicalJsonOwnerReservation): Result<Unit>
    func validateContextResource204(runId: RunId, source: String, payer: LogicalJsonOwnerReservation): Result<Unit>
    func observe204(runId: RunId, operationId: OperationId, payer: LogicalJsonOwnerReservation): Result<PlanExecutionReadOwner204>
}

private let planReadOwners204 = PlanReadOwners204()

public class PlanExecutionReadOwner204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var data: ?AgentValue = None<AgentValue>
    private var consumers: Int64 = 0
    private var callerReturned = false
    private var held = false
    var next204: ?PlanExecutionReadOwner204 = None<PlanExecutionReadOwner204>
    public init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); planReadOwners204.retain204(this)
    }
    // The producer funds the complete same-TX raw/DOM/derived peak first.
    public func ensureProducerPeak204(bytes: Int64): Unit {
        lock.lock(); try { payment.getOrThrow().ensureRetainedPeak(bytes) } finally { lock.unlock() }
    }
    // The existing source graph is already funded before this traversal.
    // Pay its actual transient canonical/hash/output work from the SAME owner
    // before a projection/string producer runs; no new bank or custody root.
    public func fundProducerGraphWork204(value: AgentValue, priorInvoice: Int64): Int64 {
        lock.lock()
        try {
            let meter = ToolSnapshotMeasure159(payment.getOrThrow(), priorInvoice: priorInvoice)
            meter.addValue159(value); meter.fund159(); meter.retainedInvoice159()
        } finally { lock.unlock() }
    }
    public func installProducerData204(value: AgentValue): Unit {
        lock.lock()
        try {
            if (callerReturned || data.isSome() || payment.isNone()) { throw IllegalStateException("plan read already installed") }
            data = Some(value)
        } finally { lock.unlock() }
    }
    public func deriveRetainedAllocation204(bytes: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            let child = payment.getOrThrow().deriveRetainedLease()
            try { child.ensureRetainedPeak(bytes); child }
            catch (error: Exception) { child.close(); throw error }
        } finally { lock.unlock() }
    }
    public func beginConsumer204(): PlanExecutionReadConsumer204 {
        lock.lock()
        try {
            if (callerReturned || data.isNone() || payment.isNone() || consumers == Int64.Max) {
                throw IllegalStateException("plan read cannot admit a consumer") }
            let metadata = payment.getOrThrow().deriveRetainedLease()
            try {
                metadata.ensureRetainedPeak(4096)
                let value = PlanExecutionReadConsumer204(this, metadata)
                consumers++; value
            } catch (error: Exception) { metadata.close(); throw error }
        } finally { lock.unlock() }
    }
    func borrowedValue204(): AgentValue {
        lock.lock(); try { data.getOrThrow() } finally { lock.unlock() }
    }
    public func holdUnknownConsumer204(): Unit {
        lock.lock(); try { held = true } finally { lock.unlock() }
    }
    // This is a complete concrete caller-frame acknowledgement, never an
    // Operation/Run/provider result or a callback-return acknowledgement.
    public func closeAfterCaller204(): Unit {
        let returned = callerReturnedFrame204()
        match (returned) { case Some(value) => value.close(); case None => () }
    }
    private func callerReturnedFrame204(): ?LogicalJsonOwnerReservation {
        lock.lock(); try { callerReturned = true; detach204() } finally { lock.unlock() }
    }
    func returnedConsumer204(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (consumers < 1) { throw IllegalStateException("plan read consumer was not registered") }
            consumers--; detach204()
        } finally { lock.unlock() }
    }
    private func detach204(): ?LogicalJsonOwnerReservation {
        if (!callerReturned || consumers != 0 || held || payment.isNone()) { return None<LogicalJsonOwnerReservation> }
        data = None<AgentValue>
        let returned = payment; payment = None<LogicalJsonOwnerReservation>
        planReadOwners204.remove204(this)
        returned
    }
}

public class PlanExecutionReadConsumer204 {
    private let lock = Mutex()
    private var owner: ?PlanExecutionReadOwner204
    private var metadata: ?LogicalJsonOwnerReservation
    init(owner: PlanExecutionReadOwner204, metadata: LogicalJsonOwnerReservation) {
        this.owner = Some(owner); this.metadata = Some(metadata)
    }
    public func value204(): AgentValue {
        lock.lock(); try { owner.getOrThrow().borrowedValue204() } finally { lock.unlock() }
    }
    // Call only after the whole helper that borrowed value204 has returned
    // and discarded every alias. A retained borrow keeps the owner charged.
    public func returnConsumerFrame204(): Unit {
        let returned = returnFrame204()
        match (returned[0]) { case Some(value) => value.close(); case None => () }
        match (returned[1]) { case Some(value) => value.close(); case None => () }
    }
    private func returnFrame204(): (?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        lock.lock()
        try {
            if (owner.isNone()) { return (None<LogicalJsonOwnerReservation>, None<LogicalJsonOwnerReservation>) }
            let dataPayment = owner.getOrThrow().returnedConsumer204()
            owner = None<PlanExecutionReadOwner204>
            let own = metadata; metadata = None<LogicalJsonOwnerReservation>
            (dataPayment, own)
        } finally { lock.unlock() }
    }
}

private class PlanReadOwners204 {
    private let lock = Mutex()
    private var first: ?PlanExecutionReadOwner204 = None<PlanExecutionReadOwner204>
    func retain204(value: PlanExecutionReadOwner204): Unit {
        lock.lock(); try { value.next204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: PlanExecutionReadOwner204): Unit {
        lock.lock()
        try {
            var prior: ?PlanExecutionReadOwner204 = None<PlanExecutionReadOwner204>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (prior) { case Some(p) => p.next204 = current.next204; case None => first = current.next204 }
                    current.next204 = None<PlanExecutionReadOwner204>; return
                }
                prior = cursor; cursor = current.next204
            }
            throw IllegalStateException("plan read owner was not registered")
        } finally { lock.unlock() }
    }
}
