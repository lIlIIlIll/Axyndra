package program_plugin

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// The host offer is only transport capability. The actual profile comes from
// this invocation; no plugin frame can raise it. All messages use the shared
// Domain codec and the SAME per-process incoming reservation.
class ProgramPayloadWindow {
    let invocation: JsonNode
    private let input: ProgramInput
    private let enabled: Bool
    private let profile: ?OrdinaryToolPayloadLimits
    private let window: String
    private var retainedBytes: Int64 = 0
    private var retainedNodes: Int64 = 0
    private let receivers: ArrayList<LogicalJsonReceiver>
    init(input: ProgramInput, hello: JsonNode, first: JsonNode) {
        let ownedReceivers = ArrayList<LogicalJsonReceiver>()
        let supported = match (hello.field("ordinary_tool_payload")) { case Some(value) => validOrdinaryToolPayloadOffer(value); case None => false }
        var received = first
        if (stringField(first, "type") == "payload_begin") {
            require(supported)
            let key = programPayloadWindowText(first.field("payload").getOrThrow(), "window")
            let receiver = LogicalJsonReceiver(programPayloadProcess, ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX, key, 1, "invoke", { => () },
                physicalFrameBytes: PROGRAM_FRAME_BYTES, reservation: Some(input.charge))
            ownedReceivers.add(receiver)
            var next = first
            while (true) {
                require(sameIdentity(first, next))
                if (stringField(next, "type") == "cancel") { emit(jsonObject(envelope(first, "cancelled").toArray())); throw ProgramCancelled() }
                match (receiver.accept(stringField(next, "type"), next.field("payload").getOrThrow())) {
                    case Some(value) => received = value; break
                    case None => next = input.frame().getOrThrow()
                }
            }
            require(sameIdentity(first, received) && stringField(received, "payload_window") == key)
        }
        let selected: ?OrdinaryToolPayloadLimits = match (received.field("tool_payload_limits")) { case Some(value) =>
            let parsed = ordinaryToolPayloadLimitsFromValue(value); require(supported && parsed.isSome()); parsed
            case None => None }
        let key = stringField(received, "payload_window")
        if (selected.isSome()) {
            require(key != "" && key.size <= 256 && selected.getOrThrow().contribution == stringField(received, "tool"))
            require(stringifyUnifiedJson(received.field("arguments").getOrThrow()).size <= selected.getOrThrow().maxInputBytes)
        } else { require(ownedReceivers.isEmpty() && key == "") }
        let source = stringifyUnifiedJson(received)
        let bytes = source.size; let nodes = logicalJsonNodeCount(source)
        input.charge.ensureDecoded(bytes, nodes)
        input.retain(bytes, nodes)
        this.input = input; this.receivers = ownedReceivers
        retainedBytes = bytes; retainedNodes = nodes
        invocation = received; profile = selected; window = key; enabled = selected.isSome()
    }
    func request(sequence: Int64, value: JsonNode): Unit {
        if (!enabled) { emit(value); return }
        require(sequence >= 2 && sameIdentity(value, invocation) && stringField(value, "type") == "service_request")
        // The old Program whole-proposal ceiling remains1MiB. The host profile
        // may narrow it; it never authorizes a tool or expands child business.
        let maximum = min(1048576, profile.getOrThrow().maxMessageBytes)
        let bound = logicalJsonWriteReservationBytes(value, maximum)
        let charge = programPayloadProcess.acquire(bound + 65536)
        try {
            // Prepay both serialized representations and the fixed framing
            // workspace BEFORE either JSON copy is made. All growth belongs
            // to this same outgoing slot, which closes only after emission.
            charge.ensureDecoded(bound * 2 + 65536, logicalJsonValueNodeCount(value))
            let rawSource = stringifyUnifiedJson(value); require(rawSource.size <= maximum)
            if (rawSource.size <= PROGRAM_FRAME_BYTES) { emit(value); return }
            value.put("payload_window", jsonString(window))
            charge.ensureDecoded(bound * 2 + 65536, logicalJsonValueNodeCount(value))
            let source = stringifyUnifiedJson(value); require(source.size <= maximum)
            charge.ensureDecoded(rawSource.size + source.size, logicalJsonNodeCount(source))
            writeLogicalJsonPayload(window, sequence, "service_request", source, maximum, { => () }, { kind, header =>
                let fields = envelope(invocation, kind); fields.add(JsonObjectEntry("payload", header)); emit(jsonObject(fields.toArray()))
            })
        } finally { charge.close() }
    }
    func response(sequence: Int64, requestId: String): JsonNode {
        let first = input.frame().getOrThrow(); require(sameIdentity(first, invocation))
        if (stringField(first, "type") == "cancel") { return first }
        var received = first
        if (stringField(first, "type") == "payload_begin") {
            require(enabled)
            let receiver = LogicalJsonReceiver(programPayloadProcess, profile.getOrThrow().maxMessageBytes,
                window, sequence, "service_response", { => () }, physicalFrameBytes: PROGRAM_FRAME_BYTES,
                reservation: Some(input.charge), retainedBytes: retainedBytes, retainedNodes: retainedNodes)
            receivers.add(receiver)
            var next = first
            while (true) {
                require(sameIdentity(next, invocation))
                if (stringField(next, "type") == "cancel") { return next }
                match (receiver.accept(stringField(next, "type"), next.field("payload").getOrThrow())) {
                    case Some(value) => received = value; break
                    case None => next = input.frame().getOrThrow()
                }
            }
        }
        require(sameIdentity(received, invocation) && stringField(received, "type") == "service_response" && stringField(received, "request_id") == requestId)
        let source = stringifyUnifiedJson(received)
        if (enabled) { require(stringifyUnifiedJson(received.field("result") ?? jsonNull()).size <= profile.getOrThrow().maxServiceResponseBytes) }
        retainedBytes += source.size; retainedNodes += logicalJsonNodeCount(source)
        input.charge.ensureDecoded(retainedBytes, retainedNodes)
        input.retain(retainedBytes, retainedNodes)
        received
    }
    func reply(value: JsonNode): Unit {
        let maximum = match (profile) { case Some(limits) => limits.maxResultBytes; case None => PROGRAM_FRAME_BYTES - 8192 }
        let result = value.field("result").getOrThrow()
        let charge = programPayloadProcess.acquire(logicalJsonWriteReservationBytes(result, maximum) + 65536)
        try {
            let resultText = stringifyUnifiedJson(result); require(resultText.size <= maximum)
            if (enabled) { value.put("payload_window", jsonString(window)) }
            let source = stringifyUnifiedJson(value)
            charge.ensureDecoded(source.size, logicalJsonNodeCount(source))
            if (source.size > PROGRAM_FRAME_BYTES) {
                require(enabled)
                writeLogicalJsonPayload(window, 1, "result", source, profile.getOrThrow().maxMessageBytes, { => () }, { kind, header =>
                    let fields = envelope(invocation, kind); fields.add(JsonObjectEntry("payload", header)); emit(jsonObject(fields.toArray()))
                })
            } else { emit(value) }
        } finally { charge.close() }
    }
    func close(): Unit {
        // Completed receiver buffers retain copies until interpretation ends.
        // Their shared charge belongs to the borrowed input owner; release its
        // accumulated charge only when the process leaves this exact window.
        for (receiver in receivers) { receiver.close() }
        input.resetCharge()
    }
}

// The Domain getter is package-private. Keep its exact text/type/error body
// here instead of changing a malformed field into the public empty fallback.
func programPayloadWindowText(value: AgentValue, name: String): String {
    let found = value.field(name).getOrThrow()
    if (found.unifiedKind != ValueKind.Text) { throw LogicalJsonPayloadError("logical payload text has wrong type") }
    found.text
}
