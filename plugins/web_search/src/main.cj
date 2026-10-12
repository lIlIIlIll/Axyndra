package web_search_plugin

import std.collection.*
import std.env.*
import std.io.*
import yjson.*
import yjson_support.*

let WEB_FRAME_BYTES: Int64 = 262144
let WEB_INPUT_BYTES: Int64 = 16384
let WEB_RESULT_BYTES: Int64 = 65536

func webReadFrame(stream: InputStream): ?String {
    let output = ArrayList<Byte>()
    let byte = Array<Byte>(1, repeat: 0)
    while (true) {
        let count = stream.read(byte)
        if (count == 0) {
            if (output.isEmpty()) { return None }
            throw SearchFailure("web_search.frame_invalid", "stream ended inside a frame")
        }
        if (byte[0] == b'\n') { return Some(String.fromUtf8(output.toArray()).removeSuffix("\r")) }
        if (output.size >= WEB_FRAME_BYTES) { throw SearchFailure("web_search.frame_limit", "frame exceeds its byte limit") }
        output.add(byte[0])
    }
    None
}

func webWriteFrame(value: JsonNode): Unit {
    let encoded = stringifyUnifiedJson(value)
    if (encoded.size > WEB_FRAME_BYTES) { throw SearchFailure("web_search.frame_limit", "reply exceeds its frame limit") }
    let output = getStdOut()
    output.write((encoded + "\n").toArray())
    output.flush()
}

main(): Int64 {
    if (getCommandLine().size != 1) { return 2 }
    try { runWebProtocol() } catch (_: Exception) {
        // Protocol diagnostics never echo raw request or HTTP response bytes.
        getStdErr().write("web search plugin rejected an invalid protocol stream\n".toArray())
        3
    }
}
