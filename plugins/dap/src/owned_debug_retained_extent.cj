package dap_plugin

import std.collection.*
import yjson.*
import yjson_support.*

// The original payloadSmallJsonBound deliberately saturates at 65537: it
// distinguishes tiny fallback messages and cannot pay a retained large value.
// This separate opt-in walker performs no stringify or String/byte copy and
// uses the same original 64-depth/65536-node transport limits and Native pool.
class DapOwnedDebugJsonExtent {
    private let maximum: Int64
    private var nodes: Int64 = 0
    init(maximum: Int64) { require(maximum > 0 && maximum <= 16777216); this.maximum = maximum }
    // String's original byte subscript does not allocate a UTF8 copy. Account
    // every JSON escape; non-ASCII/optional HTML/slash escaping is conservative.
    private func quotedUpper(value: String): Int64 {
        var bytes: Int64 = 2
        for (index in 0..value.size) {
            let byte = value[index]
            bytes += if (byte < 32u8 || byte >= 128u8 || byte == b'<' || byte == b'>' || byte == b'&') { 6 }
                else if (byte == b'"' || byte == 92u8 || byte == b'/') { 2 } else { 1 }
        }
        bytes
    }
    func measure(value: JsonNode, depth!: Int64 = 0): (Int64, Int64) {
        nodes++
        require(depth <= 64 && nodes <= 65536, "dap_plugin.payload_nodes")
        var lower: Int64 = 0; var upper: Int64 = 0
        match (value.unifiedKind) {
            case UnifiedJsonKind.Text => lower = value.text.size + 2; upper = quotedUpper(value.text)
            case UnifiedJsonKind.Number => lower = value.asNumberText().size; upper = lower
            case UnifiedJsonKind.Boolean => lower = if (value.asBool()) { 4 } else { 5 }; upper = lower
            case UnifiedJsonKind.Null => lower = 4; upper = 4
            case UnifiedJsonKind.List =>
                lower = 2; upper = 2
                var first = true
                for (item in value.items) {
                    let (a, b) = measure(item, depth: depth + 1)
                    let comma = if (first) { 0 } else { 1 }; first = false
                    lower += a + comma; upper += b + comma
                }
            case UnifiedJsonKind.Object =>
                lower = 2; upper = 2
                var first = true
                for (field in value.fields) {
                    nodes++; require(nodes <= 65536, "dap_plugin.payload_nodes")
                    let (a, b) = measure(field.value, depth: depth + 1)
                    let comma = if (first) { 0 } else { 1 }; first = false
                    lower += field.name.size + a + 3 + comma
                    upper += quotedUpper(field.name) + b + 1 + comma
                }
            case _ => throw PluginFailure("dap_plugin.payload_kind")
        }
        require(lower <= maximum, "dap_plugin.payload_capacity")
        (lower, upper)
    }
    func retainedText(value: String): Int64 {
        nodes++; require(nodes <= 65536, "dap_plugin.payload_nodes")
        quotedUpper(value)
    }
    func decodedPeak(): Int64 { nodes * 512 + 65536 }
}

class DapOwnedDebugRetainedCharge {
    private let wire: Array<PayloadCharge>
    private let decoded: PayloadCharge
    init(wire: Array<PayloadCharge>, decoded: PayloadCharge) { this.wire = wire; this.decoded = decoded }
    func close(): Unit { decoded.close(); for (part in wire) { part.close() } }
}

func dapOwnedDebugRetainedCharge(value: JsonNode, maximum: Int64,
    retainedTexts!: Array<String> = []): DapOwnedDebugRetainedCharge {
    let extent = DapOwnedDebugJsonExtent(maximum)
    let (_, originalUpper) = extent.measure(value)
    var upper = originalUpper
    for (text in retainedTexts) { upper += extent.retainedText(text) }
    // Actual original parsed references, canonical String/backing/copies and
    // complete retained DOM coexist. The original nontransfer acquire charges
    // twice its argument; invert it once to pay this full measured SUM.
    // All real components stay in that SAME original aggregate. Split only
    // at the original per-charge ceiling, never clip the measured extent or
    // fabricate a larger single-charge grant, a fresh pool or extra credit.
    let wire = ArrayList<PayloadCharge>()
    try {
        var remaining = max(1, upper) * 8
        while (remaining > 0) {
            let argument = min(33554432, (remaining + 1) / 2)
            let part = payloadPool.acquire(argument, transfer: false)
            try { wire.add(part) } catch (error: Exception) { part.close(); throw error }
            remaining -= argument * 2
        }
        let parts = wire.toArray()
        let decoded = payloadPool.acquire((extent.decodedPeak() + 1) / 2, transfer: false)
        try { DapOwnedDebugRetainedCharge(parts, decoded) }
            catch (error: Exception) { decoded.close(); throw error }
    } catch (error: Exception) { for (part in wire) { part.close() }; throw error }
}
