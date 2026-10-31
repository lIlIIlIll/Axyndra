package memory_legacy_oracle

import agent_domain.*
import agent_product.*
import persistence_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

let PRODUCT_MEMORY_PAGE: Int64 = 128

// Transport/orchestration of an immutable DAO snapshot. Comparators, scoring,
// fusion and final selection live in the installed policy, including all ties.
// No page is a source of authority and no durable snapshot registry is added.
class ProductMemoryPagedRanking {
    private let records: Array<MemoryV3Record>
    private let options: MemoryV3SearchOptions
    private let queryText: String
    private let query: (AgentValue) -> Result<AgentValue>
    private let validate: () -> Result<Unit>
    private let digest: String
    private var pageSequence: Int64 = 0
    init(records: Array<MemoryV3Record>, options: MemoryV3SearchOptions, queryText: String,
        query: (AgentValue) -> Result<AgentValue>, validate: () -> Result<Unit>) {
        this.records = records; this.options = options; this.queryText = queryText; this.query = query; this.validate = validate
        // Hash one existing record at a time; do not construct a whole-corpus
        // JSON DOM/string just to bind the bounded policy pages.
        var witness = modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("schema", textValue("axyndra.memory-pages/v1")),
            ValueField("query_sha256", textValue(modelPolicySha256Text(queryText))), ValueField("count", integerValue(records.size)),
            ValueField("limit", integerValue(options.limit)), ValueField("semantic", boolValue(options.semanticEnabled)),
            ValueField("lexical_weight", integerValue(options.lexicalWeightPermille)),
            ValueField("semantic_weight", integerValue(options.semanticWeightPermille)), ValueField("now", integerValue(options.nowMillis))])))
        for (record in records) {
            witness = modelPolicySha256Text(witness + ":" + modelPolicySha256Text(canonicalAgentValue(productMemoryPolicyRecord(record)))) }
        this.digest = witness
    }
    private func request(action: String, fields: Array<ValueField>): Result<AgentValue> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        pageSequence++
        let page = pageSequence.toString()
        let values = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue(action)),
            ValueField("snapshot_digest", textValue(digest)), ValueField("page_id", textValue(page))])
        values.add(all: fields)
        let result = match (query(objectValue(values.toArray()))) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (httpIntentText(result, "snapshot_digest") != digest || httpIntentText(result, "page_id") != page) {
            return productPolicySelectionError("memory.page_identity") }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(result)
    }
    private func rows(value: AgentValue, fields: Array<String>): Array<AgentValue> {
        if (!httpIntentExactFields(value, fields) || value.field("rows").getOrThrow().unifiedKind != ValueKind.List ||
            value.field("rows").getOrThrow().items.size > PRODUCT_MEMORY_PAGE) { throw IllegalArgumentException("invalid page shape") }
        let result = value.field("rows").getOrThrow().items.toArray(); let seen = HashSet<Int64>()
        for (row in result) {
            if (!httpIntentExactFields(row, ["index", "id", "revision", "updated_at", "lexical", "semantic", "score", "lexical_rank", "semantic_rank"])) {
                throw IllegalArgumentException("invalid score shape") }
            let index = productMemoryPolicyInt(row, "index")
            if (index < 0 || index >= records.size || seen.contains(index) || httpIntentText(row, "id") != records[index].id ||
                productMemoryPolicyInt(row, "revision") != records[index].revision || productMemoryPolicyInt(row, "updated_at") != records[index].updatedAt ||
                productMemoryPolicyInt(row, "lexical") < 0 || productMemoryPolicyInt(row, "score") < 0 || productMemoryPolicyInt(row, "score") > 1000 ||
                productMemoryPolicyInt(row, "lexical_rank") < 0 || productMemoryPolicyInt(row, "lexical_rank") > records.size ||
                productMemoryPolicyInt(row, "semantic_rank") < 0 || productMemoryPolicyInt(row, "semantic_rank") > records.size) { throw IllegalArgumentException("invalid page reference") }
            let _ = decodeExactFloat64(row.field("semantic").getOrThrow())
            seen.add(index)
        }
        result
    }
    private func permutation(actual: Array<AgentValue>, expected: Array<AgentValue>): Unit {
        if (actual.size != expected.size) { throw IllegalArgumentException("incomplete page coverage") }
        let selected = HashMap<Int64, String>()
        for (row in expected) {
            let index = productMemoryPolicyInt(row, "index")
            if (selected.contains(index)) { throw IllegalArgumentException("overlapping source runs") }
            selected[index] = canonicalAgentValue(row)
        }
        for (row in actual) {
            let index = productMemoryPolicyInt(row, "index")
            if (!selected.contains(index) || selected[index] != canonicalAgentValue(row)) { throw IllegalArgumentException("changed page proposal") }
            selected.remove(index)
        }
        if (!selected.isEmpty()) { throw IllegalArgumentException("incomplete page coverage") }
    }
    private func order(input: Array<AgentValue>, mode: String): Result<Array<AgentValue>> {
        if (mode == "semantic") { return semanticOrder(input) }
        orderTotal(input, mode)
    }
    private func semanticOrder(input: Array<AgentValue>): Result<Array<AgentValue>> {
        let output = ArrayList<AgentValue>(); let pending = ArrayList<AgentValue>(); var offset: Int64 = 0
        while (offset < input.size) {
            let part = input[offset..min(input.size, offset + PRODUCT_MEMORY_PAGE)]
            let response = match (request("partition_semantic_page", [ValueField("rows", listValue(part))])) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (!httpIntentExactFields(response, ["snapshot_digest", "page_id", "groups"]) ||
                response.field("groups").getOrThrow().unifiedKind != ValueKind.List ||
                response.field("groups").getOrThrow().items.size > part.size) { return productPolicySelectionError("memory.page_partition") }
            var consumed: Int64 = 0
            for (group in response.field("groups").getOrThrow().items) {
                if (!httpIntentExactFields(group, ["sortable", "rows"]) || group.field("sortable").getOrThrow().unifiedKind != ValueKind.Boolean) {
                    return productPolicySelectionError("memory.page_partition") }
                // Only transport coverage is interpreted here. The provider
                // decides which segments its old ordering can merge.
                let values = rows(objectValue([ValueField("rows", group.field("rows").getOrThrow())]), ["rows"])
                if (values.isEmpty() || values.size > part.size - consumed) { return productPolicySelectionError("memory.page_partition") }
                for (index in 0..values.size where canonicalAgentValue(values[index]) != canonicalAgentValue(part[consumed + index])) {
                    return productPolicySelectionError("memory.page_partition") }
                consumed += values.size
                if (group.field("sortable").getOrThrow().asBool()) { pending.add(all: values) }
                else {
                    if (values.size != 1) { return productPolicySelectionError("memory.page_partition") }
                    let ordered = match (orderTotal(pending.toArray(), "semantic")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                    output.add(all: ordered); pending.clear(); output.add(values[0])
                }
            }
            if (consumed != part.size) { return productPolicySelectionError("memory.page_partition") }
            offset += consumed
        }
        let ordered = match (orderTotal(pending.toArray(), "semantic")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        output.add(all: ordered); Result.Ok(output.toArray())
    }
    private func orderTotal(input: Array<AgentValue>, mode: String): Result<Array<AgentValue>> {
        var runs = ArrayList<Array<AgentValue>>()
        var offset: Int64 = 0
        while (offset < input.size) {
            let part = input[offset..min(input.size, offset + PRODUCT_MEMORY_PAGE)]
            let response = match (request("sort_page", [ValueField("mode", textValue(mode)), ValueField("rows", listValue(part))])) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let sorted = rows(response, ["snapshot_digest", "page_id", "rows"]); permutation(sorted, part)
            runs.add(sorted); offset += part.size
        }
        while (runs.size > 1) {
            let next = ArrayList<Array<AgentValue>>(); var index: Int64 = 0
            while (index < runs.size) {
                if (index + 1 == runs.size) { next.add(runs[index]) }
                else {
                    match (merge(runs[index], runs[index + 1], mode)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => next.add(value) }
                }
                index += 2
            }
            runs = next
        }
        Result.Ok(if (runs.isEmpty()) { [] } else { runs[0] })
    }
    private func merge(left: Array<AgentValue>, right: Array<AgentValue>, mode: String): Result<Array<AgentValue>> {
        let combined = ArrayList<AgentValue>(); var a: Int64 = 0; var b: Int64 = 0
        while (a < left.size || b < right.size) {
            let x = left[a..min(left.size, a + PRODUCT_MEMORY_PAGE)]; let y = right[b..min(right.size, b + PRODUCT_MEMORY_PAGE)]
            let response = match (request("merge_page", [ValueField("mode", textValue(mode)), ValueField("left", listValue(x)),
                ValueField("right", listValue(y)), ValueField("left_eof", boolValue(a + x.size == left.size)),
                ValueField("right_eof", boolValue(b + y.size == right.size))])) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let output = rows(response, ["snapshot_digest", "page_id", "left_consumed", "right_consumed", "rows"])
            let consumedA = productMemoryPolicyInt(response, "left_consumed"); let consumedB = productMemoryPolicyInt(response, "right_consumed")
            if (consumedA < 0 || consumedA > x.size || consumedB < 0 || consumedB > y.size || consumedA + consumedB != output.size || output.isEmpty()) {
                throw IllegalArgumentException("noncontiguous or stalled merge page") }
            let expected = ArrayList<AgentValue>(x[..consumedA]); expected.add(all: y[..consumedB])
            permutation(output, expected.toArray())
            combined.add(all: output); a += consumedA; b += consumedB
        }
        if (combined.size != left.size + right.size) { throw IllegalArgumentException("missing merged source facts") }
        Result.Ok(combined.toArray())
    }
    func retrieve(embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        try { retrieveInternal(embedding) }
        catch (_: Exception) { productPolicySelectionError("memory.page_result_invalid") }
    }
    private func retrieveInternal(embedding: ?MemoryEmbeddingPort): Result<MemoryV3SearchResult> {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let fragments = ProductMemoryFragmentScorer({ action, fields => request(action, fields) })
        let scores = ArrayList<AgentValue>(); var offset: Int64 = 0
        while (offset < records.size) {
            var end = min(records.size, offset + PRODUCT_MEMORY_PAGE)
            while (end > offset && !productMemoryPolicyFactsFit(records[offset..end], queryText)) { end = offset + (end - offset) / 2 }
            if (end == offset) {
                let record = records[offset]
                let lexical = match (fragments.lexical(record, offset, queryText)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                scores.add(objectValue([ValueField("index", integerValue(offset)), ValueField("id", textValue(record.id)),
                    ValueField("revision", integerValue(record.revision)), ValueField("updated_at", integerValue(record.updatedAt)),
                    ValueField("lexical", integerValue(lexical)), ValueField("semantic", integerValue(0)), ValueField("score", integerValue(0)),
                    ValueField("lexical_rank", integerValue(0)), ValueField("semantic_rank", integerValue(0))]))
                offset++; continue
            }
            let part = records[offset..end]
            let response = match (request("score_page", [ValueField("offset", integerValue(offset)), ValueField("query", textValue(queryText)),
                ValueField("records", listValue(part.map { record => productMemoryPolicyRecord(record) })),
                ValueField("now_millis", integerValue(options.nowMillis)), ValueField("embeddings", objectValue([
                    ValueField("state", textValue("absent")), ValueField("query", listValue([])), ValueField("records", listValue([]))]))])) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let output = rows(response, ["snapshot_digest", "page_id", "offset", "state", "rows"])
            if (output.size != part.size || productMemoryPolicyInt(response, "offset") != offset || httpIntentText(response, "state") != "absent") {
                throw IllegalArgumentException("missing source page") }
            for (i in 0..output.size where productMemoryPolicyInt(output[i], "index") != offset + i) {
                throw IllegalArgumentException("reordered or overlapping source page") }
            scores.add(all: output); offset = end
        }
        // Embedding transport never serializes a whole vector/corpus DOM. The
        // trusted adapter remains the existing port; only the plugin multiplies
        // or accumulates values. Any adapter failure still falls back for the
        // complete query, including semantic fragments already observed.
        var embeddingState = if (options.semanticEnabled && embedding.isSome()) { "ready" } else { "absent" }
        var queryVector: Array<Float64> = []
        if (embeddingState == "ready") {
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (embedding.getOrThrow().embed(queryText)) {
                case Result.Err(_) => embeddingState = "failed"
                case Result.Ok(value) => if (productMemoryVectorRepresentable(value)) { queryVector = value } else { embeddingState = "failed" }
            }
            match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        if (embeddingState == "ready") {
            for (index in 0..records.size) {
                match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let vector = match (embedding.getOrThrow().embed(records[index].content + "\n" + records[index].context)) {
                    case Result.Err(_) => embeddingState = "failed"; break
                    case Result.Ok(value) => value }
                match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                if (!productMemoryVectorRepresentable(vector) || vector.size != queryVector.size) { embeddingState = "failed"; break }
                let dot = match (fragments.dot(records[index], index, queryVector, vector)) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                scores[index].put("semantic", dot)
            }
        }
        let lexical = match (order(scores.toArray(), "lexical")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let semantic: Array<AgentValue> = if (embeddingState == "ready") {
            match (order(scores.toArray(), "semantic")) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        } else { [] }
        // These are positions in the complete provider-ordered streams, not a
        // Host comparator or a recreated similarity/ranking formula.
        let lexicalPositions = HashMap<Int64, Int64>(); let semanticPositions = HashMap<Int64, Int64>()
        for (i in 0..lexical.size) { lexicalPositions[productMemoryPolicyInt(lexical[i], "index")] = i + 1 }
        for (i in 0..semantic.size) { semanticPositions[productMemoryPolicyInt(semantic[i], "index")] = i + 1 }
        let strategy = if (embeddingState == "ready") { "hybrid" } else if (embeddingState == "failed") { "lexical_fallback" } else { "lexical" }
        let fused = ArrayList<AgentValue>(); let allScores = scores.toArray(); offset = 0
        while (offset < scores.size) {
            let part = allScores[offset..min(scores.size, offset + PRODUCT_MEMORY_PAGE)]
            for (row in part) {
                let index = productMemoryPolicyInt(row, "index")
                row.put("lexical_rank", integerValue(lexicalPositions[index]))
                row.put("semantic_rank", integerValue(semanticPositions.get(index) ?? 0)) }
            let response = match (request("fuse_page", [ValueField("rows", listValue(part)), ValueField("strategy", textValue(strategy)),
                ValueField("lexical_weight", integerValue(options.lexicalWeightPermille)), ValueField("semantic_weight", integerValue(options.semanticWeightPermille)),
                ValueField("record_count", integerValue(records.size))])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let output = rows(response, ["snapshot_digest", "page_id", "rows"])
            if (output.size != part.size) { throw IllegalArgumentException("missing fusion inputs") }
            for (i in 0..output.size) {
                for (field in ["index", "id", "revision", "updated_at", "lexical", "semantic"] where
                    canonicalAgentValue(output[i].field(field).getOrThrow()) != canonicalAgentValue(part[i].field(field).getOrThrow())) {
                    throw IllegalArgumentException("changed fusion input") }
                let index = productMemoryPolicyInt(output[i], "index")
                let a = productMemoryPolicyInt(output[i], "lexical_rank"); let b = productMemoryPolicyInt(output[i], "semantic_rank")
                if ((a != 0 && a != lexicalPositions[index]) || b != (semanticPositions.get(index) ?? 0)) { throw IllegalArgumentException("changed stream position") }
            }
            fused.add(all: output); offset += part.size
        }
        let ordered = match (order(fused.toArray(), if (strategy == "hybrid") { "fused" } else { "lexical" })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let prefix = ordered[..min(options.limit, ordered.size)]
        let final = match (request("select_page", [ValueField("rows", listValue(prefix)), ValueField("strategy", textValue(strategy)),
            ValueField("limit", integerValue(options.limit))])) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!httpIntentExactFields(final, ["snapshot_digest", "page_id", "hits", "strategy", "embedding_fallback"]) ||
            httpIntentText(final, "strategy") != strategy || final.field("embedding_fallback").getOrThrow().unifiedKind != ValueKind.Boolean ||
            final.field("embedding_fallback").getOrThrow().asBool() != (strategy == "lexical_fallback") ||
            final.field("hits").getOrThrow().unifiedKind != ValueKind.List || final.field("hits").getOrThrow().items.size > options.limit) {
            throw IllegalArgumentException("invalid final selection") }
        let hits = ArrayList<MemoryV3SearchHit>(); let seen = HashSet<String>()
        for (hit in final.field("hits").getOrThrow().items) {
            if (!httpIntentExactFields(hit, ["id", "revision", "score", "lexical_rank", "semantic_rank"])) { throw IllegalArgumentException("invalid hit") }
            let id = httpIntentText(hit, "id"); var original: ?AgentValue = None
            for (row in prefix where httpIntentText(row, "id") == id) { original = Some(row) }
            if (original.isNone() || seen.contains(id)) { throw IllegalArgumentException("foreign or duplicate selected hit") }
            let row = original.getOrThrow()
            for (field in ["id", "revision", "score", "lexical_rank", "semantic_rank"] where
                canonicalAgentValue(hit.field(field).getOrThrow()) != canonicalAgentValue(row.field(field).getOrThrow())) {
                throw IllegalArgumentException("changed selected hit") }
            seen.add(id)
            hits.add(MemoryV3SearchHit(records[productMemoryPolicyInt(row, "index")], productMemoryPolicyInt(hit, "score"),
                lexicalRank: productMemoryPolicyInt(hit, "lexical_rank"), semanticRank: productMemoryPolicyInt(hit, "semantic_rank")))
        }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(MemoryV3SearchResult(hits.toArray(), if (strategy == "hybrid") { MemorySearchStrategy.Hybrid }
            else if (strategy == "lexical_fallback") { MemorySearchStrategy.LexicalFallback } else { MemorySearchStrategy.Lexical }, strategy == "lexical_fallback"))
    }
}
