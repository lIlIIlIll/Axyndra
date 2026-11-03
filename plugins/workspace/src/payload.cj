package workspace_plugin

import agent_domain.*
import process4cj.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

// One allocation bank for physical frames, invocation/response DOMs and replies.
// Profiles select representation only; the worker never obtains Host services.
let workspacePayloadOwners = LogicalJsonOwnerBudget(maximumMessage: ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX)
let workspacePayloadTransfers = LogicalJsonProcessBudget(workspacePayloadOwners)
var workspacePayloadProfile: ?OrdinaryToolPayloadLimits = None
var workspaceInvocationPayment: ?LogicalJsonOwnerReservation = None

func workspaceAdmitPayload(frame: JsonNode, hello: JsonNode): Unit {
    let raw = frame.field("tool_payload_limits")
    let profile = ordinaryToolPayloadLimitsFromValue(raw ?? jsonNull())
    if (raw.isSome() && (!validOrdinaryToolPayloadOffer(hello.field("ordinary_tool_payload") ?? jsonNull()) ||
        profile.isNone() || profile.getOrThrow().contribution != wsText(frame, "tool") ||
        !["prepare", "tool"].contains(wsText(frame, "kind")))) {
        throw WorkspaceFailure("workspace.payload_profile", "Payload profile must match the exact offered ordinary contribution")
    }
    if (profile.isSome() != (wsText(frame, "payload_window") != "")) {
        throw WorkspaceFailure("workspace.payload_window", "Payload window requires its negotiated exact profile")
    }
    workspacePayloadProfile = profile
    let maximum = match (profile) { case Some(value) => value.maxInputBytes; case None => workspaceInputLimit(wsText(frame, "tool")) + 4096 }
    let input = frame.field("arguments") ?? jsonNull()
    let extent = logicalJsonWriteReservationBytes(input, maximum)
    let payment = workspacePayloadOwners.acquire(extent)
    try { payment.ensureDecoded(extent, logicalJsonValueNodeCount(frame)) }
    catch (error: Exception) { payment.close(); throw error }
    workspaceInvocationPayment = Some(payment)
    if (stringifyUnifiedJson(input).size > maximum) {
        throw WorkspaceFailure("workspace.input_limit", "Invocation input exceeds its selected profile") }
}

func workspaceReleasePayload(): Unit {
    workspacePayloadProfile = None
    match (workspaceInvocationPayment) { case Some(value) => value.close(); case None => () }
    workspaceInvocationPayment = None
}

func workspaceLogicalOuter(frame: JsonNode): Unit {
    if (frame.unifiedKind != UnifiedJsonKind.Object || frame.fields.size != WS_IDENTITY_FIELDS.size + 2 ||
        frame.field("payload").isNone()) { throw WorkspaceFailure("workspace.payload_outer", "Logical frame has unexpected fields") }
    for (field in frame.fields where !WS_IDENTITY_FIELDS.contains(field.name) && field.name != "type" && field.name != "payload") {
        throw WorkspaceFailure("workspace.payload_outer", "Logical frame has unexpected fields") }
}

class WorkspacePayloadReceiver {
    let identity: JsonNode
    let window: String
    private let receiver: LogicalJsonReceiver
    init(first: JsonNode, hello: JsonNode, pending: ?JsonNode) {
        workspaceLogicalOuter(first)
        let header = first.field("payload").getOrThrow()
        let isResponse = pending.isSome()
        identity = match (pending) { case Some(value) => value; case None => first }
        if (!workspaceSameIdentity(first, identity) || !workspaceValidInvocation(first, hello)) {
            throw WorkspaceFailure("workspace.payload_identity", "Logical frame differs from its actual invocation") }
        window = if (isResponse) { wsText(identity, "payload_window") } else { wsText(header, "window") }
        let maximum = if (isResponse) {
            match (workspacePayloadProfile) { case Some(value) => value.maxMessageBytes
                case None => throw WorkspaceFailure("workspace.payload_unsupported", "Logical response was not negotiated") }
        } else {
            if (!validOrdinaryToolPayloadOffer(hello.field("ordinary_tool_payload") ?? jsonNull())) {
                throw WorkspaceFailure("workspace.payload_unsupported", "Logical invocation was not offered") }
            ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX
        }
        receiver = LogicalJsonReceiver(workspacePayloadTransfers, maximum, window, 1,
            if (isResponse) { "service_response" } else { "invoke" }, { => () }, physicalFrameBytes: WORKSPACE_FRAME_BYTES)
    }
    func accept(frame: JsonNode): ?JsonNode {
        workspaceLogicalOuter(frame)
        if (!workspaceSameIdentity(identity, frame)) { throw WorkspaceFailure("workspace.payload_identity", "Logical frame identity changed") }
        let complete = receiver.accept(wsText(frame, "type"), frame.field("payload").getOrThrow())
        match (complete) { case Some(value) =>
            if (!workspaceSameIdentity(identity, value) || wsText(value, "payload_window") != window) {
                throw WorkspaceFailure("workspace.payload_identity", "Completed logical message differs from its fixed window") }
            case None => () }
        complete
    }
    func close(): Unit { receiver.close() }
}

func workspacePayloadReply(invocation: JsonNode, value: JsonNode, ok: Bool): Unit {
    let profile = workspacePayloadProfile.getOrThrow()
    let payment = workspaceInvocationPayment.getOrThrow()
    let extent = logicalJsonWriteReservationBytes(value, profile.maxResultBytes)
    payment.ensureDecoded(extent, logicalJsonValueNodeCount(value))
    let fields = workspaceEnvelope(invocation, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok))); fields.add(JsonObjectEntry("result", value))
    fields.add(JsonObjectEntry("payload_window", invocation.field("payload_window").getOrThrow()))
    let envelope = jsonObject(fields.toArray())
    payment.ensureDecoded(logicalJsonWriteReservationBytes(envelope, profile.maxMessageBytes), logicalJsonValueNodeCount(envelope))
    if (stringifyUnifiedJson(value).size > profile.maxResultBytes) {
        throw WorkspaceFailure("workspace.output_limit", "Result exceeds its frozen ordinary profile") }
    let source = stringifyUnifiedJson(envelope)
    writeLogicalJsonPayload(wsText(invocation, "payload_window"), 1, "result", source, profile.maxMessageBytes,
        { => () }, { kind, header =>
            let outer = workspaceEnvelope(invocation, kind); outer.add(JsonObjectEntry("payload", header)); wsEmit(jsonObject(outer.toArray())) })
}

// Exact UTF-8 byte accounting for the JSON writer, without a string/array copy.
func workspaceEscapedBytes(text: String): Int64 {
    var size: Int64 = 2
    unsafe {
        let bytes = acquireArrayRawData(text.rawData())
        try { for (index in 0..text.size) {
            let byte = bytes.pointer.read(index)
            size += if (byte == 34u8 || byte == 92u8 || byte == 8u8 || byte == 9u8 || byte == 10u8 || byte == 12u8 || byte == 13u8) { 2 }
                else if (byte < 32u8) { 6 } else { 1 }
        } } finally { releaseArrayRawData(bytes) }
    }
    size
}

func workspaceEscapedTwiceBytes(text: String): Int64 {
    var size: Int64 = 6
    unsafe {
        let bytes = acquireArrayRawData(text.rawData())
        try { for (index in 0..text.size) {
            let byte = bytes.pointer.read(index)
            size += if (byte == 34u8 || byte == 92u8) { 4 }
                else if (byte == 8u8 || byte == 9u8 || byte == 10u8 || byte == 12u8 || byte == 13u8) { 3 }
                else if (byte < 32u8) { 7 } else { 1 }
        } } finally { releaseArrayRawData(bytes) }
    }
    size
}
