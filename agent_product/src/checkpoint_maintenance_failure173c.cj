package agent_product

import agent_core.OwnedAgentRunResult113
import agent_domain.*
import agent_runtime.*
import std.sync.Mutex

// DATA handoff only. A pending maintenance failure has no fabricated Run,
// Source, Receipt, cut, retry or execution completion. The installed owner
// resolves the exact session and marker object before offering its share.
interface OwnedCompactionMaintenanceFailureReader173 {
    func hasMaintenanceFailure173(session: SessionId, marker: AgentError): Bool
    func admitMaintenanceFailure173(session: SessionId, marker: AgentError,
        accept: (OwnedAgentRunResult113) -> Bool): Bool
    func takeMaintenanceFailure173(session: SessionId, marker: AgentError): ?OwnedAgentRunResult113
    func collectMaintenanceFailures173(): Unit
}

class NativeCheckpointRetentionKind173 { var value = AgentErrorKind.RecoveryRequired }

// The original query invoice includes this cell and registry link BEFORE
// invoking any Native/query/SQL producer. Transferring a paid exception into
// the cell requires no new allocation invoice. Pressure cannot detach the
// original consumer and then leave it without a reachable owner.
class NativeCheckpointRetentionHeld173 {
    private let lock = Mutex()
    private var query: ?ProductCompactionReferenceQuery
    private var owner: ?LogicalJsonOwnerReservation
    private var session: ?String
    private var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var original: ?AgentError = None<AgentError>
    private var marker: ?AgentError = None<AgentError>
    private var caller: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var producerReturned = false
    private var unknownProducer = false
    private var handingOff = false
    private var transferred = false
    init(session: SessionId, query: ProductCompactionReferenceQuery, owner: LogicalJsonOwnerReservation) {
        this.session = Some(String.fromUtf8(session.value.toArray()))
        this.query = Some(query); this.owner = Some(owner)
    }
    func adopt173(actual: OwnedFailureDataConsumer113): AgentError {
        lock.lock(); try {
            consumer = Some(actual)
            let kind = NativeCheckpointRetentionKind173()
            let read = actual.withError({ error, _ => kind.value = error.kind })
            // Failure of the short kind loan leaves the full consumer in this
            // registered cell. A pending marker is never its error payload.
            match (read) { case Result.Err(_) => (); case Result.Ok(_) => () }
            let pending = AgentError(kind.value, "compaction.owned_policy_failure_pending",
                "complete maintenance failure awaits its paid consumer")
            marker = Some(pending); pending
        } finally { lock.unlock() }
    }
    func adoptPaid173(actual: OwnedCanonicalPaidFailure113): AgentError {
        lock.lock(); try {
            // Validate the already linked holder BEFORE taking the producer's
            // exact consumer. No reserve/clone/constructor may intervene in
            // this transfer. A refusal leaves the original exception intact.
            if (owner.isNone() || consumer.isSome() || original.isSome() ||
                marker.isSome() || producerReturned || unknownProducer) {
                throw IllegalStateException("maintenance failure holder is unavailable") }
            consumer = Some(actual.takeConsumer())
            let kind = NativeCheckpointRetentionKind173()
            let read = consumer.getOrThrow().withError({ error, _ => kind.value = error.kind })
            match (read) { case Result.Err(_) => (); case Result.Ok(_) => () }
            let pending = AgentError(kind.value, "compaction.owned_policy_failure_pending",
                "complete maintenance failure awaits its paid consumer")
            marker = Some(pending); pending
        } finally { lock.unlock() }
    }
    func capture173(error: AgentError): AgentError {
        lock.lock(); try {
            original = Some(error)
            try {
                match (captureOwnedFailureData113<Unit>(error, { bytes =>
                    let child = owner.getOrThrow().deriveRetainedLease()
                    try { child.ensureRetainedPeak(bytes); child }
                    catch (failure: Exception) { child.close(); throw failure }
                })) {
                    case OwnedFailureDataOutcome113.Failure(actual) =>
                        consumer = Some(actual); original = None<AgentError>
                    case OwnedFailureDataOutcome113.Value(_) => () }
            } catch (_: Exception) {
                // Retain the actual producer backing under its original
                // query/owner. Neither pressure nor throw proves retirement.
            }
            let pending = AgentError(error.kind, "compaction.owned_policy_failure_pending",
                "complete maintenance failure awaits its paid consumer")
            marker = Some(pending); pending
        } finally { lock.unlock() }
    }
    func unknownProducer173(): Unit {
        lock.lock(); try { unknownProducer = true } finally { lock.unlock() }
    }
    // Only the wrapper invokes this AFTER the entire execution/capture helper
    // has returned. A thrown wrapper cannot manufacture a returned Future.
    func returnedProducer173(): Unit {
        lock.lock(); try { producerReturned = true } finally { lock.unlock() }
    }
    func matches173(session: SessionId, marker: AgentError): Bool {
        lock.lock(); try { this.session.isSome() && this.session.getOrThrow() == session.value &&
            this.marker.isSome() && refEq(this.marker.getOrThrow(), marker) }
        finally { lock.unlock() }
    }
    func available173(): Bool {
        lock.lock(); try { owner.isSome() && marker.isSome() && !transferred }
        finally { lock.unlock() }
    }
    private func beginHandoff173(): ?OwnedAgentRunResult113 {
        lock.lock(); try {
            if (!producerReturned || unknownProducer || handingOff || transferred ||
                owner.isNone() || consumer.isNone() || original.isSome()) {
                return None<OwnedAgentRunResult113> }
            if (caller.isNone()) {
                let retained = try { consumer.getOrThrow().retainConsumer() }
                    catch (_: Exception) { return None<OwnedAgentRunResult113> }
                match (retained) {
                    case Result.Err(_) => return None<OwnedAgentRunResult113>
                    case Result.Ok(actual) => caller = Some(actual) }
            }
            handingOff = true
            Some(OwnedAgentRunResult113.Pending(caller.getOrThrow()))
        } finally { lock.unlock() }
    }
    private func finishHandoff173(accepted: Bool): Unit {
        lock.lock(); try {
            if (accepted) { transferred = true }
            handingOff = false
        } finally { lock.unlock() }
    }
    func admit173(accept: (OwnedAgentRunResult113) -> Bool): Bool {
        let offered = beginHandoff173()
        if (offered.isNone()) { return false }
        var accepted = false
        try { accepted = accept(offered.getOrThrow()) }
        // false and throw retain the same paid caller, with no producer retry.
        finally { finishHandoff173(accepted) }
        accepted
    }
    func take173(): ?OwnedAgentRunResult113 {
        let offered = beginHandoff173()
        if (offered.isSome()) { finishHandoff173(true) }
        offered
    }
    // Return the original metadata owner only after exact caller ACK and all
    // real producer/handoff frames return. The registry unlinks this cleared
    // cell; the outer collector closes the owner AFTER that helper returns.
    func detachReturned173(): ?LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (!producerReturned || unknownProducer || handingOff || owner.isNone() || original.isSome()) {
                return None<LogicalJsonOwnerReservation> }
            if (consumer.isSome()) {
                if (!transferred || caller.isNone() || !caller.getOrThrow().isAcknowledged()) {
                    return None<LogicalJsonOwnerReservation> }
                match (consumer.getOrThrow().acknowledgeAfterConsumption()) {
                    case Result.Err(_) => return None<LogicalJsonOwnerReservation>
                    case Result.Ok(_) => () }
            } else if (caller.isSome() || marker.isSome()) { return None<LogicalJsonOwnerReservation> }
            let actualQuery = query
            match (actualQuery) { case Some(actual) => actual.close(); case None => () }
            query = None<ProductCompactionReferenceQuery>
            caller = None<OwnedFailureDataConsumer113>; consumer = None<OwnedFailureDataConsumer113>
            original = None<AgentError>; marker = None<AgentError>; session = None<String>
            let actualOwner = owner; owner = None<LogicalJsonOwnerReservation>
            actualOwner
        } finally { lock.unlock() }
    }
}
