package model_provider_runtime

import agent_domain.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// The same process-level accounting covers all ModelProvider endpoints in
// this host process. Worker processes have their own bounded allocation pool.
// It is allocation accounting, never an Attempt or I/O permission registry.
let modelLogicalOwnerBudget = LogicalJsonOwnerBudget(maximumCharged: 268435456)

// Allocation-only handle. It cannot open a provider, claim an Attempt, choose
// credentials or authorize I/O. The caller retains it through adapter decode
// and the final typed result, on the same aggregate pool as Model messages.
public func reserveModelProviderResponse(): LogicalJsonOwnerReservation {
    modelLogicalOwnerBudget.acquire(1)
}

public class ModelProviderMessage {
    public let value: AgentValue
    private let release: () -> Unit
    private let lock = Mutex()
    private var closed = false
    public init(value: AgentValue, release: () -> Unit) { this.value = value; this.release = release }
    public func close(): Unit {
        lock.lock()
        let selected = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (selected) { release() }
    }
}

// One actual Attempt's bidirectional JSON channel. The host supplies immutable
// identity/profile from its claimed dispatch; every physical frame and the
// completed logical message must match it. No plugin field selects an owner.
public class ModelProviderLogicalWire {
    private let identity: String
    private let identityJson: String
    private let window: String
    private let maximum: Int64
    private let limits: ServicePayloadLimits
    private let physical: Int64
    private let budget = LogicalJsonProcessBudget(modelLogicalOwnerBudget)
    private let check: () -> Result<Unit>
    private let readPhysical: () -> Result<AgentValue>
    private let writePhysical: (AgentValue) -> Result<Unit>
    private var received: Int64 = 0
    private var sent: Int64 = 0
    private var transportError: ?AgentError = None

    public init(identity: AgentValue, window: String, limits: ServicePayloadLimits,
        check: () -> Result<Unit>, read: () -> Result<AgentValue>, write: (AgentValue) -> Result<Unit>,
        physicalFrameBytes!: Int64 = 262144) {
        if (window == "" || window.size > 256 || window.contains("\u{0}") ||
            physicalFrameBytes < 65536 || physicalFrameBytes > 262144) {
            throw IllegalArgumentException("invalid model logical channel window")
        }
        let frozen = identity.stringify()
        this.identityJson = frozen; this.identity = canonicalAgentValue(parseUnifiedJson(frozen))
        this.window = window; this.maximum = limits.maxMessageBytes; this.limits = limits
        this.physical = physicalFrameBytes; this.check = check; this.readPhysical = read; this.writePhysical = write
    }

    public func send(value: AgentValue): Result<Unit> {
        var reservation: ?LogicalJsonReservation = None
        try {
            checkCurrent()
            validateIdentity(value)
            // Own serialization/UTF8/hex/DOM copy costs before stringify.
            let owned = budget.acquire(logicalJsonWriteReservationBytes(value, maximum)); reservation = Some(owned)
            let source = value.stringify()
            if (source.size < 1 || source.size > maximum) { throw LogicalJsonPayloadError("model logical message exceeds its approved bound") }
            owned.ensureDecoded(source.size, logicalJsonNodeCount(source))
            validateRouteSize(value)
            if (source.size <= physical - 4096) { sendPhysical(value); return Result.Ok(()) }
            if (sent >= 65536) { throw LogicalJsonPayloadError("model logical transfer count is exhausted") }
            sent += 1
            writeLogicalJsonPayload(window, sent, "model_message", source, maximum,
                { => checkCurrent() }, { kind, header =>
                    let envelope = objectValue([ValueField("schema", textValue(MODEL_PROVIDER_PROTOCOL)),
                        ValueField("type", textValue(kind)), ValueField("identity", parseUnifiedJson(identityJson)),
                        ValueField("payload", header)])
                    sendPhysical(envelope)
                })
            Result.Ok(())
        } catch (_: Exception) { failure() }
        finally { match (reservation) { case Some(value) => value.close(); case None => () } }
    }

    public func receive(): Result<ModelProviderMessage> {
        var reservation: ?LogicalJsonReservation = None
        var receiver: ?LogicalJsonReceiver = None
        var retained = false
        try {
            checkCurrent()
            // Reserve before a physical parser or logical begin can allocate.
            // The physical callback parses JSON. Reserve its worst allowed
            // lexical-node DOM before calling it, not after parsing a dense
            // tiny frame. Raw physical parsers enforce the same65,536 ceiling.
            let physicalChargeBytes = max(physical, (physical * 4 + 65536 * 512 + 1048576 + 7) / 8)
            let owned = budget.acquire(physicalChargeBytes); reservation = Some(owned)
            let first = receivePhysical()
            validateIdentity(first)
            let kind = providerTextIfPresent(first, "type")
            if (kind != "payload_begin") {
                if (kind == "payload_chunk" || kind == "payload_end") { throw LogicalJsonPayloadError("model payload has no begin") }
                let source = first.stringify()
                if (source.size > physical) { throw LogicalJsonPayloadError("model physical frame exceeds its bound") }
                owned.ensureDecoded(source.size, logicalJsonNodeCount(source))
                validateRouteSize(first)
                retained = true
                return Result.Ok(ModelProviderMessage(first, { => owned.close() }))
            }
            if (received >= 65536) { throw LogicalJsonPayloadError("model logical transfer count is exhausted") }
            received += 1
            // Transfer the reservation to the shared assembler. Reuse its
            // accounting instead of charging the complete body a second time.
            let assembly = LogicalJsonReceiver(budget, maximum, window, received, "model_message", { => checkCurrent() },
                physicalFrameBytes: physical, reservation: Some(owned), maximumDepth: 64, reserveMaximum: false)
            reservation = None
            receiver = Some(assembly)
            var next = first
            while (true) {
                validateIdentity(next)
                providerExact(next, ["schema", "type", "identity", "payload"])
                let complete = assembly.accept(providerText(next, "type"), providerField(next, "payload"))
                match (complete) {
                    case Some(value) =>
                        validateIdentity(value)
                        validateRouteSize(value)
                        let nested = providerTextIfPresent(value, "type")
                        if (["payload_begin", "payload_chunk", "payload_end"].contains(nested)) {
                            throw LogicalJsonPayloadError("nested model payload is forbidden")
                        }
                        retained = true
                        return Result.Ok(ModelProviderMessage(value, { => assembly.close() }))
                    case None => next = receivePhysical()
                }
            }
            providerFailure(AgentErrorKind.Internal, "model.logical_unreachable", AttemptFailureKind.ProviderProtocolError)
        } catch (_: Exception) { failure() }
        finally {
            if (!retained) {
                match (receiver) { case Some(value) => value.close(); case None => () }
                match (reservation) { case Some(value) => value.close(); case None => () }
            }
        }
    }

    private func validateRouteSize(value: AgentValue): Unit {
        let kind = providerTextIfPresent(value, "type")
        if (kind == "execute") {
            if (providerField(value, "request").stringify().size > limits.maxInputBytes) {
                throw LogicalJsonPayloadError("model input exceeds its operator payload allowance")
            }
        } else if (kind == "http_request" && providerTextIfPresent(value, "action") == "open") {
            if (providerField(value, "arguments").stringify().size > limits.maxPrepareBytes) {
                throw LogicalJsonPayloadError("model authored HTTP bytes exceed its operator payload allowance")
            }
        } else if (kind == "" && value.field("payload").isSome()) {
            if (providerField(value, "payload").stringify().size > limits.maxResultBytes) {
                throw LogicalJsonPayloadError("model typed result exceeds its operator payload allowance")
            }
        }
    }
    private func validateIdentity(value: AgentValue): Unit {
        if (providerText(value, "schema") != MODEL_PROVIDER_PROTOCOL ||
            canonicalAgentValue(providerField(value, "identity")) != identity) {
            throw LogicalJsonPayloadError("model message differs from its actual Attempt identity")
        }
    }
    private func checkCurrent(): Unit {
        match (check()) { case Result.Ok(_) => (); case Result.Err(error) =>
            transportError = Some(error); throw LogicalJsonPayloadError("model actual owner is no longer current") }
    }
    private func sendPhysical(value: AgentValue): Unit {
        checkCurrent()
        if (value.stringify().size > physical) { throw LogicalJsonPayloadError("model physical frame exceeds its bound") }
        match (writePhysical(value)) { case Result.Ok(_) => (); case Result.Err(error) =>
            transportError = Some(error); throw LogicalJsonPayloadError("model physical write failed") }
    }
    private func receivePhysical(): AgentValue {
        checkCurrent()
        match (readPhysical()) { case Result.Ok(value) => value; case Result.Err(error) =>
            transportError = Some(error); throw LogicalJsonPayloadError("model physical read failed") }
    }
    private func failure<T>(): Result<T> {
        match (transportError) { case Some(error) => Result.Err(error)
            case None => providerFailure(AgentErrorKind.Protocol, "model.logical_protocol_invalid", AttemptFailureKind.ProviderProtocolError) }
    }
}

func providerTextIfPresent(value: AgentValue, name: String): String {
    match (value.field(name)) { case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => "" }
}
