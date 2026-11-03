package agent_core

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.sync.*

private let coreModelInputDebts159 = CoreModelInputDebts159()

// A private DATA holder on the existing Registry bank. The Future captures
// this prepaid cell; its action is cleared only after the action frame returns.
// A completed flag alone never releases either the input graph or its invoice.
class CoreModelInput159 <: ModelInputDataBudget159 {
    private let lock = Mutex()
    private let workerFinished = AtomicBool(false)
    private var payment: ?LogicalJsonOwnerReservation
    private var action: ?(() -> Result<ModelReply>) = None<() -> Result<ModelReply>>
    private var future: ?Future<Result<ModelReply>> = None<Future<Result<ModelReply>>>
    private var toolsBorrow159: ?ModelInputToolsBorrow159 = None<ModelInputToolsBorrow159>
    private var callerReturned = false
    private var inputReturned = false
    private var returnWitness159: ?ModelInputReturnWitness159 = None<ModelInputReturnWitness159>
    private var held = false
    private var retiring = false
    var next159: ?CoreModelInput159 = None<CoreModelInput159>
    var debtNext159: ?CoreModelInput159 = None<CoreModelInput159>
    private var originalTaskWitness180: ?OwnedTaskReturnWitness113 = None<OwnedTaskReturnWitness113>
    private var originalFailure180: ?Exception = None<Exception>
    func bindOriginalTaskWitness180(value: ?OwnedTaskReturnWitness113): Unit {
        lock.lock(); try { originalTaskWitness180 = value } finally { lock.unlock() }
    }
    private func originalTaskWitnessReturnedFrame180(): Bool {
        let actual = try { lock.lock(); originalTaskWitness180 } finally { lock.unlock() }
        match (actual) { case Some(value) => value.allOwnedProducersReturned113(); case None => false }
    }


    init(payment: LogicalJsonOwnerReservation, request: ModelRequest) {
        this.payment = Some(payment)
        coreModelInputDebts159.retain159(this)
        try {
            toolsBorrow159 = match (request.inputToolsLifetime159) {
                case Some(value) => Some(value.borrowModelTools159())
                case None => None<ModelInputToolsBorrow159>
            }
        } catch (error: Exception) { held = true; throw error }
    }

    public func reserveRetainedModelMetadata159(bytes: Int64): LogicalJsonOwnerReservation {
        if (bytes < 1) { throw IllegalArgumentException("model metadata invoice must be positive") }
        lock.lock()
        try {
            if (payment.isNone() || retiring || inputReturned) {
                throw IllegalStateException("model input has no active funding owner")
            }
            let independent = payment.getOrThrow().deriveRetainedLease()
            try { independent.ensureRetainedPeak(bytes); independent }
            catch (error: Exception) { independent.close(); throw error }
        } finally { lock.unlock() }
    }

    func start159(value: () -> Result<ModelReply>): Future<Result<ModelReply>> {
        lock.lock()
        try {
            if (action.isSome() || future.isSome() || payment.isNone()) {
                throw IllegalStateException("model input already has its actual worker")
            }
            action = Some(value)
            let actual = spawn { executeAction159() }
            future = Some(actual)
            actual
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }

    private func executeAction159(): Result<ModelReply> {
        try { invokeActionFrame159() }
        finally {
            // invokeActionFrame159, including its copied callback reference,
            // has left the stack before the cell drops the last action field.
            lock.lock()
            try { action = None<() -> Result<ModelReply>> }
            finally { lock.unlock() }
            workerFinished.store(true)
        }
    }
    private func invokeActionFrame159(): Result<ModelReply> {
        let actual = try { lock.lock(); action.getOrThrow() } finally { lock.unlock() }
        actual()
    }

    func recordInputReturn159(knownReturned: Bool): Unit {
        lock.lock()
        try {
            if (knownReturned) { inputReturned = true } else { held = true }
        } finally { lock.unlock() }
    }
    func pendingInputReturn159(witness: ModelInputReturnWitness159): Unit {
        lock.lock(); try { returnWitness159 = Some(witness) } finally { lock.unlock() }
    }
    private func returnedInputWitnessFrame159(): Bool {
        let actual = try { lock.lock(); returnWitness159 } finally { lock.unlock() }
        match (actual) { case Some(value) => value.inputAliasesReturned159(); case None => false }
    }
    func returnedCaller159(): Unit {
        lock.lock(); try { callerReturned = true } finally { lock.unlock() }
    }
    func hold159(error!: ?Exception = None<Exception>): Unit {
        lock.lock(); try { held = true; if (originalFailure180.isNone()) { originalFailure180 = error } } finally { lock.unlock() }
    }

    private func returnedFutureFrame159(): Bool {
        let selected = try { lock.lock(); future } finally { lock.unlock() }
        match (selected) {
            case None => false
            case Some(actual) =>
                try { let _ = actual.get(); true }
                catch (_: Exception) { false }
        }
    }
    func takeReturnedPayment159(): ?LogicalJsonOwnerReservation {
        if (!originalTaskWitnessReturnedFrame180()) { return None<LogicalJsonOwnerReservation> }
        // No collector holds the input cell lock while reading the provider's
        // separate DATA witness. Its complete query frame returns first.
        if (returnedInputWitnessFrame159()) {
            lock.lock(); try { inputReturned = true; returnWitness159 = None<ModelInputReturnWitness159> }
            finally { lock.unlock() }
        }
        lock.lock()
        try {
            if (retiring || held || !callerReturned || !inputReturned ||
                !workerFinished.load() || action.isSome() || payment.isNone()) {
                return None<LogicalJsonOwnerReservation>
            }
            retiring = true
        } finally { lock.unlock() }
        // The observer is never asked to get foreign-blocked work. The marker
        // only permits the get; successful whole get return is still required.
        if (!returnedFutureFrame159()) {
            lock.lock(); try { held = true; retiring = false } finally { lock.unlock() }
            return None<LogicalJsonOwnerReservation>
        }
        lock.lock()
        try {
            if (held || action.isSome()) { retiring = false; return None<LogicalJsonOwnerReservation> }
            future = None<Future<Result<ModelReply>>>
            // Provider witness, actual Future.get and all helper returns were
            // checked above. This returns only this independently held input.
            match (toolsBorrow159) { case Some(value) => value.returnModelToolsFrame159(); case None => () }
            toolsBorrow159 = None<ModelInputToolsBorrow159>
            originalTaskWitness180 = None<OwnedTaskReturnWitness113>
            let value = payment
            payment = None<LogicalJsonOwnerReservation>
            value
        } finally { lock.unlock() }
    }
}

// Unknown aliases have an explicit, prepaid strong owner, even after the old
// Core Run registry drops its terminal control. No GC/finalizer refunds them.
private class CoreModelInputDebts159 {
    private let lock = Mutex()
    private var head: ?CoreModelInput159 = None<CoreModelInput159>
    func retain159(value: CoreModelInput159): Unit {
        lock.lock(); try { value.debtNext159 = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: CoreModelInput159): Unit {
        lock.lock()
        try {
            var prior: ?CoreModelInput159 = None<CoreModelInput159>
            var cursor = head
            while (cursor.isSome()) {
                let item = cursor.getOrThrow()
                if (refEq(item, value)) {
                    match (prior) { case Some(p) => p.debtNext159 = item.debtNext159
                        case None => head = item.debtNext159 }
                    item.debtNext159 = None<CoreModelInput159>
                    return
                }
                prior = cursor; cursor = item.debtNext159
            }
        } finally { lock.unlock() }
    }
}

func removeReturnedModelInputDebt159(value: CoreModelInput159): Unit {
    coreModelInputDebts159.remove159(value)
}

// Explicit owned-provider contract, not callback Unit and not Run terminal.
// Unknown ModelPort implementations retain their input allocation. The raw
// compatibility contract cannot prove that their request aliases have retired.
func executeModelInput159(model: ModelPort, request: ModelRequest, events: ModelEventSink,
    custody: ?CoreModelInput159, settings180: AgentValue,
    counters180: ?ModelStreamFaultCounters180, stopped180: () -> Bool): Result<ModelReply> {
    match (executeFrozenModelFault180(settings180, counters180, events, stopped180)) {
        case Some(result) =>
            // The complete local injection helper returned without exposing
            // request to a provider. Its actual action/Future/caller must still
            // return before the existing custody collector can clear anything.
            match (custody) { case Some(value) => value.recordInputReturn159(true); case None => () }
            return result
        case None => ()
    }

    match (model) {
        case consumer: ReturningModelInputPort159 =>
            let owner = match (custody) {
                case Some(value) => value
                // Catalogs without a Registry owner keep their original API;
                // this path never creates an unrelated fallback bank.
                case None => return model.execute(request, events)
            }
            let returned = consumer.executeReturningInput159(request, events, owner)
            match (returned) {
                case ModelInputReturn159.Returned(result) =>
                    match (custody) { case Some(value) => value.recordInputReturn159(true); case None => () }
                    result
                case ModelInputReturn159.Pending(result, witness) =>
                    owner.pendingInputReturn159(witness)
                    result
                case ModelInputReturn159.Held(result) =>
                    match (custody) { case Some(value) => value.recordInputReturn159(false); case None => () }
                    result
            }
        case _ =>
            match (custody) { case Some(value) => value.recordInputReturn159(false); case None => () }
            model.execute(request, events)
    }
}
