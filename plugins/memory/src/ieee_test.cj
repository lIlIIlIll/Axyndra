package memory_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func memoryIeeeRecord(index: Int64, now: Int64): AgentValue {
    objectValue([ValueField("id", textValue("record-雪-" + index.toString())), ValueField("revision", integerValue(1)),
        ValueField("kind", textValue("preference")), ValueField("scope", textValue("workspace")), ValueField("scope_key", textValue("/workspace")),
        ValueField("content", textValue(if (index % 3 == 0) { "other" } else { "concise 文档" })),
        ValueField("context", textValue("concise")), ValueField("source", textValue("user")),
        ValueField("importance_permille", integerValue(index % 1001)), ValueField("status", textValue("active")),
        ValueField("expires_at", integerValue(0)), ValueField("updated_at", integerValue(now - index % 7))])
}

@Test
class MemoryIeeeOracleTests {
    @TestCase
    func bitCodecPreservesZerosSubnormalsInfinitiesAndNanPayloadsWithoutJsonNumbers(): Unit {
        let patterns: Array<UInt64> = [0, 0x8000000000000000, 1, 0x8000000000000001, 0x0010000000000000,
            0x3ff0000000000001, 0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000,
            0x7ff8000000000001, 0xfff8000012345678]
        for (bits in patterns) {
            let value = exactFloat64Value(Float64.fromBits(bits))
            @Expect(decodeExactFloat64(parseUnifiedJson(stringifyUnifiedJson(value))).toBits(), bits)
        }
        for (bad in [textValue("inf"), objectValue([ValueField("binary64", textValue("7FF0000000000000"))]),
            objectValue([ValueField("binary64", textValue("7ff000000000000"))]),
            objectValue([ValueField("binary64", textValue("7ff000000000000g"))]),
            objectValue([ValueField("binary64", textValue("7ff0000000000000")), ValueField("authority", boolValue(true))])]) {
            var rejected = false
            try { let _ = decodeExactFloat64(bad) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }
    @TestCase
    func fragmentedDotRetainsOverflowAndOppositeInfinityNanAcrossEverySplit(): Unit {
        let infinity = Float64.fromBits(0x7ff0000000000000)
        let vectors: Array<Array<Float64>> = [[1.0e308, 1.0e308, 1.0], [infinity, -infinity, 1.0],
            [0.0, infinity, -0.0], [1.0e16, 1.0, -1.0e16], [Float64.fromBits(1), -0.0, 0.0]]
        let queries: Array<Array<Float64>> = [[1.0e308, 1.0e308, 1.0], [1.0, 1.0, 1.0],
            [infinity, 1.0, 1.0], [1.0, 1.0, 1.0], [1.0, 1.0, 1.0]]
        for (index in 0..vectors.size) {
            let expected = memoryV3Dot(queries[index], vectors[index])
            for (width in [1, 2, 3]) {
                let driver = MemoryPagedOracleDriver(); var offset: Int64 = 0; var sum = exactFloat64Value(0.0)
                while (offset < 3) {
                    let end = min(3, offset + width)
                    let value = driver.call("dot_fragment", [ValueField("record_digest", textValue("exact-record")),
                        ValueField("index", integerValue(index)), ValueField("revision", integerValue(1)),
                        ValueField("dimension", integerValue(3)), ValueField("offset", integerValue(offset)),
                        ValueField("query", listValue(queries[index][offset..end].map { x => exactFloat64Value(x) })),
                        ValueField("vector", listValue(vectors[index][offset..end].map { x => exactFloat64Value(x) })), ValueField("sum", sum)])
                    sum = value.field("sum").getOrThrow(); offset = end
                }
                @Expect(decodeExactFloat64(sum).toBits(), expected.toBits())
            }
        }
    }
    @TestCase
    func pagedNanBarriersAndInputFailuresMatchTheActualWholeCorpusLegacyOracle(): Unit {
        let now: Int64 = 1700000000000; let records = ArrayList<AgentValue>(); let vectors = ArrayList<AgentValue>()
        let infinity = Float64.fromBits(0x7ff0000000000000)
        for (index in 0..257) {
            let record = memoryIeeeRecord(index, now); records.add(record)
            // Boundaries 0/127/128/255/256 exercise barriers at both sides of
            // a physical page. All embedding inputs here are valid under the
            // original contract; their dot products can still become NaN.
            let vector: Array<Float64> = if ([0, 127, 128, 255, 256].contains(index)) { [infinity, -infinity] }
                else if (index % 7 == 0) { [1.0e308, 1.0e308] }
                else if (index % 5 == 0) { [-infinity, -infinity] }
                else if (index % 3 == 0) { [-0.0, 0.0] } else { [Float64(index % 11 - 5), 1.0] }
            vectors.add(objectValue([ValueField("id", record.field("id").getOrThrow()), ValueField("revision", integerValue(1)),
                ValueField("vector", listValue(vector.map { x => exactFloat64Value(x) }))]))
        }
        for (rawQuery in [[1.0, 1.0], [1.0e308, 1.0e308], [infinity, 1.0], [Float64.fromBits(0x7ff8000000000001), 1.0]]) {
            let query = rawQuery.map { x => exactFloat64Value(x) }
            let input = objectValue([ValueField("schema", textValue("axyndra.memory-policy/v1")), ValueField("action", textValue("retrieve")),
                ValueField("snapshot_digest", textValue("original-whole-ieee")), ValueField("query", textValue("concise 文档")),
                ValueField("records", listValue(records.toArray())), ValueField("options", objectValue([ValueField("limit", integerValue(100)),
                    ValueField("semantic_enabled", boolValue(true)), ValueField("lexical_weight", integerValue(650)),
                    ValueField("semantic_weight", integerValue(350)), ValueField("now_millis", integerValue(now))])),
                ValueField("embeddings", objectValue([ValueField("state", textValue("ready")), ValueField("query", listValue(query)),
                    ValueField("records", listValue(vectors.toArray()))]))])
            let expected = memoryPolicyRetrieve(input)
            let actual = MemoryPagedOracleDriver().retrieve(records.toArray(), "ready", vectors.toArray(), now, queryVector: query)
            @Expect(canonicalAgentValue(actual.field("hits").getOrThrow()), canonicalAgentValue(expected.field("hits").getOrThrow()))
            @Expect(memoryPolicyText(actual, "strategy"), memoryPolicyText(expected, "strategy"))
            @Expect(actual.field("embedding_fallback").getOrThrow().asBool(), expected.field("embedding_fallback").getOrThrow().asBool())
        }
        // A NaN in a later record also invalidates the entire embedding result,
        // including semantic rows computed in already completed source pages.
        vectors[200].put("vector", listValue([exactFloat64Value(Float64.fromBits(0x7ff8000000000001)), integerValue(1)]))
        let actual = MemoryPagedOracleDriver().retrieve(records.toArray(), "ready", vectors.toArray(), now)
        @Expect(memoryPolicyText(actual, "strategy"), "lexical_fallback")
        @Expect(actual.field("embedding_fallback").getOrThrow().asBool())
    }
}
