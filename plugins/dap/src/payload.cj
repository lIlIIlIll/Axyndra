package dap_plugin

import std.collection.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// A transport resource profile, selected only by the host's pinned handshake.
// It is never a grant to write bytes or select an artifact in the host store.
class PayloadLimits {
    let message: Int64; let input: Int64; let prepared: Int64; let result: Int64; let write: Int64
    init(value: JsonNode) {
        exact(value, ["version", "max_message_bytes", "max_input_bytes", "max_prepare_bytes", "max_result_bytes", "max_write_bytes"])
        message = number(value, "max_message_bytes"); input = number(value, "max_input_bytes")
        prepared = number(value, "max_prepare_bytes"); result = number(value, "max_result_bytes"); write = number(value, "max_write_bytes")
        require(number(value, "version") == 1 && message >= 1048576 && message <= 16777216 &&
            input > 0 && input <= 4194304 && prepared > 0 && prepared <= 8388608 &&
            result > 0 && result <= 8388608 && write > 0 && write <= 4194304 &&
            input + 262144 <= message && prepared + 262144 <= message && result + 262144 <= message &&
            write * 2 + 65536 <= prepared, "dap_plugin.payload_profile_invalid")
        for (entry in value.fields) {
            require(entry.value.unifiedKind == UnifiedJsonKind.Number &&
                number(value, entry.name).toString() == entry.value.asNumberText(), "dap_plugin.payload_profile_invalid")
        }
    }
}

// The endpoint's aggregate pool includes in-flight logical messages and
// retained prepared calls. A cancelled or failed transfer releases its charge
// through the same finally path as a successful invocation.
let payloadPool = PayloadPool()
class PayloadPool {
    private let lock = Mutex()
    private var charged: Int64 = 0
    private var transfers: Int64 = 0
    func acquire(bytes: Int64, transfer!: Bool = true): PayloadCharge {
        require(bytes > 0 && bytes <= 33554432, "dap_plugin.payload_capacity")
        let cost = if (transfer) { max(16777216, bytes * 8) } else { bytes * 2 }
        lock.lock()
        try {
            require((!transfer || transfers < 2) && cost <= 134217728 - charged, "dap_plugin.payload_capacity")
            charged += cost
            if (transfer) { transfers += 1 }
            PayloadCharge(this, cost, transfer)
        } finally { lock.unlock() }
    }
    func release(cost: Int64, transfer: Bool): Unit {
        lock.lock()
        try { charged -= cost; if (transfer) { transfers -= 1 } } finally { lock.unlock() }
    }
}
class PayloadCharge {
    private let pool: PayloadPool
    private let cost: Int64
    private let transfer: Bool
    private let lock = Mutex()
    private var closed = false
    init(pool: PayloadPool, cost: Int64, transfer: Bool) { this.pool = pool; this.cost = cost; this.transfer = transfer }
    func close(): Unit {
        lock.lock()
        let release = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (release) { pool.release(cost, transfer) }
    }
}

class PayloadJsonTokenCounter {
    private var quoted = false
    private var escaped = false
    var nodes: Int64 = 0
    func accept(byte: Byte): Unit {
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == b'\\') { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') { quoted = true; nodes += 1 }
        else if (byte == b'{' || byte == b'[' || byte == b',' || byte == b':') { nodes += 1 }
        require(nodes <= 65536, "dap_plugin.payload_nodes")
    }
}
func payloadNodeBound(source: String): Unit { let _ = payloadNodeCount(source) }
func payloadNodeCount(source: String): Int64 {
    let counter = PayloadJsonTokenCounter()
    for (byte in source.toArray()) { counter.accept(byte) }
    counter.nodes
}
func payloadFrameNodeCount(source: ArrayList<Byte>): Int64 {
    let counter = PayloadJsonTokenCounter()
    for (byte in source) { counter.accept(byte) }
    counter.nodes
}
func payloadDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray() where !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    true
}
func payloadEnvelope(invocation: JsonNode, kind: String, window: String, values: Array<JsonObjectEntry>): JsonNode {
    let header = ArrayList<JsonObjectEntry>([JsonObjectEntry("schema", jsonString("axyndra.logical-json/v1")),
        JsonObjectEntry("window", jsonString(window)), JsonObjectEntry("transfer_sequence", jsonNumber("1"))])
    header.add(all: values)
    let entries = envelope(invocation, kind); entries.add(JsonObjectEntry("payload", jsonObject(header.toArray())))
    jsonObject(entries.toArray())
}

// Sole stdin reader owns this assembler. No callback can replace its fixed
// identity or extend the deadline. The reservation is transferred to the
// actual invocation worker and held until its JSON consumers have returned.
class PayloadReceiver {
    private let limits: ProtocolLimits
    let invocation: JsonNode
    let window: String
    let deadline: MonoTime
    private let maximum: Int64
    private let digest: String
    private let charge: PayloadCharge
    private var bytes: Array<Byte>
    private var offset: Int64 = 0
    private var complete = false
    init(begin: JsonNode, limits: ProtocolLimits) {
        this.limits = limits
        require(limits.payload.isSome(), "dap_plugin.payload_unsupported")
        payloadOuter(begin)
        let header = field(begin, "payload")
        exact(header, ["schema", "window", "transfer_sequence", "message_type", "bytes", "sha256"])
        require(text(begin, "type") == "payload_begin" && text(header, "schema") == "axyndra.logical-json/v1" &&
            number(header, "transfer_sequence") == 1 && field(header, "transfer_sequence").asNumberText() == "1" &&
            text(header, "message_type") == "invoke", "dap_plugin.payload_begin_invalid")
        window = text(header, "window")
        require(window != "" && window.size <= 256 && !window.contains("\u{0000}"), "dap_plugin.payload_window_invalid")
        maximum = limits.payload.getOrThrow().message
        let length = number(header, "bytes")
        digest = text(header, "sha256")
        require(length > 0 && length <= maximum && length.toString() == field(header, "bytes").asNumberText() &&
            payloadDigest(digest), "dap_plugin.payload_begin_invalid")
        // Validate ordinary source identity before reserving/allocating a body.
        let probe = envelope(begin, "invoke"); probe.add(JsonObjectEntry("arguments", jsonObject([])))
        validateInvocation(jsonObject(probe.toArray()), limits: limits)
        invocation = begin
        deadline = MonoTime.now() + Duration.millisecond * limits.timeout
        charge = payloadPool.acquire(length)
        try { bytes = Array<Byte>(length, repeat: 0) } catch (error: Exception) { charge.close(); throw error }
    }
    func accept(frame: JsonNode): ?JsonNode {
        require(!complete && MonoTime.now() < deadline && sameIdentity(frame, invocation), "dap_plugin.payload_identity_invalid")
        payloadOuter(frame)
        let header = field(frame, "payload")
        require(text(header, "schema") == "axyndra.logical-json/v1" && text(header, "window") == window &&
            number(header, "transfer_sequence") == 1 && field(header, "transfer_sequence").asNumberText() == "1", "dap_plugin.payload_window_invalid")
        if (text(frame, "type") == "payload_chunk") {
            exact(header, ["schema", "window", "transfer_sequence", "offset", "bytes_hex"])
            require(number(header, "offset") == offset && field(header, "offset").asNumberText() == offset.toString(), "dap_plugin.payload_offset")
            let chunk = unhex(text(header, "bytes_hex"), 16384)
            require(chunk.size > 0 && chunk.size <= bytes.size - offset, "dap_plugin.payload_chunk_limit")
            for (index in 0..chunk.size) { bytes[offset + index] = chunk[index] }
            offset += chunk.size; return None
        }
        exact(header, ["schema", "window", "transfer_sequence"])
        require(text(frame, "type") == "payload_end" && offset == bytes.size, "dap_plugin.payload_incomplete")
        let source = String.fromUtf8(bytes)
        require(sha(source) == digest, "dap_plugin.payload_digest")
        payloadNodeBound(source)
        let result = parseUnifiedJson(source, maxBytes: maximum, maxDepth: 32)
        require(text(result, "type") == "invoke" && text(result, "payload_window") == window &&
            sameIdentity(result, invocation), "dap_plugin.payload_identity_invalid")
        validateInvocation(result, limits: limits)
        require(MonoTime.now() < deadline, "dap_plugin.payload_expired")
        complete = true; bytes = []
        Some(result)
    }
    func close(): Unit { bytes = []; charge.close() }
}
func payloadOuter(value: JsonNode): Unit {
    let names = ArrayList<String>(["type"]); names.add(all: IDENTITY_FIELDS); names.add("payload")
    exact(value, names.toArray())
}

// Upper bound sufficient to distinguish genuinely small errors/results from
// expanded JSON without allocating text or walking unbounded scalar content.
func payloadSmallJsonBound(value: JsonNode, remaining: Int64, depth!: Int64 = 0): Int64 {
    if (depth > 32 || remaining < 1) { return 65537 }
    if (value.unifiedKind == UnifiedJsonKind.Text) { return min(65537, value.text.size * 6 + 2) }
    if (value.unifiedKind == UnifiedJsonKind.Number) { return min(65537, value.asNumberText().size) }
    if (value.unifiedKind == UnifiedJsonKind.Boolean || value.unifiedKind == UnifiedJsonKind.Null) { return 5 }
    var total: Int64 = 2
    if (value.unifiedKind == UnifiedJsonKind.Object) {
        for (entry in value.fields) {
            total += entry.name.size * 6 + 4
            if (total > remaining) { return 65537 }
            total += payloadSmallJsonBound(entry.value, remaining - total, depth: depth + 1)
            if (total > remaining) { return 65537 }
        }
    } else if (value.unifiedKind == UnifiedJsonKind.List) {
        for (item in value.items) {
            total += 1 + payloadSmallJsonBound(item, remaining - total, depth: depth + 1)
            if (total > remaining) { return 65537 }
        }
    }
    total
}

// StdIO is newline-framed JSON. Check tokens before mcp4cj allocates a
// decoded response, including ordinary (unfragmented) service responses.
class PayloadJsonLineGuard {
    private var quoted = false
    private var escaped = false
    private var nodes: Int64 = 0
    func accept(bytes: Array<Byte>): Unit {
        for (byte in bytes) {
            if (byte == 10u8) { quoted = false; escaped = false; nodes = 0; continue }
            if (quoted) {
                if (escaped) { escaped = false }
                else if (byte == b'\\') { escaped = true }
                else if (byte == b'"') { quoted = false }
            } else if (byte == b'"') { quoted = true; nodes += 1 }
            else if (byte == b'{' || byte == b'[' || byte == b',' || byte == b':') { nodes += 1 }
            require(nodes <= 65536, "dap_plugin.payload_nodes")
        }
    }
}
