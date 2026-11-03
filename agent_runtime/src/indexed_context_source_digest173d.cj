package agent_runtime

import agent_domain.*
import std.collection.*
import std.overflow.*
import yjson.*
import yjson_support.*

// DATA only: exactly the original contextSourceDigest framing. This writer
// retains only scalar counters; each complete Item remains in its real loan.
// The caller prepays the fixed writer/recursive frames and actual row node SUM
// under the SAME original owner before dispatch. No digest grants a cut.
func ownedThreadDigestMultiply173d(a: Int64, b: Int64): Int64 {
    if (a < 0 || b < 1 || a > Int64.Max / b) { throw IllegalStateException("context digest payment overflow") }; a * b
}
class IndexedContextByteWriter173d {
    var bytes: Int64 = 0
    var hash: UInt64 = 1469598103934665603
    var seen: Int64 = 0
    private let hashing: Bool
    private let fund: (Int64) -> Unit
    init(hashing: Bool, fund: (Int64) -> Unit) { this.hashing = hashing; this.fund = fund }
    func text(value: String): Unit {
        bytes = ownedProjectionAdd(bytes, value.size)
        if (hashing) { for (byte in unsafe { value.rawData() }) {
            hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211) } }
    }
    func prefix(length: Int64): Unit { text(length.toString()); text(":") }
    func frame(value: String): Unit { prefix(value.size); text(value) }
    func value(value: AgentValue): Unit {
        match (value.unifiedKind) {
            case ValueKind.Null => text("n")
            case ValueKind.Boolean => text(if (value.asBool()) { "t" } else { "f" })
            case ValueKind.Number => text("d"); frame(value.asNumberText())
            case ValueKind.Text => text("s"); frame(value.text)
            case ValueKind.List =>
                let array = value.asArray(); text("l"); frame(array.size().toString())
                for (at in 0..array.size()) { this.value(array.get(at).getOrThrow()) }
            case ValueKind.Object =>
                let object = value.asObject(); text("o"); frame(object.size().toString())
                for (at in 0..object.size()) { frame(object.nameAt(at)); this.value(object.valueAt(at)) }
        }
    }
    func parts(parts: Array<ThreadMessagePart>): Unit {
        frame(parts.size.toString())
        for (part in parts) { match (part) {
            case ThreadMessagePart.Text(value) => text("text"); frame(value)
            case ThreadMessagePart.Refusal(value) => text("refusal"); frame(value)
            case ThreadMessagePart.Image(image) => text("image")
                frame(match (image.sourceKind) {
                    case ThreadImageSourceKind.Url => "url"
                    case ThreadImageSourceKind.Base64 => "base64"
                    case ThreadImageSourceKind.Artifact => "artifact" })
                frame(image.data); frame(image.mediaType) } }
    }
    func content(content: ThreadItemContent): Unit {
        match (content) {
            case ThreadItemContent.UserMessage(parts) => text("user"); this.parts(parts)
            case ThreadItemContent.AssistantMessage(parts) => text("assistant"); this.parts(parts)
            case ThreadItemContent.ToolCall(call, name, value) => text("call"); frame(call.value); frame(name); this.value(value)
            case ThreadItemContent.ToolResult(call, operation, receipt, value, error) =>
                text("result"); frame(call.value); frame(operation.value); frame(receipt); this.value(value); text(if (error) { "t" } else { "f" })
            case ThreadItemContent.ReasoningReference(reference, summary) => text("reasoning"); frame(reference); frame(summary)
            case ThreadItemContent.ProviderOpaqueItem(state) => text("opaque"); frame(state.providerId); frame(state.protocol)
                frame(state.itemId); frame(state.payload); text(if (state.replayRequired) { "t" } else { "f" })
            case ThreadItemContent.ArtifactReference(hash, mime, size) => text("artifact"); frame(hash); frame(mime); frame(size.toString())
            case ThreadItemContent.SystemNote(value) => text("system"); frame(value)
        }
    }
    // The original provenance additions use canonicalAgentValue rather than
    // contextValue. Preserve its sorted-field order and nested child frames.
    func canonical(value: AgentValue): Unit {
        match (value.unifiedKind) {
            case ValueKind.Null => text("null")
            case ValueKind.Boolean => text(if (value.asBool()) { "true" } else { "false" })
            case ValueKind.Number => text("n"); frame(value.asNumberText())
            case ValueKind.Text => text("s"); frame(value.text)
            case ValueKind.List =>
                let array = value.asArray(); text("[")
                for (at in 0..array.size()) { canonicalFrame(array.get(at).getOrThrow()) }; text("]")
            case ValueKind.Object => text("{")
                let object = value.asObject()
                // Stable (name,index) order, exactly canonicalAgentValue,
                // with scalar state only. Indexed borrowed access constructs
                // neither a field snapshot nor a width-dependent bitmap.
                fund(65536)
                var previous: Int64 = -1
                for (_ in 0..object.size()) {
                    var selected: Int64 = -1
                    for (at in 0..object.size()) {
                        let afterPrevious = previous < 0 || object.nameAt(at) > object.nameAt(previous) ||
                            (object.nameAt(at) == object.nameAt(previous) && at > previous)
                        if (afterPrevious && (selected < 0 || object.nameAt(at) < object.nameAt(selected) ||
                            (object.nameAt(at) == object.nameAt(selected) && at < selected))) { selected = at }
                    }
                    if (selected < 0) { throw IllegalStateException("canonical field order is inconsistent") }
                    frame(object.nameAt(selected)); canonicalFrame(object.valueAt(selected)); previous = selected
                }
                text("}")
        }
    }
    func canonicalFrame(value: AgentValue): Unit {
        let measure = IndexedContextByteWriter173d(false, fund); measure.canonical(value)
        prefix(measure.bytes); canonical(value)
    }
    func item(item: ThreadItem): Unit {
        frame(item.id.value); frame(item.turnId.value); frame(item.ordinal.toString())
        let measure = IndexedContextByteWriter173d(false, fund); measure.content(item.content)
        prefix(measure.bytes); content(item.content)
        frame(item.provenance.source)
        frame(match (item.provenance.runId) { case Some(value) => value.value; case None => "" })
        frame(match (item.provenance.operationId) { case Some(value) => value.value; case None => "" })
        frame(item.createdAtMillis.toString())
        match (item.provenance.continuationOrigin) {
            case Some(origin) => canonicalFrame(continuationRunOriginValue(origin)); case None => () }
        match (item.provenance.continuationHistory) {
            case Some(history) => canonicalFrame(continuationHistorySourceValue(history)); case None => () }
        match(item.provenance.completedInitiatorHistory173e){
            case Some(history)=>canonicalFrame(completedInitiatorHistoryValue173e(history));case None=>()}
    }
}

public class OwnedContextPrefixDigest173d {
    private let writer: IndexedContextByteWriter173d
    private let cover: Int64
    public init(thread: ThreadId, cover: Int64, fund: (Int64) -> Unit) {
        if (cover < 1) { throw IllegalArgumentException("context source digest cover is outside canonical history") }
        fund(65536)
        this.writer = IndexedContextByteWriter173d(true, fund); this.cover = cover
        writer.frame(thread.value); writer.frame(cover.toString())
    }
    public func consumeItem173d(item: ThreadItem): Unit {
        if (item.ordinal <= cover) {
            if (item.ordinal != writer.seen + 1) { throw IllegalStateException("canonical Thread prefix is not ordinal-complete") }
            writer.item(item); writer.seen++
        }
    }
    public func finish173d(): String {
        if (writer.seen != cover) { throw IllegalStateException("canonical Thread prefix is not ordinal-complete") }
        "fnv1a64-v1:" + writer.hash.toString()
    }
}
