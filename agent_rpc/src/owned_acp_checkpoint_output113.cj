package agent_rpc

import agent_core.*
import agent_domain.*
import agent_runtime.*
import agent_product.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// ACP retains its own JSON-RPC envelope. The generic concrete output port
// supplies only the actual write/flush witness; no RPC response/chunk frame
// is substituted. Event and caller are distinct paid consumers of one reply.
class AcpOwnedFailureControl113 {
    var id: ?String = None<String>
    var encoded: ?String = None<String>
    var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var answer = Result<Unit>.Ok(())
    var sequence: Int64 = -1
}
class AcpOwnedDiagnostic113 {
    var source: ?OwnedFailureRunPublication113
    var encoded: ?String = None<String>
    var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var sequence: Int64 = -1
    private var attempted = false
    init(source: OwnedFailureRunPublication113) { this.source = Some(source) }
    func prepare113(): Bool {
        if (encoded.isSome()) { return true }
        if (attempted || secondary.isSome() || source.isNone()) { return false }
        attempted = true
        let actual = source.getOrThrow()
        match (actual.withError({ _, fund => fund(4096) })) {
            case Result.Err(_) => return false; case Result.Ok(_) => ()
        }
        let result = AcpOwnedFailureControl113()
        let borrowed = actual.withDiagnostic({ event, fund =>
            try {
                match (event.payload) {
                    case AgentEventPayload.Diagnostic(error) =>
                        result.sequence = event.meta.sequence
                        // This is the complete original Diagnostic payload,
                        // including all eight error fields and ten attempt
                        // diagnostics. The old six-field detail is not used.
                        match (acpDiagnosticMetadataPayment113(event.meta, fund)) {
                            case Result.Err(error) =>
                                result.secondary = Some(acpCapturePublicationFailure113(actual, error))
                                return Result<Unit>.Ok(())
                            case Result.Ok(_) => ()
                        }
                        let prefix = acpDiagnosticMetadata113(event.meta)
                        match (encodeOwnedFailureError113(error, prefix, "error_data", fund)) {
                            case Result.Ok(value) => result.encoded = Some(value)
                            case Result.Err(error) => result.secondary = Some(acpCapturePublicationFailure113(actual, error))
                        }
                    case _ => result.secondary = Some(acpCapturePublicationFailure113(actual,
                        AgentError(AgentErrorKind.Protocol, "acp.failure_diagnostic_changed", "actual checkpoint event is not Diagnostic")))
                }
            } catch (failure: OwnedCanonicalPaidFailure113) {
                result.secondary = Some(failure.takeConsumer())
            } catch (failure: OwnedCanonicalDataFailure113) {
                result.secondary = Some(acpCapturePublicationFailure113(actual, failure.error))
            } catch (failure: Exception) {
                match (fund(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(failure.message), 8)))) {
                    case Result.Err(_) => return Result<Unit>.Ok(())
                    case Result.Ok(_) => result.secondary = Some(acpCapturePublicationFailure113(actual,
                        AgentError(AgentErrorKind.Internal, "acp.failure_diagnostic_encoding_failed", failure.message)))
                }
            }
            Result<Unit>.Ok(())
        })
        encoded = result.encoded; secondary = result.secondary; sequence = result.sequence
        borrowed.isOk() && encoded.isSome() && secondary.isNone()
    }
}

// Node metadata belongs to the actual caller/error lease, not a new pool.
// The diagnostic list is already paid by each retained publication. A partly
// offered reply is never offered a second time and retains all its consumers.
class AcpOwnedWaveCaller113 {
    private var caller: ?RpcFailureAlias113
    private var receipt: ?RpcFailureAlias113 = None<RpcFailureAlias113>
    private var diagnostic: ?AcpOwnedDiagnostic113 = None<AcpOwnedDiagnostic113>
    private var event: ?AcpOwnedDiagnostic113 = None<AcpOwnedDiagnostic113>
    private var expected: ?Bool = None<Bool>
    private var eventConsumed = false
    var encoded: ?String = None<String>
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    init(value: RpcFailureAlias113) { caller = Some(value) }
    func prepay113(bytes: Int64): Result<Unit> {
        let actual = match (caller) { case Some(value) => value; case None => receipt.getOrThrow() }
        actual.withError({ _, fund => fund(bytes) })
    }
    func prepare113(session: ApplicationSession, run: RunId, metadata: Int64): Bool {
        if (secondary.isSome()) { return false }
        if (receipt.isNone()) {
            match (caller.getOrThrow().retain()) {
                case Result.Err(_) => return false; case Result.Ok(value) => receipt = Some(value) }
        }
        let actual = receipt.getOrThrow()
        match (actual.withError({ _, fund => fund(metadata) })) {
            case Result.Err(_) => return false; case Result.Ok(_) => () }
        if (encoded.isNone()) {
            match (actual.withError({ _, fund => fund(4096) })) {
                case Result.Err(_) => return false; case Result.Ok(_) => () }
            let answer = AcpOwnedFailureControl113()
            match (actual.withError({ error, fund =>
                match (encodeOwnedFailureError113(error, fund)) {
                    case Result.Ok(value) => answer.encoded = Some(value)
                    case Result.Err(error) => answer.secondary = Some(actual.capture(error)) }
                Result<Unit>.Ok(())
            })) { case Result.Err(_) => return false; case Result.Ok(_) => () }
            encoded = answer.encoded; secondary = answer.secondary
            if (encoded.isNone() || secondary.isSome()) { return false }
        }
        match (actual) {
            case RpcFailureAlias113.Publication(value) =>
                if (diagnostic.isNone()) {
                    match (value.withError({ _, fund => fund(8192) })) {
                        case Result.Err(_) => return false; case Result.Ok(_) => () }
                    diagnostic = Some(AcpOwnedDiagnostic113(value))
                }
                let data = diagnostic.getOrThrow()
                if (!data.prepare113()) { return false }
                expected = session.ownedCheckpointEventExpectation113(run, data.sequence)
                expected.isSome()
            case RpcFailureAlias113.Data(_) => expected = Some(false); true
        }
    }
    func observeRun113(consume: (RunId) -> Unit): Bool {
        let actual = match (caller) { case Some(value) => value; case None => return false }
        match (actual) {
            case RpcFailureAlias113.Publication(value) =>
                // withSnapshot keeps the actual full caller loan alive and
                // prepays its original metadata before the transient copy.
                value.withSnapshot({ snapshot, _ => consume(snapshot.runId); Result<Unit>.Ok(()) }).isOk()
            case RpcFailureAlias113.Data(_) => false
        }
    }
    func diagnosticBytes113(): Int64 {
        if (!expected.getOrThrow()) { return 0 }
        acpOwnedUtf8Bytes113(diagnostic.getOrThrow().encoded.getOrThrow())
    }
    func appendDiagnostic113(output: StringBuilder, first: Bool): Bool {
        if (!expected.getOrThrow()) { return first }
        if (!first) { output.append(",") }
        output.append(diagnostic.getOrThrow().encoded.getOrThrow()); false
    }
    func attachEvent113(value: AcpOwnedDiagnostic113): Bool {
        if (expected.isNone() || !expected.getOrThrow() || event.isSome() || eventConsumed) { return false }
        let canonical = diagnostic.getOrThrow()
        // These are complete immutable codec bytes: every original EventMeta
        // identity field and all eight error fields, not code/sequence/hash.
        if (value.sequence != canonical.sequence || value.encoded.getOrThrow() != canonical.encoded.getOrThrow()) { return false }
        event = Some(value); true
    }
    func afterWritten113(): Bool {
        // Called only after exact whole-wire flush/output ACK/helper return.
        // Its independent receipt share keeps complete matching bytes paid
        // after the caller's original share has really been ACKed.
        match (caller) { case Some(actual) =>
            match (actual.acknowledge()) { case Result.Err(_) => return false; case Result.Ok(_) => caller = None<RpcFailureAlias113> }
            case None => () }
        if (expected.getOrThrow() && !eventConsumed) {
            let actual = match (event) { case Some(value) => value; case None => return false }
            if (actual.secondary.isSome()) { return false }
            actual.encoded = None<String>
            match (actual.source) { case Some(source) =>
                match (source.acknowledgeAfterConsumption()) {
                    case Result.Err(_) => return false; case Result.Ok(_) => actual.source = None<OwnedFailureRunPublication113> }
                case None => () }
            event = None<AcpOwnedDiagnostic113>; eventConsumed = true
        }
        // Dynamic receipt copies and publication aliases disappear before
        // the exact original-bank receipt child is retired. Failed ACK keeps
        // that same child reachable and is not retried as an output offer.
        encoded = None<String>
        match (diagnostic) { case Some(value) => value.encoded = None<String>; value.source = None<OwnedFailureRunPublication113>
            case None => () }
        diagnostic = None<AcpOwnedDiagnostic113>
        match (receipt) { case Some(actual) =>
            match (actual.acknowledge()) { case Result.Err(_) => return false; case Result.Ok(_) => receipt = None<RpcFailureAlias113> }
            case None => () }
        true
    }
    func fundWave113(consume: ((Int64)->Result<Unit>)->Unit): Bool {
        let actual = match (caller) { case Some(value) => value; case None => receipt.getOrThrow() }
        actual.withError({ _, fund => consume(fund); Result<Unit>.Ok(()) }).isOk()
    }
    func capture113(error: AgentError): OwnedFailureDataConsumer113 {
        let actual = match (caller) { case Some(value) => value; case None => receipt.getOrThrow() }
        actual.capture(error)
    }
    func retainOutput113(): Result<RpcFailureAlias113> { caller.getOrThrow().retain() }
}

class AcpOwnedCheckpointDelivery113 {
    private var callers: ?ArrayList<AcpOwnedWaveCaller113> = None<ArrayList<AcpOwnedWaveCaller113>>
    private var requestPrefix: ?String = None<String>
    private var outputChild: ?RpcFailureAlias113 = None<RpcFailureAlias113>
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var frozen = false
    private var offered = false
    private var returned = false
    private var written = false
    private var retirementComplete = false
    private var dataPrepared = false
    func count113(): Int64 { match (callers) { case Some(value) => value.size; case None => 0 } }
    func admitCaller113(value: OwnedAgentRunResult113, id: ?AgentValue): Bool {
        if (frozen || offered) { return false }
        let alias = match (value) {
            case OwnedAgentRunResult113.Failed(actual) => RpcFailureAlias113.Publication(actual)
            case OwnedAgentRunResult113.Pending(actual) => RpcFailureAlias113.Data(actual)
            case _ => return false }
        match (alias.withError({ _, fund => fund(acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(count113(), 1), 4096))) })) {
            case Result.Err(_) => return false; case Result.Ok(_) => () }
        if (id.isSome()) {
            if (requestPrefix.isSome()) { return false }
            let result = AcpOwnedFailureControl113()
            match (alias.withError({ _, fund =>
                match (encodeOwnedFailureError113(None<AgentError>, [ValueField("jsonrpc", textValue("2.0")),
                    ValueField("id", id.getOrThrow())], "__acp_prefix_end_113", fund)) {
                    case Result.Err(error) => return Result<Unit>.Err(error)
                    case Result.Ok(encoded) => result.id = Some(encoded) }
                Result<Unit>.Ok(())
            })) { case Result.Err(_) => return false; case Result.Ok(_) => () }
            requestPrefix = result.id
        } else if (requestPrefix.isNone()) { return false }
        if (callers.isNone()) { callers = Some(ArrayList<AcpOwnedWaveCaller113>()) }
        callers.getOrThrow().add(AcpOwnedWaveCaller113(alias)); true
    }
    func observeCallerRun113(consume: (RunId) -> Unit): Bool {
        if (callers.isNone() || callers.getOrThrow().isEmpty()) { return false }
        callers.getOrThrow()[0].observeRun113(consume)
    }
    func prepareWave113(session: ApplicationSession, run: RunId): (Bool, Int64, Int64) {
        let actual = callers.getOrThrow()[0]
        if (actual.prepay113(8192).isError()) { return (false, 0, 0) }
        let answer = AcpOwnedWaveScalar113()
        if (!actual.fundWave113({ fund => answer.value = session.prepareOwnedCheckpointWave113(run, fund) })) { return (false, 0, 0) }
        // Complete App/Client/Core/scope/get helpers returned before this
        // explicit clearing of our cached scalar producer witness alias.
        session.retireOwnedCheckpointProducerWitness113(run)
        answer.value
    }
    func prepareCallers113(session: ApplicationSession, run: RunId): Bool {
        if (dataPrepared) { return true }
        let values = callers.getOrThrow()
        let metadata = acpOwnedAdd113(65536, acpOwnedAdd113(acpOwnedMultiply113(values.size, 4096),
            acpOwnedMultiply113(acpOwnedUtf8Bytes113(requestPrefix.getOrThrow()), 8)))
        for (value in values) { if (!value.prepare113(session, run, metadata)) { return false } }
        dataPrepared = true; true
    }
    func attachEvent113(value: AcpOwnedDiagnostic113): Bool {
        if (callers.isNone()) { return false }
        for (caller in callers.getOrThrow()) { if (caller.attachEvent113(value)) { return true } }
        false
    }
    func freeze113(count: Int64): Bool {
        if (frozen) { return count113() == count }
        if (count113() != count) { return false }
        frozen = true; true
    }
    func offer113(output: ?OwnedRpcFailureOutput113): Unit {
        if (!frozen || offered) { return }
        let target = match (output) { case Some(value) => value; case None => return }
        offered = true
        try {
            match (callers.getOrThrow()[0].retainOutput113()) {
                case Result.Err(error) => secondary = Some(callers.getOrThrow()[0].capture113(error)); return
                case Result.Ok(value) => outputChild = Some(value) }
            acpWriteCheckpointHelper113(this, outputChild.getOrThrow(), target)
        } finally { returned = true }
    }
    func render113(error: AgentError, fund: (Int64)->Result<Unit>): Result<String> {
        match (fund(65536)) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
        var fieldBytes = acpOwnedAdd113(acpOwnedUtf8Bytes113(error.code), acpOwnedUtf8Bytes113(error.message))
        for (field in error.fields) { fieldBytes = acpOwnedAdd113(fieldBytes,
            acpOwnedAdd113(acpOwnedUtf8Bytes113(field.name), acpOwnedUtf8Bytes113(field.value))) }
        match (fund(acpOwnedAdd113(acpOwnedMultiply113(fieldBytes, 8), acpOwnedMultiply113(error.fields.size, 4096)))) {
            case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
        let fields = ArrayList<AgentValue>()
        for (field in error.fields) { fields.add(objectValue([ValueField("name", textValue(field.name)), ValueField("value", textValue(field.value))])) }
        let data = match (encodeOwnedFailureError113(error, [ValueField("code", textValue(error.code)),
            ValueField("fields", listValue(fields.toArray()))], "error_data", fund)) {
            case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(value) => value }
        let header = match (encodeOwnedFailureError113(None<AgentError>, [ValueField("code", integerValue(acpErrorCode(error))),
            ValueField("message", textValue(error.message))], "__acp_prefix_end_113", fund)) {
            case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(value) => value }
        let values = callers.getOrThrow()
        var bytes = acpOwnedAdd113(4096, acpOwnedAdd113(acpOwnedUtf8Bytes113(requestPrefix.getOrThrow()),
            acpOwnedAdd113(acpOwnedUtf8Bytes113(header), acpOwnedUtf8Bytes113(data))))
        for (value in values) { bytes = acpOwnedAdd113(bytes,
            acpOwnedAdd113(acpOwnedUtf8Bytes113(value.encoded.getOrThrow()), value.diagnosticBytes113())) }
        match (fund(acpOwnedMultiply113(bytes, 8))) { case Result.Err(error) => return Result<String>.Err(error); case Result.Ok(_) => () }
        let output = StringBuilder()
        output.append(acpRemovePaidPrefixSentinel113(requestPrefix.getOrThrow())); output.append(",\"error\":")
        output.append(acpRemovePaidPrefixSentinel113(header)); output.append(",\"data\":")
        if (!data.endsWith("}")) { throw IllegalStateException("paid full ACP object changed") }
        output.append(data[0..data.size-1]); output.append(",\"secondary_errors\":[")
        for (index in 1..values.size) { if (index != 1) { output.append(",") }; output.append(values[index].encoded.getOrThrow()) }
        output.append("],\"diagnostics\":[")
        var first = true
        for (value in values) { first = value.appendDiagnostic113(output, first) }
        output.append("]}}}"); Result<String>.Ok(output.toString())
    }
    func noteWrite113(answer: OwnedFailureDataOutcome113<Unit>): Unit {
        match (answer) { case OwnedFailureDataOutcome113.Value(_) => written = true
            case OwnedFailureDataOutcome113.Failure(value) => secondary = Some(value) }
    }
    func retireWritten113(): Bool {
        if (retirementComplete) { return true }
        if (!returned || !written || secondary.isSome() || outputChild.isNone() || !outputChild.getOrThrow().acknowledged()) { return false }
        // Entire stdout/render/write helper returned before any source ACK.
        requestPrefix = None<String>
        var complete = true
        for (value in callers.getOrThrow()) { if (!value.afterWritten113()) { complete = false } }
        if (!complete) { return false }
        callers.getOrThrow().clear(); callers = None<ArrayList<AcpOwnedWaveCaller113>>
        outputChild = None<RpcFailureAlias113>; retirementComplete = true; true
    }
}
class AcpOwnedWaveScalar113 { var value: (Bool, Int64, Int64) = (false, 0, 0) }
class AcpOwnedPendingDiagnostic113 {
    let data: AcpOwnedDiagnostic113
    var next: ?AcpOwnedPendingDiagnostic113 = None<AcpOwnedPendingDiagnostic113>
    init(data: AcpOwnedDiagnostic113) { this.data = data }
}

class AcpOwnedCheckpointQueue113 {
    private let lock = Mutex()
    private var diagnostics: ?AcpOwnedPendingDiagnostic113 = None<AcpOwnedPendingDiagnostic113>
    private var last: ?AcpOwnedPendingDiagnostic113 = None<AcpOwnedPendingDiagnostic113>
    private var processing: ?AcpOwnedPendingDiagnostic113 = None<AcpOwnedPendingDiagnostic113>
    private var delivery: ?AcpOwnedCheckpointDelivery113 = None<AcpOwnedCheckpointDelivery113>
    private var working = false
    func admitEvent113(value: OwnedFailureRunPublication113): Bool {
        lock.lock()
        try {
            // Register a separate paid node even while stdout is blocked.
            // The active collector traverses only its detached private list.
            match (value.withError({ _, fund => fund(65536) })) {
                case Result.Err(_) => return false; case Result.Ok(_) => () }
            let actual = AcpOwnedPendingDiagnostic113(AcpOwnedDiagnostic113(value))
            match (last) { case Some(tail) => tail.next = Some(actual); case None => diagnostics = Some(actual) }
            last = Some(actual); true
        } finally { lock.unlock() }
    }
    func admitCaller113(value: OwnedAgentRunResult113, id: AgentValue): Bool {
        lock.lock()
        try {
            if (working || delivery.isSome()) { return false }
            let alias = match (value) { case OwnedAgentRunResult113.Failed(actual) => RpcFailureAlias113.Publication(actual)
                case OwnedAgentRunResult113.Pending(actual) => RpcFailureAlias113.Data(actual); case _ => return false }
            match (alias.withError({ _, fund => fund(65536) })) { case Result.Err(_) => return false; case Result.Ok(_) => () }
            let actual = AcpOwnedCheckpointDelivery113()
            if (!actual.admitCaller113(value, Some(id))) { return false }
            delivery = Some(actual); true
        } finally { lock.unlock() }
    }
    func admitSecondary113(value: OwnedAgentRunResult113): Bool {
        lock.lock(); try { if (working || delivery.isNone()) { return false }; delivery.getOrThrow().admitCaller113(value, None<AgentValue>) }
        finally { lock.unlock() }
    }
    func count113(): Int64 { lock.lock(); try { match (delivery) { case Some(value) => value.count113(); case None => 0 } } finally { lock.unlock() } }
    func observeCallerRun113(consume: (RunId) -> Unit): Bool {
        let actual = try {
            lock.lock()
            try { if (working) { return false }; delivery }
            finally { lock.unlock() }
        } catch (_: Exception) { return false }
        match (actual) { case Some(value) => value.observeCallerRun113(consume); case None => false }
    }
    func prepareWave113(session: ApplicationSession, run: RunId): (Bool, Int64, Int64) {
        // Do NOT set working across Core preflight: its actual synchronous
        // event admissions register here and must keep their real input share.
        let actual = try { lock.lock(); if (working) { return (false, 0, 0) }; delivery } finally { lock.unlock() }
        match (actual) { case Some(value) => value.prepareWave113(session, run); case None => (false, 0, 0) }
    }
    func collect113(output: ?OwnedRpcFailureOutput113, session: ApplicationSession, run: RunId, count: Int64): Bool {
        lock.lock()
        try {
            if (working) { return false }
            working = true
            if (processing.isNone()) { processing = diagnostics; diagnostics = None<AcpOwnedPendingDiagnostic113>; last = None<AcpOwnedPendingDiagnostic113> }
        } finally { lock.unlock() }
        try { collectCheckpointOutputHelper113(output, session, run, count) }
        finally { lock.lock(); try { working = false } finally { lock.unlock() } }
    }
    private func collectCheckpointOutputHelper113(output: ?OwnedRpcFailureOutput113, session: ApplicationSession, run: RunId, count: Int64): Bool {
        let actual = match (delivery) { case Some(value) => value; case None => return processing.isNone() && diagnostics.isNone() }
        if (!actual.prepareCallers113(session, run)) { return false }
        if (!attachProcessingEventsHelper113(actual)) { return false }
        if (!actual.freeze113(count)) { return false }
        actual.offer113(output)
        if (!actual.retireWritten113()) { return false }
        lock.lock()
        try {
            if (diagnostics.isSome() || processing.isSome()) { return false }
            delivery = None<AcpOwnedCheckpointDelivery113>; true
        } finally { lock.unlock() }
    }
    private func attachProcessingEventsHelper113(actual: AcpOwnedCheckpointDelivery113): Bool {
        while (processing.isSome()) {
            let node = processing.getOrThrow()
            if (!node.data.prepare113() || !actual.attachEvent113(node.data)) { return false }
            processing = node.next; node.next = None<AcpOwnedPendingDiagnostic113>
        }
        true
    }
    func pending113(): Bool {
        lock.lock(); try { working || diagnostics.isSome() || processing.isSome() || delivery.isSome() } finally { lock.unlock() }
    }
}

class AcpOwnedCheckpointSink113 <: OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let queue: AcpOwnedCheckpointQueue113
    private let observeRun: (RunId) -> Unit
    init(queue: AcpOwnedCheckpointQueue113, observeRun: (RunId) -> Unit) {
        this.queue = queue; this.observeRun = observeRun
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        // The full real publication, not a marker/code match, supplies this
        // run identity. Its loan remains live until the paid record copies it.
        match (value.withDiagnostic({ event, _ => observeRun(event.meta.runId); Result<Unit>.Ok(()) })) {
            case Result.Err(_) => return OwnedFailureEventAdmissionOutcome113.Held; case Result.Ok(_) => ()
        }
        if (queue.admitEvent113(value)) { OwnedFailureEventAdmissionOutcome113.Accepted }
        else { OwnedFailureEventAdmissionOutcome113.Held }
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        if (value.isAcknowledged()) { Result<Unit>.Ok(()) } else { acpOwnedWorkersPending113<Unit>() }
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case OwnedFailureEventAdmissionOutcome113.Failed(error) => OwnedFailureDataOutcome113<Unit>.Failure(error)
            case OwnedFailureEventAdmissionOutcome113.Held => throw OwnedCanonicalDataFailure113(acpOwnedWorkersPending113<Unit>().error().getOrThrow())
        }
    }
}
private func acpWriteCheckpointHelper113(node: AcpOwnedCheckpointDelivery113, child: RpcFailureAlias113,
    output: OwnedRpcFailureOutput113): Unit {
    node.noteWrite113(child.write(output, { error, fund => node.render113(error, fund) }))
}
private func acpCapturePublicationFailure113(value: OwnedFailureRunPublication113, error: AgentError): OwnedFailureDataConsumer113 {
    match (value.captureFailure113<Unit>(error)) {
        case OwnedFailureDataOutcome113.Failure(actual) => actual
        case _ => throw IllegalStateException("actual failure capture returned no paid error")
    }
}
private func acpRemovePaidPrefixSentinel113(source: String): String {
    let suffix = ",\"__acp_prefix_end_113\":null}"
    if (!source.endsWith(suffix)) { throw IllegalStateException("paid prefix terminal sentinel changed") }
    source[0..source.size-suffix.size]
}
private func acpDiagnosticMetadataPayment113(meta: EventMeta, fund: (Int64)->Result<Unit>): Result<Unit> {
    var bytes = acpOwnedAdd113(acpOwnedUtf8Bytes113(meta.traceId.value), acpOwnedUtf8Bytes113(meta.runId.value))
    match (meta.turnId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.requestId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.semanticRequestId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.attemptId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.toolBatchId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.toolCallId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    match (meta.operationId) { case Some(value) => bytes = acpOwnedAdd113(bytes, acpOwnedUtf8Bytes113(value.value)); case None => () }
    fund(acpOwnedAdd113(65536, acpOwnedMultiply113(bytes, 8)))
}
private func acpDiagnosticMetadata113(meta: EventMeta): Array<ValueField> {
    [ValueField("type", textValue("diagnostic")), ValueField("sequence", integerValue(meta.sequence)),
        ValueField("occurred_at_millis", integerValue(meta.occurredAtMillis)),
        ValueField("trace_id", textValue(meta.traceId.value)), ValueField("run_id", textValue(meta.runId.value)),
        ValueField("turn_id", match (meta.turnId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("request_id", match (meta.requestId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("semantic_request_id", match (meta.semanticRequestId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("attempt_id", match (meta.attemptId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("tool_batch_id", match (meta.toolBatchId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("tool_call_id", match (meta.toolCallId) { case Some(value) => textValue(value.value); case None => nullValue() }),
        ValueField("operation_id", match (meta.operationId) { case Some(value) => textValue(value.value); case None => nullValue() })]
}
