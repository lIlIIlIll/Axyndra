package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

private let canonicalArgumentsDebts204 = CanonicalArgumentsDebts204()

// Temporary canonicalizer DATA only. The host producer pays on its actual
// configuration bank and returns its complete private construction frame.
// Pipeline copies the outcome to its original Core bank before acknowledging
// this carrier. Neither the outcome nor the acknowledgment grants authority.
public class ToolCanonicalArgumentsOwner204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var outcome: ?Result<AgentValue> = None<Result<AgentValue>>
    private var retained: Int64 = 131072
    private var producerReturned = false
    private var consumerActive = false
    private var loans204: Int64 = 0
    private var callerReturned = false
    private var held = false
    private var returned = false
    private let prepayStatus204 = ToolCopyPrepayStatus204()
    private var copyStarted204 = false
    private var precopyRefused204 = false
    var next204: ?ToolCanonicalArgumentsOwner204 = None<ToolCanonicalArgumentsOwner204>
    public init(payment: LogicalJsonOwnerReservation) {
        payment.ensureRetainedPeak(131072)
        this.payment = Some(payment)
        canonicalArgumentsDebts204.retain204(this)
    }
    public func fundAdditional204(invoice: Int64): Unit {
        lock.lock(); try {
            if (producerReturned || outcome.isSome() || returned || invoice < 1 || invoice > Int64.Max - retained) {
                throw IllegalStateException("canonicalizer DATA construction is unavailable") }
            try { prepayStatus204.fundRetainedPeak204(payment.getOrThrow(), retained + invoice) }
            catch (error: Exception) {
                if (prepayStatus204.isExactRefusal204(error)) { precopyRefused204 = true }
                else { held = true }; throw error
            }
            retained += invoice
        } finally { lock.unlock() }
    }
    public func installProducerData204(value: AgentValue): Unit {
        lock.lock(); try {
            requireConstruction204()
            let meter = ToolSnapshotMeasure159(payment.getOrThrow(), prepayStatus204, priorInvoice: retained)
            meter.addValue159(value); meter.fund159(); retained = meter.retainedInvoice159()
            copyStarted204 = true
            outcome = Some(Result<AgentValue>.Ok(copyJsonData204(value)))
        } catch (error: Exception) {
            if (!copyStarted204 && outcome.isNone() && prepayStatus204.isExactRefusal204(error)) { precopyRefused204 = true }
            else { held = true }; throw error
        }
        finally { lock.unlock() }
    }
    public func installProducerError204(error: AgentError): Unit {
        lock.lock(); try {
            requireConstruction204()
            let meter = ToolSnapshotMeasure159(payment.getOrThrow(), prepayStatus204, priorInvoice: retained)
            meter.addText159(error.code); meter.addText159(error.message); meter.addSlots159(error.fields.size)
            for (field in error.fields) { meter.addText159(field.name); meter.addText159(field.value) }
            meter.fund159(); retained = meter.retainedInvoice159()
            if (error.attemptFailure.isSome() || error.observation.isSome()) { held = true }
            copyStarted204 = true
            outcome = Some(Result<AgentValue>.Err(AgentError(error.kind, copyTextData204(error.code), copyTextData204(error.message),
                retryable: error.retryable, fallbackAllowed: error.fallbackAllowed,
                fields: error.fields.map { field => ErrorField(copyTextData204(field.name), copyTextData204(field.value)) },
                attemptFailure: error.attemptFailure, observation: error.observation)))
        } catch (failure: Exception) {
            if (!copyStarted204 && outcome.isNone() && prepayStatus204.isExactRefusal204(failure)) { precopyRefused204 = true }
            else { held = true }; throw failure
        }
        finally { lock.unlock() }
    }
    // Preserve the preparer's final current-source recheck AFTER copying.
    // Only its unpublished success may become a copied business error. The
    // already funded success peak is retained; this is never a refund/clear.
    public func rejectCopiedProducerData204(error: AgentError): Unit {
        lock.lock(); try {
            if (producerReturned || consumerActive || callerReturned || returned || outcome.isNone()) {
                throw IllegalStateException("canonicalizer DATA outcome is already published") }
            match (outcome.getOrThrow()) { case Result.Ok(_) => (); case Result.Err(_) =>
                throw IllegalStateException("canonicalizer DATA outcome is not pending success") }
            let meter = ToolSnapshotMeasure159(payment.getOrThrow(), priorInvoice: retained)
            meter.addText159(error.code); meter.addText159(error.message); meter.addSlots159(error.fields.size)
            for (field in error.fields) { meter.addText159(field.name); meter.addText159(field.value) }
            meter.fund159(); retained = meter.retainedInvoice159()
            if (error.attemptFailure.isSome() || error.observation.isSome()) { held = true }
            outcome = Some(Result<AgentValue>.Err(AgentError(error.kind, copyTextData204(error.code), copyTextData204(error.message),
                retryable: error.retryable, fallbackAllowed: error.fallbackAllowed,
                fields: error.fields.map { field => ErrorField(copyTextData204(field.name), copyTextData204(field.value)) },
                attemptFailure: error.attemptFailure, observation: error.observation)))
        } catch (failure: Exception) { held = true; throw failure }
        finally { lock.unlock() }
    }
    // Only after the complete Host producer helper has returned/unwound.
    // A pre-copy bank refusal is nonacceptance, not a generic abort token.
    public func closeUnacceptedProducer204(error: Exception): Bool {
        lock.lock(); try {
            if (returned || held || producerReturned || consumerActive || callerReturned || copyStarted204 ||
                outcome.isSome() || !precopyRefused204 || !prepayStatus204.isExactRefusal204(error)) { return false }
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            prepayStatus204.clearReturnedFrame204(); returned = true
            canonicalArgumentsDebts204.remove204(this); true
        } finally { lock.unlock() }
    }
    private func requireConstruction204(): Unit {
        if (producerReturned || outcome.isSome() || returned || payment.isNone()) {
            throw IllegalStateException("canonicalizer DATA producer has returned") }
    }
    // Called only AFTER the entire concrete host preparer helper returned,
    // including its worker/proposal/configuration and original response aliases.
    public func producerFrameReturned204(): Unit {
        lock.lock(); try {
            if (producerReturned || outcome.isNone() || returned) { throw IllegalStateException("canonicalizer DATA outcome is not installed") }
            producerReturned = true
        } finally { lock.unlock() }
    }
    public func holdUnknownConsumer204(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    func requireSameBank204(actual: LogicalJsonOwnerReservation): Unit {
        lock.lock(); try {
            if (returned || payment.isNone() || !payment.getOrThrow().paysSamePrivateBankData180(actual)) {
                throw IllegalArgumentException("canonicalizer DATA requires its original Registry bank") }
        } finally { lock.unlock() }
    }
    func beginConsumer204(): Unit {
        lock.lock(); try {
            if (!producerReturned || consumerActive || callerReturned || returned || outcome.isNone()) {
                throw IllegalStateException("canonicalizer DATA has no live consumer") }
            payment.getOrThrow().ensureRetainedPeak(retained + 4096)
            consumerActive = true
        } finally { lock.unlock() }
    }
    func withOutcome204<T>(body: (Result<AgentValue>) -> T): T {
        let actual = try { lock.lock()
            if (!producerReturned || !consumerActive || callerReturned || returned || loans204 == Int64.Max) {
                throw IllegalStateException("canonicalizer DATA loan is not active") }
            loans204++; outcome.getOrThrow()
        } finally { lock.unlock() }
        try { body(actual) }
        catch (error: Exception) { holdUnknownConsumer204(); throw error }
        finally { lock.lock(); try { loans204-- } finally { lock.unlock() } }
    }
    // Private Pipeline entry after the complete independent copy helper has
    // returned. Unknown exceptions do not reach this acknowledgment.
    func returnCopiedConsumerFrame204(): Unit {
        lock.lock(); try {
            if (!consumerActive || callerReturned || returned || loans204 != 0) { throw IllegalStateException("canonicalizer DATA consumer has not returned") }
            consumerActive = false; callerReturned = true
            if (held) { return }
            outcome = None<Result<AgentValue>>
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            returned = true; canonicalArgumentsDebts204.remove204(this)
        } finally { lock.unlock() }
    }
}
private class CanonicalArgumentsDebts204 {
    private let lock = Mutex()
    private var first: ?ToolCanonicalArgumentsOwner204 = None<ToolCanonicalArgumentsOwner204>
    func retain204(value: ToolCanonicalArgumentsOwner204): Unit {
        lock.lock(); try { value.next204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: ToolCanonicalArgumentsOwner204): Unit {
        lock.lock(); try {
            var previous: ?ToolCanonicalArgumentsOwner204 = None<ToolCanonicalArgumentsOwner204>
            var cursor = first
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual,value)) {
                    match (previous) { case Some(parent) => parent.next204 = actual.next204; case None => first = actual.next204 }
                    actual.next204 = None<ToolCanonicalArgumentsOwner204>; return
                }
                previous = cursor; cursor = actual.next204
            }
            throw IllegalStateException("canonicalizer DATA debt is missing")
        } finally { lock.unlock() }
    }
}
