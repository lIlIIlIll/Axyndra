package skills_plugin

import agent_domain.*
import process4cj.*
import skill_runtime.*
import std.collection.*
import std.env.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Allocation accounting is shared by physical frames, logical input and the
// result consumer. It is not a capability, a Run, or a second source registry.
let skillsPayloadOwner = LogicalJsonOwnerBudget()
let skillsPayloadBudget = LogicalJsonProcessBudget(skillsPayloadOwner)

class SkillsWireFrame {
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
class SkillsWireInput {
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    private var eof = false
    private let bufferCharge = skillsPayloadOwner.acquireFixedBuffer(8192)
    func close(): Unit { buffered = []; bufferCharge.close() }
    func next(deadline!: ?MonoTime = None): ?SkillsWireFrame {
        let charge = skillsPayloadOwner.acquire(SKILLS_FRAME_BYTES)
        var retained = false
        try {
            let output = ArrayList<Byte>()
            while (true) {
                match (deadline) { case Some(value) => skillsDeadline(value); case None => () }
                if (offset >= buffered.size) {
                    if (eof) {
                        if (!output.isEmpty()) { throw SkillError("skills.frame_incomplete", "Protocol frame ended early") }
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
                if (bytes > SKILLS_FRAME_BYTES - output.size) { throw SkillError("skills.frame_limit", "Frame is too large") }
                output.add(all: buffered[begin..offset])
                if (offset < buffered.size) {
                    offset++
                    let text = String.fromUtf8(output.toArray())
                    // Raw bytes were reserved before allocation; the denser
                    // DOM cost is claimed before parsing, including normal
                    // small physical frames which never use logical chunks.
                    charge.ensureDecoded(text.size, logicalJsonNodeCount(text))
                    let value = parseUnifiedJson(text, maxBytes: SKILLS_FRAME_BYTES, maxDepth: 32)
                    let result = SkillsWireFrame(value, charge)
                    retained = true
                    return Some(result)
                }
            }
            None
        } finally { if (!retained) { charge.close() } }
    }
}

func skillsDeadline(deadline: MonoTime): Unit {
    if (MonoTime.now() >= deadline) { throw SkillError("skills.query_timeout", "Pure content deadline elapsed") }
}
func skillsSameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in SKILLS_IDENTITY) {
        if (stringifyUnifiedJson(left.field(name) ?? jsonNull()) != stringifyUnifiedJson(right.field(name) ?? jsonNull())) { return false }
    }
    true
}
func skillsLogicalOuter(frame: JsonNode): Unit {
    if (frame.unifiedKind != UnifiedJsonKind.Object || frame.fields.size != SKILLS_IDENTITY.size + 2) {
        throw SkillError("skills.payload_identity", "Logical frame has unknown fields")
    }
    for (field in frame.fields where field.name != "type" && field.name != "payload" && !SKILLS_IDENTITY.contains(field.name)) {
        throw SkillError("skills.payload_identity", "Logical frame has unknown fields")
    }
}

class SkillsQueryInput {
    let value: JsonNode
    let deadline: MonoTime
    private let receiver: ?LogicalJsonReceiver
    init(value: JsonNode, deadline: MonoTime, receiver!: ?LogicalJsonReceiver = None) {
        this.value = value; this.deadline = deadline; this.receiver = receiver
    }
    func close(): Unit { match (receiver) { case Some(value) => value.close(); case None => () } }
}

func skillsReceiveQuery(first: JsonNode, hello: JsonNode, enabled: Bool, input: SkillsWireInput): SkillsQueryInput {
    let deadline = MonoTime.now() + Duration.second * 5
    if (!skillsValidInvocation(first, hello)) { throw SkillError("skills.identity", "Invalid pure content identity") }
    if (skillsText(first, "type") == "invoke") {
        if (enabled && skillsText(first, "payload_window") == "") { throw SkillError("skills.payload_identity", "Logical profile requires its fixed window") }
        if (!enabled && first.field("payload_window").isSome()) { throw SkillError("skills.payload_unsupported", "Logical profile was not negotiated") }
        return SkillsQueryInput(first, deadline)
    }
    if (!enabled || skillsText(first, "type") != "payload_begin") { throw SkillError("skills.payload_unsupported", "Logical profile was not negotiated") }
    skillsLogicalOuter(first)
    let header = first.field("payload").getOrThrow()
    let window = skillsText(header, "window")
    let receiver = LogicalJsonReceiver(skillsPayloadBudget, CONTENT_PAYLOAD_MESSAGE_BYTES, window, 1, "invoke",
        { => skillsDeadline(deadline) }, physicalFrameBytes: SKILLS_FRAME_BYTES)
    var retained = false
    try {
        let _ = receiver.accept("payload_begin", header)
        while (true) {
            let incoming = input.next(deadline: Some(deadline)).getOrThrow()
            try {
                let frame = incoming.value
                if (!skillsSameIdentity(frame, first)) { throw SkillError("skills.payload_identity", "Logical frame identity changed") }
                if (skillsText(frame, "type") == "cancel") { throw SkillError("skills.cancelled", "Content query was cancelled") }
                skillsLogicalOuter(frame)
                match (receiver.accept(skillsText(frame, "type"), frame.field("payload").getOrThrow())) {
                    case Some(value) =>
                        if (!skillsSameIdentity(value, first) || skillsText(value, "type") != "invoke" ||
                            skillsText(value, "payload_window") != window || !skillsValidInvocation(value, hello)) {
                            throw SkillError("skills.payload_identity", "Completed logical identity changed") }
                        let result = SkillsQueryInput(value, deadline, receiver: Some(receiver))
                        retained = true
                        return result
                    case None => ()
                }
            } finally { incoming.close() }
        }
        throw SkillError("skills.payload_incomplete", "Logical query did not complete")
    } finally { if (!retained) { receiver.close() } }
}

func skillsPayloadReply(frame: JsonNode, value: JsonNode, ok: Bool, enabled: Bool, deadline: MonoTime): Unit {
    skillsDeadline(deadline)
    let fields = skillsEnvelope(frame, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    if (enabled) { fields.add(JsonObjectEntry("payload_window", frame.field("payload_window").getOrThrow())) }
    let source = stringifyUnifiedJson(jsonObject(fields.toArray()))
    if (source.size + 1 <= SKILLS_FRAME_BYTES) {
        skillsDeadline(deadline)
        let output = getStdOut(); output.write((source + "\n").toArray()); output.flush()
        return
    }
    if (!enabled) { throw SkillError("skills.frame_limit", "Unnegotiated logical result") }
    writeLogicalJsonPayload(skillsText(frame, "payload_window"), 1, "result", source,
        CONTENT_PAYLOAD_MESSAGE_BYTES, { => skillsDeadline(deadline) }, { kind, header =>
            let envelope = skillsEnvelope(frame, kind)
            envelope.add(JsonObjectEntry("payload", header))
            skillsEmit(jsonObject(envelope.toArray()))
        })
}
