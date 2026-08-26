package model_adapters

import yjson.*
import yjson_support.*
import std.collection.*
import std.deriving.*

@Derive[Equatable]
public enum ContentBlockKind {
    Text | Thinking | ToolUse | ToolResult | Unknown
}

public class ContentBlock {
    public let kind: ContentBlockKind
    public let id: String
    public let name: String
    public let text: String
    public let input: JsonNode

    public init(kind: ContentBlockKind, id!: String = "", name!: String = "",
        text!: String = "", input!: JsonNode = jsonNull()) {
        this.kind = kind
        this.id = id
        this.name = name
        this.text = text
        this.input = input
    }
}

public class MessageResponse {
    public let raw: String
    public let stopReason: String
    public let content: Array<ContentBlock>

    public init(raw: String, stopReason: String, content: Array<ContentBlock>) {
        this.raw = raw
        this.stopReason = stopReason
        this.content = content
    }

    // Compatibility adapters keep lesson code focused on the agent loop. New
    // infrastructure code should use `content` directly.
    public func toolUseIndex(from: Int64): Int64 { nextToolUseIndex(raw, from) }

    public func text(): String {
        var result = ""
        for (block in content where block.kind == ContentBlockKind.Text) {
            result += block.text
        }
        result
    }
}

public func parseMessageResponse(raw: String): MessageResponse {
    let root = parseUnifiedJson(raw)
    requireKind(root, UnifiedJsonKind.Object, "message response")
    let stopReason = optionalStringField(root, "stop_reason")
    let contentValue = requiredField(root, "content")
    requireKind(contentValue, UnifiedJsonKind.List, "content")
    let blocks = ArrayList<ContentBlock>()
    for (value in contentValue.items) { blocks.add(parseContentBlock(value)) }
    MessageResponse(raw, stopReason, blocks.toArray())
}

func parseContentBlock(value: JsonNode): ContentBlock {
    requireKind(value, UnifiedJsonKind.Object, "content block")
    let blockType = requiredStringField(value, "type")
    match (blockType) {
        case "text" => ContentBlock(ContentBlockKind.Text, text: requiredStringField(value, "text"))
        case "thinking" => ContentBlock(
            ContentBlockKind.Thinking,
            text: optionalStringField(value, "thinking"),
            input: value
        )
        case "redacted_thinking" => ContentBlock(ContentBlockKind.Thinking, input: value)
        case "tool_use" => ContentBlock(
            ContentBlockKind.ToolUse,
            id: requiredStringField(value, "id"),
            name: requiredStringField(value, "name"),
            input: requiredField(value, "input")
        )
        case "tool_result" => ContentBlock(
            ContentBlockKind.ToolResult,
            id: requiredStringField(value, "tool_use_id"),
            text: requiredStringField(value, "content")
        )
        case _ => ContentBlock(ContentBlockKind.Unknown, name: blockType, input: value)
    }
}

func requiredField(value: JsonNode, name: String): JsonNode {
    match (value.field(name)) {
        case Some(found) => found
        case None => throw JsonException("missing field ${name}", code: "missing_field")
    }
}

func requiredStringField(value: JsonNode, name: String): String {
    let found = requiredField(value, name)
    requireKind(found, UnifiedJsonKind.Text, name)
    found.text
}

func optionalStringField(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(found) =>
            requireKind(found, UnifiedJsonKind.Text, name)
            found.text
        case None => ""
    }
}

func requireKind(value: JsonNode, expected: UnifiedJsonKind, label: String): Unit {
    if (value.unifiedKind != expected) {
        throw JsonException("${label} has the wrong JSON type", code: "type_mismatch")
    }
}
