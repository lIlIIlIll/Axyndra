package agent_domain

import std.collection.*
import yjson.*
import yjson_support.*

// This counts the current tree's original default JSON encoding. It does not
// cache a value, identify a Source, grant a capability, or skip any field.
func channelParentJsonByteSize(value: AgentValue): Int64 {
    let options = JsonWriteOptions.defaults
    if (!options.indent.isEmpty() || options.htmlSafe || options.maxOutputBytes != 0 ||
        options.maxDepth != 256) {
        return stringifyUnifiedJson(value).size
    }
    // Preserve the original writer's runtime-freeze boundary before reading
    // the current mutable tree. The original serializer remains the oracle.
    let _ = JsonNode.nullValue.toJson()
    let count = ChannelParentJsonByteCounter(options.maxDepth)
    try {
        if (count.visit(value)) { return count.bytes() }
    } catch (_: Exception) {
        // Replay the whole original writer so unsupported nodes, nonfinite
        // numbers and all other errors keep their original code and path.
    }
    stringifyUnifiedJson(value).size
}

private class ChannelParentJsonByteCounter {
    private let ancestors = ArrayList<JsonNode>()
    private let maxDepth: Int64
    private var total: Int64 = 0

    init(maxDepth: Int64) { this.maxDepth = maxDepth }

    func bytes(): Int64 { total }

    private func add(bytes: Int64): Bool {
        if (bytes < 0 || bytes > Int64.Max - total) { return false }
        total += bytes
        true
    }

    private func stringBytes(value: String): Bool {
        if (channelJsonStringNeedsEscape(value)) {
            return add(JsonNode.string(value).toJson().size)
        }
        add(2) && add(value.size)
    }

    private func enter(value: JsonNode): Bool {
        // The original writer checks cycles before its 256-container limit.
        // Either failure replays that writer, including its exact error path.
        for (ancestor in ancestors) {
            if (refEq(value, ancestor)) { return false }
        }
        if (ancestors.size >= maxDepth) { return false }
        ancestors.add(value)
        true
    }

    func visit(value: JsonNode): Bool {
        match (value) {
            case array: JsonArray =>
                if (!enter(array)) { return false }
                try {
                    if (!add(2)) { return false }
                    for (index in 0..array.size()) {
                        if (index > 0 && !add(1)) { return false }
                        if (!visit(array.get(index).getOrThrow())) { return false }
                    }
                    true
                } finally { ancestors.remove(at: ancestors.size - 1) }
            case object: JsonObject =>
                if (!enter(object)) { return false }
                try {
                    if (!add(2)) { return false }
                    for (index in 0..object.size()) {
                        if (index > 0 && !add(1)) { return false }
                        if (!stringBytes(object.nameAt(index)) || !add(1) ||
                            !visit(object.valueAt(index))) { return false }
                    }
                    true
                } finally { ancestors.remove(at: ancestors.size - 1) }
            case _ =>
                // asString is the original non-open concrete-type getter.
                // A custom JsonNode's advertised kind is never consulted.
                let text: ?String = try { Some(value.asString()) }
                    catch (_: JsonException) { None<String> }
                if (let Some(actual) <- text) { return stringBytes(actual) }
                // Use the original serializer for every other scalar, keeping
                // exact numeric spelling, finite checks and invalid-node rules.
                add(value.toJson().size)
        }
    }
}

@When[os != "Windows"]
foreign func memchr(data: CPointer<UInt8>, value: Int32, bytes: UIntNative): CPointer<UInt8>

@When[os != "Windows"]
private func channelJsonStringNeedsEscape(value: String): Bool {
    let data = unsafe { value.rawData() }
    if (data.size < 256) {
        for (byte in data) {
            if (byte < 32 || byte == 34 || byte == 92) { return true }
        }
        return false
    }
    let bytes = UIntNative(data.size)
    // The exact default writer's 34 escape bytes are checked over the entire
    // UTF-8 range. All objects exist before pinning; only scalar operations and
    // synchronous foreign calls occur while this original array is pinned.
    unsafe {
        let lease = acquireArrayRawData(data)
        try {
            var control: Int32 = 0
            while (control < 32) {
                if (!memchr(lease.pointer, control, bytes).isNull()) { return true }
                control++
            }
            !memchr(lease.pointer, 34, bytes).isNull() ||
                !memchr(lease.pointer, 92, bytes).isNull()
        } finally { releaseArrayRawData(lease) }
    }
}

@When[os == "Windows"]
private func channelJsonStringNeedsEscape(value: String): Bool {
    // Keep the same complete byte check on the platform without this libc
    // binding. This path has the original writer's exact default semantics.
    let data = unsafe { value.rawData() }
    for (byte in data) {
        if (byte < 32 || byte == 34 || byte == 92) { return true }
    }
    false
}
