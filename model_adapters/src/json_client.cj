package model_adapters

import json4cj.*
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
    public let input: JsonValue

    public init(kind: ContentBlockKind, id!: String = "", name!: String = "",
        text!: String = "", input!: JsonValue = JsonValue.nullValue()) {
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
    let root = parseJson(raw)
    requireKind(root, JsonKind.Object, "message response")
    let stopReason = optionalStringField(root, "stop_reason")
    let contentValue = requiredField(root, "content")
    requireKind(contentValue, JsonKind.List, "content")
    let blocks = ArrayList<ContentBlock>()
    for (value in contentValue.items) { blocks.add(parseContentBlock(value)) }
    MessageResponse(raw, stopReason, blocks.toArray())
}

func parseContentBlock(value: JsonValue): ContentBlock {
    requireKind(value, JsonKind.Object, "content block")
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

func requiredField(value: JsonValue, name: String): JsonValue {
    match (value.field(name)) {
        case Some(found) => found
        case None => throw JsonParseError("missing field ${name}", 0)
    }
}

func requiredStringField(value: JsonValue, name: String): String {
    let found = requiredField(value, name)
    requireKind(found, JsonKind.Text, name)
    found.text
}

func optionalStringField(value: JsonValue, name: String): String {
    match (value.field(name)) {
        case Some(found) =>
            requireKind(found, JsonKind.Text, name)
            found.text
        case None => ""
    }
}

func requireKind(value: JsonValue, expected: JsonKind, label: String): Unit {
    if (value.kind != expected) { throw JsonParseError("${label} has the wrong JSON type", 0) }
}
