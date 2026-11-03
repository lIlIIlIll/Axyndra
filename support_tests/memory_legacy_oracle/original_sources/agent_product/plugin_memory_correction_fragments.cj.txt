package agent_product

import agent_domain.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

class ProductMemoryCorrectionFragments {
    private let query: (AgentValue) -> Result<AgentValue>
    private let current: MemoryV3Record
    private let changes: AgentValue
    private let raw: AgentValue
    private let digest: String
    private var sequence: Int64 = 0
    init(current: MemoryV3Record, changes: AgentValue, query: (AgentValue) -> Result<AgentValue>) {
        if (changes.unifiedKind != ValueKind.Object || changes.fields.size < 1 || changes.fields.size > 7) {
            throw IllegalArgumentException("bounded correction fields required") }
        let copied = ArrayList<ValueField>()
        for (field in changes.fields) {
            copied.add(ValueField(field.name, if (field.value.unifiedKind == ValueKind.Text) { textValue(field.value.text) }
                else if (field.value.unifiedKind == ValueKind.Number) { numberValue(field.value.asNumberText()) }
                else { throw IllegalArgumentException("scalar correction fields required") }))
        }
        let frozen = objectValue(copied.toArray())
        this.current = current; this.changes = frozen; this.query = query
        let record = productMemoryPolicyRecord(current)
        this.raw = record
        this.digest = modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("current", record), ValueField("changes", frozen)])))
    }
    private func request(action: String, fields: Array<ValueField>): Result<AgentValue> {
        sequence++; let page = sequence.toString()
        let input = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue(action)),
            ValueField("snapshot_digest", textValue(digest)), ValueField("page_id", textValue(page))])
        input.add(all: fields)
        let response = match (query(objectValue(input.toArray()))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (httpIntentText(response, "snapshot_digest") != digest || httpIntentText(response, "page_id") != page) {
            return productPolicySelectionError("memory.fragment_identity") }
        Result.Ok(response)
    }
    private func reference(name: String, value: AgentValue, source: String): AgentValue {
        if (["content", "context", "scope_key"].contains(name)) {
            if (value.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("correction text field required") }
            return objectValue([ValueField("source", textValue(source)), ValueField("field", textValue(name)),
                ValueField("sha256", textValue(modelPolicySha256Text(value.text))), ValueField("bytes", integerValue(value.text.size))])
        }
        value
    }
    func correction(): Result<AgentValue> {
        try { correctInternal() } catch (_: Exception) { productPolicySelectionError("memory.policy_correction_invalid") }
    }
    private func correctInternal(): Result<AgentValue> {
        let permitted = ["kind", "scope", "scope_key", "content", "context", "importance_permille", "expires_at"]
        if (changes.unifiedKind != ValueKind.Object || changes.fields.size < 1) { return productPolicySelectionError("memory.policy_correction_invalid") }
        for (field in changes.fields where !permitted.contains(field.name)) { return productPolicySelectionError("memory.policy_correction_invalid") }
        let currentFields = ArrayList<ValueField>(); let changedFields = ArrayList<ValueField>(); let expectedFields = ArrayList<ValueField>()
        for (name in permitted) {
            currentFields.add(ValueField(name, reference(name, raw.field(name).getOrThrow(), "current")))
            if (changes.field(name).isSome()) { changedFields.add(ValueField(name, reference(name, changes.field(name).getOrThrow(), "changes"))) }
            expectedFields.add(ValueField(name, reference(name, changes.field(name) ?? raw.field(name).getOrThrow(),
                if (changes.field(name).isSome()) { "changes" } else { "current" })))
        }
        let content = (changes.field("content") ?? raw.field("content").getOrThrow()).text
        let contentDigest = modelPolicySha256Text(content); var offset: Int64 = 0; var first = true; var nonblank = false
        while (first || offset < content.size) {
            first = false; let part = productMemoryFragmentText(content, offset, min(262144, content.size - offset))
            let result = match (request("text_nonblank_fragment", [ValueField("field_digest", textValue(contentDigest)), ValueField("offset", integerValue(offset)),
                ValueField("total", integerValue(content.size)), ValueField("text", textValue(part))])) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (!httpIntentExactFields(result, ["snapshot_digest", "page_id", "field_digest", "next_offset", "nonblank"]) ||
                httpIntentText(result, "field_digest") != contentDigest || productMemoryPolicyInt(result, "next_offset") != offset + part.size ||
                result.field("nonblank").getOrThrow().unifiedKind != ValueKind.Boolean) { return productPolicySelectionError("memory.fragment_coverage") }
            nonblank = result.field("nonblank").getOrThrow().asBool(); offset += part.size
            if (nonblank) { break }
        }
        let result = match (request("correct_references", [ValueField("id", textValue(current.id)), ValueField("revision", integerValue(current.revision)),
            ValueField("status", textValue(memoryV3StatusName(current.status))), ValueField("current", objectValue(currentFields.toArray())),
            ValueField("changes", objectValue(changedFields.toArray())), ValueField("content_nonblank", boolValue(nonblank))])) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!httpIntentExactFields(result, ["snapshot_digest", "page_id", "id", "revision", "replacement"]) ||
            httpIntentText(result, "id") != current.id || productMemoryPolicyInt(result, "revision") != current.revision ||
            canonicalAgentValue(result.field("replacement").getOrThrow()) != canonicalAgentValue(objectValue(expectedFields.toArray()))) {
            return productPolicySelectionError("memory.policy_correction_changed") }
        // No provider reference can dereference arbitrary data: each field is
        // copied only from this caller's exact current/default or change value.
        // Reconstruct scalar nodes so no mutable input JsonNode aliases escape.
        let output = ArrayList<ValueField>()
        for (name in permitted) {
            let value = changes.field(name) ?? raw.field(name).getOrThrow()
            output.add(ValueField(name, if (value.unifiedKind == ValueKind.Text) { textValue(value.text) }
                else if (value.unifiedKind == ValueKind.Number) { numberValue(value.asNumberText()) }
                else { throw IllegalArgumentException("invalid correction scalar") }))
        }
        Result.Ok(objectValue(output.toArray()))
    }
}
