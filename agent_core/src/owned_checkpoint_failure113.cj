package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

// This result is deliberately in Core: AgentRunOutcome is a Core type.
// Runtime/Domain therefore acquire no upward package dependency.
public enum OwnedAgentRunResult113 {
    Existing(Result<AgentRunOutcome>) | Failed(OwnedFailureRunPublication113)
    | Pending(OwnedFailureDataConsumer113) | Held
}

// Each actual failed observer has a separate already-paid consumer. The
// linked entries copy no AgentError, error fields, observation or Diagnostic.
// Several failed callbacks in one committed wave retain separate consumers;
// choosing the first legacy fatal value never loses the other owned errors.
class CoreCheckpointFailureEntry113 {
    private let lock = Mutex()
    private var working = false
    var consumer: ?OwnedFailureDataConsumer113
    let primary: Bool
    let dataOnly113: Bool
    let marker: AgentError
    var next: ?CoreCheckpointFailureEntry113 = None<CoreCheckpointFailureEntry113>
    var publication: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var saveAlias: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var appendAlias: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var eventAlias: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var saved = false
    var appended = false
    var delivered = false
    var callerTransferred = false
    var saveSent = false
    var appendSent = false
    var eventSent = false
    var eventAccepted113 = false
    init(consumer: OwnedFailureDataConsumer113, primary: Bool, kind: AgentErrorKind, dataOnly113: Bool) {
        this.consumer = Some(consumer); this.primary = primary; this.dataOnly113 = dataOnly113
        // Fixed text only, with the real original scalar kind. This bounded
        // marker belongs to the already-paid holder, not to a raw error loan.
        this.marker = AgentError(kind, "run.owned_checkpoint_failure_pending",
            "the actual post-canonical failure awaits paid Run, Diagnostic and caller consumption")
    }
    // No entry or queue mutex is held while a real Repository/Event consumer
    // runs. Reentrant callers see pending instead of acquiring another share
    // from the publication currently being installed.
    func beginWork(): Bool {
        lock.lock(); try { if (working) { false } else { working = true; true } }
        finally { lock.unlock() }
    }
    func endWork(): Unit { lock.lock(); try { working = false } finally { lock.unlock() } }
    func isWorking(): Bool { lock.lock(); try { working } finally { lock.unlock() } }
    func retireAfterHandoff(): Result<Unit> {
        if (!beginWork()) { return Result.Err(coreOwnedCheckpointFailurePending113()) }
        try {
        if (!saved || !appended || !delivered || !callerTransferred) {
            return Result.Err(coreOwnedCheckpointFailurePending113()) }
        if (consumer.isSome() || saveAlias.isSome() || appendAlias.isSome() || eventAlias.isSome()) {
            return Result.Err(coreOwnedCheckpointFailurePending113()) }
        let value = match (publication) {
            case Some(actual) => actual
            case None => return Result.Err(coreOwnedCheckpointFailurePending113()) }
        // Successful delivery requires the actual separate alias ACKs. A
        // callback's ordinary return never satisfies any of these flags.
        match (value.acknowledgeAfterConsumption()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => publication = None<OwnedFailureRunPublication113>; Result<Unit>.Ok(()) }
        } finally { endWork() }
    }
}

class CoreCheckpointFailureQueue113 {
    private let lock = Mutex()
    private var first: ?CoreCheckpointFailureEntry113 = None<CoreCheckpointFailureEntry113>
    private var last: ?CoreCheckpointFailureEntry113 = None<CoreCheckpointFailureEntry113>
    private var captured113: Int64 = 0
    func capture(consumer: OwnedFailureDataConsumer113, primary: Bool, dataOnly113: Bool): AgentError {
        // The original consumer's derived lease has already prepaid its
        // bounded holder envelope. No full error is borrowed or cloned here.
        // Prepay the existing reference cell from this exact consumer's bank.
        // Failed payment/loan retains the original consumer; it cannot install
        // a RecoveryRequired marker in place of the unobserved original kind.
        match (coreCheckpointMetadataCellPayment143(consumer)) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(_) => () }
        let kind = CoreCheckpointFailureKind143()
        match (consumer.withError({ error, _ => kind.value = error.kind })) {
            case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(_) => () }
        let entry = CoreCheckpointFailureEntry113(consumer, primary, kind.value, dataOnly113)
        lock.lock(); try {
            if (captured113 == Int64.Max) { throw IllegalStateException("checkpoint wave count exhausted") }
            captured113++
            match (last) { case Some(value) => value.next = Some(entry)
                case None => first = Some(entry) }
            last = Some(entry)
        } finally { lock.unlock() }
        entry.marker
    }
    // Scalar custody only: no error/Diagnostic aliases, sequence or ACK.
    // The caller must ALSO observe its actual outer producer Future return.
    func waveCounts113(producersQuiet: Bool): (Bool, Int64, Int64) {
        lock.lock()
        try {
            var quiet = producersQuiet
            var remaining: Int64 = 0
            var selected = first
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (!entry.beginWork()) { return (false, captured113, 0) }
                try {
                    if (!entry.callerTransferred) { remaining++ }
                    if (entry.publication.isNone()) {
                        // Only a secondary produced by a returned port call
                        // is final DATA without a new snapshot/event producer.
                        if (!entry.dataOnly113) { quiet = false }
                    } else if (!entry.saved) {
                        if (!entry.saveSent || entry.saveAlias.isSome()) { quiet = false }
                    } else if (!entry.appended) {
                        if (!entry.appendSent || entry.appendAlias.isSome()) { quiet = false }
                    } else if (!entry.eventSent || (!entry.eventAccepted113 && entry.eventAlias.isSome())) { quiet = false }
                } finally { entry.endWork() }
                selected = entry.next
            }
            (quiet, captured113, remaining)
        } finally { lock.unlock() }
    }

    // Look up only scalar sequence on the actual paid publication. This is
    // neither a user code match nor an ACK/late-Event fabrication.
    func eventExpectation113(sequence: Int64): ?Bool {
        lock.lock()
        try {
            var selected = first
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (!entry.beginWork()) { return None<Bool> }
                try {
                    match (entry.publication) {
                        case Some(value) =>
                            match (value.withError({ _, fund => fund(4096) })) {
                                case Result.Err(_) => return None<Bool>; case Result.Ok(_) => () }
                            let scalar = CoreCheckpointWaveSequenceCell113()
                            match (value.withDiagnostic({ event, _ => scalar.sequence = event.meta.sequence; Result<Unit>.Ok(()) })) {
                                case Result.Err(_) => return None<Bool>; case Result.Ok(_) => () }
                            if (scalar.sequence == sequence) {
                                if (entry.eventAccepted113) { return Some(true) }
                                if ((!entry.saved && entry.saveSent && entry.saveAlias.isNone()) ||
                                    (!entry.appended && entry.appendSent && entry.appendAlias.isNone())) { return Some(false) }
                                if (entry.eventSent && entry.eventAlias.isNone()) { return Some(false) }
                                return None<Bool>
                            }
                        case None => ()
                    }
                } finally { entry.endWork() }
                selected = entry.next
            }
            None<Bool>
        } finally { lock.unlock() }
    }

    func hasDebt(): Bool { lock.lock(); try { first.isSome() } finally { lock.unlock() } }
    func head(): ?CoreCheckpointFailureEntry113 { lock.lock(); try { first } finally { lock.unlock() } }
    func isMarker(error: AgentError): Bool {
        lock.lock(); try {
            var selected = first
            while (selected.isSome()) {
                let entry = selected.getOrThrow()
                if (refEq(error, entry.marker)) { return true }
                selected = entry.next
            }
            false
        } finally { lock.unlock() }
    }
    func hasActiveConsumerFrame(): Bool {
        lock.lock(); try {
            var selected = first
            while (selected.isSome()) {
                let value = selected.getOrThrow()
                if (value.isWorking()) { return true }
                selected = value.next
            }
            false
        } finally { lock.unlock() }
    }
    func retireReadyHeads(): Result<Unit> {
        lock.lock(); try {
            while (first.isSome()) {
                let value = first.getOrThrow()
                match (value.retireAfterHandoff()) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(_) =>
                        first = value.next; value.next = None<CoreCheckpointFailureEntry113>
                        if (first.isNone()) { last = None<CoreCheckpointFailureEntry113> } }
            }
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
}

// Identity, rather than a user-controlled code string, distinguishes the
// bounded old-API marker from the complete owned error. No error field from
// the original failed callback is copied into this marker.
let CORE_OWNED_CHECKPOINT_FAILURE_PENDING113 = AgentError(
    AgentErrorKind.RecoveryRequired, "run.owned_checkpoint_failure_pending",
    "the actual post-canonical failure awaits paid Run, Diagnostic and caller consumption")
func coreOwnedCheckpointFailurePending113(): AgentError {
    CORE_OWNED_CHECKPOINT_FAILURE_PENDING113
}

func coreOwnedCheckpointMetadataPeak113(request: AgentRunRequest,
    context: ToolInvocationContext, control: CoreRunControl): Int64 {
    var bytes = coreCheckpointMetadataAdd113(request.runId.value.size, request.sessionId.value.size)
    bytes = coreCheckpointMetadataAdd113(bytes, control.traceId.value.size)
    bytes = coreCheckpointMetadataAdd113(bytes, control.currentRequestId().size)
    match (control.currentTurnId()) { case Some(value) => bytes = coreCheckpointMetadataAdd113(bytes, value.value.size); case None => () }
    match (control.currentBatchId()) { case Some(value) => bytes = coreCheckpointMetadataAdd113(bytes, value.value.size); case None => () }
    if (bytes > (Int64.Max - 32768) / 8) { throw IllegalStateException("failure metadata payment overflow") }
    32768 + bytes * 8
}
func coreCheckpointMetadataAdd113(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || right > Int64.Max - left) { throw IllegalStateException("failure metadata payment overflow") }
    left + right
}

class CoreCheckpointWaveSequenceCell113 { var sequence: Int64 = -1 }
