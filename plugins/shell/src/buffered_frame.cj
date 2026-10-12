package shell_plugin

import std.collection.*
import std.io.*
import yjson.*
import yjson_support.*

// One reader per stream. Retain only one bounded frame and one 8 KiB block;
// carry bytes after a newline into the next call without another channel read.
// Limits, strict UTF-8 decoding, JSON depth and incomplete-EOF rules are unchanged.
class ShellFrameReader {
    private let stream: InputStream
    private let buffer = Array<Byte>(8192, repeat: 0)
    private var offset: Int64 = 0
    private var count: Int64 = 0
    init(stream: InputStream) { this.stream = stream }

    func readFrame(): ?JsonNode {
        let result = ArrayList<Byte>()
        while (true) {
            if (offset == count) {
                count = stream.read(buffer); offset = 0
                require(count >= 0 && count <= buffer.size, "shell_plugin.frame_read_invalid")
                if (count == 0) {
                    require(result.isEmpty(), "shell_plugin.incomplete_frame")
                    return None
                }
            }
            let start = offset
            while (offset < count && buffer[offset] != 10u8) { offset += 1 }
            require(offset - start <= FRAME_LIMIT - result.size, "shell_plugin.frame_limit")
            result.add(all: buffer[start..offset])
            if (offset < count) {
                offset += 1
                return Some(parseUnifiedJson(String.fromUtf8(result.toArray()), maxBytes: FRAME_LIMIT, maxDepth: 32))
            }
        }
        None
    }
}

// Canonical RFC 4648 only: no whitespace, alternate alphabet, nonzero pad bits,
// interior padding or oversized allocation. The default remains 8 KiB; the
// artifact session explicitly selects the Host's existing 16 KiB append bound.
func shellArtifactBase64(value: String, maxBytes!: Int64 = 8192): String {
    String.fromUtf8(shellCanonicalBase64(value, maxBytes, false))
}

func shellChannelBase64(value: String): Array<Byte> {
    shellCanonicalBase64(value, 32768, true)
}

// Binary channel decode deliberately does not call String.fromUtf8. Empty
// data is valid for a quiet poll/EOF; artifacts retain their nonempty contract.
func shellCanonicalBase64(value: String, maxBytes: Int64, allowEmpty: Bool): Array<Byte> {
    require(maxBytes >= 1 && maxBytes <= (if (allowEmpty) { 32768 } else { 16384 }), "shell_plugin.output_encoding")
    if (value == "") { require(allowEmpty, "shell_plugin.output_encoding"); return [] }
    require(value.size > 0 && value.size % 4 == 0 && value.size <= ((maxBytes + 2) / 3) * 4,
        "shell_plugin.output_encoding")
    let source = value.toArray()
    let padding: Int64 = if (source[source.size - 2] == b'=') { 2 }
        else if (source[source.size - 1] == b'=') { 1 } else { 0 }
    let size = source.size / 4 * 3 - padding
    require(size > 0 && size <= maxBytes, "shell_plugin.output_encoding")
    let result = Array<Byte>(size, repeat: 0)
    func digit(value: Byte): Int64 {
        if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
        if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
        if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
        if (value == b'+') { return 62 }
        if (value == b'/') { return 63 }
        throw PluginFailure("shell_plugin.output_encoding")
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
                "shell_plugin.output_encoding")
        } else if (last && padding == 1) {
            require(source[input + 3] == b'=' && c % 4 == 0, "shell_plugin.output_encoding")
        }
        result[output] = UInt8(a * 4 + b / 16); output += 1
        if (output < size) { result[output] = UInt8(b % 16 * 16 + c / 4); output += 1 }
        if (output < size) { result[output] = UInt8(c % 4 * 64 + d); output += 1 }
        input += 4
    }
    result
}
