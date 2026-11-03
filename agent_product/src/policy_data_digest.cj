package agent_product

import agent_domain.*
import agent_extension_runtime.reserveNativeObservationBuffer
import std.collection.*
import std.convert.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

// Streams exactly canonicalAgentValue's framing and sorted object fields.
// The immutable source is already charged by its query owner. No second
// complete history string/byte array is allocated merely to obtain its hash.
class ProductPolicyDataDigest {
    private let hash = SHA256()
    private func add(a: Int64, b: Int64): Int64 {
        if (a < 0 || b < 0 || b > Int64.Max - a) { throw IllegalStateException("policy source length overflow") }
        a + b
    }
    private func frame(size: Int64): Int64 { add(size, size.toString().size + 1) }
    private func size(value: AgentValue, depth: Int64): Int64 {
        if (depth > 128) { throw IllegalStateException("policy source nesting exceeds codec bound") }
        match (value.unifiedKind) {
            case ValueKind.Null => 4
            case ValueKind.Boolean => if (value.asBool()) { 4 } else { 5 }
            case ValueKind.Number => add(1, frame(value.asNumberText().size))
            case ValueKind.Text => add(1, frame(value.text.size))
            case ValueKind.List =>
                var count: Int64 = 2
                for (child in value.items) { count = add(count, frame(size(child, depth + 1))) }; count
            case ValueKind.Object =>
                var count: Int64 = 2
                for (field in value.fields) { count = add(count, add(frame(field.name.size), frame(size(field.value, depth + 1)))) }; count
        }
    }
    private func text(value: String): Unit {
        let raw = unsafe { value.rawData() }; var offset: Int64 = 0
        while (offset < raw.size) { let end = offset + min(65536, raw.size - offset); hash.write(raw[offset..end]); offset = end }
    }
    private func framedText(value: String): Unit { text(value.size.toString() + ":"); text(value) }
    private func emit(value: AgentValue, depth: Int64): Unit {
        match (value.unifiedKind) {
            case ValueKind.Null => text("null")
            case ValueKind.Boolean => text(if (value.asBool()) { "true" } else { "false" })
            case ValueKind.Number => text("n"); framedText(value.asNumberText())
            case ValueKind.Text => text("s"); framedText(value.text)
            case ValueKind.List =>
                text("[")
                for (child in value.items) { text(size(child, depth + 1).toString() + ":"); emit(child, depth + 1) }
                text("]")
            case ValueKind.Object =>
                text("{")
                let used = Array<Bool>(value.fields.size, repeat: false)
                for (_ in 0..value.fields.size) {
                    var selected: Int64 = -1
                    for (index in 0..value.fields.size where !used[index]) {
                        if (selected < 0 || value.fields[index].name < value.fields[selected].name) { selected = index }
                    }
                    used[selected] = true
                    framedText(value.fields[selected].name)
                    text(size(value.fields[selected].value, depth + 1).toString() + ":")
                    emit(value.fields[selected].value, depth + 1)
                }; text("}")
        }
    }
    // Opt-in streamed canonical framing. Caller owns the complete source,
    // framing metadata and actual hash buffer until finish; old digest is exact.
    func measureData113(value: AgentValue): Int64 { size(value, 0) }
    func emitData113(value: AgentValue): Unit { emit(value, 0) }
    func emitText113(value: String): Unit { text(value) }
    func emitFrameText113(value: String): Unit { framedText(value) }
    func finishData113(): String {
        let output = ArrayList<Byte>(); let hex = "0123456789abcdef".toArray()
        for (byte in hash.finish()) { output.add(hex[Int64(byte) / 16]); output.add(hex[Int64(byte) % 16]) }
        String.fromUtf8(output.toArray())
    }
    func digest(value: AgentValue): String {
        let reservation = reserveNativeObservationBuffer()
        try {
            let _ = size(value, 0)
            emit(value, 0)
            let output = ArrayList<Byte>(); let hex = "0123456789abcdef".toArray()
            for (byte in hash.finish()) { output.add(hex[Int64(byte) / 16]); output.add(hex[Int64(byte) % 16]) }
            String.fromUtf8(output.toArray())
        } finally { reservation.close() }
    }
}
