package model_provider_runtime

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// A reference is only a serialization optimization. It names a contiguous
// range of text already received by this one ProviderStream, never a file,
// artifact, another Attempt or a resource with independent authority.
public func modelProviderStreamReplyValue(reply: ModelReply): AgentValue {
    if (reply.blocks.size > 4096) { throw IllegalArgumentException("too many model output blocks") }
    let blocks = ArrayList<ModelBlock>(); let references = ArrayList<AgentValue>()
    var textOffset: Int64 = 0; var reasoningOffset: Int64 = 0; var index: Int64 = 0
    for (block in reply.blocks) {
        let referenced = block.kind == ModelBlockKind.Text || block.kind == ModelBlockKind.Reasoning
        if (referenced) {
            let isText = block.kind == ModelBlockKind.Text
            references.add(objectValue([ValueField("block_index", integerValue(index)),
                ValueField("kind", textValue(if (isText) { "text" } else { "reasoning" })),
                ValueField("offset", integerValue(if (isText) { textOffset } else { reasoningOffset })),
                ValueField("length", integerValue(block.text.size)),
                ValueField("sha256", textValue(modelPolicySha256Text(block.text)))]))
            if (isText) { textOffset += block.text.size } else { reasoningOffset += block.text.size }
        }
        blocks.add(ModelBlock(block.kind, text: if (referenced) { "" } else { block.text },
            callId: block.callId, name: block.name, arguments: block.arguments, isError: block.isError,
            image: block.image, receiptId: block.receiptId, opaqueState: block.opaqueState))
        index++
    }
    objectValue([ValueField("schema", textValue("axyndra.model-stream-reply/v1")),
        ValueField("reply", modelProviderReplyWithBlocks(reply, blocks.toArray())),
        ValueField("references", listValue(references.toArray()))])
}

func restoreModelProviderStreamReply(value: AgentValue, text: String, reasoning: String): AgentValue {
    providerExact(value, ["schema", "reply", "references"])
    if (providerText(value, "schema") != "axyndra.model-stream-reply/v1") {
        throw IllegalArgumentException("invalid streamed model reply schema")
    }
    let reply = providerField(value, "reply")
    let blocks = providerField(reply, "blocks"); let references = providerField(value, "references")
    if (blocks.unifiedKind != ValueKind.List || references.unifiedKind != ValueKind.List ||
        blocks.items.size > 4096 || references.items.size > blocks.items.size) {
        throw IllegalArgumentException("invalid streamed model reply references")
    }
    let textBytes = text.toArray(); let reasoningBytes = reasoning.toArray()
    var textOffset: Int64 = 0; var reasoningOffset: Int64 = 0
    var referenceIndex: Int64 = 0; var index: Int64 = 0
    for (block in blocks.items) {
        let kind = providerText(block, "kind")
        if (kind == "text" || kind == "reasoning") {
            if (providerText(block, "text") != "" || referenceIndex >= references.items.size) {
                throw IllegalArgumentException("stream reply text must have exactly one reference")
            }
            let reference = references.items[referenceIndex]
            providerExact(reference, ["block_index", "kind", "offset", "length", "sha256"])
            let source = if (kind == "text") { textBytes } else { reasoningBytes }
            let offset = providerInt(reference, "offset"); let length = providerInt(reference, "length")
            let expected = if (kind == "text") { textOffset } else { reasoningOffset }
            if (providerInt(reference, "block_index") != index || providerText(reference, "kind") != kind ||
                offset != expected || offset < 0 || length < 0 || offset > source.size || length > source.size - offset) {
                throw IllegalArgumentException("stream reply ranges must be ordered and contiguous")
            }
            // String construction rejects references splitting UTF-8 scalars.
            let restored = String.fromUtf8(source[offset..offset + length])
            if (modelPolicySha256Text(restored) != providerText(reference, "sha256")) {
                throw IllegalArgumentException("stream reply text digest changed")
            }
            block.put("text", textValue(restored))
            if (kind == "text") { textOffset += length } else { reasoningOffset += length }
            referenceIndex++
        }
        index++
    }
    if (referenceIndex != references.items.size || textOffset != text.size || reasoningOffset != reasoning.size) {
        throw IllegalArgumentException("stream reply must cover all observed text exactly once")
    }
    // Existing neutral block decoding and ProviderStream.validateReply still
    // check output kinds, tools, usage, identity and terminal evidence.
    reply
}
