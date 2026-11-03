package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.io.*
import yjson.*
import yjson_support.*

func compactionFragmentError(): Nothing {
    throw PureProviderError("compaction.fragment_invalid", "fragment identity, range or carry is invalid")
}
func compactionFragmentBool(value: AgentValue, key: String): Bool {
    let node = value.field(key).getOrThrow()
    if (node.unifiedKind != ValueKind.Boolean) { compactionFragmentError() }
    node.asBool()
}
func compactionFragmentReply(input: AgentValue, fields: Array<ValueField>): AgentValue {
    let output = ArrayList<ValueField>([
        ValueField("snapshot_digest", input.field("snapshot_digest").getOrThrow()),
        ValueField("source", input.field("source").getOrThrow()),
        ValueField("sequence", input.field("sequence").getOrThrow())])
    output.add(all: fields); objectValue(output.toArray())
}

class CompactionTrimFragmentState {
    let output = ArrayList<Byte>()
    let held = ArrayList<Byte>()
    var started = false
    var overflow = false
    var truncated = false
    func emit(raw: Byte, limit: Int64): Unit {
        if (raw == 13) { return }
        let byte = if (raw == 10) { UInt8(32) } else { raw }
        let whitespace = byte == 32 || (byte >= 9 && byte <= 13)
        if (whitespace) {
            if (started) { if (held.size <= limit + 3) { held.add(byte) } else { overflow = true } }
        } else {
            if (overflow) { output.add(all: held.toArray()); held.clear(); truncated = true; return }
            output.add(all: held.toArray()); held.clear(); started = true; output.add(byte)
        }
    }
}

// The previous compactText byte semantics, including internal whitespace and
// byte-prefix slicing, remain here in the plugin. The host only transports
// exact source chunks. Pending whitespace and prior-summary marker candidates
// stay bounded across arbitrarily long source values.
func compactionTextFragment(input: AgentValue): AgentValue {
    policyFields(input, ["schema", "phase", "snapshot_digest", "source", "sequence", "mode", "limit", "offset", "total", "text", "carry"])
    let offset = structuredInteger(input, "offset"); let total = structuredInteger(input, "total")
    let text = policyText(input, "text"); let mode = policyText(input, "mode")
    let requested = structuredInteger(input, "limit")
    if (!["compact", "excerpt"].contains(mode) || requested < 1 || requested > 1600 ||
        offset < 0 || total < offset || text.size > total - offset || text.size > 262144 ||
        (text == "" && total != 0) || (mode == "excerpt" && offset == 0 && text.size < min(total, 26))) { compactionFragmentError() }
    let carry = input.field("carry").getOrThrow()
    let state = CompactionTrimFragmentState()
    let markerHeld = ArrayList<Byte>()
    var prior = mode == "excerpt" && offset == 0 && text.startsWith("[Compacted session history]")
    if (carry.unifiedKind != ValueKind.Null) {
        policyFields(carry, ["offset", "prefix", "held", "marker", "started", "overflow", "prior", "complete"])
        if (structuredInteger(carry, "offset") != offset || compactionFragmentBool(carry, "complete")) { compactionFragmentError() }
        let prefix = policyText(carry, "prefix"); let pending = policyText(carry, "held"); let marker = policyText(carry, "marker")
        if (prefix.size > 1604 || pending.size > 1604 || marker.size > MODEL_COMPACTION_OVERVIEW_MARKER.size) { compactionFragmentError() }
        state.output.add(all: prefix.toArray()); state.held.add(all: pending.toArray()); markerHeld.add(all: marker.toArray())
        state.started = compactionFragmentBool(carry, "started"); state.overflow = compactionFragmentBool(carry, "overflow")
        prior = compactionFragmentBool(carry, "prior")
    } else if (offset != 0) { compactionFragmentError() }
    let limit = if (prior) { 1600 } else { requested }
    var markerFound = false
    let marker = MODEL_COMPACTION_OVERVIEW_MARKER.toArray()
    for (raw in unsafe { text.rawData() }) {
        // Stop at a scalar boundary. Final legacy byte slicing below is exact:
        // if the old algorithm rejects a split UTF-8 limit, this does too.
        if ((raw & 0xC0) != 0x80 && state.output.size > limit) { state.truncated = true; break }
        if (prior) {
            markerHeld.add(raw)
            while (!markerHeld.isEmpty()) {
                var prefix = markerHeld.size <= marker.size
                if (prefix) { for (index in 0..markerHeld.size where markerHeld[index] != marker[index]) { prefix = false; break } }
                if (prefix) { break }
                let first = markerHeld.remove(at: 0); state.emit(first, limit)
            }
            if (markerHeld.size == marker.size) { markerFound = true; markerHeld.clear(); break }
        } else { state.emit(raw, limit) }
        if (state.truncated) { break }
    }
    let eof = offset + text.size == total
    if (eof && !state.truncated && !markerFound) { for (byte in markerHeld) { state.emit(byte, limit) }; markerHeld.clear() }
    if (state.output.size > limit) { state.truncated = true }
    let complete = state.truncated || markerFound || eof
    let rawPrefix = String.fromUtf8(state.output.toArray())
    let prefix = if (state.truncated) { rawPrefix[..min(limit, rawPrefix.size)] } else { rawPrefix }
    let next = offset + text.size
    compactionFragmentReply(input, [ValueField("next_offset", integerValue(next)), ValueField("complete", boolValue(complete)),
        ValueField("prior", boolValue(prior)), ValueField("result", if (complete) { textValue(prefix + if (state.truncated) { "..." } else { "" }) } else { nullValue() }),
        ValueField("carry", objectValue([ValueField("offset", integerValue(next)), ValueField("prefix", textValue(prefix)),
            ValueField("held", textValue(if (complete) { "" } else { String.fromUtf8(state.held.toArray()) })),
            ValueField("marker", textValue(if (complete) { "" } else { String.fromUtf8(markerHeld.toArray()) })),
            ValueField("started", boolValue(state.started)), ValueField("overflow", boolValue(state.overflow)),
            ValueField("prior", boolValue(prior)), ValueField("complete", boolValue(complete))]))])
}

// Hashline discovery retains offsets rather than unbounded path text. Returned
// ranges are data proposals; the host verifies them against the same immutable
// source and interns their exact bytes. The plugin retains duplicate/order
// policy after those neutral equality identities have been returned.
func compactionHashlineFragment(input: AgentValue): AgentValue {
    policyFields(input, ["schema", "phase", "snapshot_digest", "source", "sequence", "offset", "total", "text", "carry"])
    let offset = structuredInteger(input, "offset"); let total = structuredInteger(input, "total")
    let text = policyText(input, "text"); let carry = input.field("carry").getOrThrow()
    if (offset < 0 || total < offset || text.size > total - offset || text.size > 262144 ||
        (text == "" && total != 0)) { compactionFragmentError() }
    var start = offset; var separator: Int64 = -1; var first: Int64 = -1; var last: Int64 = -1
    if (carry.unifiedKind != ValueKind.Null) {
        policyFields(carry, ["offset", "start", "separator", "first", "last"])
        if (structuredInteger(carry, "offset") != offset) { compactionFragmentError() }
        start = structuredInteger(carry, "start"); separator = structuredInteger(carry, "separator")
        first = structuredInteger(carry, "first"); last = structuredInteger(carry, "last")
        if (start < 0 || start > offset || separator < -1 || separator > offset || first < -1 || first > 255 || last < -1 || last > 255) {
            compactionFragmentError() }
    } else if (offset != 0) { compactionFragmentError() }
    let ranges = ArrayList<AgentValue>(); var next = offset
    for (byte in unsafe { text.rawData() }) {
        if (byte == 10) {
            if (first == 91 && last == 93 && separator > start + 1) {
                ranges.add(objectValue([ValueField("offset", integerValue(start + 1)), ValueField("bytes", integerValue(separator - start - 1))])) }
            start = next + 1; separator = -1; first = -1; last = -1
        } else {
            if (first == -1) { first = Int64(byte) }
            if (separator == -1 && byte == 35) { separator = next }
            last = Int64(byte)
        }
        next++
        if (ranges.size == 128) { break }
    }
    if (next == total) { if (first == 91 && last == 93 && separator > start + 1) {
                ranges.add(objectValue([ValueField("offset", integerValue(start + 1)), ValueField("bytes", integerValue(separator - start - 1))])) } }
    compactionFragmentReply(input, [ValueField("next_offset", integerValue(next)), ValueField("complete", boolValue(next == total)),
        ValueField("ranges", listValue(ranges.toArray())), ValueField("carry", objectValue([
            ValueField("offset", integerValue(next)), ValueField("start", integerValue(start)), ValueField("separator", integerValue(separator)),
            ValueField("first", integerValue(first)), ValueField("last", integerValue(last))]))])
}
