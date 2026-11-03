package pure_provider_runtime

import logical_json_payload.*
import process4cj.*
import std.collection.*
import std.env.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Allocation accounting is shared by physical frames, logical input and the
// result consumer. It is not a capability, a Run, or a second source registry.
// This consumer declares its own aggregate explicitly instead of inheriting the
// library default: its saturation contracts drive this pool to its refusal point
// (two legal 8 MiB declarations plus the retained hello/incoming/max-reply
// owners) and assert `document.data_capacity`, so the capacity it was written
// against must stay fixed. It is a separate bank from the host's shared pool.
let providerPayloadOwner = LogicalJsonOwnerBudget(maximumCharged: 134217728)
let providerPayloadBudget = LogicalJsonProcessBudget(providerPayloadOwner)

class ProviderWireFrame {
    let value: JsonNode
    private let reservation: LogicalJsonOwnerReservation
    init(value: JsonNode, reservation: LogicalJsonOwnerReservation) {
        this.value = value; this.reservation = reservation
    }
    func close(): Unit { reservation.close() }
}

// Borrow fd 0; never close it and never start a competing reader. Waiting in
// ConsoleReader's native getc pins a Cangjie GC mutator, so use bounded polling
// and buffered readFdChunk, as the independently tested MCP native endpoint.
class ProviderWireInput {
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    private var eof = false
    private let bufferCharge = providerPayloadOwner.acquireFixedBuffer(8192)
    func close(): Unit { buffered = []; bufferCharge.close() }
    func next(deadline!: ?MonoTime = None): ?ProviderWireFrame {
        let charge = providerPayloadOwner.acquire(PROVIDER_FRAME_BYTES)
        var retained = false
        try {
            let output = ArrayList<Byte>()
            while (true) {
                match (deadline) { case Some(value) => providerDeadline(value); case None => () }
                if (offset >= buffered.size) {
                    if (eof) {
                        if (!output.isEmpty()) { throw PureProviderError("provider.frame_incomplete", "Protocol frame ended early") }
                        return None
                    }
                    if (!waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                    match (readFdChunk(0, maxBytes: 8192)) {
                        case Some(value) => buffered = value; offset = 0
                        case None => eof = true; continue
                    }
                }
                let begin = offset
                while (offset < buffered.size && buffered[offset] != 10u8) { offset++ }
                let bytes = offset - begin
                if (bytes > PROVIDER_FRAME_BYTES - output.size) { throw PureProviderError("provider.frame_limit", "Frame is too large") }
                output.add(all: buffered[begin..offset])
                if (offset < buffered.size) {
                    offset++
                    let text = String.fromUtf8(output.toArray())
                    // Raw bytes were reserved before allocation; the denser
                    // DOM cost is claimed before parsing, including normal
                    // small physical frames which never use logical chunks.
                    charge.ensureDecoded(text.size, logicalJsonNodeCount(text))
                    let value = parseUnifiedJson(text, maxBytes: PROVIDER_FRAME_BYTES, maxDepth: 32)
                    let result = ProviderWireFrame(value, charge)
                    retained = true
                    return Some(result)
                }
            }
            None
        } finally { if (!retained) { charge.close() } }
    }
}

func providerDeadline(deadline: MonoTime): Unit {
    if (MonoTime.now() >= deadline) { throw PureProviderError("provider.query_timeout", "Pure content deadline elapsed") }
}
func providerSameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in PROVIDER_IDENTITY) {
        if (stringifyUnifiedJson(left.field(name) ?? jsonNull()) != stringifyUnifiedJson(right.field(name) ?? jsonNull())) { return false }
    }
    true
}
func providerLogicalOuter(frame: JsonNode): Unit {
    if (frame.unifiedKind != UnifiedJsonKind.Object || frame.fields.size != PROVIDER_IDENTITY.size + 2) {
        throw PureProviderError("provider.payload_identity", "Logical frame has unknown fields")
    }
    for (field in frame.fields where field.name != "type" && field.name != "payload" && !PROVIDER_IDENTITY.contains(field.name)) {
        throw PureProviderError("provider.payload_identity", "Logical frame has unknown fields")
    }
}

class ProviderQueryInput {
    let value: JsonNode
    let deadline: MonoTime
    private let receiver: ?LogicalJsonReceiver
    init(value: JsonNode, deadline: MonoTime, receiver!: ?LogicalJsonReceiver = None) {
        this.value = value; this.deadline = deadline; this.receiver = receiver
    }
    func close(): Unit { match (receiver) { case Some(value) => value.close(); case None => () } }
}

func providerReceiveQuery(first: JsonNode, hello: JsonNode, enabled: Bool, input: ProviderWireInput): ProviderQueryInput {
    let deadline = MonoTime.now() + Duration.second * 5
    if (!providerValidInvocation(first, hello)) { throw PureProviderError("provider.identity", "Invalid pure content identity") }
    if (providerText(first, "type") == "invoke") {
        if (enabled && providerText(first, "payload_window") == "") { throw PureProviderError("provider.payload_identity", "Logical profile requires its fixed window") }
        if (!enabled && first.field("payload_window").isSome()) { throw PureProviderError("provider.payload_unsupported", "Logical profile was not negotiated") }
        return ProviderQueryInput(first, deadline)
    }
    if (!enabled || providerText(first, "type") != "payload_begin") { throw PureProviderError("provider.payload_unsupported", "Logical profile was not negotiated") }
    providerLogicalOuter(first)
    let header = first.field("payload").getOrThrow()
    let window = providerText(header, "window")
    let receiver = LogicalJsonReceiver(providerPayloadBudget, CONTENT_PAYLOAD_MESSAGE_BYTES, window, 1, "invoke",
        { => providerDeadline(deadline) }, physicalFrameBytes: PROVIDER_FRAME_BYTES)
    var retained = false
    try {
        let _ = receiver.accept("payload_begin", header)
        while (true) {
            let incoming = input.next(deadline: Some(deadline)).getOrThrow()
            try {
                let frame = incoming.value
                if (!providerSameIdentity(frame, first)) { throw PureProviderError("provider.payload_identity", "Logical frame identity changed") }
                if (providerText(frame, "type") == "cancel") { throw PureProviderError("provider.cancelled", "Content query was cancelled") }
                providerLogicalOuter(frame)
                match (receiver.accept(providerText(frame, "type"), frame.field("payload").getOrThrow())) {
                    case Some(value) =>
                        if (!providerSameIdentity(value, first) || providerText(value, "type") != "invoke" ||
                            providerText(value, "payload_window") != window || !providerValidInvocation(value, hello)) {
                            throw PureProviderError("provider.payload_identity", "Completed logical identity changed") }
                        let result = ProviderQueryInput(value, deadline, receiver: Some(receiver))
                        retained = true
                        return result
                    case None => ()
                }
            } finally { incoming.close() }
        }
        throw PureProviderError("provider.payload_incomplete", "Logical query did not complete")
    } finally { if (!retained) { receiver.close() } }
}

func providerPayloadReply(frame: JsonNode, value: JsonNode, ok: Bool, enabled: Bool, deadline: MonoTime): Unit {
    providerDeadline(deadline)
    let fields = providerEnvelope(frame, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    if (enabled) { fields.add(JsonObjectEntry("payload_window", frame.field("payload_window").getOrThrow())) }
    let source = stringifyUnifiedJson(jsonObject(fields.toArray()))
    if (source.size + 1 <= PROVIDER_FRAME_BYTES) {
        providerDeadline(deadline)
        let output = getStdOut(); output.write((source + "\n").toArray()); output.flush()
        return
    }
    if (!enabled) { throw PureProviderError("provider.frame_limit", "Unnegotiated logical result") }
    writeLogicalJsonPayload(providerText(frame, "payload_window"), 1, "result", source,
        CONTENT_PAYLOAD_MESSAGE_BYTES, { => providerDeadline(deadline) }, { kind, header =>
            let envelope = providerEnvelope(frame, kind)
            envelope.add(JsonObjectEntry("payload", header))
            providerEmit(jsonObject(envelope.toArray()))
        })
}
