package pure_provider_runtime

import logical_json_payload.*
import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

// A transport window, not a Host permission. It borrows the exact incoming
// identity and keeps all decoded responses charged until the Tool terminates.
class DocumentProtocolWindow {
    let invocation: JsonNode
    let deadline: MonoTime
    private let input: ProviderWireInput
    private let content: Bool
    private let ordinary: ?OrdinaryToolPayloadLimits
    private let receivers: ArrayList<LogicalJsonReceiver>
    private let frames = ArrayList<ProviderWireFrame>()
    private var closed = false

    init(input: ProviderWireInput, hello: JsonNode, first: JsonNode) {
        let until = MonoTime.now() + Duration.second * (if (providerText(first, "kind") == "tool") { 30 } else { 5 })
        let isContent = ["provider", "context_provider"].contains(providerText(first, "kind"))
        let offeredContent = validContentPayloadLimits(hello.field("content_payload_limits") ?? jsonNull())
        let offeredOrdinary = validOrdinaryToolPayloadOffer(hello.field("ordinary_tool_payload") ?? jsonNull())
        let owners = ArrayList<LogicalJsonReceiver>()
        var value = first
        var retained = false
        try {
            if (providerText(first, "type") == "payload_begin") {
                if (!(if (isContent) { offeredContent } else { offeredOrdinary })) {
                    throw PureProviderError("document.payload_unsupported", "logical payload profile was not offered") }
                providerLogicalOuter(first)
                let header = first.field("payload").getOrThrow()
                let key = providerText(header, "window")
                let maximum = if (isContent) { CONTENT_PAYLOAD_MESSAGE_BYTES } else { ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX }
                let receiver = LogicalJsonReceiver(providerPayloadBudget, maximum, key, 1, "invoke",
                    { => providerDeadline(until) }, physicalFrameBytes: PROVIDER_FRAME_BYTES)
                owners.add(receiver)
                let _ = receiver.accept("payload_begin", header)
                while (true) {
                    let incoming = input.next(deadline: Some(until)).getOrThrow()
                    try {
                        if (!providerSameIdentity(first, incoming.value)) {
                            throw PureProviderError("document.payload_identity", "logical invocation identity changed") }
                        if (providerText(incoming.value, "type") == "cancel") { throw PureDocumentCancelled() }
                        providerLogicalOuter(incoming.value)
                        match (receiver.accept(providerText(incoming.value, "type"), incoming.value.field("payload").getOrThrow())) {
                            case Some(complete) => value = complete; break
                            case None => () }
                    } finally { incoming.close() }
                }
                if (!providerSameIdentity(first, value) || providerText(value, "type") != "invoke" ||
                    providerText(value, "payload_window") != key) {
                    throw PureProviderError("document.payload_identity", "assembled invocation has another identity") }
            }
            let profile = ordinaryToolPayloadLimitsFromValue(value.field("tool_payload_limits") ?? jsonNull())
            let hasProfile = value.field("tool_payload_limits").isSome()
            if (hasProfile && (!offeredOrdinary || profile.isNone() || isContent ||
                profile.getOrThrow().contribution != providerText(value, "tool"))) {
                throw PureProviderError("document.payload_profile", "ordinary profile does not match its contribution") }
            let enabled = if (isContent) { offeredContent } else { profile.isSome() }
            if (enabled != (providerText(value, "payload_window") != "") || (!enabled && !owners.isEmpty())) {
                throw PureProviderError("document.payload_window", "logical window differs from its negotiated profile") }
            let maximum = if (isContent && offeredContent) { CONTENT_PAYLOAD_INPUT_BYTES }
                else { match (profile) { case Some(p) => p.maxInputBytes; case None => PROVIDER_FRAME_BYTES - 8192 } }
            if (stringifyUnifiedJson(value.field("arguments") ?? jsonNull()).size > maximum) {
                throw PureProviderError("document.input_limit", "input exceeds the actual transport profile") }
            this.input = input; this.invocation = value; this.deadline = until
            this.content = isContent && offeredContent; this.ordinary = profile; this.receivers = owners
            retained = true
        } finally { if (!retained) { for (owner in owners) { owner.close() } } }
    }

    func maxResult(): Int64 {
        if (content) { CONTENT_PAYLOAD_RESULT_BYTES }
        else { match (ordinary) { case Some(p) => p.maxResultBytes; case None => PROVIDER_FRAME_BYTES - 8192 } }
    }
    // The runtime already owns the reply reservation before user code runs.
    // Reuse it for the complete wire envelope until the actual send completes;
    // a third acquisition would violate the original two-transfer ceiling.
    func reply(value: JsonNode, ok: Bool, charge: LogicalJsonReservation): Unit {
        providerDeadline(deadline)
        let valueBytes = logicalJsonWriteReservationBytes(value, maxResult())
        if (valueBytes > maxResult()) {
            throw PureProviderError("document.result_limit", "result exceeds its exact profile") }
        charge.ensureDecoded(valueBytes, logicalJsonValueNodeCount(value))
        let fields = providerEnvelope(invocation, "result")
        fields.add(JsonObjectEntry("ok", jsonBool(ok))); fields.add(JsonObjectEntry("result", value))
        let enabled = content || ordinary.isSome()
        if (enabled) { fields.add(JsonObjectEntry("payload_window", invocation.field("payload_window").getOrThrow())) }
        let envelope = jsonObject(fields.toArray())
        let maximum = if (content) { CONTENT_PAYLOAD_MESSAGE_BYTES }
            else { match (ordinary) { case Some(profile) => profile.maxMessageBytes; case None => PROVIDER_FRAME_BYTES } }
        let envelopeBytes = logicalJsonWriteReservationBytes(envelope, maximum)
        if (envelopeBytes > maximum) {
            throw PureProviderError("document.result_limit", "result exceeds its negotiated complete wire envelope") }
        // Pay for actual value/field nodes before stringify allocates the full
        // encoded envelope. No live owner is released or reduced here.
        charge.ensureDecoded(envelopeBytes, logicalJsonValueNodeCount(envelope))
        let encoded = stringifyUnifiedJson(envelope)
        charge.ensureDecoded(encoded.size, logicalJsonNodeCount(encoded))
        if (encoded.size + 1 <= PROVIDER_FRAME_BYTES) { providerEmit(envelope) }
        else {
            if (!enabled) { throw PureProviderError("document.result_limit", "logical result was not negotiated") }
            writeLogicalJsonPayload(providerText(invocation, "payload_window"), 1, "result", encoded, maximum,
                { => providerDeadline(deadline) }, { kind, header =>
                    let outer = providerEnvelope(invocation, kind); outer.add(JsonObjectEntry("payload", header))
                    providerEmit(jsonObject(outer.toArray())) })
        }
    }

    func documentResponse(sequence: Int64, id: String): JsonNode {
        if (closed || providerText(invocation, "kind") != "tool") {
            throw PureProviderError("document.window_closed", "this window has no document broker") }
        let incoming = input.next(deadline: Some(deadline)).getOrThrow()
        frames.add(incoming)
        let first = incoming.value
        if (!providerSameIdentity(first, invocation)) { throw PureProviderError("document.response_identity", "response has another invocation identity") }
        if (providerText(first, "type") == "cancel") { throw PureDocumentCancelled() }
        var value = first
        if (providerText(first, "type") == "payload_begin") {
            if (ordinary.isNone()) { throw PureProviderError("document.payload_unsupported", "logical response was not negotiated") }
            providerLogicalOuter(first)
            let receiver = LogicalJsonReceiver(providerPayloadBudget, ordinary.getOrThrow().maxMessageBytes,
                providerText(invocation, "payload_window"), sequence, "service_response",
                { => providerDeadline(deadline) }, physicalFrameBytes: PROVIDER_FRAME_BYTES)
            receivers.add(receiver)
            let _ = receiver.accept("payload_begin", first.field("payload").getOrThrow())
            while (true) {
                let chunk = input.next(deadline: Some(deadline)).getOrThrow()
                try {
                    if (!providerSameIdentity(chunk.value, invocation)) { throw PureProviderError("document.response_identity", "logical response identity changed") }
                    if (providerText(chunk.value, "type") == "cancel") { throw PureDocumentCancelled() }
                    providerLogicalOuter(chunk.value)
                    match (receiver.accept(providerText(chunk.value, "type"), chunk.value.field("payload").getOrThrow())) {
                        case Some(complete) => value = complete; break
                        case None => () }
                } finally { chunk.close() }
            }
        }
        if (!providerSameIdentity(value, invocation) || providerText(value, "request_id") != id) {
            throw PureProviderError("document.response_identity", "response request ID differs") }
        if (ordinary.isSome() && providerText(value, "payload_window") != providerText(invocation, "payload_window")) {
            throw PureProviderError("document.response_window", "service response belongs to another payload window") }
        let accepted = value.field("ok") ?? jsonNull()
        if (providerText(value, "type") == "service_error" || accepted.unifiedKind != UnifiedJsonKind.Boolean || !accepted.boolValue) {
            throw PureProviderError("document.service_failed", "Host refused the document operation; it was not retried") }
        if (providerText(value, "type") != "service_response") { throw PureProviderError("document.response_type", "expected a document service response") }
        let result = value.field("result") ?? jsonNull()
        let maximum = match (ordinary) { case Some(p) => p.maxServiceResponseBytes; case None => PROVIDER_FRAME_BYTES - 8192 }
        if (stringifyUnifiedJson(result).size > maximum || providerText(result, "receipt_id") == "") {
            throw PureProviderError("document.receipt_missing", "document response requires a bounded actual Receipt") }
        result
    }
    func close(): Unit {
        if (closed) { return }; closed = true
        for (receiver in receivers) { receiver.close() }
        for (frame in frames) { frame.close() }
    }
}
