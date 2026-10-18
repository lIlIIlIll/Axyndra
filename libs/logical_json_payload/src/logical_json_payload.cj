package logical_json_payload

import std.collection.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// Pure bounded framing/allocation primitives. The caller owns identity,
// deadline, cancellation and any I/O. A reservation is never source authority.
public let LOGICAL_JSON_PAYLOAD_SCHEMA = "axyndra.logical-json/v1"
public let LOGICAL_JSON_CHUNK_BYTES: Int64 = 16384
public let LOGICAL_JSON_HARD_BYTES: Int64 = 67108864

public class LogicalJsonPayloadError <: Exception {
    public init(message: String) { super(message) }
}

public class LogicalJsonOwnerBudget {
    private let lock = Mutex()
    private let maximumCharged: Int64
    private let maximumMessage: Int64
    private let maximumTransfers: Int64
    private var charged: Int64 = 0
    private var count: Int64 = 0
    private var fixedBufferCount: Int64 = 0
    // Every consumer owns its capacity requirement explicitly: a process-wide
    // pool that must admit its declared 32 concurrent transfers raises
    // maximumCharged itself (see nativePayloadOwnerBudget). The default stays
    // conservative so that a pool which does not state a need also keeps the
    // documented saturation behaviour its callers assert.
    public init(maximumCharged!: Int64 = 134217728,
        maximumMessage!: Int64 = 16777216, maximumTransfers!: Int64 = 32) {
        if (maximumCharged < 16777216 || maximumCharged > 1073741824 ||
            maximumMessage < 1 || maximumMessage > LOGICAL_JSON_HARD_BYTES ||
            maximumTransfers < 1 || maximumTransfers > 32) {
            throw LogicalJsonPayloadError("logical payload pool configuration is invalid")
        }
        this.maximumCharged = maximumCharged; this.maximumMessage = maximumMessage
        this.maximumTransfers = maximumTransfers
    }
    func requireDataPhaseMessageExtent328(bytes:Int64):Unit{
        if(bytes<1 || bytes>maximumMessage){throw LogicalJsonPayloadError("logical payload exceeds its message bound")}
    }
    public func acquire(bytes: Int64): LogicalJsonOwnerReservation {
        if (bytes < 1 || bytes > maximumMessage) { throw LogicalJsonPayloadError("logical payload exceeds its message bound") }
        let cost = max(16777216, bytes * 8)
        lock.lock()
        try {
            if (count >= maximumTransfers || cost > maximumCharged - charged) {
                throw LogicalJsonPayloadError("logical payload aggregate capacity is exhausted")
            }
            count += 1; charged += cost
            LogicalJsonOwnerReservation(this, cost, bytes * 8)
        } finally { lock.unlock() }
    }
    // Fixed host-side transport storage has no decoded JSON copies. Its exact
    // capacity shares the same aggregate allocation bound, but cannot be used
    // as a logical message reservation or grown from a worker declaration.
    // Their 1 KiB minimum bounds the reservation count through the same
    // aggregate bytes. Idle hosts do not consume logical-message concurrency
    // or create a smaller host-count ceiling than the existing worker owner.
    public func acquireFixedBuffer(bytes: Int64): LogicalJsonFixedBufferReservation {
        if (bytes < 1024 || bytes > 65536) { throw LogicalJsonPayloadError("fixed transport buffer exceeds its bound") }
        lock.lock()
        try {
            if (bytes > maximumCharged - charged) {
                throw LogicalJsonPayloadError("fixed transport buffer exceeds aggregate capacity")
            }
            fixedBufferCount += 1; charged += bytes
            LogicalJsonFixedBufferReservation(this, bytes)
        } finally { lock.unlock() }
    }
    func grow(cost: Int64): Unit {
        lock.lock()
        try {
            if (cost < 0 || cost > maximumCharged - charged) {
                throw LogicalJsonPayloadError("logical payload aggregate decoded capacity is exhausted")
            }
            charged += cost
        } finally { lock.unlock() }
    }
    func release(cost: Int64): Unit {
        lock.lock(); try { charged -= cost; count -= 1 } finally { lock.unlock() }
    }
    func releaseFixedBuffer(cost: Int64): Unit {
        lock.lock(); try { charged -= cost; fixedBufferCount -= 1 } finally { lock.unlock() }
    }
    public func usage(): (Int64, Int64) { lock.lock(); try { (count + fixedBufferCount, charged) } finally { lock.unlock() } }
    // The fixed aggregate this pool was configured with. Numeric only; a reader
    // can compute remaining capacity but cannot widen or resize the pool.
    public func capacity(): Int64 { maximumCharged }
}

public class LogicalJsonFixedBufferReservation {
    private let owner: LogicalJsonOwnerBudget
    private let cost: Int64
    private let lock = Mutex()
    private var closed = false
    init(owner: LogicalJsonOwnerBudget, cost: Int64) { this.owner = owner; this.cost = cost }
    public func close(): Unit {
        lock.lock()
        try { if (!closed) { closed = true; owner.releaseFixedBuffer(cost) } }
        finally { lock.unlock() }
    }
}

public class LogicalJsonOwnerReservation {
    private let owner: LogicalJsonOwnerBudget
    private var cost: Int64
    private let lock = Mutex()
    private var closed = false
    private var declared: Int64
    private var shared: ?LogicalJsonSharedCustody = None
    private var child: Int64 = 0
    init(owner: LogicalJsonOwnerBudget, cost: Int64, declared: Int64) {
        this.owner = owner; this.cost = cost; this.declared = declared
    }
    init(owner: LogicalJsonOwnerBudget, shared: LogicalJsonSharedCustody, child: Int64) {
        this.owner = owner; this.cost = 0; this.declared = 0
        this.shared = Some(shared); this.child = child
    }
    // Only allocation custody is derived. Children share the original pool,
    // slot and floor; their concurrently retained peaks are added, never maxed.
    // A closed parent cannot derive a child. Existing children remain paid
    // until their real users (including producer join) close them.
    // A genuinely copied bounded frontend preview is independent of this
    // row's high-water ledger, while still paying the SAME private bank. The
    // source reservation must be alive; no bank or authority is exposed.
    public func acquireCopiedDisplayAllocationData(totalInvoice: Int64): PayloadDataResult<LogicalJsonCopiedDisplayAllocation> {
        lock.lock()
        try {
            if (closed) { return logicalJsonCopiedDisplayError("display.source_reservation_closed") }
            logicalJsonAcquireCopiedDisplay(owner, totalInvoice)
        } finally { lock.unlock() }
    }
    // Numeric DATA only. These are the exact original custody totals;
    // no reservation, allocator, input, Source or callback escapes this read.
    public func retainedCustodyUsage113(): (Int64, Int64, Int64) {
        lock.lock()
        try {
            match (shared) {
                case Some(value) => value.usage113()
                case None => if (closed) { (0, 0, 0) } else { (declared, cost, 1) }
            }
        } finally { lock.unlock() }
    }
    // Private bank identity is compared here, never exported as a token or
    // allocator. Closed or foreign reservations cannot pay another producer.
    public func paysSamePrivateBankData180(original: LogicalJsonOwnerReservation): Bool {
        lock.lock()
        try { !closed && refEq(owner, original.owner) } finally { lock.unlock() }
    }
    public func derivePaidDataPhase328(bytes:Int64):LogicalJsonOwnerReservation{
        owner.requireDataPhaseMessageExtent328(bytes)
        let actual=deriveRetainedLease()
        try{actual.ensureRetainedPeak(bytes*8);actual}
        catch(error:Exception){actual.close();throw error}
    }
    public func deriveRetainedLease(): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (closed) { throw LogicalJsonPayloadError("logical JSON reservation is closed") }
            let ledger = match (shared) {
                case Some(value) => value
                case None =>
                    let wanted = max(cost, declared + 1024)
                    if (wanted > cost) { owner.grow(wanted - cost); cost = wanted }
                    let value = LogicalJsonSharedCustody(owner, cost, declared)
                    shared = Some(value); value
            }
            ledger.derive(child)
        } finally { lock.unlock() }
    }
    public func ensureDecoded(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || bytes > LOGICAL_JSON_HARD_BYTES || nodes < 0 || nodes > 65536) {
            throw LogicalJsonPayloadError("logical JSON decoded shape exceeds its bound")
        }
        let minimum = max(bytes * 8, bytes * 4 + nodes * 512 + 1048576)
        ensureRetainedPeak(minimum)
    }
    // Host-owned decoding can overlap raw storage and a second canonical
    // representation. Prepay that peak in the SAME aggregate reservation.
    public func ensureRetainedPeak(minimum: Int64): Unit {
        if (minimum < 0 || minimum > 1073741824) {
            throw LogicalJsonPayloadError("logical JSON retained peak exceeds its bound")
        }
        lock.lock()
        try {
            if (closed) { throw LogicalJsonPayloadError("logical JSON reservation is closed") }
            match (shared) {
                case Some(value) => value.ensure(child, minimum)
                case None =>
                    if (minimum > cost) { owner.grow(minimum - cost); cost = minimum }
            }
            declared = max(declared, minimum)
        } finally { lock.unlock() }
    }
    public func close(): Unit {
        lock.lock()
        try {
            if (!closed) {
                closed = true
                match (shared) { case Some(value) => value.close(child); case None => owner.release(cost) }
            }
        } finally { lock.unlock() }
    }
}

// One physical reservation, with a ledger for actual concurrent allocations.
// The existing 16 MiB floor and high-water charge remain until its last lease
// closes. Removing a lease never releases the physical owner's slot early.
class LogicalJsonSharedCustody {
    private let owner: LogicalJsonOwnerBudget
    private let lock = Mutex()
    private let leases = HashMap<Int64, Int64>()
    private var next: Int64 = 1
    private var sum: Int64
    private var cost: Int64
    init(owner: LogicalJsonOwnerBudget, cost: Int64, declared: Int64) {
        this.owner = owner; this.cost = cost; this.sum = declared + 1024
        leases[0] = declared
    }
    func derive(parent: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (!leases.contains(parent) || next == Int64.Max) {
                throw LogicalJsonPayloadError("logical JSON allocation ancestor is closed or exhausted")
            }
            if (sum > 1073741824 - 1024) { throw LogicalJsonPayloadError("logical JSON allocation ledger exceeds its bound") }
            let wanted = sum + 1024
            if (wanted > cost) { owner.grow(wanted - cost); cost = wanted }
            let id = next; next += 1; sum = wanted; leases[id] = 0
            LogicalJsonOwnerReservation(owner, this, id)
        } finally { lock.unlock() }
    }
    func ensure(id: Int64, minimum: Int64): Unit {
        lock.lock()
        try {
            if (!leases.contains(id)) { throw LogicalJsonPayloadError("logical JSON allocation lease is closed") }
            let previous = leases[id]
            if (minimum > previous) {
                let growth = minimum - previous
                if (growth > 1073741824 - sum) { throw LogicalJsonPayloadError("logical JSON allocation sum exceeds its bound") }
                let wanted = sum + growth
                if (wanted > cost) { owner.grow(wanted - cost); cost = wanted }
                sum = wanted; leases[id] = minimum
            }
        } finally { lock.unlock() }
    }
    func usage113(): (Int64, Int64, Int64) {
        lock.lock()
        try { (sum, cost, leases.size) } finally { lock.unlock() }
    }
    func close(id: Int64): Unit {
        lock.lock()
        try {
            if (leases.contains(id)) {
                sum -= leases[id] + 1024; leases.remove(id)
                // The shared high-water charge intentionally remains paid
                // until the actual original closes, even after its derived
                // children close: their concurrent peaks were added to this
                // same aggregate, and the sum is what the original single-bank
                // contract asserts (`agent_domain` DerivedDataPhasesSum...).
                // Releasing the excess here would under-count that peak, so
                // keep this behaviour.
                if (leases.isEmpty()) { owner.release(cost) }
            }
        } finally { lock.unlock() }
    }
}

public class LogicalJsonProcessBudget {
    private let owner: LogicalJsonOwnerBudget
    private let lock = Mutex()
    private var active: Int64 = 0
    public init(owner: LogicalJsonOwnerBudget) { this.owner = owner }
    public func acquire(bytes: Int64): LogicalJsonReservation {
        lock.lock()
        try {
            if (active >= 2) { throw LogicalJsonPayloadError("logical payload worker capacity is exhausted") }
            let selected = owner.acquire(bytes)
            active += 1
            LogicalJsonReservation(this, selected)
        } finally { lock.unlock() }
    }
    func release(): Unit { lock.lock(); try { active -= 1 } finally { lock.unlock() } }
}

public class LogicalJsonReservation {
    private let process: LogicalJsonProcessBudget
    private let owner: LogicalJsonOwnerReservation
    private let lock = Mutex()
    private var closed = false
    private var transferActive = true
    init(process: LogicalJsonProcessBudget, owner: LogicalJsonOwnerReservation) {
        this.process = process; this.owner = owner
    }
    public func ensureDecoded(bytes: Int64, nodes: Int64): Unit {
        lock.lock()
        try {
            if (closed) { throw LogicalJsonPayloadError("logical payload reservation is closed") }
            owner.ensureDecoded(bytes, nodes)
        } finally { lock.unlock() }
    }
    // Completed transport may retain decoded values in a caller. Retire only
    // its transfer slot; the SAME aggregate allocation remains until close.
    public func detachTransfer(): Unit {
        lock.lock()
        let detached = try { if (!transferActive) { false } else { transferActive = false; true } } finally { lock.unlock() }
        if (detached) { process.release() }
    }
    public func close(): Unit {
        lock.lock()
        let release = try { if (closed) { false } else { closed = true; true } } finally { lock.unlock() }
        if (release) { owner.close(); detachTransfer() }
    }
}

// Accepts only the payload header, after the caller checks its transport's
// complete outer identity. The completed JSON must be checked again by caller.
public class LogicalJsonReceiver {
    private let maximumBytes: Int64
    private let window: String
    private let sequence: Int64
    private let messageType: String
    private let maximumDepth: Int64
    private let retainedBytes: Int64
    private let retainedNodes: Int64
    private let check: () -> Unit
    private let reservation: LogicalJsonReservation
    private var buffer: Array<Byte> = []
    private var offset: Int64 = 0
    private var expectedDigest = ""
    private var begun = false
    private var complete = false
    private var closed = false
    public init(budget: LogicalJsonProcessBudget, maximumBytes: Int64,
        window: String, sequence: Int64, messageType: String, check: () -> Unit,
        physicalFrameBytes!: Int64 = 0, reservation!: ?LogicalJsonReservation = None,
        maximumDepth!: Int64 = 32, reserveMaximum!: Bool = true,
        retainedBytes!: Int64 = 0, retainedNodes!: Int64 = 0) {
        if (maximumBytes < 1 || maximumBytes > LOGICAL_JSON_HARD_BYTES || window == "" || window.size > 256 ||
            window.contains("\u{0}") || sequence < 1 || messageType == "" || messageType.size > 64 ||
            physicalFrameBytes < 0 || physicalFrameBytes > LOGICAL_JSON_HARD_BYTES || maximumDepth < 1 || maximumDepth > 64) {
            throw LogicalJsonPayloadError("invalid host logical payload window")
        }
        if (retainedBytes < 0 || retainedBytes > LOGICAL_JSON_HARD_BYTES - maximumBytes || retainedNodes < 0 || retainedNodes > 65536) {
            throw LogicalJsonPayloadError("logical payload retained allocation is outside its bound")
        }
        this.retainedBytes = retainedBytes; this.retainedNodes = retainedNodes
        this.maximumBytes = maximumBytes; this.window = window; this.sequence = sequence
        this.messageType = messageType; this.check = check; this.maximumDepth = maximumDepth
        let initial = if (reserveMaximum) { max(maximumBytes, physicalFrameBytes) } else { max(1, physicalFrameBytes) }
        let selected = match (reservation) { case Some(value) => value
            case None => budget.acquire(initial) }
        // A caller may hand over its pre-parser reservation. Confirm and grow
        // that same live charge before allocating any declared transfer body.
        try { selected.ensureDecoded(initial + retainedBytes, retainedNodes) }
        catch (error: Exception) { selected.close(); throw error }
        this.reservation = selected
    }
    public prop pending: Bool { get() { begun && !complete } }
    public func accept(kind: String, header: AgentValue): ?AgentValue {
        check()
        if (closed || complete) { throw LogicalJsonPayloadError("logical payload was already consumed or closed") }
        if (header.unifiedKind != ValueKind.Object || logicalJsonText(header, "schema") != LOGICAL_JSON_PAYLOAD_SCHEMA ||
            logicalJsonText(header, "window") != window || logicalJsonInteger(header, "transfer_sequence") != sequence) {
            throw LogicalJsonPayloadError("logical payload window differs from the fixed invocation")
        }
        if (kind == "payload_begin") {
            if (begun || !httpIntentExactFields(header, ["schema", "window", "transfer_sequence", "message_type", "bytes", "sha256"]) ||
                logicalJsonText(header, "message_type") != messageType) { throw LogicalJsonPayloadError("invalid logical payload begin") }
            let length = logicalJsonInteger(header, "bytes"); let digest = logicalJsonText(header, "sha256")
            if (length < 1 || length > maximumBytes || !httpIntentDigest(digest)) {
                throw LogicalJsonPayloadError("logical payload declaration exceeds its fixed bound")
            }
            // Grow the already-owned reservation before the first body byte
            // allocation. Model channels need not pre-reserve their largest
            // permitted body for every tiny streaming event.
            reservation.ensureDecoded(length + retainedBytes, retainedNodes)
            try { buffer = Array<Byte>(length, repeat: 0) } catch (error: Exception) { close(); throw error }
            expectedDigest = digest; begun = true; return None
        }
        if (!begun) { throw LogicalJsonPayloadError("logical payload has no begin") }
        if (kind == "payload_chunk") {
            if (!httpIntentExactFields(header, ["schema", "window", "transfer_sequence", "offset", "bytes_hex"]) ||
                logicalJsonInteger(header, "offset") != offset) { throw LogicalJsonPayloadError("logical payload offset is stale or overlapping") }
            let text = logicalJsonText(header, "bytes_hex")
            if (text.size < 2 || text.size > LOGICAL_JSON_CHUNK_BYTES * 2 || text.size % 2 != 0 || text.size / 2 > buffer.size - offset) {
                throw LogicalJsonPayloadError("logical payload chunk exceeds its remaining bound")
            }
            // Bounds above prove every source pair and destination byte is
            // inside its live buffer. Pin only for this synchronous decode;
            // avoid a cloned hex Array and generic array callbacks per byte.
            unsafe {
                let source = acquireArrayRawData(text.rawData())
                try {
                    let target = acquireArrayRawData(buffer)
                    try {
                        for (index in 0..text.size / 2) {
                            let high = logicalJsonHex(source.pointer.read(index * 2))
                            let low = logicalJsonHex(source.pointer.read(index * 2 + 1))
                            if (high < 0 || low < 0) {
                                throw LogicalJsonPayloadError("logical payload chunk is not canonical hexadecimal") }
                            target.pointer.write(offset + index, UInt8(high * 16 + low))
                        }
                    } finally { releaseArrayRawData(target) }
                } finally { releaseArrayRawData(source) }
            }
            offset += text.size / 2; return None
        }
        if (kind != "payload_end" || !httpIntentExactFields(header, ["schema", "window", "transfer_sequence"]) || offset != buffer.size) {
            throw LogicalJsonPayloadError("logical payload is incomplete")
        }
        let source = String.fromUtf8(buffer)
        if (modelPolicySha256Text(source) != expectedDigest) { throw LogicalJsonPayloadError("logical payload digest differs from its begin") }
        reservation.ensureDecoded(source.size + retainedBytes, logicalJsonNodeCount(source) + retainedNodes)
        let value = parseUnifiedJson(source, maxBytes: maximumBytes, maxDepth: maximumDepth)
        check(); complete = true
        Some(value)
    }
    // A completed message can relinquish its raw buffer while its caller
    // continues to own the SAME paid invocation reservation. No slot or byte
    // charge is detached/refunded; default close below remains unchanged.
    public func clearRetainedMessageBuffer(): Unit {
        if (closed || !complete) { throw LogicalJsonPayloadError("logical payload buffer is not completed") }
        buffer = []
    }
    public func close(): Unit {
        if (!closed) { closed = true; buffer = []; reservation.close() }
    }
}

public func writeLogicalJsonPayload(window: String, sequence: Int64, messageType: String,
    source: String, maximum: Int64, check: () -> Unit, emit: (String, AgentValue) -> Unit): Unit {
    if (maximum < 1 || maximum > LOGICAL_JSON_HARD_BYTES || source.size < 1 || source.size > maximum ||
        window == "" || window.size > 256 || window.contains("\u{0}") || sequence < 1 ||
        messageType == "" || messageType.size > 64) { throw LogicalJsonPayloadError("outgoing logical payload exceeds its fixed bound") }
    let _ = logicalJsonNodeCount(source)
    func send(kind: String, values: Array<ValueField>): Unit {
        check()
        let header = ArrayList<ValueField>([ValueField("schema", textValue(LOGICAL_JSON_PAYLOAD_SCHEMA)),
            ValueField("window", textValue(window)), ValueField("transfer_sequence", integerValue(sequence))])
        header.add(all: values); emit(kind, objectValue(header.toArray()))
    }
    send("payload_begin", [ValueField("message_type", textValue(messageType)), ValueField("bytes", integerValue(source.size)),
        ValueField("sha256", textValue(modelPolicySha256Text(source)))])
    let bytes = source.toArray(); var offset: Int64 = 0
    while (offset < bytes.size) {
        let end = min(bytes.size, offset + LOGICAL_JSON_CHUNK_BYTES)
        send("payload_chunk", [ValueField("offset", integerValue(offset)), ValueField("bytes_hex", textValue(logicalJsonEncodeHex(bytes[offset..end])))])
        offset = end
    }
    send("payload_end", [])
}

// Allocation preflight, not JSON validation. Keep the original lexical-node
// definition (including field names and malformed input); the bounded parser
// remains responsible for syntax, UTF-8 and nesting validation.
public func logicalJsonNodeCount(source: String): Int64 {
    var offset: Int64 = 0
    var nodes: Int64 = 0
    var scalar = false
    while (offset < source.size) {
        let byte = source[offset]
        if (byte == b'"') {
            scalar = false; nodes += 1
            if (nodes > 65536) { throw LogicalJsonPayloadError("logical JSON has too many lexical nodes") }
            offset += 1
            // Search on the original String, without copying its entire byte
            // array or revisiting ordinary string bytes in the scalar loop.
            // Only a quote preceded by an even backslash run ends the string.
            // Each search advances; each backward run stays within that search
            // interval. Even escape-heavy or unterminated input stays linear.
            while (true) {
                let closingQuote = match (source.indexOf(b'"', offset)) {
                    case Some(value) => value
                    case None => return nodes
                }
                var runStart = closingQuote
                while (runStart > offset && source[runStart - 1] == b'\\') { runStart -= 1 }
                let escaped = (closingQuote - runStart) % 2 != 0
                offset = closingQuote + 1
                if (!escaped) { break }
            }
        } else {
            if (byte == b'{' || byte == b'[') { scalar = false; nodes += 1 }
            else if (byte == b',' || byte == b':' || byte == b'}' || byte == b']' ||
                byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n') { scalar = false }
            else if (!scalar) { scalar = true; nodes += 1 }
            if (nodes > 65536) { throw LogicalJsonPayloadError("logical JSON has too many lexical nodes") }
            offset += 1
        }
    }
    nodes
}

// Walk an existing bounded DOM without stringify or copying string bytes.
// Lower bounds reject impossible messages before allocation; upper bounds
// reserve worst-case escaped serialization, capped by the caller's hard limit.
public func logicalJsonWriteReservationBytes(value: AgentValue, maximum: Int64): Int64 {
    if (maximum < 1 || maximum > LOGICAL_JSON_HARD_BYTES) { throw LogicalJsonPayloadError("logical JSON write bound is invalid") }
    let counter = LogicalJsonBoundCounter(maximum)
    let (_, upper) = counter.measure(value, 0)
    min(maximum, max(1, upper))
}
// Existing immutable DOM shape, including one node per field name. This
// traversal shares the original depth/node limit and allocates no JSON copy.
public func logicalJsonValueNodeCount(value: AgentValue): Int64 {
    let counter=LogicalJsonBoundCounter(LOGICAL_JSON_HARD_BYTES)
    let _=counter.measure(value,0)
    counter.nodeCount()
}
class LogicalJsonBoundCounter {
    private let maximum: Int64
    private var nodes: Int64 = 0
    init(maximum: Int64) { this.maximum = maximum }
    func nodeCount():Int64{nodes}
    func measure(value: AgentValue, depth: Int64): (Int64, Int64) {
        nodes += 1
        if (depth > 64 || nodes > 65536) { throw LogicalJsonPayloadError("logical JSON write shape exceeds its bound") }
        var lower: Int64 = 0; var upper: Int64 = 0
        if (value.unifiedKind == ValueKind.Text) { lower = value.text.size + 2; upper = value.text.size * 6 + 2 }
        else if (value.unifiedKind == ValueKind.Number) { lower = value.asNumberText().size; upper = lower }
        else if (value.unifiedKind == ValueKind.Null) { lower = 4; upper = 4 }
        else if (value.unifiedKind == ValueKind.Boolean) { lower = 4; upper = 5 }
        else {
            lower = 2; upper = 2
            if (value.unifiedKind == ValueKind.Object) {
                for (entry in value.fields) {
                    nodes += 1
                    let (a, b) = measure(entry.value, depth + 1)
                    lower += entry.name.size + 3 + a
                    upper = min(maximum, upper + entry.name.size * 6 + 4 + b)
                    if (lower > maximum) { throw LogicalJsonPayloadError("logical JSON write exceeds its byte limit") }
                }
            } else if (value.unifiedKind == ValueKind.List) {
                for (item in value.items) {
                    let (a, b) = measure(item, depth + 1); lower += a
                    upper = min(maximum, upper + b + 1)
                    if (lower > maximum) { throw LogicalJsonPayloadError("logical JSON write exceeds its byte limit") }
                }
            } else { throw LogicalJsonPayloadError("logical JSON has unsupported value kind") }
        }
        if (lower > maximum) { throw LogicalJsonPayloadError("logical JSON write exceeds its byte limit") }
        (lower, min(maximum, upper))
    }
}
public func logicalJsonEncodeHex(bytes: Array<Byte>): String {
    let alphabet = "0123456789abcdef".toArray(); let output = Array<Byte>(bytes.size * 2, repeat: 0)
    for (index in 0..bytes.size) {
        output[index * 2] = alphabet[Int64(bytes[index] >> 4)]
        output[index * 2 + 1] = alphabet[Int64(bytes[index] & 15)]
    }
    String.fromUtf8(output)
}
func logicalJsonHex(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') { Int64(byte - b'0') }
    else if (byte >= b'a' && byte <= b'f') { Int64(byte - b'a') + 10 }
    else { -1 }
}
func logicalJsonText(value: AgentValue, name: String): String {
    let found = value.field(name).getOrThrow()
    if (found.unifiedKind != ValueKind.Text) { throw LogicalJsonPayloadError("logical payload text has wrong type") }
    found.text
}
func logicalJsonInteger(value: AgentValue, name: String): Int64 {
    let found = value.field(name).getOrThrow()
    if (found.unifiedKind != ValueKind.Number) { throw LogicalJsonPayloadError("logical payload integer has wrong type") }
    let parsed = Int64.parse(found.asNumberText())
    if (parsed.toString() != found.asNumberText()) { throw LogicalJsonPayloadError("logical payload integer is not canonical") }
    parsed
}
