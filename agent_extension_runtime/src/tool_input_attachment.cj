package agent_extension_runtime

import agent_sdk.*
import std.convert.*
import std.collection.*
import yjson.*
import yjson_support.*

// Shared manifest/ready metadata parser. Invalid/unknown shapes are rejected
// before a native process can become a mounted contribution.
func nativeToolInputAttachmentMetadata(value: JsonNode): ?(String, Int64) {
    if (value.unifiedKind != UnifiedJsonKind.Object || value.fields.size != 2 ||
        value.field("field").isNone() || value.field("max_bytes").isNone()) { return None }
    let field = value.field("field").getOrThrow()
    let limit = value.field("max_bytes").getOrThrow()
    if (field.unifiedKind != UnifiedJsonKind.Text || limit.unifiedKind != UnifiedJsonKind.Number) { return None }
    try {
        let bytes = Int64.parse(limit.asNumberText())
        if (field.text == "" || !validPluginInputAttachmentDeclaration(field.text, bytes) ||
            bytes.toString() != limit.asNumberText()) { return None }
        Some((field.text, bytes))
    } catch (_: Exception) { None }
}

func nativeContributionWithoutInputAttachment(value: JsonNode): JsonNode {
    let fields = ArrayList<JsonObjectEntry>()
    for (field in value.fields where field.name != "input_attachment") {
        fields.add(JsonObjectEntry(field.name, field.value))
    }
    jsonObject(fields.toArray())
}

func nativeInputAttachmentFieldCount(value: JsonNode): Int64 {
    var count: Int64 = 0
    for (field in value.fields where field.name == "input_attachment") { count++ }
    count
}
