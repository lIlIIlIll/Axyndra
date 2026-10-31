package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import yjson.*
import std.convert.*

// Original-bank DATA accounting only. Canonical framing is the original
// protocol_values.cj grammar, not JSON and not a newly selected codec.
// The retained/copy invoice is conservative; it is not encoded JSON size.
public class ToolSnapshotMeasure159 {
    private let payment: LogicalJsonOwnerReservation
    private var invoice: Int64 = 131072
    private var pathPeak: Int64 = 0
    public init(payment: LogicalJsonOwnerReservation, priorInvoice!: Int64 = 131072) {
        if (priorInvoice < 131072) { throw LogicalJsonPayloadError("invalid prior snapshot invoice") }
        this.payment = payment; this.invoice = priorInvoice
    }
    public func retainedInvoice159(): Int64 { add(invoice, pathPeak) }
    private func add(left: Int64, right: Int64): Int64 {
        if (left < 0 || right < 0 || right > Int64.Max - left) {
            throw LogicalJsonPayloadError("tool snapshot invoice overflow")
        }
        left + right
    }
    private func mul(value: Int64, factor: Int64): Int64 {
        if (value < 0 || factor < 1 || value > Int64.Max / factor) {
            throw LogicalJsonPayloadError("tool snapshot invoice overflow")
        }
        value * factor
    }
    private func frame159(bytes: Int64): Int64 { add(add(bytes, bytes.toString().size), 1) }
    public func addSlots159(count: Int64): Unit { invoice = add(invoice, mul(count, 128)) }
    public func addText159(value: String): Unit {
        invoice = add(invoice, add(1024, mul(value.size, 32)))
    }
    public func addCapability159(value: Capability): Unit {
        invoice = add(invoice, 4096); addText159(value.resource)
    }
    public func addHook159(value: ToolHookHandlerSnapshot): Unit {
        invoice = add(invoice, 16384)
        addText159(value.event); addText159(value.pluginId); addText159(value.pluginVersion)
        addText159(value.contentDigest); addText159(value.packageRoot); addText159(value.matcher)
        addText159(value.command)
    }
    private func scalar159(value: AgentValue): Int64 {
        if (value.isNull) { return 4 }
        try {
            let text = value.asString()
            invoice = add(invoice, mul(text.size, 16))
            return add(1, frame159(text.size))
        } catch (error: JsonException) { if (error.code != "type_mismatch") { throw error } }
        try { return if (value.asBool()) { 4 } else { 5 } }
        catch (error: JsonException) { if (error.code != "type_mismatch") { throw error } }
        try {
            // The pinned accessor borrows an existing literal spelling. Only
            // Int64/UInt64 (at most 20 bytes) and Float64 format new text; the
            // SDK Float64 C formatter has a fixed 512-byte buffer. Pay its
            // buffer, copies and headers before calling it, then charge the
            // actual UTF8 spelling below before any canonical/copy producer.
            // This invoice is not the unchanged one-MiB text/codec bound.
            payment.ensureRetainedPeak(add(add(invoice, pathPeak), 4096 + 512 * 16))
            let text = value.asNumberText()
            invoice = add(invoice, mul(text.size, 16))
            return add(1, frame159(text.size))
        } catch (error: JsonException) { if (error.code != "type_mismatch") { throw error } }
        throw JsonException("Unsupported JsonNode implementation")
    }
    private func canonicalWork159(bytes: Int64): Unit {
        // SUM complete subtree frames, including repeated DAG occurrences.
        // This pays simultaneous parent/child canonical Strings, concatenation,
        // UTF8/hash copies and the surrounding fixed lane/entry DOM layers.
        invoice = add(invoice, mul(frame159(bytes), 16))
    }
    private func prepayPath159(depth: Int64): Unit {
        let extent = mul(depth, 1024)
        if (extent > pathPeak) { pathPeak = extent }
        payment.ensureRetainedPeak(add(invoice, pathPeak))
    }
    private func rejectAncestor159(value: AgentValue, head: ?ToolSnapshotPath159): Unit {
        var cursor = head
        while (cursor.isSome()) {
            let item = cursor.getOrThrow()
            if (refEq(item.value.getOrThrow(), value)) {
                throw JsonException("Cyclic JsonNode graph is not supported", code: "cyclic_json_node")
            }
            cursor = item.previous
        }
    }
    public func addValue159(value: AgentValue): Unit {
        var current: ?AgentValue = Some(value)
        var head: ?ToolSnapshotPath159 = Option<ToolSnapshotPath159>.None
        var depth: Int64 = 0
        try {
            while (true) {
                match (current) {
                    case Some(actual) =>
                        current = Option<AgentValue>.None
                        invoice = add(invoice, 512)
                        match (actual) {
                            case array: JsonArray =>
                                rejectAncestor159(actual, head); addSlots159(array.size())
                                prepayPath159(add(depth, 1))
                                head = Some(ToolSnapshotPath159(actual, head)); depth++
                            case object: JsonObject =>
                                rejectAncestor159(actual, head); addSlots159(mul(object.size(), 2))
                                prepayPath159(add(depth, 1))
                                head = Some(ToolSnapshotPath159(actual, head)); depth++
                            case _ =>
                                let bytes = scalar159(actual); canonicalWork159(bytes)
                                match (head) {
                                    case Some(parent) => parent.bytes = add(parent.bytes, frame159(bytes))
                                    case None => return
                                }
                        }
                    case None =>
                        match (head) {
                            case None => return
                            case Some(frame) =>
                                var next: ?AgentValue = Option<AgentValue>.None
                                match (frame.value.getOrThrow()) {
                                    case array: JsonArray => if (frame.index < array.size()) {
                                        next = array.get(frame.index); frame.index++
                                    }
                                    case object: JsonObject => if (frame.index < object.size()) {
                                        let name = object.nameAt(frame.index)
                                        invoice = add(invoice, add(512, mul(name.size, 16)))
                                        frame.bytes = add(frame.bytes, frame159(name.size))
                                        next = Some(object.valueAt(frame.index)); frame.index++
                                    }
                                    case _ => throw JsonException("Unsupported JsonNode implementation")
                                }
                                if (next.isSome()) { current = next }
                                else {
                                    let bytes = frame.bytes; canonicalWork159(bytes)
                                    head = frame.previous
                                    frame.value = Option<AgentValue>.None
                                    frame.previous = Option<ToolSnapshotPath159>.None
                                    depth--
                                    match (head) {
                                        case Some(parent) => parent.bytes = add(parent.bytes, frame159(bytes))
                                        case None => return
                                    }
                                }
                        }
                }
            }
        } finally {
            current = Option<AgentValue>.None
            while (head.isSome()) {
                let frame = head.getOrThrow(); head = frame.previous
                frame.value = Option<AgentValue>.None
                frame.previous = Option<ToolSnapshotPath159>.None
            }
        }
    }
    public func addSnapshot159(value: ToolSetSnapshot): Unit {
        addText159(value.id)
        match (value.threadId) { case Some(thread) => addText159(thread.value); case None => () }
        addSlots159(value.entries.size); addSlots159(value.hookHandlers.size)
        for (entry in value.entries) {
            addText159(entry.name); addText159(entry.description); addValue159(entry.inputSchema)
            addText159(entry.executorVersion); addText159(entry.implementationFingerprint); addText159(entry.schemaDigest)
            addSlots159(entry.requiredCapabilities.size)
            for (capability in entry.requiredCapabilities) { addCapability159(capability) }
        }
        for (handler in value.hookHandlers) { addHook159(handler) }
    }
    public func addModelRequest159(value: ModelRequest): Unit {
        // Walk actual retained fields before request callbacks/Futures or the
        // provider's repeated whole-input codec copies can be constructed.
        addText159(value.model); addText159(value.system)
        addText159(value.requestId); addText159(value.serviceTier); addText159(value.cacheKey)
        addSlots159(value.messages.size); addSlots159(value.tools.size)
        for (message in value.messages) {
            addSlots159(message.blocks.size)
            for (block in message.blocks) {
                addText159(block.text); addText159(block.callId); addText159(block.name)
                addText159(block.receiptId); addValue159(block.arguments)
                match (block.image) {
                    case Some(image) => addText159(image.data); addText159(image.mediaType)
                    case None => ()
                }
                match (block.opaqueState) {
                    case Some(opaque) =>
                        addText159(opaque.providerId); addText159(opaque.protocol)
                        addText159(opaque.itemId); addText159(opaque.payload)
                    case None => ()
                }
            }
        }
        for (tool in value.tools) {
            addText159(tool.name); addText159(tool.description); addValue159(tool.inputSchema)
        }
        match (value.structuredOutput) {
            case Some(output) =>
                addText159(output.name); addText159(output.description); addValue159(output.schema)
            case None => ()
        }
        match (value.resolvedPolicy) {
            case Some(policy) =>
                addText159(policy.capabilityFingerprint); addText159(policy.capabilitySnapshotPayload)
                addSlots159(policy.thinking.constraints.size); addSlots159(policy.output.constraints.size)
            case None => ()
        }
    }
    public func fund159(): Unit { payment.ensureRetainedPeak(add(invoice, pathPeak)) }
}
private class ToolSnapshotPath159 {
    var value: ?AgentValue
    var previous: ?ToolSnapshotPath159
    var index: Int64 = 0
    var bytes: Int64 = 2
    init(value: AgentValue, previous: ?ToolSnapshotPath159) {
        this.value = Some(value); this.previous = previous
    }
}
