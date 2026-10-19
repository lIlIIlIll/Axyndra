package logical_json_payload

import std.collection.*
import std.convert.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// One canonical JSON tree and the original pure protocol functions. These
// are data/framing helpers; none admits an Operation, Source, I/O or callback.
public type AgentValue = JsonNode
public type ValueKind = UnifiedJsonKind
public type ValueField = JsonObjectEntry

public func nullValue(): AgentValue {
    jsonNull()
}

public func boolValue(value: Bool): AgentValue {
    jsonBool(value)
}

public func integerValue(value: Int64): AgentValue {
    numberValue(value.toString())
}

public func numberValue(value: String): AgentValue {
    if (value.trimAscii() == "") {
        throw IllegalArgumentException("number value must not be empty")
    }
    jsonNumber(value)
}

public func textValue(value: String): AgentValue {
    jsonString(value)
}

public func listValue(values: Array<AgentValue>): AgentValue {
    jsonArray(values)
}

public func objectValue(fields: Array<ValueField>): AgentValue {
    jsonObject(fields)
}

public func modelPolicySha256(bytes: Array<Byte>): String {
    // The same SHA-256 identity for every caller, using the pinned SDK's
    // standard digest primitive already used by the shared artifact owner.
    // Hash all bytes; no cache, truncation, weaker digest or skipped witness.
    let digest = SHA256()
    digest.write(bytes)
    let value = digest.finish()
    let hex = "0123456789abcdef".toArray()
    let result = Array<Byte>(64, repeat: 0)
    for (index in 0..value.size) {
        result[index * 2] = hex[Int64(value[index]) / 16]
        result[index * 2 + 1] = hex[Int64(value[index]) % 16]
    }
    String.fromUtf8(result)
}

public func canonicalAgentValue(value: AgentValue): String {
    match (value.unifiedKind) {
        case ValueKind.Null => "null"
        case ValueKind.Boolean => if (value.asBool()) { "true" } else { "false" }
        case ValueKind.Number => "n" + agentValueFrame(value.asNumberText())
        case ValueKind.Text => "s" + agentValueFrame(value.text)
        case ValueKind.List =>
            var output = "["
            for (item in value.items) { output += agentValueFrame(canonicalAgentValue(item)) }
            output + "]"
        case ValueKind.Object =>
            var output = "{"
            let used = Array<Bool>(value.fields.size, repeat: false)
            for (_ in 0..value.fields.size) {
                var selected: Int64 = -1
                for (index in 0..value.fields.size where !used[index]) {
                    if (selected < 0 || value.fields[index].name < value.fields[selected].name) {
                        selected = index
                    }
                }
                used[selected] = true
                output += agentValueFrame(value.fields[selected].name) +
                    agentValueFrame(canonicalAgentValue(value.fields[selected].value))
            }
            output + "}"
    }
}

func agentValueFrame(value: String): String {
    value.size.toString() + ":" + value
}

public func modelPolicySha256Text(value: String): String {
    modelPolicySha256(value.toArray())
}

public func httpIntentExactFields(value: AgentValue, names: Array<String>): Bool {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) { return false }
    let seen = ArrayList<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || seen.contains(field.name)) { return false }
        seen.add(field.name)
    }
    true
}

public func httpIntentText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

public func httpIntentDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) || (byte >= 97u8 && byte <= 102u8))) { return false }
    true
}

public func httpIntentIdentifier(value: String): Bool {
    if (value == "" || value.size > 64) { return false }
    for (byte in value.toArray() where !((byte >= 48u8 && byte <= 57u8) ||
        (byte >= 65u8 && byte <= 90u8) || (byte >= 97u8 && byte <= 122u8) ||
        byte == 45u8 || byte == 95u8 || byte == 46u8)) { return false }
    true
}

public func readonlyDelegationInteger(value: AgentValue, field: String): Int64 {
    let item = match (value.field(field)) { case Some(found) => found; case None => return -1 }
    if (item.unifiedKind != ValueKind.Number) { return -1 }
    try { Int64.parse(item.asNumberText()) } catch (_: Exception) { -1 }
}

public func channelIntentIdentifier(value: String): Bool {
    if (value.size < 1 || value.size > 512) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b'_' || byte == b':' || byte == b'-')) { return false }
    }
    true
}

