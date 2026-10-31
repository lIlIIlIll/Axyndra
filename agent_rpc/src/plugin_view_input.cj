package agent_rpc

import agent_domain.*
import yjson.*
import yjson_support.*
import std.convert.*
import std.sync.*

// Private transport DATA, not a request, Source, permission or Operation.
// The actual frontend lends this message owner from its existing bank.
class RpcPluginViewInput {
    private var chunkId: ?String
    let count: Int64
    let byteLength: Int64
    private var nextIndex: Int64 = 0
    private var used: Int64 = 0
    private var buffer: ?Array<Byte> = None
    private var payment: ?LogicalJsonOwnerReservation
    private var decoderPayment: ?LogicalJsonOwnerReservation = None
    private let retireLock = Mutex()
    private var retired = false

    init(id: String, count: Int64, byteLength: Int64, paid: LogicalJsonOwnerReservation) {
        paid.ensureRetainedPeak(65536 + byteLength * 8)
        this.chunkId = Some(String.fromUtf8(id.toArray()))
        this.count = count; this.byteLength = byteLength; this.payment = Some(paid)
        buffer = Some(Array<Byte>(byteLength, repeat: 0))
    }
    func matches(id: String, count: Int64, byteLength: Int64): Bool {
        chunkId.getOrThrow() == id && this.count == count && this.byteLength == byteLength
    }
    func append(index: Int64, data: String): Bool {
        if (index != nextIndex || index >= count) { throw IllegalArgumentException("chunk index is not the next declared index") }
        let source = unsafe { data.rawData() }
        if (source.size == 0 || source.size % 4 != 0) { throw IllegalArgumentException("chunk data is not canonical Base64") }
        let padding: Int64 = if (source[source.size - 1] == b'=') {
            if (source[source.size - 2] == b'=') { 2 } else { 1 }
        } else { 0 }
        let decoded = source.size / 4 * 3 - padding
        if (decoded <= 0 || decoded > byteLength - used) { throw IllegalArgumentException("chunk data exceeds its declared byte length") }
        var offset: Int64 = 0
        let output = buffer.getOrThrow()
        while (offset < source.size) {
            let a = rpcViewBase64Digit(source[offset]); let b = rpcViewBase64Digit(source[offset + 1])
            let c = rpcViewBase64Digit(source[offset + 2]); let d = rpcViewBase64Digit(source[offset + 3])
            let last = offset + 4 == source.size
            if (a < 0 || b < 0 || c == -1 || d == -1 ||
                (!last && (c < 0 || d < 0)) || (c == -2 && (d != -2 || (b & 15) != 0)) ||
                (c >= 0 && d == -2 && (c & 3) != 0)) {
                throw IllegalArgumentException("chunk data is not canonical Base64")
            }
            output[used] = UInt8((a << 2) | (b >> 4)); used++
            if (c >= 0) {
                output[used] = UInt8(((b & 15) << 4) | (c >> 2)); used++
                if (d >= 0) { output[used] = UInt8(((c & 3) << 6) | d); used++ }
            }
            offset += 4
        }
        nextIndex++
        if ((nextIndex == count) != (used == byteLength)) {
            throw IllegalArgumentException("chunk count and declared byte length disagree")
        }
        nextIndex == count
    }
    func decode(): AgentValue {
        if (nextIndex != count || used != byteLength || decoderPayment.isSome()) {
            throw IllegalStateException("View input decoder has no complete unconsumed message")
        }
        let paid = payment.getOrThrow()
        let decoder = paid.deriveRetainedLease()
        decoderPayment = Some(decoder)
        decoder.ensureRetainedPeak(4096)
        // Pay lexical container/string/atom density before constructing a DOM.
        // The same message already pays its byte buffer and UTF-8 overlap.
        paid.ensureRetainedPeak(rpcViewInputDecodePeak(buffer.getOrThrow()))
        let source = String.fromUtf8(buffer.getOrThrow())
        parseUnifiedJson(source, maxBytes: 67108864, maxDepth: 32)
    }
    func paysSameBank(source: LogicalJsonOwnerReservation): Bool {
        payment.getOrThrow().paysSamePrivateBankData180(source)
    }
    private func clearBufferAfterWholeHelper(): Unit {
        buffer = None; chunkId = None
    }
    func retireAfterWholeHelper(): Unit {
        retireLock.lock()
        try {
            if (retired) { return }
            clearBufferAfterWholeHelper()
            match (payment) { case Some(paid) => paid.close(); payment = None; case None => () }
            match (decoderPayment) { case Some(paid) => paid.close(); decoderPayment = None; case None => () }
            retired = true
        } finally { retireLock.unlock() }
    }
}

class RpcPluginViewInputRead {
    var retiring: ?RpcPluginViewInput = None
    let returned = SyncCounter(1)
    private let retireLock = Mutex()
    private var retired = false
    func retireAfterWholeHelper(): Unit {
        retireLock.lock()
        try {
            if (retired) { return }
            let input = retiring; retiring = None
            match (input) { case Some(actual) => actual.retireAfterWholeHelper(); case None => () }
            retired = true
            // Both ordinary and chunked requests wait for the actual complete
            // decode/dispatch producer, including its private capture helper.
            returned.dec()
        } finally { retireLock.unlock() }
    }
}

func rpcViewBase64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { Int64(value - b'A') }
    else if (value >= b'a' && value <= b'z') { Int64(value - b'a') + 26 }
    else if (value >= b'0' && value <= b'9') { Int64(value - b'0') + 52 }
    else if (value == b'+') { 62 }
    else if (value == b'/') { 63 }
    else if (value == b'=') { -2 }
    else { -1 }
}

func rpcViewChunkInteger(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("chunk metadata requires integers") }
    Int64.parse(field.asNumberText())
}

func rpcViewInputDecodePeak(bytes: Array<Byte>): Int64 {
    var total: Int64 = 65536 + bytes.size * 8
    var quoted = false; var escaped = false; var atom = false
    for (byte in bytes) {
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') {
            quoted = true; atom = false; total = rpcViewInvoiceAdd(total, 1024)
        } else if (byte == b'[' || byte == b'{') {
            atom = false; total = rpcViewInvoiceAdd(total, 1024)
        } else if (byte == b',' || byte == b':' || byte == b']' || byte == b'}') {
            atom = false
        } else if (byte != b' ' && byte != b'\t' && byte != b'\r' && byte != b'\n' && !atom) {
            atom = true; total = rpcViewInvoiceAdd(total, 1024)
        }
    }
    total
}
