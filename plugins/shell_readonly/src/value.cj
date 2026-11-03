package shell_readonly_plugin

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

let SR_FRAME_BYTES: Int64 = 262144
let SR_INPUT_BYTES: Int64 = 229376
let SR_COMMAND_BYTES: Int64 = 131072
let SR_CAPTURE_BYTES: Int64 = 131072
let SR_ID_FIELDS = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
    "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

class ReadonlyShellFailure <: Exception {
    let code: String
    init(code: String, message: String) { super(message); this.code = code }
}
func srRequire(condition: Bool, code!: String = "shell_readonly.argument_invalid"): Unit {
    if (!condition) { throw ReadonlyShellFailure(code, "Readonly Shell request is invalid") }
}
func srField(value: JsonNode, name: String): JsonNode { value.field(name) ?? jsonNull() }
func srText(value: JsonNode, name: String): String {
    let found = srField(value, name)
    if (found.unifiedKind == UnifiedJsonKind.Text) { found.text } else { "" }
}
func srInteger(value: JsonNode, name: String): Int64 {
    let found = srField(value, name)
    if (found.unifiedKind != UnifiedJsonKind.Number) { return -1 }
    let parsed = try { Int64.parse(found.asNumberText()) } catch (_: Exception) { -1 }
    if (parsed.toString() == found.asNumberText()) { parsed } else { -1 }
}
func srBool(value: JsonNode, name: String): Bool {
    let found = srField(value, name)
    found.unifiedKind == UnifiedJsonKind.Boolean && found.asBool()
}
func srExact(value: JsonNode, names: Array<String>): Bool {
    if (value.unifiedKind != UnifiedJsonKind.Object || value.fields.size != names.size) { return false }
    let seen = HashSet<String>()
    for (item in value.fields) {
        if (!names.contains(item.name) || seen.contains(item.name)) { return false }; seen.add(item.name) }
    true
}
func srDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    true
}
func srRelative(value: String): Bool {
    if (value == "" || value == ".") { return true }
    if (value.startsWith("/") || value.contains("\\") || value.contains(":") || value.contains("\u{0000}")) { return false }
    for (part in value.split("/") where part == ".." || part == "") { return false }
    true
}
func srEnvironmentName(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 128) { return false }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || byte == b'_' ||
            (index > 0 && byte >= b'0' && byte <= b'9'))) { return false } }
    true
}
func srQuote(value: String): String { "'" + value.replace("'", "'\\''") + "'" }

// Business policy belongs to the independent package. The actual host view,
// denied network and canonical Root remain the enforcement boundary.
func srReadonlyViolation(command: String): Bool {
    for (token in ["rm ", "mv ", "touch ", "mkdir ", "cp ", "ln ", "chmod ", "chown ", "tee ", "dd ",
        "curl ", "wget ", "nc ", "sudo ", "apt ", "yum ", "dnf ", "pacman ", "npm install", "npm i",
        "pip install", "git push", "git commit", "git checkout", "git reset", "git rm", "git clean",
        "cargo build", "cargo test", "cjpm build", "cjpm test", "make ", "kill ", "pkill ", "reboot"] where command.contains(token)) { return true }
    let bytes = command.toArray()
    for (index in 0..bytes.size where bytes[index] == b'>') {
        var cursor = index + 1
        while (cursor < bytes.size && bytes[cursor] == b' ') { cursor++ }
        let tail = String.fromUtf8(bytes[cursor..])
        if (!tail.startsWith("/dev/null") && !tail.startsWith("&1")) { return true }
    }
    false
}
func srTimeout(input: JsonNode): Int64 {
    srRequire(!(input.field("timeout").isSome() && input.field("timeout_ms").isSome()))
    if (input.field("timeout_ms").isSome()) {
        let millis = srInteger(input, "timeout_ms"); srRequire(millis >= 1 && millis <= 600000); return millis }
    if (input.field("timeout").isSome()) {
        let seconds = srInteger(input, "timeout"); srRequire(seconds >= 0 && seconds <= 600)
        return if (seconds == 0) { 600000 } else { seconds * 1000 } }
    30000
}
func srValidate(input: JsonNode): JsonNode {
    srRequire(input.unifiedKind == UnifiedJsonKind.Object && stringifyUnifiedJson(input).size <= SR_INPUT_BYTES)
    let seen = HashSet<String>()
    for (field in input.fields) {
        srRequire(["command", "timeout", "timeout_ms", "cwd", "env", "title"].contains(field.name) && !seen.contains(field.name)); seen.add(field.name) }
    let command = srField(input, "command")
    srRequire(command.unifiedKind == UnifiedJsonKind.Text && command.text.trimAscii() != "" &&
        command.text.size <= SR_COMMAND_BYTES && !command.text.contains("\u{0000}"), code: "shell_readonly.command_invalid")
    srRequire(!srReadonlyViolation(command.text), code: "tool.readonly_rejected")
    let _ = srTimeout(input)
    for (name in ["cwd", "title"] where input.field(name).isSome()) {
        let value = srField(input, name); srRequire(value.unifiedKind == UnifiedJsonKind.Text && value.text.size <= 4096 && !value.text.contains("\u{0000}")) }
    srRequire(srRelative(srText(input, "cwd")), code: "shell_readonly.cwd_invalid")
    if (input.field("env").isSome()) {
        let environment = srField(input, "env"); srRequire(environment.unifiedKind == UnifiedJsonKind.Object && environment.fields.size <= 128)
        let names = HashSet<String>(); var bytes: Int64 = 0
        for (field in environment.fields) {
            srRequire(srEnvironmentName(field.name) && !names.contains(field.name) && field.value.unifiedKind == UnifiedJsonKind.Text && !field.value.text.contains("\u{0000}"))
            names.add(field.name); bytes += field.name.size + field.value.text.size }
        srRequire(bytes <= 65536) }
    input
}
