package agent_runtime

import agent_domain.*
import yjson.*
import yjson_support.*

// Closed numeric view of the actual frozen snapshot. These are the original
// Host retained-reference bytes/nodes, including its original limits; no raw
// snapshot/schema/callback or capability leaves this private measuring frame.
class ToolSnapshotRetainedShape159 {
    private let payment: LogicalJsonOwnerReservation
    private var bytes: Int64
    private var nodes: Int64
    init(payment: LogicalJsonOwnerReservation, bytes: Int64, nodes: Int64) {
        if (bytes < 0 || bytes > 1073741824 || nodes < 0 || nodes > 1000000) {
            throw LogicalJsonPayloadError("managed retained prefix exceeds original accounting") }
        this.payment = payment; this.bytes = bytes; this.nodes = nodes
        // begin159 already paid this fixed counter before its allocation.
        // This same-bank phase funds the bounded recursion and original
        // scalar formatter before either can execute. Indexed container reads
        // create no fields/items snapshots or temporary arrays.
        payment.ensureRetainedPeak(1048576 + 131072)
    }
    private func text159(value: String): Unit {
        nodes += 1; bytes += 64 + value.size
        if (bytes > 1073741824 || nodes > 1000000) {
            throw LogicalJsonPayloadError("managed retained text overflows aggregate accounting") }
    }
    private func add159(value: AgentValue, depth: Int64): Unit {
        nodes += 1
        if (depth > 64 || nodes > 1000000) {
            throw LogicalJsonPayloadError("managed retained value exceeds original StoredValue shape") }
        bytes += 64
        match (value.unifiedKind) {
            case ValueKind.Text => bytes += value.text.size
            case ValueKind.Number => bytes += value.asNumberText().size
            case ValueKind.Object =>
                let object = value.asObject()
                for (index in 0..object.size()) {
                    nodes += 1; bytes += object.nameAt(index).size + 64
                    add159(object.valueAt(index), depth + 1)
                }
            case ValueKind.List =>
                let array = value.asArray()
                for (index in 0..array.size()) { add159(array.get(index).getOrThrow(), depth + 1) }
            case ValueKind.Boolean | ValueKind.Null => ()
            case _ => throw LogicalJsonPayloadError("managed retained value has unsupported kind")
        }
        if (bytes > 1073741824) {
            throw LogicalJsonPayloadError("managed retained value overflows aggregate accounting") }
    }
    func snapshot159(value: ToolSetSnapshot): (Int64, Int64) {
        text159(value.id)
        match (value.threadId) { case Some(thread) => text159(thread.value); case None => () }
        for (entry in value.entries) {
            text159(entry.name); text159(entry.description); add159(entry.inputSchema, 0)
            text159(entry.executorVersion); text159(entry.implementationFingerprint); text159(entry.schemaDigest)
            for (capability in entry.requiredCapabilities) { text159(capability.resource) }
        }
        for (handler in value.hookHandlers) {
            text159(handler.event); text159(handler.pluginId); text159(handler.pluginVersion)
            text159(handler.contentDigest); text159(handler.packageRoot); text159(handler.matcher)
            text159(handler.command)
        }
        (bytes, nodes)
    }
}
