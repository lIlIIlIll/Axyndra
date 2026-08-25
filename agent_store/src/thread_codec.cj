package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*

// SQLite payloads use a byte-length-framed canonical value encoding. It is
// deliberately independent from provider and App Protocol JSON so durable
// recovery never needs a model adapter or transport package.
public func encodeStoredValue(value: AgentValue): String {
    let output = ArrayList<Byte>()
    appendStoredValue(output, value)
    String.fromUtf8(output.toArray())
}

func appendStoredValue(output: ArrayList<Byte>, value: AgentValue): Unit {
    match (value.kind) {
        case ValueKind.Null => output.add(b'n')
        case ValueKind.Boolean => output.add(if (value.boolean) { b't' } else { b'f' })
        case ValueKind.Number =>
            output.add(b'd')
            appendStoredFrame(output, value.number)
        case ValueKind.Text =>
            output.add(b's')
            appendStoredFrame(output, value.text)
        case ValueKind.List =>
            output.add(b'l')
            appendStoredFrame(output, value.items.size.toString())
            for (item in value.items) { appendStoredValue(output, item) }
        case ValueKind.Object =>
            output.add(b'o')
            appendStoredFrame(output, value.fields.size.toString())
            for (field in value.fields) {
                appendStoredFrame(output, field.name)
                appendStoredValue(output, field.value)
            }
    }
}

func appendStoredFrame(output: ArrayList<Byte>, value: String): Unit {
    let bytes = unsafe { value.rawData() }
    for (byte in bytes.size.toString().toArray()) { output.add(byte) }
    output.add(b':')
    for (byte in bytes) { output.add(byte) }
}

public func decodeStoredValue(source: String): AgentValue {
    StoredValueParser(source).parse()
}

public func encodeStoredThreadContent(content: ThreadItemContent): String {
    let value: AgentValue = match (content) {
        case ThreadItemContent.UserMessage(parts) => objectValue([
            ValueField("kind", textValue("user_message")),
            ValueField("parts", storedMessageParts(parts))
        ])
        case ThreadItemContent.AssistantMessage(parts) => objectValue([
            ValueField("kind", textValue("assistant_message")),
            ValueField("parts", storedMessageParts(parts))
        ])
        case ThreadItemContent.ToolCall(callId, name, arguments) => objectValue([
            ValueField("kind", textValue("tool_call")),
            ValueField("call_id", textValue(callId.value)),
            ValueField("name", textValue(name)),
            ValueField("arguments", arguments)
        ])
        case ThreadItemContent.ToolResult(callId, operationId, receiptId, result, isError) => objectValue([
            ValueField("kind", textValue("tool_result")),
            ValueField("call_id", textValue(callId.value)),
            ValueField("operation_id", textValue(operationId.value)),
            ValueField("receipt_id", textValue(receiptId)),
            ValueField("result", result),
            ValueField("is_error", boolValue(isError))
        ])
        case ThreadItemContent.ReasoningReference(referenceId, summary) => objectValue([
            ValueField("kind", textValue("reasoning_reference")),
            ValueField("reference_id", textValue(referenceId)),
            ValueField("summary", textValue(summary))
        ])
        case ThreadItemContent.ProviderOpaqueItem(state) => objectValue([
            ValueField("kind", textValue("provider_opaque")),
            ValueField("provider_id", textValue(state.providerId)),
            ValueField("protocol", textValue(state.protocol)),
            ValueField("item_id", textValue(state.itemId)),
            ValueField("payload", textValue(state.payload)),
            ValueField("replay_required", boolValue(state.replayRequired))
        ])
        case ThreadItemContent.ArtifactReference(hash, mimeType, size) => objectValue([
            ValueField("kind", textValue("artifact_reference")),
            ValueField("hash", textValue(hash)),
            ValueField("mime", textValue(mimeType)),
            ValueField("size", integerValue(size))
        ])
        case ThreadItemContent.SystemNote(value) => objectValue([
            ValueField("kind", textValue("system_note")),
            ValueField("value", textValue(value))
        ])
    }
    encodeStoredValue(value)
}

public func decodeStoredThreadContent(source: String): ThreadItemContent {
    let value = decodeStoredValue(source)
    let kind = storedTextField(value, "kind")
    match (kind) {
        case "user_message" => ThreadItemContent.UserMessage(
            decodeStoredMessageParts(storedField(value, "parts"))
        )
        case "assistant_message" => ThreadItemContent.AssistantMessage(
            decodeStoredMessageParts(storedField(value, "parts"))
        )
        case "tool_call" => ThreadItemContent.ToolCall(
            CanonicalToolCallId(storedTextField(value, "call_id")),
            storedTextField(value, "name"),
            storedField(value, "arguments")
        )
        case "tool_result" => ThreadItemContent.ToolResult(
            CanonicalToolCallId(storedTextField(value, "call_id")),
            OperationId(storedTextField(value, "operation_id")),
            storedTextField(value, "receipt_id"),
            storedField(value, "result"),
            storedBoolField(value, "is_error")
        )
        case "reasoning_reference" => ThreadItemContent.ReasoningReference(
            storedTextField(value, "reference_id"), storedTextField(value, "summary")
        )
        case "provider_opaque" => ThreadItemContent.ProviderOpaqueItem(
            OpaqueProviderState(
                storedTextField(value, "provider_id"),
                storedTextField(value, "protocol"),
                storedTextField(value, "payload"),
                itemId: storedTextField(value, "item_id"),
                replayRequired: storedBoolField(value, "replay_required")
            )
        )
        case "artifact_reference" => ThreadItemContent.ArtifactReference(
            storedTextField(value, "hash"), storedTextField(value, "mime"),
            storedIntField(value, "size")
        )
        case "system_note" => ThreadItemContent.SystemNote(storedTextField(value, "value"))
        case _ => throw IllegalStateException("unknown stored Thread item kind: " + kind)
    }
}

public func encodeStoredProvenance(provenance: ItemProvenance): String {
    encodeStoredValue(objectValue([
        ValueField("source", textValue(provenance.source)),
        ValueField("run_id", match (provenance.runId) {
            case Some(value) => textValue(value.value)
            case None => nullValue()
        }),
        ValueField("operation_id", match (provenance.operationId) {
            case Some(value) => textValue(value.value)
            case None => nullValue()
        })
    ]))
}

public func decodeStoredProvenance(source: String): ItemProvenance {
    let value = decodeStoredValue(source)
    ItemProvenance(
        storedTextField(value, "source"),
        runId: storedOptionalRunId(value),
        operationId: storedOptionalOperationId(value)
    )
}

func storedOptionalRunId(value: AgentValue): ?RunId {
    let candidate = storedField(value, "run_id")
    if (candidate.kind == ValueKind.Null) {
        None
    } else {
        Some(RunId(storedText(candidate, "run_id")))
    }
}

func storedOptionalOperationId(value: AgentValue): ?OperationId {
    let candidate = storedField(value, "operation_id")
    if (candidate.kind == ValueKind.Null) {
        None
    } else {
        Some(OperationId(storedText(candidate, "operation_id")))
    }
}

func storedMessageParts(parts: Array<ThreadMessagePart>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (part in parts) {
        let value: AgentValue = match (part) {
            case ThreadMessagePart.Text(value) => objectValue([
                ValueField("kind", textValue("text")), ValueField("value", textValue(value))
            ])
            case ThreadMessagePart.Refusal(value) => objectValue([
                ValueField("kind", textValue("refusal")), ValueField("value", textValue(value))
            ])
            case ThreadMessagePart.Image(image) => objectValue([
                ValueField("kind", textValue("image")),
                ValueField("source", textValue(match (image.sourceKind) {
                    case ThreadImageSourceKind.Url => "url"
                    case ThreadImageSourceKind.Base64 => "base64"
                    case ThreadImageSourceKind.Artifact => "artifact"
                })),
                ValueField("data", textValue(image.data)),
                ValueField("media_type", textValue(image.mediaType))
            ])
        }
        values.add(value)
    }
    listValue(values.toArray())
}

func decodeStoredMessageParts(value: AgentValue): Array<ThreadMessagePart> {
    if (value.kind != ValueKind.List) {
        throw IllegalStateException("stored Thread message parts are not a list")
    }
    let parts = ArrayList<ThreadMessagePart>()
    for (part in value.items) {
        let kind = storedTextField(part, "kind")
        let decoded: ThreadMessagePart = match (kind) {
            case "text" => ThreadMessagePart.Text(storedTextField(part, "value"))
            case "refusal" => ThreadMessagePart.Refusal(storedTextField(part, "value"))
            case "image" => ThreadMessagePart.Image(ThreadImage(
                match (storedTextField(part, "source")) {
                    case "url" => ThreadImageSourceKind.Url
                    case "base64" => ThreadImageSourceKind.Base64
                    case "artifact" => ThreadImageSourceKind.Artifact
                    case source => throw IllegalStateException("unknown stored image source: " + source)
                },
                storedTextField(part, "data"),
                mediaType: storedTextField(part, "media_type")
            ))
            case _ => throw IllegalStateException("unknown stored message part: " + kind)
        }
        parts.add(decoded)
    }
    parts.toArray()
}

func storedField(value: AgentValue, name: String): AgentValue {
    if (value.kind != ValueKind.Object) {
        throw IllegalStateException("stored value is not an object")
    }
    match (value.field(name)) {
        case Some(field) => field
        case None => throw IllegalStateException("stored value is missing field: " + name)
    }
}

func storedTextField(value: AgentValue, name: String): String {
    storedText(storedField(value, name), name)
}

func storedText(value: AgentValue, name: String): String {
    if (value.kind != ValueKind.Text) {
        throw IllegalStateException("stored field is not text: " + name)
    }
    value.text
}

func storedBoolField(value: AgentValue, name: String): Bool {
    let field = storedField(value, name)
    if (field.kind != ValueKind.Boolean) {
        throw IllegalStateException("stored field is not boolean: " + name)
    }
    field.boolean
}

func storedIntField(value: AgentValue, name: String): Int64 {
    let field = storedField(value, name)
    if (field.kind != ValueKind.Number) {
        throw IllegalStateException("stored field is not numeric: " + name)
    }
    parseStoredInt(field.number, "stored field is not an integer: " + name)
}

class StoredValueParser {
    let data: Array<Byte>
    var offset: Int64 = 0

    init(source: String) {
        data = unsafe { source.rawData() }
        if (data.size > 8388608) {
            throw IllegalStateException("stored value exceeds 8 MiB")
        }
    }

    func parse(): AgentValue {
        let value = parseValue(0)
        if (offset != data.size) {
            throw IllegalStateException("stored value has trailing bytes")
        }
        value
    }

    func parseValue(depth: Int64): AgentValue {
        if (depth > 64 || offset >= data.size) {
            throw IllegalStateException("stored value is truncated or too deeply nested")
        }
        let tag = data[offset]
        offset += 1
        match (tag) {
            case b'n' => nullValue()
            case b't' => boolValue(true)
            case b'f' => boolValue(false)
            case b'd' => numberValue(readFrame())
            case b's' => textValue(readFrame())
            case b'l' =>
                let count = readCount()
                let values = ArrayList<AgentValue>()
                for (_ in 0..count) { values.add(parseValue(depth + 1)) }
                listValue(values.toArray())
            case b'o' =>
                let count = readCount()
                let fields = ArrayList<ValueField>()
                for (_ in 0..count) {
                    let name = readFrame()
                    for (field in fields where field.name == name) {
                        throw IllegalStateException("stored object has duplicate field: " + name)
                    }
                    fields.add(ValueField(name, parseValue(depth + 1)))
                }
                objectValue(fields.toArray())
            case _ => throw IllegalStateException("stored value has an unknown type tag")
        }
    }

    func readCount(): Int64 {
        let text = readFrame()
        let count = parseStoredInt(text, "stored collection count is invalid")
        if (count < 0 || count > 1000000) {
            throw IllegalStateException("stored collection count is out of bounds")
        }
        count
    }

    func readFrame(): String {
        let start = offset
        while (offset < data.size && data[offset] >= b'0' && data[offset] <= b'9') {
            offset += 1
        }
        if (start == offset || offset >= data.size || data[offset] != b':') {
            throw IllegalStateException("stored value has an invalid length frame")
        }
        let lengthText = String.fromUtf8(data[start..offset])
        offset += 1
        let length = parseStoredInt(lengthText, "stored value frame length is invalid")
        if (length < 0 || offset + length > data.size) {
            throw IllegalStateException("stored value frame is truncated")
        }
        let value = String.fromUtf8(data[offset..offset + length])
        offset += length
        value
    }
}

func parseStoredInt(source: String, message: String): Int64 {
    try {
        Int64.parse(source)
    } catch (_: Exception) {
        throw IllegalStateException(message)
    }
}
