package shell_plugin

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
func require(condition: Bool): Unit { require(condition, "shell_plugin.input_invalid") }
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
    let alphabet = "0123456789abcdef".toArray()
    let result = ArrayList<Byte>()
    for (byte in bytes) { result.add(alphabet[Int64(byte) / 16]); result.add(alphabet[Int64(byte) % 16]) }
    String.fromUtf8(result.toArray())
}
func unhex(value: String, maximum: Int64): Array<Byte> {
    require(value.size % 2 == 0 && value.size <= maximum * 2, "shell_plugin.channel_response_invalid")
    let bytes = value.toArray()
    let result = ArrayList<Byte>()
    func digit(value: Byte): Byte {
        if (value >= 48u8 && value <= 57u8) { return value - 48u8 }
        if (value >= 97u8 && value <= 102u8) { return value - 87u8 }
        throw PluginFailure("shell_plugin.channel_response_invalid")
    }
    var index: Int64 = 0
    while (index < bytes.size) { result.add(digit(bytes[index]) * 16u8 + digit(bytes[index + 1])); index += 2 }
    result.toArray()
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
func validateInvocation(frame: JsonNode): Unit {
    require(text(frame, "protocol") == "axyndra-js-host-v2" && text(frame, "extension_id") == "shell" &&
        text(frame, "extension_version") == "1.1.0" && number(frame, "generation") > 0 &&
        text(frame, "tool") == "session" && text(frame, "command_id") == "", "shell_plugin.identity_invalid")
    for (name in ["id", "thread_id", "run_id", "call_id"]) {
        let value = text(frame, name)
        require(value != "" && value.size <= 256 && !value.contains("\u{0000}"), "shell_plugin.identity_invalid")
    }
    require(number(frame, "epoch") > 0, "shell_plugin.identity_invalid")
    let kind = text(frame, "kind")
    require((kind == "service_prepare" && text(frame, "operation_id") == "") ||
        (kind == "service" && text(frame, "operation_id") != ""), "shell_plugin.identity_invalid")
    require(field(frame, "arguments").unifiedKind == UnifiedJsonKind.Object)
    // Canonical execution includes host_plan; pure preparation retains the smaller host input bound.
    require(stringifyUnifiedJson(field(frame, "arguments")).size <=
        (if (kind == "service_prepare") { INPUT_LIMIT } else { 196608 }), "shell_plugin.input_limit")
}

class WireOutput {
    private let lock = Mutex()
    func write(value: JsonNode): Unit {
        writeGuarded(value, { => true })
    }
    func writeGuarded(value: JsonNode, allowed: () -> Bool): Unit {
        let encoded = stringifyUnifiedJson(value)
        require(encoded.size <= FRAME_LIMIT, "shell_plugin.frame_limit")
        lock.lock()
        try { if (!allowed()) { return }; let output = getStdOut(); output.write((encoded + "\n").toArray()); output.flush() }
        finally { lock.unlock() }
    }
    func result(invocation: JsonNode, value: JsonNode, ok: Bool, allowed!: () -> Bool = { => true }): Unit {
        require(stringifyUnifiedJson(value).size <= OUTPUT_LIMIT, "shell_plugin.result_limit")
        let entries = envelope(invocation, "result")
        entries.add(JsonObjectEntry("ok", jsonBool(ok))); entries.add(JsonObjectEntry("result", value))
        writeGuarded(jsonObject(entries.toArray()), allowed)
    }
}
// Sole reader of the inherited protocol fd. Borrow it without closing or
// creating another owner. ConsoleReader blocks inside native getc while a GC
// mutator remains running; a silent host can then stall every worker at GC.
// Poll only a bounded interval, never pin a Cangjie buffer while waiting, and
// read only after readiness. The one-reader invariant makes that read safe.
class ProtocolInput <: InputStream {
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    private var eof = false
    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.isEmpty()) { return 0 }
        while (true) {
            if (offset < buffered.size) {
                let count = if (buffer.size < buffered.size - offset) { buffer.size } else { buffered.size - offset }
                for (index in 0..count) { buffer[index] = buffered[offset + index] }
                offset += count; return count
            }
            if (eof) { return 0 }
            if (!waitReadableFd(0, 10)) {
                sleep(Duration.millisecond)
                continue
            }
            match (readFdChunk(0, maxBytes: 8192)) {
                case Some(value) => buffered = value; offset = 0
                case None => eof = true; return 0
            }
        }
        0
    }
}

