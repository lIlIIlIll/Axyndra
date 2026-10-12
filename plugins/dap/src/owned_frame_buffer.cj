package dap_plugin

import process4cj.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Finite Native parsing between actual Host read operations. This parser owns
// no fd and cannot poll, launch or write a process. Header interpretation is
// the original process4cj Content-Length interpretation (last matching header,
// ASCII-trimmed decimal length, ignored unrelated headers, full UTF8/EOF).
class DapOwnedFrameBuffer {
    private let maximum: Int64
    private let header = ArrayList<Byte>()
    private var body = ArrayList<Byte>()
    private let headerStorage = payloadPool.acquire(65536, transfer: false)
    private var length: Int64 = -1
    private var reservation: ?ProtocolFrameReservation = None
    private var closed = false
    init(maximum: Int64) { require(maximum > 0); this.maximum = maximum }

    // A true return transfers this actual paid frame to the response consumer.
    // Events that copy only their bounded cache are consumed within this call.
    func append(bytes: Array<Byte>, consume: (JsonNode, OwnedProtocolFrame) -> Bool): Unit {
        require(!closed && bytes.size <= 16384, "dap_plugin.backend_chunk_limit")
        for (byte in bytes) {
            if (length < 0) {
                require(header.size < 65536, "dap.frame_invalid")
                header.add(byte)
                if (byte == 10u8) {
                    let count = header.size
                    let empty = count == 1 || (count == 2 && header[0] == 13u8) || count >= 2 && (header[count - 2] == 10u8 ||
                        (count >= 4 && header[count - 2] == 13u8 && header[count - 3] == 10u8))
                    if (empty) { beginBody() }
                }
            } else { body.add(byte) }
            if (length >= 0 && body.size == length) { finishBody(consume) }
        }
    }
    private func beginBody(): Unit {
        let source = String.fromUtf8(header.toArray())
        var found: Int64 = -1
        var accounted: Int64 = 0
        let lines = source.split("\n")
        for (index in 0..lines.size - 1) {
            let raw = lines[index]
            let line = if (raw.endsWith("\r")) { raw[..raw.size - 1] } else { raw }
            accounted += line.size + 2
            require(accounted <= 65536, "dap.frame_invalid")
            match (line.indexOf(":")) {
                case Some(index) =>
                    if (line[..index].trimAscii().toAsciiLower() == "content-length") {
                        found = try { Int64.parse(line[index + 1..].trimAscii()) }
                            catch (_: Exception) { throw PluginFailure("dap.frame_invalid") }
                    }
                case None => ()
            }
        }
        require(found >= 0 && found <= maximum, "dap.frame_invalid")
        // Pay the actual complete raw frame before any body byte is retained.
        reservation = Some(DapResponseBudget(maximum).reserve(found))
        length = found; header.clear()
    }
    private func finishBody(consume: (JsonNode, OwnedProtocolFrame) -> Bool): Unit {
        let frame = OwnedProtocolFrame(body.toArray(), reservation)
        reservation = None; body = ArrayList<Byte>(); length = -1
        var transferred = false
        try {
            frame.beforeDecode()
            let value = parseUnifiedJson(String.fromUtf8(frame.bytes), maxBytes: maximum, maxDepth: 64)
            require(value.unifiedKind == UnifiedJsonKind.Object && value.field("seq").isSome() &&
                value.field("type").isSome(), "dap.envelope_invalid")
            transferred = consume(value, frame)
        } finally { if (!transferred) { frame.close() } }
    }
    func eof(): Unit {
        require(header.isEmpty() && body.isEmpty() && length < 0, "dap.transport_closed")
    }
    func close(): Unit {
        if (closed) { return }; closed = true
        header.clear(); body = ArrayList<Byte>()
        match (reservation) { case Some(value) => value.close(); case None => () }
        reservation = None; headerStorage.close()
    }
}
