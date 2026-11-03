package agent_product

import agent_domain.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

class ProductMemoryContextFragments {
    private let query: (AgentValue) -> Result<AgentValue>
    private let digest: String
    private var ordinal: Int64 = 0
    init(hits: Array<MemoryV3SearchHit>, query: (AgentValue) -> Result<AgentValue>) {
        this.query = query
        var witness = modelPolicySha256Text("axyndra.memory-context-fragments/v1:" + hits.size.toString())
        for (hit in hits) {
            witness = modelPolicySha256Text(witness + ":" + hit.scorePermille.toString() + ":" +
                modelPolicySha256Text(canonicalAgentValue(productMemoryPolicyRecord(hit.memory)))) }
        this.digest = witness
    }
    private func request(action: String, fields: Array<ValueField>): Result<AgentValue> {
        ordinal++
        let page = ordinal.toString()
        let values = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue(action)),
            ValueField("snapshot_digest", textValue(digest)), ValueField("page_id", textValue(page))])
        values.add(all: fields)
        let result = match (query(objectValue(values.toArray()))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (httpIntentText(result, "snapshot_digest") != digest || httpIntentText(result, "page_id") != page) {
            return productPolicySelectionError("memory.fragment_identity") }
        Result.Ok(result)
    }
    private func inline(record: MemoryV3Record, field: String, bound: Int64): Result<String> {
        let raw = if (field == "content") { record.content } else { record.context }
        let recordDigest = modelPolicySha256Text(canonicalAgentValue(productMemoryPolicyRecord(record)))
        var offset: Int64 = 0; var first = true; var carry = nullValue()
        while (first || offset < raw.size) {
            first = false
            let part = productMemoryFragmentText(raw, offset, min(262144, raw.size - offset))
            let result = match (request("inline_fragment", [ValueField("record_digest", textValue(recordDigest)), ValueField("field", textValue(field)),
                ValueField("offset", integerValue(offset)), ValueField("total", integerValue(raw.size)), ValueField("text", textValue(part)),
                ValueField("max_bytes", integerValue(bound)), ValueField("carry", carry)])) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (!httpIntentExactFields(result, ["snapshot_digest", "page_id", "record_digest", "field", "next_offset", "complete", "truncated", "carry"]) ||
                httpIntentText(result, "record_digest") != recordDigest || httpIntentText(result, "field") != field ||
                productMemoryPolicyInt(result, "next_offset") != offset + part.size ||
                result.field("complete").getOrThrow().unifiedKind != ValueKind.Boolean ||
                result.field("truncated").getOrThrow().unifiedKind != ValueKind.Boolean) { return productPolicySelectionError("memory.fragment_coverage") }
            let complete = result.field("complete").getOrThrow().asBool(); let truncated = result.field("truncated").getOrThrow().asBool()
            if (complete != (truncated || offset + part.size == raw.size)) { return productPolicySelectionError("memory.fragment_coverage") }
            carry = result.field("carry").getOrThrow()
            if (!httpIntentExactFields(carry, ["offset", "prefix", "pending", "overflow", "started", "last_space", "complete"]) ||
                productMemoryPolicyInt(carry, "offset") != offset + part.size ||
                carry.field("prefix").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(carry, "prefix").size > bound ||
                carry.field("pending").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(carry, "pending").size > bound + 4 ||
                carry.field("complete").getOrThrow().unifiedKind != ValueKind.Boolean || carry.field("complete").getOrThrow().asBool() != complete) {
                return productPolicySelectionError("memory.fragment_coverage") }
            if (complete) { return Result.Ok(httpIntentText(carry, "prefix")) }
            offset += part.size
        }
        productPolicySelectionError("memory.fragment_coverage")
    }
    func render(hits: Array<MemoryV3SearchHit>, maxBytes: Int64): Result<String> {
        try { renderInternal(hits, maxBytes) }
        catch (_: Exception) { productPolicySelectionError("memory.fragment_result_invalid") }
    }
    private func renderInternal(hits: Array<MemoryV3SearchHit>, maxBytes: Int64): Result<String> {
        if (hits.size > 100 || maxBytes < 1 || maxBytes > 65536) { return productPolicySelectionError("memory.policy_context_limit") }
        let facts = hits.map { hit => objectValue([ValueField("id", textValue(hit.memory.id)), ValueField("revision", integerValue(hit.memory.revision)),
            ValueField("kind", textValue(memoryV3KindName(hit.memory.kind))), ValueField("scope", textValue(memoryV3ScopeName(hit.memory.scope.kind))),
            ValueField("updated_at", integerValue(hit.memory.updatedAt)), ValueField("score", integerValue(hit.scorePermille))]) }
        let selection = match (request("context_references", [ValueField("hits", listValue(facts))])) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!httpIntentExactFields(selection, ["snapshot_digest", "page_id", "references"]) ||
            selection.field("references").getOrThrow().unifiedKind != ValueKind.List ||
            selection.field("references").getOrThrow().items.size != min(8, hits.size)) { return productPolicySelectionError("memory.fragment_coverage") }
        let seen = HashSet<String>(); var prefix = nullValue()
        for (reference in selection.field("references").getOrThrow().items) {
            if (!httpIntentExactFields(reference, ["id", "revision"])) { return productPolicySelectionError("memory.fragment_coverage") }
            let id = httpIntentText(reference, "id"); var record: ?MemoryV3Record = None
            for (hit in hits where hit.memory.id == id && hit.memory.revision == productMemoryPolicyInt(reference, "revision")) { record = Some(hit.memory) }
            if (record.isNone() || seen.contains(id)) { return productPolicySelectionError("memory.fragment_coverage") }; seen.add(id)
            let actual = record.getOrThrow()
            let content = match (inline(actual, "content", maxBytes + 1)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let context = match (inline(actual, "context", maxBytes + 1)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let row = objectValue([ValueField("id", textValue(id)), ValueField("revision", integerValue(actual.revision)),
                ValueField("kind", textValue(memoryV3KindName(actual.kind))), ValueField("scope", textValue(memoryV3ScopeName(actual.scope.kind))),
                ValueField("content", textValue(content)), ValueField("context", textValue(context))])
            let result = match (request("context_compose", [ValueField("rows", listValue([row])), ValueField("max_bytes", integerValue(maxBytes)),
                ValueField("prefix", prefix)])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (!httpIntentExactFields(result, ["snapshot_digest", "page_id", "content", "complete"]) ||
                result.field("content").getOrThrow().unifiedKind != ValueKind.Text || httpIntentText(result, "content").size > maxBytes ||
                result.field("complete").getOrThrow().unifiedKind != ValueKind.Boolean) { return productPolicySelectionError("memory.fragment_result_invalid") }
            prefix = result.field("content").getOrThrow()
            if (result.field("complete").getOrThrow().asBool()) { break }
        }
        Result.Ok(if (prefix.unifiedKind == ValueKind.Null) { "" } else { prefix.text })
    }
}
