package agent_host_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Content-only wire representation. Decoded bytes still obey the original
// 16 KiB append limit and strict UTF-8 contract. The current invocation and
// every authority check remain in ProductServiceArtifactSession.handle.
func hostServiceArtifactEncodingRequire(condition: Bool, code: String): Unit {
    if (!condition) { throw IllegalArgumentException(code) }
}
public func hostServiceArtifactAppendText(args: AgentValue): String {
    let encoded = args.field("data_base64")
    let name = if (encoded.isSome()) { "data_base64" } else { "text" }
    hostServiceArtifactEncodingRequire(httpIntentExactFields(args, ["action", "stream", "offset", name]),
        "artifact.stream_encoding")
    let value = args.field(name).getOrThrow()
    hostServiceArtifactEncodingRequire(value.unifiedKind == ValueKind.Text, "artifact.stream_encoding")
    let content = if (encoded.isSome()) { hostServiceArtifactBase64(value.text) } else { value.text }
    hostServiceArtifactEncodingRequire(content.size > 0 && content.size <= 16384, "artifact.stream_encoding")
    content
}

// RFC 4648 canonical alphabet/padding/pad bits, validated before allocation.
public func hostServiceArtifactBase64(value: String): String {
    hostServiceArtifactEncodingRequire(value.size > 0 && value.size % 4 == 0 && value.size <= 21848,
        "artifact.stream_encoding")
    let source = value.toArray()
    let padding: Int64 = if (source[source.size - 2] == b'=') { 2 }
        else if (source[source.size - 1] == b'=') { 1 } else { 0 }
    let size = source.size / 4 * 3 - padding
    hostServiceArtifactEncodingRequire(size > 0 && size <= 16384, "artifact.stream_encoding")
    let result = Array<Byte>(size, repeat: 0)
    func digit(value: Byte): Int64 {
        if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
        if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
        if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
        if (value == b'+') { return 62 }
        if (value == b'/') { return 63 }
        throw IllegalArgumentException("artifact.stream_encoding")
    }
    var input: Int64 = 0
    var output: Int64 = 0
    while (input < source.size) {
        let last = input + 4 == source.size
        let a = digit(source[input]); let b = digit(source[input + 1])
        let c = if (last && padding == 2) { 0 } else { digit(source[input + 2]) }
        let d = if (last && padding > 0) { 0 } else { digit(source[input + 3]) }
        if (last && padding == 2) {
            hostServiceArtifactEncodingRequire(source[input + 2] == b'=' && source[input + 3] == b'=' && b % 16 == 0,
                "artifact.stream_encoding")
        } else if (last && padding == 1) {
            hostServiceArtifactEncodingRequire(source[input + 3] == b'=' && c % 4 == 0, "artifact.stream_encoding")
        }
        result[output] = UInt8(a * 4 + b / 16); output += 1
        if (output < size) { result[output] = UInt8(b % 16 * 16 + c / 4); output += 1 }
        if (output < size) { result[output] = UInt8(c % 4 * 64 + d); output += 1 }
        input += 4
    }
    String.fromUtf8(result)
}
