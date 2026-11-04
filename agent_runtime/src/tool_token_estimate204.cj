package agent_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.sync.*

private let tokenScratchDebts204 = TokenScratchDebts204()

// A temporary original-bank traversal frame. It contains no schema or Source.
// Unknown traversal retains this actual debt until a concrete return exists.
public class ToolTokenScratch204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var active: Int64 = 0
    private var held = false
    var next204: ?ToolTokenScratch204 = None<ToolTokenScratch204>
    public init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); tokenScratchDebts204.retain204(this)
    }
    func beginEstimate204(): Unit {
        lock.lock(); try {
            if (payment.isNone() || held || active != 0) { throw IllegalStateException("tool token scratch is unavailable") }
            active++
        } finally { lock.unlock() }
    }
    func returnedEstimateFrame204(): Unit {
        lock.lock(); try {
            if (active < 1) { throw IllegalStateException("tool token scratch frame underflow") }
            active--
        } finally { lock.unlock() }
    }
    func markUnknown204(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    func fundPath204(depth: Int64): Unit {
        lock.lock(); try {
            if (payment.isNone() || held || active < 1) { throw IllegalStateException("tool token scratch has no active frame") }
            if (depth < 0 || depth > (Int64.Max - 131072) / 2048) {
                throw LogicalJsonPayloadError("tool token traversal depth invoice overflow") }
            // Reuse the maximum live recursion path, not a cumulative per-node
            // invoice. Scalar number formatting is prepaid before its accessor.
            payment.getOrThrow().ensureRetainedPeak(131072 + depth * 2048)
        } finally { lock.unlock() }
    }
    public func returnWholeEstimate204(): Unit {
        lock.lock(); try {
            if (held || active != 0) { throw IllegalStateException("tool token scratch frame remains owned or unknown") }
            let actual = payment.getOrThrow()
            actual.close(); payment = None<LogicalJsonOwnerReservation>
            tokenScratchDebts204.remove204(this)
        } finally { lock.unlock() }
    }
}
private class TokenScratchDebts204 {
    private let lock = Mutex()
    private var first: ?ToolTokenScratch204 = None<ToolTokenScratch204>
    func retain204(value: ToolTokenScratch204): Unit {
        lock.lock(); try { value.next204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: ToolTokenScratch204): Unit {
        lock.lock(); try {
            var previous: ?ToolTokenScratch204 = None<ToolTokenScratch204>
            var cursor = first
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(prior) => prior.next204 = actual.next204; case None => first = actual.next204 }
                    actual.next204 = None<ToolTokenScratch204>; return
                }
                previous = cursor; cursor = actual.next204
            }
            throw IllegalStateException("tool token traversal debt is missing")
        } finally { lock.unlock() }
    }
}

// One formula shared by Core and closed Catalog scalar consumers.
public func estimateToolTokensData204(name: String, description: String, schema: AgentValue,
    scratch!: ?ToolTokenScratch204 = None<ToolTokenScratch204>): Int64 {
    18 + estimateTextTokensData204(name, 3) + estimateTextTokensData204(description, 4) +
        estimateAgentValueTokensData204(schema, scratch: scratch)
}
public func estimateAgentValueTokensData204(value: AgentValue,
    scratch!: ?ToolTokenScratch204 = None<ToolTokenScratch204>): Int64 {
    match (scratch) { case Some(actual) => actual.beginEstimate204(); case None => () }
    try { estimateAgentValueTokensFrame204(value, scratch, 0) }
    catch (error: Exception) {
        match (scratch) { case Some(actual) => actual.markUnknown204(); case None => () }; throw error
    } finally { match (scratch) { case Some(actual) => actual.returnedEstimateFrame204(); case None => () } }
}
private func estimateAgentValueTokensFrame204(value: AgentValue,
    scratch: ?ToolTokenScratch204, depth: Int64): Int64 {
    match (scratch) { case Some(actual) => actual.fundPath204(depth); case None => () }
    match (value.unifiedKind) {
        case ValueKind.Null | ValueKind.Boolean => 1
        // Pinned JsonNode.asNumberText borrows a literal of any length;
        // only Int64/UInt64/finite Float64 format new bounded text. This is
        // not the arbitrary backend JsonValueView text interface.
        case ValueKind.Number => max(1, estimateTextTokensData204(value.asNumberText(), 3))
        case ValueKind.Text => estimateTextTokensData204(value.text, 3) + 2
        case ValueKind.List =>
            var tokens: Int64 = 2
            let source = value.asArray()
            for (index in 0..source.size()) {
                tokens += 1 + estimateAgentValueTokensFrame204(source.get(index).getOrThrow(), scratch, depth + 1)
            }
            tokens
        case ValueKind.Object =>
            var tokens: Int64 = 2
            let source = value.asObject()
            for (index in 0..source.size()) {
                tokens += 3 + estimateTextTokensData204(source.nameAt(index), 3) +
                    estimateAgentValueTokensFrame204(source.valueAt(index), scratch, depth + 1)
            }
            tokens
    }
}

public func estimateTextTokensData204(value: String, asciiDivisor: Int64): Int64 {
    if (value == "") {
        return 0
    }
    let bytes = unsafe { value.rawData() }
    var weightedAscii: Int64 = 0
    var unicodeTokens: Int64 = 0
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte < 128) {
            weightedAscii += if ((byte >= 33 && byte <= 47) || (byte >= 58 && byte <= 64) ||
                (byte >= 91 && byte <= 96) || (byte >= 123 && byte <= 126)) { 2 } else { 1 }
            index += 1
        } else if (byte >= 240) {
            unicodeTokens += 2
            index += min(4, bytes.size - index)
        } else if (byte >= 224) {
            unicodeTokens += 1
            index += min(3, bytes.size - index)
        } else if (byte >= 192) {
            unicodeTokens += 1
            index += min(2, bytes.size - index)
        } else {
            // Invalid/continuation bytes are charged conservatively.
            unicodeTokens += 1
            index += 1
        }
    }
    unicodeTokens + (weightedAscii + asciiDivisor - 1) / asciiDivisor
}
