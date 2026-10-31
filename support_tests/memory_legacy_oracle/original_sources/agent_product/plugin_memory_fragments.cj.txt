package agent_product

import agent_domain.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// The installed policy alone interprets text and computes similarities. This
// class supplies contiguous slices of the one DAO snapshot and checks complete
// consumption. It owns no registry, durable state, credentials or extra Run.
class ProductMemoryFragmentScorer {
    private let request: (String, Array<ValueField>) -> Result<AgentValue>
    init(request: (String, Array<ValueField>) -> Result<AgentValue>) { this.request = request }
    func lexical(record: MemoryV3Record, index: Int64, query: String): Result<Int64> {
        let digest = modelPolicySha256Text(canonicalAgentValue(productMemoryPolicyRecord(record)))
        let queryBytes = query.trimAscii().size
        if (queryBytes == 0 || !productMemoryPolicyFactsFit([], query)) { return productPolicySelectionError("memory.policy_query_limit") }
        var cursor: Int64 = -1; var score: Int64 = 0
        while (cursor < queryBytes) {
            var carry = nullValue(); var nextCursor: Int64 = -1; var finalScore: Int64 = 0
            for (field in ["content", "context"]) {
                let raw = if (field == "content") { record.content } else { record.context }
                var offset: Int64 = 0; var first = true
                while (first || offset < raw.size) {
                    first = false
                    var width = min(262144, raw.size - offset)
                    var text = productMemoryFragmentText(raw, offset, width)
                    while (!productMemoryPolicyFactsFit([], query, extra: [text])) {
                        width /= 2
                        if (width < 4) { return productPolicySelectionError("memory.policy_query_limit") }
                        text = productMemoryFragmentText(raw, offset, width)
                    }
                    let response = match (request("lexical_fragment", [ValueField("record_digest", textValue(digest)),
                        ValueField("index", integerValue(index)), ValueField("id", textValue(record.id)),
                        ValueField("revision", integerValue(record.revision)), ValueField("updated_at", integerValue(record.updatedAt)),
                        ValueField("importance_permille", integerValue(record.importancePermille)), ValueField("query", textValue(query)),
                        ValueField("query_cursor", integerValue(cursor)), ValueField("content_bytes", integerValue(record.content.size)),
                        ValueField("context_bytes", integerValue(record.context.size)), ValueField("field", textValue(field)),
                        ValueField("offset", integerValue(offset)), ValueField("text", textValue(text)),
                        ValueField("base_score", integerValue(score)), ValueField("carry", carry)])) {
                            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    if (!httpIntentExactFields(response, ["snapshot_digest", "page_id", "record_digest", "index", "revision", "query_cursor",
                        "next_query_cursor", "query_bytes", "field", "next_offset", "batch_complete", "raw_score", "lexical", "carry"]) ||
                        httpIntentText(response, "record_digest") != digest || productMemoryPolicyInt(response, "index") != index ||
                        productMemoryPolicyInt(response, "revision") != record.revision || productMemoryPolicyInt(response, "query_cursor") != cursor ||
                        productMemoryPolicyInt(response, "query_bytes") != queryBytes || httpIntentText(response, "field") != field ||
                        productMemoryPolicyInt(response, "next_offset") != offset + text.size ||
                        response.field("batch_complete").getOrThrow().unifiedKind != ValueKind.Boolean ||
                        response.field("batch_complete").getOrThrow().asBool() != (field == "context" && offset + text.size == raw.size)) {
                        return productPolicySelectionError("memory.fragment_coverage") }
                    let next = productMemoryPolicyInt(response, "next_query_cursor")
                    if ((cursor == -1 && next != 0) || (cursor >= 0 && (next <= cursor || next > queryBytes)) ||
                        (nextCursor >= 0 && nextCursor != next)) { return productPolicySelectionError("memory.fragment_coverage") }
                    nextCursor = next; carry = response.field("carry").getOrThrow()
                    if (!httpIntentExactFields(carry, ["content_offset", "context_offset", "states", "complete"]) ||
                        productMemoryPolicyInt(carry, "content_offset") != (if (field == "content") { offset + text.size } else { record.content.size }) ||
                        productMemoryPolicyInt(carry, "context_offset") != (if (field == "context") { offset + text.size } else { 0 }) ||
                        carry.field("complete").getOrThrow().unifiedKind != ValueKind.Boolean ||
                        carry.field("complete").getOrThrow().asBool() != response.field("batch_complete").getOrThrow().asBool() ||
                        carry.field("states").getOrThrow().unifiedKind != ValueKind.List || carry.field("states").getOrThrow().items.size > 32) {
                        return productPolicySelectionError("memory.fragment_coverage") }
                    if (response.field("batch_complete").getOrThrow().asBool()) {
                        let nextScore = productMemoryPolicyInt(response, "raw_score")
                        if (nextScore < score || nextScore > score + 4000) { return productPolicySelectionError("memory.fragment_result_invalid") }
                        score = nextScore; finalScore = productMemoryPolicyInt(response, "lexical")
                        if (finalScore < 0 || finalScore > score + 100) { return productPolicySelectionError("memory.fragment_result_invalid") }
                    } else if (productMemoryPolicyInt(response, "raw_score") != score || productMemoryPolicyInt(response, "lexical") != 0) {
                        return productPolicySelectionError("memory.fragment_result_invalid") }
                    offset += text.size
                }
            }
            if (nextCursor == queryBytes) { return Result.Ok(finalScore) }
            cursor = nextCursor
        }
        productPolicySelectionError("memory.fragment_coverage")
    }
    func dot(record: MemoryV3Record, index: Int64, left: Array<Float64>, right: Array<Float64>): Result<AgentValue> {
        if (left.isEmpty() || left.size != right.size) { return productPolicySelectionError("memory.embedding_shape") }
        let digest = modelPolicySha256Text(canonicalAgentValue(productMemoryPolicyRecord(record)))
        var offset: Int64 = 0; var sum = exactFloat64Value(0.0)
        while (offset < left.size) {
            let end = min(left.size, offset + 4096)
            let value = match (request("dot_fragment", [ValueField("record_digest", textValue(digest)), ValueField("index", integerValue(index)),
                ValueField("revision", integerValue(record.revision)), ValueField("dimension", integerValue(left.size)),
                ValueField("offset", integerValue(offset)), ValueField("query", productMemoryVectorValue(left[offset..end])),
                ValueField("vector", productMemoryVectorValue(right[offset..end])), ValueField("sum", sum)])) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (!httpIntentExactFields(value, ["snapshot_digest", "page_id", "record_digest", "index", "revision", "dimension", "next_offset", "sum"]) ||
                httpIntentText(value, "record_digest") != digest || productMemoryPolicyInt(value, "index") != index ||
                productMemoryPolicyInt(value, "revision") != record.revision || productMemoryPolicyInt(value, "dimension") != left.size ||
                productMemoryPolicyInt(value, "next_offset") != end) {
                return productPolicySelectionError("memory.fragment_coverage") }
            sum = value.field("sum").getOrThrow(); let _ = decodeExactFloat64(sum); offset = end
        }
        Result.Ok(sum)
    }
}

func productMemoryFragmentText(text: String, offset: Int64, maximum: Int64): String {
    let bytes = unsafe { text.rawData() }; var end = min(bytes.size, offset + maximum)
    while (end > offset && end < bytes.size && (bytes[end] & 0xC0) == 0x80) { end-- }
    if (end == offset && offset < bytes.size) { throw IllegalArgumentException("fragment cannot split a UTF-8 scalar") }
    text[offset..end]
}
