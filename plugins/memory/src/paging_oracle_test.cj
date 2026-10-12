package memory_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Test-only transport/index driver. It calls the production pure page algebra,
// never a test action in the native protocol and never its own comparator.
class MemoryPagedOracleDriver {
    private var sequence: Int64 = 0
    func call(action: String, fields: Array<ValueField>): AgentValue {
        sequence++
        let all = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.memory-policy/v1")),
            ValueField("action", textValue(action)), ValueField("snapshot_digest", textValue("full-corpus-oracle")),
            ValueField("page_id", textValue(sequence.toString()))])
        all.add(all: fields); memoryPolicy(objectValue(all.toArray()))
    }
    func order(input: Array<AgentValue>, mode: String): Array<AgentValue> {
        if (mode == "semantic") { return semanticOrder(input) }
        orderTotal(input, mode)
    }
    func semanticOrder(input: Array<AgentValue>): Array<AgentValue> {
        let output = ArrayList<AgentValue>(); let pending = ArrayList<AgentValue>(); var offset: Int64 = 0
        while (offset < input.size) {
            let end = min(input.size, offset + 128)
            let response = call("partition_semantic_page", [ValueField("rows", listValue(input[offset..end]))])
            for (group in response.field("groups").getOrThrow().items) {
                let values = group.field("rows").getOrThrow().items.toArray()
                if (group.field("sortable").getOrThrow().asBool()) { pending.add(all: values) }
                else { output.add(all: orderTotal(pending.toArray(), "semantic")); pending.clear(); output.add(all: values) }
            }
            offset = end
        }
        output.add(all: orderTotal(pending.toArray(), "semantic")); output.toArray()
    }
    func orderTotal(input: Array<AgentValue>, mode: String): Array<AgentValue> {
        var runs = ArrayList<Array<AgentValue>>()
        var at: Int64 = 0
        while (at < input.size) {
            let next = min(input.size, at + 128)
            runs.add(call("sort_page", [ValueField("mode", textValue(mode)), ValueField("rows", listValue(input[at..next]))])
                .field("rows").getOrThrow().items.toArray()); at = next
        }
        while (runs.size > 1) {
            let result = ArrayList<Array<AgentValue>>(); var index: Int64 = 0
            while (index < runs.size) {
                if (index + 1 == runs.size) { result.add(runs[index]); break }
                let left = runs[index]; let right = runs[index + 1]
                var a: Int64 = 0; var b: Int64 = 0; let merged = ArrayList<AgentValue>()
                while (a < left.size || b < right.size) {
                    let x = left[a..min(left.size, a + 128)]; let y = right[b..min(right.size, b + 128)]
                    let value = call("merge_page", [ValueField("mode", textValue(mode)), ValueField("left", listValue(x)),
                        ValueField("right", listValue(y)), ValueField("left_eof", boolValue(a + x.size == left.size)),
                        ValueField("right_eof", boolValue(b + y.size == right.size))])
                    let rows = value.field("rows").getOrThrow().items.toArray()
                    let da = memoryPolicyInt(value, "left_consumed"); let db = memoryPolicyInt(value, "right_consumed")
                    if (rows.isEmpty() || da < 0 || da > x.size || db < 0 || db > y.size || da + db != rows.size) {
                        throw IllegalStateException("nonprogressing pure merge") }
                    merged.add(all: rows); a += da; b += db
                }
                result.add(merged.toArray()); index += 2
            }
            runs = result
        }
        if (runs.isEmpty()) { [] } else { runs[0] }
    }
    func retrieve(records: Array<AgentValue>, state: String, vectors: Array<AgentValue>, now: Int64,
        queryVector!: Array<AgentValue> = [integerValue(1), integerValue(0)]): AgentValue {
        var actualState = state
        let scores = ArrayList<AgentValue>(); var offset: Int64 = 0
        while (offset < records.size) {
            let end = min(records.size, offset + 128)
            let embedding = objectValue([ValueField("state", textValue(state)),
                ValueField("query", if (state == "ready") { listValue(queryVector) } else { listValue([]) }),
                ValueField("records", listValue(if (state == "ready") { vectors[offset..end] } else { [] }))])
            let result = call("score_page", [ValueField("offset", integerValue(offset)), ValueField("query", textValue("concise 文档")),
                ValueField("records", listValue(records[offset..end])), ValueField("now_millis", integerValue(now)), ValueField("embeddings", embedding)])
            if (memoryPolicyText(result, "state") == "failed") { actualState = "failed" }
            scores.add(all: result.field("rows").getOrThrow().items.toArray()); offset = end
        }
        let lexical = order(scores.toArray(), "lexical")
        let semantic: Array<AgentValue> = if (actualState == "ready") { order(scores.toArray(), "semantic") } else { [] }
        let lexicalRanks = HashMap<Int64, Int64>(); let semanticRanks = HashMap<Int64, Int64>()
        for (i in 0..lexical.size) { lexicalRanks[memoryPolicyInt(lexical[i], "index")] = i + 1 }
        for (i in 0..semantic.size) { semanticRanks[memoryPolicyInt(semantic[i], "index")] = i + 1 }
        let strategy = if (actualState == "ready") { "hybrid" } else if (actualState == "failed") { "lexical_fallback" } else { "lexical" }
        let all = scores.toArray(); let fused = ArrayList<AgentValue>(); offset = 0
        while (offset < all.size) {
            let end = min(all.size, offset + 128); let rows = all[offset..end]
            for (row in rows) {
                let index = memoryPolicyInt(row, "index")
                row.put("lexical_rank", integerValue(lexicalRanks[index])); row.put("semantic_rank", integerValue(semanticRanks.get(index) ?? 0)) }
            let result = call("fuse_page", [ValueField("rows", listValue(rows)), ValueField("strategy", textValue(strategy)),
                ValueField("lexical_weight", integerValue(650)), ValueField("semantic_weight", integerValue(350)), ValueField("record_count", integerValue(records.size))])
            fused.add(all: result.field("rows").getOrThrow().items.toArray()); offset = end
        }
        let ordered = order(fused.toArray(), if (actualState == "ready") { "fused" } else { "lexical" })
        call("select_page", [ValueField("rows", listValue(ordered[..min(100, ordered.size)])),
            ValueField("strategy", textValue(strategy)), ValueField("limit", integerValue(100))])
    }
}

@Test
class MemoryWholeCorpusOracleTests {
    @TestCase
    func allThreeStrategiesOn3001FactsMatchTheActualUnpagedLegacyFunctions(): Unit {
        let records = ArrayList<AgentValue>(); let vectors = ArrayList<AgentValue>(); let now: Int64 = 1700000000000
        for (index in 0..3001) {
            let id = "record-雪-" + index.toString()
            records.add(objectValue([ValueField("id", textValue(id)), ValueField("revision", integerValue(1)),
                ValueField("kind", textValue("preference")), ValueField("scope", textValue("workspace")), ValueField("scope_key", textValue("/workspace")),
                ValueField("content", textValue(if (index % 3 == 0) { "other" } else { "concise 文档" })),
                ValueField("context", textValue("concise")), ValueField("source", textValue("user")),
                ValueField("importance_permille", integerValue(index % 1001)), ValueField("status", textValue("active")),
                ValueField("expires_at", integerValue(0)), ValueField("updated_at", integerValue(now - index % 7))]))
            vectors.add(objectValue([ValueField("id", textValue(id)), ValueField("revision", integerValue(1)),
                ValueField("vector", listValue([integerValue(index % 11 - 5), integerValue(1)]))]))
        }
        for (state in ["absent", "ready", "failed"]) {
            let input = objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue("retrieve")),
                ValueField("snapshot_digest", textValue("original-whole-corpus")), ValueField("query", textValue("concise 文档")),
                ValueField("records", listValue(records.toArray())), ValueField("options", objectValue([ValueField("limit", integerValue(100)),
                    ValueField("semantic_enabled", boolValue(true)), ValueField("lexical_weight", integerValue(650)),
                    ValueField("semantic_weight", integerValue(350)), ValueField("now_millis", integerValue(now))])),
                ValueField("embeddings", objectValue([ValueField("state", textValue(state)),
                    ValueField("query", if (state == "ready") { listValue([integerValue(1), integerValue(0)]) } else { listValue([]) }),
                    ValueField("records", listValue(if (state == "ready") { vectors.toArray() } else { [] }))]))])
            // Direct pure library call intentionally has no native wire parser
            // ceiling. This does not advertise an oversized protocol action.
            let original = memoryPolicyRetrieve(input)
            let actual = MemoryPagedOracleDriver().retrieve(records.toArray(), state, vectors.toArray(), now)
            @Expect(canonicalAgentValue(actual.field("hits").getOrThrow()), canonicalAgentValue(original.field("hits").getOrThrow()))
            @Expect(memoryPolicyText(actual, "strategy"), memoryPolicyText(original, "strategy"))
            @Expect(actual.field("embedding_fallback").getOrThrow().asBool(), original.field("embedding_fallback").getOrThrow().asBool())
        }
    }
}
