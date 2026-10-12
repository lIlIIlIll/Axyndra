package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCanonicalValueEqualityTests {
    @TestCase
    func originalWholeCanonicalOracleAcrossTypesAndStableDuplicateNames(): Unit {
        // A0-03: the pinned JsonObject cannot contain duplicate names. Keep
        // both original ordered inputs at the real Reject/LastWins boundary;
        // the whole writer oracle below compares all 16 supported nodes.
        let duplicateForward = "{\"same\":-0,\"same\":0}"
        let duplicateReverse = "{\"same\":0,\"same\":-0}"
        @Expect(modelCanonicalFixtureDuplicateRejected(duplicateForward), true)
        @Expect(modelCanonicalFixtureDuplicateRejected(duplicateReverse), true)
        let forward = modelCanonicalFixtureJson(duplicateForward, JsonDuplicateKeyPolicy.LastWins)
        let reverse = modelCanonicalFixtureJson(duplicateReverse, JsonDuplicateKeyPolicy.LastWins)
        @Expect(forward.asObject().size(), 1); @Expect(reverse.asObject().size(), 1)
        @Expect(forward.field("same").getOrThrow().asNumberText(), "0")
        @Expect(reverse.field("same").getOrThrow().asNumberText(), "-0")
        @Expect(canonicalAgentValue(forward), canonicalAgentValue(objectValue([ValueField("same", numberValue("0"))])))
        @Expect(canonicalAgentValue(reverse), canonicalAgentValue(objectValue([ValueField("same", numberValue("-0"))])))
        let values = [nullValue(), boolValue(false), boolValue(true), numberValue("-0"),
            numberValue("0"), numberValue("1.0"), numberValue("1e0"), textValue("雪🙂\u{0}:[]{}"),
            textValue(""), listValue([]), objectValue([]), listValue([textValue("a"), numberValue("1")]),
            objectValue([ValueField("z", textValue("tail")), ValueField("a", listValue([nullValue(), boolValue(true)]))]),
            objectValue([ValueField("a", listValue([nullValue(), boolValue(true)])), ValueField("z", textValue("tail"))]),
            forward, reverse]
        for (left in values) { for (right in values) {
            @Expect(canonicalAgentValuesEqual(left, right), canonicalAgentValue(left) == canonicalAgentValue(right))
        } }
    }
    @TestCase
    func completeModelHistoryLateArgumentsAndRawNumbersRemainDistinct(): Unit {
        let prior = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "完整历史雪🙂")])
        let original = modelRequestSnapshotValue(ModelRequest("model", [prior,
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, callId: "call", name: "tool",
                arguments: objectValue([ValueField("early", textValue("same")), ValueField("late", numberValue("-0"))]))])],
            system: "system", streaming: true, requestId: "data-only-comparison"))
        // The pinned generic DOM parser turns integer -0 into 0. Its typed
        // JsonReader.readNode entry keeps every raw number literal unchanged.
        let reparsed = modelCanonicalFixtureJson(original.stringify(), JsonDuplicateKeyPolicy.Reject)
        @Expect(YJson.toJson(original, codec: ModelCanonicalFixtureNodeCodec()), original.stringify())
        @Expect(canonicalAgentValue(reparsed), canonicalAgentValue(original))
        let normalized = parseUnifiedJson(original.stringify())
        @Expect(canonicalAgentValuesEqual(original, normalized), canonicalAgentValue(original) == canonicalAgentValue(normalized))
        @Expect(canonicalAgentValuesEqual(original, normalized), false)
        @Expect(canonicalAgentValuesEqual(original, reparsed), true)
        let changed = modelRequestSnapshotValue(ModelRequest("model", [prior,
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, callId: "call", name: "tool",
                arguments: objectValue([ValueField("early", textValue("same")), ValueField("late", numberValue("0"))]))])],
            system: "system", streaming: true, requestId: "data-only-comparison"))
        @Expect(canonicalAgentValuesEqual(original, changed), false)
        @Expect(canonicalAgentValuesEqual(listValue([original, changed]), listValue([changed, original])), false)
    }
    @TestCase
    func completeEightMiBNulAndLastByteDifferenceUseOriginalPaidBank(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let owner = pool.acquire(8388608)
        owner.ensureRetainedPeak(67174400)
        try { modelCanonicalValueEqualityLargeFixture() } finally { owner.close() }
        // The helper frame and all raw/DOM references have ended. This is
        // one data-only comparison fixture, never a Source or retired grant.
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}

// This codec delegates decoding to the actual pinned SDK semantic reader.
// It neither reconstructs the request nor changes the production comparator.
private class ModelCanonicalFixtureNodeCodec <: JsonCodec<JsonNode> {
    public func read(reader: JsonReader): JsonNode { reader.readNode() }
    public func write(value: JsonNode, writer: JsonWriter): Unit {
        match (value.kind()) {
            case JsonKind.Null => writer.writeNull()
            case JsonKind.Boolean => writer.writeBool(value.asBool())
            case JsonKind.Number => writer.writeNumberLiteral(value.asNumberText())
            case JsonKind.String => writer.writeString(value.asString())
            case JsonKind.Array =>
                writer.startArray()
                let array = value.asArray()
                for (index in 0..array.size()) { write(array.get(index).getOrThrow(), writer) }
                writer.endArray()
            case JsonKind.Object =>
                writer.startObject()
                let object = value.asObject()
                for (index in 0..object.size()) {
                    writer.writeName(object.nameAt(index)); write(object.valueAt(index), writer)
                }
                writer.endObject()
        }
    }
}

private func modelCanonicalFixtureJson(source: String, policy: JsonDuplicateKeyPolicy): AgentValue {
    YJson.fromJson(source, codec: ModelCanonicalFixtureNodeCodec(), options: JsonReadOptions(
        duplicateKeyPolicy: policy, maxDepth: 64, maxStringBytes: 1048576,
        maxInputBytes: 1048576, maxBufferedValueBytes: 1048576))
}

private func modelCanonicalFixtureDuplicateRejected(source: String): Bool {
    try {
        let _ = modelCanonicalFixtureJson(source, JsonDuplicateKeyPolicy.Reject)
        false
    } catch (error: JsonException) { error.code == "duplicate_key" }
}

private func modelCanonicalValueEqualityLargeFixture(): Unit {
    let raw = String.fromUtf8(Array<Byte>(8388608, repeat: 0))
    let original = objectValue([ValueField("value", textValue(raw)), ValueField("meta", boolValue(true))])
    let copied = objectValue([ValueField("meta", boolValue(true)),
        ValueField("value", textValue(String.fromUtf8(raw.toArray())))])
    @Expect(canonicalAgentValuesEqual(original, copied), true)
    let changed = objectValue([ValueField("meta", boolValue(true)),
        ValueField("value", textValue(raw[..raw.size - 1] + "x"))])
    @Expect(canonicalAgentValuesEqual(original, changed), false)
}
