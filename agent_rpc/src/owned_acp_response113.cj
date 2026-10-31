package agent_rpc

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.sync.*

// The producer derives/funds this original-bank child BEFORE constructing
// its UTF8 String. The actual parser/handler borrows the same source share;
// raw input and its decoded DOM invoice overlap in that same physical peak.
public class AcpOwnedInput113 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var source: ?String = None<String>
    private var peak: Int64
    private var borrowing = false
    private var handled = false
    private var retired = false
    public init(payment: LogicalJsonOwnerReservation, invoice: Int64,
        produce: () -> String) {
        payment.ensureRetainedPeak(invoice)
        this.payment = Some(payment); this.peak = invoice
        this.source = Some(produce())
    }
    private func fund113(bytes: Int64): Result<Unit> {
        lock.lock()
        try {
            if (retired || !borrowing) { return acpOwnedWorkersPending113<Unit>() }
            let actual = acpOwnedAdd113(peak, bytes)
            payment.getOrThrow().ensureRetainedPeak(actual); peak = actual
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    public func prepareParser113(): Bool {
        lock.lock()
        try {
            if (retired || !borrowing || source.isNone()) { return false }
            // The original input invoice already includes its overlapping
            // raw String/decoded shape. Re-measure from the actual borrowed
            // bytes, then grow this SAME share before decodeAgentValue.
            let wanted = max(peak, acpOwnedInputInvoice113(source.getOrThrow()))
            payment.getOrThrow().ensureRetainedPeak(wanted); peak = wanted
            true
        } finally { lock.unlock() }
    }
    public func withLine113(consume: (String, (Int64)->Result<Unit>) -> Result<Unit>): Result<Unit> {
        lock.lock()
        let actual = try {
            if (retired || borrowing || handled || source.isNone()) { return acpOwnedWorkersPending113<Unit>() }
            borrowing = true; source.getOrThrow()
        } finally { lock.unlock() }
        try {
            let result = consume(actual, { bytes => fund113(bytes) })
            if (result.isOk()) { handled = true }
            result
        } finally { lock.lock(); try { borrowing = false } finally { lock.unlock() } }
    }
    public func retireAfterHandlerReturn113(): Bool {
        lock.lock()
        try {
            if (retired) { return true }
            if (borrowing || !handled) { return false }
            source = None<String>
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            retired = true; true
        } finally { lock.unlock() }
    }
    public func isRetired113(): Bool { lock.lock(); try { retired } finally { lock.unlock() } }
    public func isHandled113(): Bool { lock.lock(); try { handled } finally { lock.unlock() } }
    public func canDestroyAfterFailedFrontendReturn113(): Bool { lock.lock(); try { !borrowing } finally { lock.unlock() } }
    public func destroyAfterFailedFrontendReturn113(): Bool {
        lock.lock()
        try {
            if (retired) { return true }
            if (borrowing) { return false }
            // Explicit failure/cancel disposition after all actual consumers
            // and frontend helpers returned. Does not set handled=true.
            source = None<String>
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            retired = true; true
        } finally { lock.unlock() }
    }

}

// ACP keeps its original JSON-RPC value/schema. This port carries the actual
// paid frame instead of letting an untracked String escape into production.
public interface AcpOwnedResponseOutput113 {
    func writeAcpResponse113(value: AcpOwnedResponse113): OwnedFailureDataOutcome113<Unit>
}

// Constructed and registered under its original-root child BEFORE a producer
// callback or DOM envelope is constructed. A failed/partial offer never runs
// again and keeps the original frame and exact captured secondary reachable.
public class AcpOwnedResponse113 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var peak: Int64 = 65536
    private var value: ?String = None<String>
    private var secondary: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    private var producing = false
    private var produced = false
    private var borrowing = false
    private var offered = false
    private var writeReturned = false
    private var writeSucceeded = false
    private var acknowledged = false
    init(payment: LogicalJsonOwnerReservation) {
        payment.ensureRetainedPeak(65536)
        this.payment = Some(payment)
    }
    func fund113(bytes: Int64): Result<Unit> {
        lock.lock()
        try {
            if (acknowledged || payment.isNone()) { return acpOwnedWorkersPending113<Unit>() }
            let actual = acpOwnedAdd113(peak, bytes)
            payment.getOrThrow().ensureRetainedPeak(actual)
            peak = actual
            Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    func capture113(error: AgentError): OwnedFailureDataConsumer113 {
        lock.lock()
        try {
            let actual = payment.getOrThrow()
            match (captureOwnedFailureData113<Unit>(error, { _ => actual.deriveRetainedLease() })) {
                case OwnedFailureDataOutcome113.Failure(held) => held
                case _ => throw IllegalStateException("ACP paid response capture returned no error") }
        } finally { lock.unlock() }
    }
    // The caller's live input/event/worker loan supplies the original value.
    // Prefix/control metadata is charged before the callback constructs it;
    // the original paid codec charges traversal and exact default JSON extent
    // before serialization. The wrapper is removed without changing bytes.
    func buildText113(produce: ((Int64)->Result<Unit>) -> Result<String>): Bool {
        lock.lock()
        try {
            if (producing || produced || acknowledged) { return false }
            producing = true
        } finally { lock.unlock() }
        try {
            match (produce({ bytes => fund113(bytes) })) {
                case Result.Ok(actual) => value = Some(actual)
                case Result.Err(error) => secondary = Some(capture113(error)) }
        } catch (failure: OwnedCanonicalPaidFailure113) { secondary = Some(failure.takeConsumer()) }
        catch (failure: OwnedCanonicalDataFailure113) { secondary = Some(capture113(failure.error)) }
        catch (failure: Exception) { let _ = captureOutputException113(failure) }
        finally { lock.lock(); try { producing = false; produced = true } finally { lock.unlock() } }
        value.isSome() && secondary.isNone()
    }

    func buildValue113(produce: ((Int64)->Result<Unit>) -> AgentValue): Bool {
        lock.lock()
        try {
            if (producing || produced || acknowledged) { return false }
            producing = true
        } finally { lock.unlock() }
        try { buildValueHelper113(produce) }
        finally { lock.lock(); try { producing = false; produced = true } finally { lock.unlock() } }
        value.isSome() && secondary.isNone()
    }
    private func buildValueHelper113(produce: ((Int64)->Result<Unit>) -> AgentValue): Unit {
        try {
            match (fund113(65536)) { case Result.Err(error) => secondary = Some(capture113(error)); return; case Result.Ok(_) => () }
            let actual = produce({ bytes => fund113(bytes) })
            let encoded = match (encodeOwnedFailureError113(None<AgentError>,
                [ValueField("__acp_owned_value_113", actual)], "__acp_owned_end_113", { bytes => fund113(bytes) })) {
                case Result.Err(error) => secondary = Some(capture113(error)); return
                case Result.Ok(result) => result }
            let prefix = "{\"__acp_owned_value_113\":"
            let suffix = ",\"__acp_owned_end_113\":null}"
            if (!encoded.startsWith(prefix) || !encoded.endsWith(suffix)) {
                throw IllegalStateException("original ACP paid codec wrapper changed") }
            match (fund113(acpOwnedMultiply113(acpOwnedUtf8Bytes113(encoded), 8))) {
                case Result.Err(error) => secondary = Some(capture113(error)); return
                case Result.Ok(_) => value = Some(encoded[prefix.size..encoded.size-suffix.size]) }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            secondary = Some(failure.takeConsumer())
        } catch (failure: OwnedCanonicalDataFailure113) {
            secondary = Some(capture113(failure.error))
        } catch (failure: Exception) {
            match (fund113(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(failure.message), 8)))) {
                case Result.Err(_) => ()
                case Result.Ok(_) => secondary = Some(capture113(AgentError(AgentErrorKind.Internal,
                    "acp.response_encoding_failed", failure.message))) }
        }
    }
    func buildAgentError113(id: AgentValue, error: AgentError, wireCode!: ?Int64 = None<Int64>, closeData!: ?(((Int64)->Result<Unit>)->Result<String>) = None<((Int64)->Result<Unit>)->Result<String>>): Bool {
        lock.lock()
        try {
            if (producing || produced || acknowledged) { return false }
            producing = true
        } finally { lock.unlock() }
        try { buildAgentErrorHelper113(id, error, wireCode, closeData) }
        finally { lock.lock(); try { producing = false; produced = true } finally { lock.unlock() } }
        value.isSome() && secondary.isNone()
    }
    private func buildAgentErrorHelper113(id: AgentValue, error: AgentError, wireCode: ?Int64, closeData: ?(((Int64)->Result<Unit>)->Result<String>)): Unit {
        try {
            var raw = acpOwnedAdd113(acpOwnedUtf8Bytes113(error.code), acpOwnedUtf8Bytes113(error.message))
            for (field in error.fields) {
                raw = acpOwnedAdd113(raw, acpOwnedAdd113(acpOwnedUtf8Bytes113(field.name), acpOwnedUtf8Bytes113(field.value))) }
            match (fund113(acpOwnedAdd113(65536, acpOwnedAdd113(acpOwnedMultiply113(raw, 8), acpOwnedMultiply113(error.fields.size, 4096))))) {
                case Result.Err(failure) => secondary = Some(capture113(failure)); return
                case Result.Ok(_) => () }
            let fields = ArrayList<AgentValue>()
            for (field in error.fields) {
                fields.add(objectValue([ValueField("name", textValue(field.name)), ValueField("value", textValue(field.value))])) }
            let data = match (encodeOwnedFailureError113(error, [ValueField("code", textValue(error.code)),
                ValueField("fields", listValue(fields.toArray()))], "error_data", { bytes => fund113(bytes) })) {
                case Result.Err(failure) => secondary = Some(capture113(failure)); return
                case Result.Ok(actual) => actual }
            let request = match (encodeOwnedFailureError113(None<AgentError>, [ValueField("jsonrpc", textValue("2.0")),
                ValueField("id", id)], "__acp_prefix_end_113", { bytes => fund113(bytes) })) {
                case Result.Err(failure) => secondary = Some(capture113(failure)); return
                case Result.Ok(actual) => actual }
            let header = match (encodeOwnedFailureError113(None<AgentError>, [ValueField("code", integerValue(match (wireCode) { case Some(actual) => actual; case None => acpErrorCode(error) })),
                ValueField("message", textValue(error.message))], "__acp_prefix_end_113", { bytes => fund113(bytes) })) {
                case Result.Err(failure) => secondary = Some(capture113(failure)); return
                case Result.Ok(actual) => actual }
            let bytes = acpOwnedAdd113(8192, acpOwnedAdd113(acpOwnedUtf8Bytes113(request),
                acpOwnedAdd113(acpOwnedUtf8Bytes113(header), acpOwnedUtf8Bytes113(data))))
            match (fund113(acpOwnedMultiply113(bytes, 8))) {
                case Result.Err(failure) => secondary = Some(capture113(failure)); return
                case Result.Ok(_) => () }
            let completeData = match (closeData) {
                case None => data
                case Some(render) =>
                    let errors = match (render({ bytes => fund113(bytes) })) {
                        case Result.Err(failure) => secondary = Some(capture113(failure)); return
                        case Result.Ok(actual) => actual }
                    match (fund113(acpOwnedMultiply113(acpOwnedAdd113(acpOwnedUtf8Bytes113(data), acpOwnedUtf8Bytes113(errors)), 8))) {
                        case Result.Err(failure) => secondary = Some(capture113(failure)); return
                        case Result.Ok(_) => () }
                    if (!data.endsWith("}")) { throw IllegalStateException("ACP original full error data changed") }
                    data[0..data.size-1] + ",\"secondary_errors\":" + errors + "}"
            }
            value = Some(acpResponseRemovePaidSentinel113(request) + ",\"error\":" +
                acpResponseRemovePaidSentinel113(header) + ",\"data\":" + completeData + "}}")
        } catch (failure: OwnedCanonicalPaidFailure113) { secondary = Some(failure.takeConsumer()) }
        catch (failure: OwnedCanonicalDataFailure113) { secondary = Some(capture113(failure.error)) }
        catch (failure: Exception) {
            match (fund113(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(failure.message), 8)))) {
                case Result.Err(_) => ()
                case Result.Ok(_) => secondary = Some(capture113(AgentError(AgentErrorKind.Internal,
                    "acp.response_encoding_failed", failure.message))) }
        }
    }
    func markOffered113(): Bool {
        lock.lock()
        try {
            if (!produced || producing || offered || value.isNone() || secondary.isSome()) { return false }
            offered = true; true
        } finally { lock.unlock() }
    }
    // Concrete Main calls println+flush inside this exact short loan. Its
    // actual raw Err/Exception is cloned while the producing loan/payment is
    // still live; it never escapes as an unpaid error or an implicit ACK.
    public func withResponse113(consume: (String) -> Result<Unit>): OwnedFailureDataOutcome113<Unit> {
        lock.lock()
        let selected = try {
            if (!offered || borrowing || writeReturned || acknowledged || value.isNone()) {
                throw IllegalStateException("ACP response has no new output loan") }
            borrowing = true; value.getOrThrow()
        } finally { lock.unlock() }
        try { writeResponseHelper113(selected, consume) }
        finally {
            lock.lock()
            try { borrowing = false; writeReturned = true }
            finally { lock.unlock() }
        }
    }
    private func writeResponseHelper113(selected: String,
        consume: (String) -> Result<Unit>): OwnedFailureDataOutcome113<Unit> {
        try {
            match (consume(selected)) {
                case Result.Ok(_) => writeSucceeded = true; OwnedFailureDataOutcome113<Unit>.Value(())
                case Result.Err(error) =>
                    let actual = capture113(error); secondary = Some(actual)
                    OwnedFailureDataOutcome113<Unit>.Failure(actual) }
        } catch (failure: OwnedCanonicalPaidFailure113) {
            let actual = failure.takeConsumer(); secondary = Some(actual)
            OwnedFailureDataOutcome113<Unit>.Failure(actual)
        } catch (failure: OwnedCanonicalDataFailure113) {
            let actual = capture113(failure.error); secondary = Some(actual)
            OwnedFailureDataOutcome113<Unit>.Failure(actual)
        } catch (failure: Exception) {
            match (fund113(acpOwnedAdd113(16384, acpOwnedMultiply113(acpOwnedUtf8Bytes113(failure.message), 8)))) {
                case Result.Err(error) => throw OwnedCanonicalDataFailure113(error)
                case Result.Ok(_) => () }
            let actual = capture113(AgentError(AgentErrorKind.Internal,
                "acp.stdout_failed", failure.message))
            secondary = Some(actual); OwnedFailureDataOutcome113<Unit>.Failure(actual)
        }
    }
    public func acknowledgeAfterWriteHelperReturn113(): Result<Unit> {
        lock.lock()
        try {
            if (acknowledged) { return Result<Unit>.Ok(()) }
            if (producing || borrowing || !offered || !writeReturned || !writeSucceeded || secondary.isSome()) {
                return acpOwnedWorkersPending113<Unit>() }
            value = None<String>
            // A throwing close keeps the same payment reachable here.
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            acknowledged = true; Result<Unit>.Ok(())
        } finally { lock.unlock() }
    }
    func retireUnpublishedAfterProducerReturn113(): Bool {
        lock.lock()
        try {
            if (acknowledged) { return true }
            if (producing || !produced || borrowing || offered || secondary.isSome()) { return false }
            value = None<String>
            payment.getOrThrow().close(); payment = None<LogicalJsonOwnerReservation>
            acknowledged = true; true
        } finally { lock.unlock() }
    }
    public func isAcknowledged113(): Bool { lock.lock(); try { acknowledged } finally { lock.unlock() } }
    func hasSecondary113(): Bool { lock.lock(); try { secondary.isSome() } finally { lock.unlock() } }
    public func captureOutputFailure113(actual: OwnedFailureDataConsumer113): OwnedFailureDataOutcome113<Unit> {
        lock.lock(); try { secondary = Some(actual) } finally { lock.unlock() }
        OwnedFailureDataOutcome113<Unit>.Failure(actual)
    }
    public func captureOutputException113(error: Exception): OwnedFailureDataOutcome113<Unit> {
        match (fund113(acpOwnedAdd113(32768, acpOwnedMultiply113(acpOwnedUtf8Bytes113(error.message), 8)))) {
            case Result.Err(pressure) => throw OwnedCanonicalDataFailure113(pressure)
            case Result.Ok(_) => () }
        captureOutputFailure113(AgentError(AgentErrorKind.Internal,
            "acp.output_retirement_failed", error.message, retryable: false, fallbackAllowed: false))
    }

    public func captureOutputFailure113(error: AgentError): OwnedFailureDataOutcome113<Unit> {
        let actual = capture113(error)
        lock.lock(); try { secondary = Some(actual) } finally { lock.unlock() }
        OwnedFailureDataOutcome113<Unit>.Failure(actual)
    }
}

// There is no production bare-String fallback. Each node is reachable before
// construction/adoption and remains here if a concrete write or close fails.
class AcpOwnedResponseRegistry113 {
    private let control: AcpOwnedWorkerControl113
    private let lock = Mutex()
    private let frames = ArrayList<AcpOwnedResponse113>()
    private var unregistered: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var active: Int64 = 0
    init(control: AcpOwnedWorkerControl113) { this.control = control }
    func prepare113(): AcpOwnedResponse113 {
        lock.lock()
        try {
            if (unregistered.isSome()) { throw IllegalStateException("ACP retains unregistered response payment") }
            control.ensureRegistryMetadata113(3, acpOwnedAdd113(65536, acpOwnedMultiply113(acpOwnedAdd113(frames.size, 1), 4096)))
            let payment = control.deriveMetadata113(65536)
            unregistered = Some(payment)
            let value = AcpOwnedResponse113(payment)
            frames.add(value); unregistered = None<LogicalJsonOwnerReservation>; value
        } finally { lock.unlock() }
    }
    func offer113(value: AcpOwnedResponse113, output: AcpOwnedResponseOutput113): Bool {
        if (!value.markOffered113()) { return false }
        lock.lock(); try { active = acpOwnedAdd113(active, 1) } finally { lock.unlock() }
        try { offerResponseHelper113(value, output) }
        finally { lock.lock(); try { active-- } finally { lock.unlock() } }
        // The complete output helper physically returned; a plain Value is
        // insufficient. Only the actual adapter's explicit true ACK retires.
        if (!value.isAcknowledged113()) { return false }
        removeAcknowledged113(value); true
    }
    private func offerResponseHelper113(value: AcpOwnedResponse113,
        output: AcpOwnedResponseOutput113): Unit { let _ = output.writeAcpResponse113(value) }
    private func removeAcknowledged113(value: AcpOwnedResponse113): Unit {
        lock.lock()
        try {
            for (index in 0..frames.size) { if (refEq(frames[index], value)) { frames.remove(at: index); break } }
        } finally { lock.unlock() }
    }
    func collectUnpublished113(): Bool {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < frames.size) {
                let value = frames[index]
                if (value.isAcknowledged113() || value.retireUnpublishedAfterProducerReturn113()) { frames.remove(at: index) }
                else { index++ }
            }
            active == 0 && frames.isEmpty() && unregistered.isNone()
        } finally { lock.unlock() }
    }
}

// Native ACP owner acquisition/routing can fail before any workspace server
// accepted a Source. Reuse its actual owned response registry and serializer;
// this port creates no Product/Core/Store and no synthetic execution receipt.
public class AcpOwnerRoutingOutput180 {
    private let responses: AcpOwnedResponseRegistry113
    public init(control: AcpOwnedWorkerControl113) {
        control.ensureFrontendRegistryMetadata113(65536)
        responses = AcpOwnedResponseRegistry113(control)
    }
    public func write180(id: AgentValue, error: AgentError, output: AcpOwnedResponseOutput113): Bool {
        let frame = responses.prepare113()
        if (!frame.buildAgentError113(id, error)) { return false }
        responses.offer113(frame, output)
    }
    public func retireAfterFrontendHelpersReturn180(): Bool { responses.collectUnpublished113() }
}

private func acpResponseRemovePaidSentinel113(source: String): String {
    let suffix = ",\"__acp_prefix_end_113\":null}"
    if (!source.endsWith(suffix)) { throw IllegalStateException("ACP original prefix sentinel changed") }
    source[0..source.size-suffix.size]
}
