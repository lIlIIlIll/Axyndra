package lsp_plugin

import yjson.*
import yjson_support.*

// Representation only. The caller explicitly selects the controlled Host API.
// Hex remains the default codec, with its original exact shape and 16 KiB bound.
// Base64 cannot fall back to hex and is decoded as binary before LSP framing.
func lspChannelReadBytes(value: JsonNode, encoding!: String = "hex"): Array<Byte> {
    require(encoding == "hex" || encoding == "base64", "lsp_plugin.channel_response_invalid")
    let name = if (encoding == "base64") { "bytes_base64" } else { "bytes_hex" }
    exact(value, [name, "eof"])
    require(field(value, name).unifiedKind == UnifiedJsonKind.Text &&
        field(value, "eof").unifiedKind == UnifiedJsonKind.Boolean, "lsp_plugin.channel_response_invalid")
    if (encoding == "base64") { lspCanonicalBase64(text(value, name), 32768, true) }
    else { unhex(text(value, name), 16384) }
}

// Exact independent copy of the existing Shell canonical RFC 4648 algorithm;
// no Shell import, process API, workspace business, Source or grant is shared.
func lspCanonicalBase64(value: String, maxBytes: Int64, allowEmpty: Bool): Array<Byte> {
    require(maxBytes >= 1 && maxBytes <= (if (allowEmpty) { 32768 } else { 16384 }), "lsp_plugin.channel_response_invalid")
    if (value == "") { require(allowEmpty, "lsp_plugin.channel_response_invalid"); return [] }
    require(value.size > 0 && value.size % 4 == 0 && value.size <= ((maxBytes + 2) / 3) * 4,
        "lsp_plugin.channel_response_invalid")
    let source = value.toArray()
    let padding: Int64 = if (source[source.size - 2] == b'=') { 2 }
        else if (source[source.size - 1] == b'=') { 1 } else { 0 }
    let size = source.size / 4 * 3 - padding
    require(size > 0 && size <= maxBytes, "lsp_plugin.channel_response_invalid")
    let result = Array<Byte>(size, repeat: 0)
    func digit(value: Byte): Int64 {
        if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
        if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
        if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
        if (value == b'+') { return 62 }
        if (value == b'/') { return 63 }
        throw PluginFailure("lsp_plugin.channel_response_invalid")
    }
    var input: Int64 = 0
    var output: Int64 = 0
    while (input < source.size) {
        let last = input + 4 == source.size
        let a = digit(source[input]); let b = digit(source[input + 1])
        let c = if (last && padding == 2) { 0 } else { digit(source[input + 2]) }
        let d = if (last && padding > 0) { 0 } else { digit(source[input + 3]) }
        if (last && padding == 2) {
            require(source[input + 2] == b'=' && source[input + 3] == b'=' && b % 16 == 0,
                "lsp_plugin.channel_response_invalid")
        } else if (last && padding == 1) {
            require(source[input + 3] == b'=' && c % 4 == 0, "lsp_plugin.channel_response_invalid")
        }
        result[output] = UInt8(a * 4 + b / 16); output += 1
        if (output < size) { result[output] = UInt8(b % 16 * 16 + c / 4); output += 1 }
        if (output < size) { result[output] = UInt8(c % 4 * 64 + d); output += 1 }
        input += 4
    }
    result
}
