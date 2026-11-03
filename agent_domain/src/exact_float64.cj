package agent_domain

import std.convert.*
import std.io.*
import yjson.*
import yjson_support.*

// Data codec only. JSON numbers cannot represent infinities or NaNs and a
// decimal formatter need not preserve every binary64 bit. No arithmetic,
// ordering, resource reference or authority is supplied by this envelope.
public func exactFloat64Value(value: Float64): AgentValue {
    let alphabet = "0123456789abcdef"; let digits = unsafe { alphabet.rawData() }
    let result = Array<Byte>(16, repeat: b'0'); var bits = value.toBits()
    for (offset in 0..16) {
        result[15 - offset] = digits[Int64(bits & 15)]; bits = bits >> 4
    }
    objectValue([ValueField("binary64", textValue(String.fromUtf8(result)))])
}

public func decodeExactFloat64(value: AgentValue): Float64 {
    // Existing finite JSON facts remain valid. New producers use exact bits.
    if (value.unifiedKind == ValueKind.Number) { return Float64.parse(value.asNumberText()) }
    if (value.unifiedKind != ValueKind.Object || value.fields.size != 1 || value.field("binary64").isNone()) {
        throw IllegalArgumentException("invalid binary64 data envelope")
    }
    let text = value.field("binary64").getOrThrow()
    if (text.unifiedKind != ValueKind.Text || text.text.size != 16) {
        throw IllegalArgumentException("invalid binary64 data length")
    }
    let bytes = unsafe { text.text.rawData() }; var bits: UInt64 = 0
    for (byte in bytes) {
        let digit = if (byte >= b'0' && byte <= b'9') { byte - b'0' }
            else if (byte >= b'a' && byte <= b'f') { byte - b'a' + 10 }
            else { throw IllegalArgumentException("invalid binary64 data digit") }
        bits = (bits << 4) | UInt64(digit)
    }
    Float64.fromBits(bits)
}
