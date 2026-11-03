package mcp_client_plugin

import process4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

let FRAME_LIMIT: Int64 = 262144
let INPUT_LIMIT: Int64 = 16384
let OUTPUT_LIMIT: Int64 = 65536
let IDENTITY_FIELDS = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
    "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

class PluginFailure <: Exception {
    let code: String
    init(code: String) { super(code); this.code = code }
}
func require(condition: Bool): Unit { require(condition, "mcp_plugin.input_invalid") }
func require(condition: Bool, code: String): Unit {
    if (!condition) { throw PluginFailure(code) }
}
func field(value: JsonNode, name: String): JsonNode { value.field(name) ?? jsonNull() }
func text(value: JsonNode, name: String): String {
    let found = field(value, name)
    if (found.unifiedKind == UnifiedJsonKind.Text) { found.text } else { "" }
}
func number(value: JsonNode, name: String): Int64 {
    let found = field(value, name)
    if (found.unifiedKind != UnifiedJsonKind.Number) { return -1 }
    try { Int64.parse(found.asNumberText()) } catch (_: Exception) { -1 }
}
func boolean(value: JsonNode, name: String): Bool {
    let found = field(value, name)
    found.unifiedKind == UnifiedJsonKind.Boolean && found.asBool()
}
func exact(value: JsonNode, names: Array<String>): Unit {
    require(value.unifiedKind == UnifiedJsonKind.Object && value.fields.size == names.size)
    for (entry in value.fields) {
        var found = false
        for (name in names where name == entry.name) { found = true }
        require(found)
    }
}
func hex(bytes: Array<Byte>): String {
    let result = Array<Byte>(bytes.size * 2, repeat: 0)
    // Callers already own the bounded serialization charge. Borrow both exact
    // extents synchronously; no pointer survives the loop or failure.
    unsafe {
        let source = acquireArrayRawData(bytes)
        try {
            let target = acquireArrayRawData(result)
            try {
                for (index in 0..bytes.size) {
                    let byte = source.pointer.read(index)
                    let high = byte / 16u8; let low = byte % 16u8
                    target.pointer.write(index * 2, if (high < 10u8) { high + 48u8 } else { high + 87u8 })
                    target.pointer.write(index * 2 + 1, if (low < 10u8) { low + 48u8 } else { low + 87u8 })
                }
            } finally { releaseArrayRawData(target) }
        } finally { releaseArrayRawData(source) }
    }
    String.fromUtf8(result)
}
func unhex(value: String, maximum: Int64): Array<Byte> {
    require(value.size % 2 == 0 && value.size <= maximum * 2, "mcp_plugin.channel_response_invalid")
    let result = Array<Byte>(value.size / 2, repeat: 0)
    func digit(value: Byte): Byte {
        if (value >= 48u8 && value <= 57u8) { return value - 48u8 }
        if (value >= 97u8 && value <= 102u8) { return value - 87u8 }
        throw PluginFailure("mcp_plugin.channel_response_invalid")
    }
    // Validate every lowercase nibble before it reaches its exact destination.
    // The existing extent bound proves both source reads and each target write.
    unsafe {
        let source = acquireArrayRawData(value.rawData())
        try {
            let target = acquireArrayRawData(result)
            try {
                for (index in 0..result.size) {
                    let high = digit(source.pointer.read(index * 2))
                    let low = digit(source.pointer.read(index * 2 + 1))
                    target.pointer.write(index, high * 16u8 + low)
                }
            } finally { releaseArrayRawData(target) }
        } finally { releaseArrayRawData(source) }
    }
    result
}
func sha(value: String): String { let hash = SHA256(); hash.write(value.toArray()); hex(hash.finish()) }
func stableId(invocation: JsonNode): String {
    // Input cannot supply this identity. JSON array encoding avoids concatenation ambiguity.
    "host-" + sha(stringifyUnifiedJson(jsonArray([
        field(invocation, "thread_id"), field(invocation, "run_id"), field(invocation, "epoch"), field(invocation, "call_id")
    ])))
}
func sameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in IDENTITY_FIELDS) {
        if (stringifyUnifiedJson(field(left, name)) != stringifyUnifiedJson(field(right, name))) { return false }
    }
    true
}
func sameJson(left: JsonNode, right: JsonNode): Bool {
    if (left.unifiedKind != right.unifiedKind) { return false }
    // Canonical JSON string encoding is injective: decoded text equality has
    // the same result without escaping/copying large scalar values twice.
    if (left.unifiedKind == UnifiedJsonKind.Text) { return left.text == right.text }
    if (left.unifiedKind == UnifiedJsonKind.Object) {
        if (left.fields.size != right.fields.size) { return false }
        for (entry in left.fields) {
            match (right.field(entry.name)) { case Some(value) => if (!sameJson(entry.value, value)) { return false }; case None => return false }
        }
        return true
    }
    if (left.unifiedKind == UnifiedJsonKind.List) {
        if (left.items.size != right.items.size) { return false }
        for (index in 0..left.items.size where !sameJson(left.items[index], right.items[index])) { return false }
        return true
    }
    stringifyUnifiedJson(left) == stringifyUnifiedJson(right)
}
func envelope(invocation: JsonNode, typeName: String): ArrayList<JsonObjectEntry> {
    let entries = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(typeName))])
    for (name in IDENTITY_FIELDS) { entries.add(JsonObjectEntry(name, field(invocation, name))) }
    entries
}
func validateInvocation(frame: JsonNode, extensionId!: String, limits!: ProtocolLimits = ProtocolLimits()): Unit {
    require(text(frame, "protocol") == "axyndra-js-host-v2" && text(frame, "extension_id") == extensionId &&
        text(frame, "extension_version") == "1.0.0" && number(frame, "generation") > 0 &&
        text(frame, "tool") == "session" && text(frame, "command_id") == "", "mcp_plugin.identity_invalid")
    for (name in ["id", "thread_id", "run_id", "call_id"]) {
        let value = text(frame, name)
        require(value != "" && value.size <= 256 && !value.contains("\u{0000}"), "mcp_plugin.identity_invalid")
    }
    require(number(frame, "epoch") > 0, "mcp_plugin.identity_invalid")
    let kind = text(frame, "kind")
    require((kind == "service_prepare" && text(frame, "operation_id") == "") ||
        (kind == "service" && text(frame, "operation_id") != ""), "mcp_plugin.identity_invalid")
    require(field(frame, "arguments").unifiedKind == UnifiedJsonKind.Object)
    // Canonical execution includes host_plan; pure preparation retains the smaller host input bound.
    require(stringifyUnifiedJson(field(frame, "arguments")).size <=
        (if (kind == "service_prepare") { limits.prepareInput } else { limits.canonical }), "mcp_plugin.input_limit")
}

class WireOutput {
    private let lock = Mutex()
    private var selectedLimits: ?ProtocolLimits = None
    prop limits: ProtocolLimits { get() { lock.lock(); try { selectedLimits ?? ProtocolLimits() } finally { lock.unlock() } } }
    func configure(hello: JsonNode): Unit {
        lock.lock()
        try {
            require(selectedLimits.isNone(), "mcp_plugin.hello_repeated")
            let raw = hello.field("service_protocol_limits")
            let selected = if (raw.isSome() && raw.getOrThrow().unifiedKind != UnifiedJsonKind.Null) {
                let payload = hello.field("service_payload_limits")
                ProtocolLimits(raw.getOrThrow(), payload: if (payload.isSome() && payload.getOrThrow().unifiedKind != UnifiedJsonKind.Null) { payload } else { None })
            } else {
                require(hello.field("service_payload_limits").isNone() || field(hello, "service_payload_limits").unifiedKind == UnifiedJsonKind.Null,
                    "mcp_plugin.payload_unsupported")
                ProtocolLimits()
            }
            if (selected.isExplicit) { require(number(hello, "max_frame_bytes") == selected.frame, "mcp_plugin.profile_invalid") }
            selectedLimits = Some(selected)
        } finally { lock.unlock() }
    }
    func write(value: JsonNode): Unit {
        writeGuarded(value, { => true })
    }
    func writeGuarded(value: JsonNode, allowed: () -> Bool): Unit {
        writeEncodedGuarded(stringifyUnifiedJson(value), allowed)
    }
    private func writeEncodedGuarded(encoded: String, allowed: () -> Bool): Unit {
        require(encoded.size <= limits.frame, "mcp_plugin.frame_limit")
        lock.lock()
        try { if (!allowed()) { return }; let output = getStdOut(); output.write((encoded + "\n").toArray()); output.flush() }
        finally { lock.unlock() }
    }
    func result(invocation: JsonNode, value: JsonNode, ok: Bool, allowed!: () -> Bool = { => true },
        deadline!: ?MonoTime = None, reserved!: Bool = false): Unit {
        let maximum = if (text(invocation, "kind") == "service_prepare") { limits.prepared } else { limits.result }
        // Compute a conservative small-value bound without materializing a
        // JSON string. Large serialization owns its selected maximum first.
        let small = payloadSmallJsonBound(value, 65536)
        let charge: ?PayloadCharge = if (limits.payload.isSome() && !reserved) { Some(payloadPool.acquire((if (small <= 65536) { small } else { maximum }) + 65536)) } else { None }
        try {
        // Serialize the already paid value exactly once. Header and window
        // encoding still use the standard serializer; only this trusted
        // envelope joins their canonical JSON fragments in the old order.
        let encodedValue = stringifyUnifiedJson(value)
        require(encodedValue.size <= maximum, "mcp_plugin.result_limit")
        let entries = envelope(invocation, "result")
        entries.add(JsonObjectEntry("ok", jsonBool(ok)))
        let header = stringifyUnifiedJson(jsonObject(entries.toArray()))
        let encodedWindow = if (limits.payload.isSome()) { stringifyUnifiedJson(field(invocation, "payload_window")) } else { "" }
        let builder = StringBuilder(header.size + 10 + encodedValue.size +
            (if (limits.payload.isSome()) { 18 + encodedWindow.size } else { 0 }))
        builder.append(header[..header.size - 1])
        builder.append(",\"result\":"); builder.append(encodedValue)
        if (limits.payload.isSome()) {
            builder.append(",\"payload_window\":"); builder.append(encodedWindow)
        }
        builder.append("}")
        let encoded = builder.toString()
        if (encoded.size <= limits.frame) { writeEncodedGuarded(encoded, allowed); return }
        require(limits.payload.isSome() && encoded.size <= limits.payload.getOrThrow().message, "mcp_plugin.result_limit")
        let window = text(invocation, "payload_window")
        require(window != "" && window.size <= 256, "mcp_plugin.payload_window_invalid")
            payloadNodeBound(encoded)
            let fixedDeadline = deadline ?? (MonoTime.now() + Duration.millisecond * limits.timeout)
            func emit(kind: String, values: Array<JsonObjectEntry>): Bool {
                if (!allowed()) { return false }
                require(MonoTime.now() < fixedDeadline, "mcp_plugin.payload_expired")
                writeGuarded(payloadEnvelope(invocation, kind, window, values), allowed); true
            }
            if (!emit("payload_begin", [JsonObjectEntry("message_type", jsonString("result")),
                JsonObjectEntry("bytes", jsonNumber(encoded.size.toString())), JsonObjectEntry("sha256", jsonString(sha(encoded)))])) { return }
            let bytes = encoded.toArray(); var offset: Int64 = 0
            while (offset < bytes.size) {
                let end = if (bytes.size - offset > 16384) { offset + 16384 } else { bytes.size }
                if (!emit("payload_chunk", [JsonObjectEntry("offset", jsonNumber(offset.toString())),
                    JsonObjectEntry("bytes_hex", jsonString(hex(bytes[offset..end])))])) { return }
                offset = end
            }
            let _ = emit("payload_end", [])
        } finally { match (charge) { case Some(value) => value.close(); case None => () } }
    }
}
// Sole reader of the inherited protocol fd. Borrow it without closing or
// creating another owner. ConsoleReader blocks inside native getc while a GC
// mutator remains running; a silent host can then stall every worker at GC.
// Poll only a bounded interval, never pin a Cangjie buffer while waiting, and
// read only after readiness. The one-reader invariant makes that read safe.
class ProtocolInput {
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    private var eof = false
    var transferDeadline: ?MonoTime = None
    private var frameCharge: ?PayloadCharge = None
    func retainFrame(value: PayloadCharge): Unit { require(frameCharge.isNone()); frameCharge = Some(value) }
    func takeFrameCharge(): ?PayloadCharge { let value = frameCharge; frameCharge = None; value }
    // Consume one physical line directly from the sole fd reader's buffered
    // chunks. Keep prefetched successor bytes owned here, not in a frame.
    func readLine(maxBytes: Int64): ?ArrayList<Byte> {
        let result = ArrayList<Byte>()
        while (true) {
            match (transferDeadline) { case Some(value) => require(MonoTime.now() < value, "mcp_plugin.payload_expired"); case None => () }
            if (offset == buffered.size) {
                if (eof) { require(result.isEmpty(), "mcp_plugin.incomplete_frame"); return None }
                if (!waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                match (readFdChunk(0, maxBytes: 8192)) {
                    case Some(value) => buffered = value; offset = 0
                    case None => eof = true; continue
                }
            }
            var end = offset
            unsafe {
                let chunk = acquireArrayRawData(buffered)
                try { while (end < buffered.size && chunk.pointer.read(end) != 10u8) { end++ } }
                finally { releaseArrayRawData(chunk) }
            }
            require(end - offset <= maxBytes - result.size, "mcp_plugin.frame_limit")
            result.add(all: buffered[offset..end])
            offset = end
            match (transferDeadline) { case Some(value) => require(MonoTime.now() < value, "mcp_plugin.payload_expired"); case None => () }
            if (end < buffered.size) { offset++; return Some(result) }
        }
        None
    }
}

func readFrame(stream: ProtocolInput, maxBytes!: Int64 = FRAME_LIMIT, payloadEnabled!: Bool = false): ?JsonNode {
    let raw: ?PayloadCharge = if (payloadEnabled) { Some(payloadPool.acquire(maxBytes, transfer: false)) } else { None }
    try {
        let result = match (stream.readLine(maxBytes)) {
            case Some(value) => value
            case None => return None
        }
        // Scan the existing raw buffer before UTF8/string/DOM copies.
        // 512 bytes/token is a conservative accounting coefficient,
        // not a measured RSS claim. Bounds keep every product <64 MiB.
        let nodes = if (payloadEnabled) { payloadFrameNodeCount(result) } else { 0 }
        require(result.size <= 4194304 && nodes <= 65536, "mcp_plugin.frame_limit")
        let retainedCost = if (max(1, result.size) * 8 > result.size * 4 + nodes * 512 + 1048576) {
            max(1, result.size) * 8
        } else { result.size * 4 + nodes * 512 + 1048576 }
        let charge: ?PayloadCharge = if (payloadEnabled) { Some(payloadPool.acquire((retainedCost + 1) / 2, transfer: false)) } else { None }
        var transferred = false
        try {
            let source = String.fromUtf8(result.toArray())
            if (payloadEnabled) { payloadNodeBound(source) }
            let parsed = parseUnifiedJson(source, maxBytes: maxBytes, maxDepth: 32)
            match (charge) { case Some(value) => stream.retainFrame(value); transferred = true; case None => () }
            Some(parsed)
        } finally { if (!transferred) { match (charge) { case Some(value) => value.close(); case None => () } } }
    } finally { match (raw) { case Some(value) => value.close(); case None => () } }
}
