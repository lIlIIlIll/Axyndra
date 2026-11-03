package agent_domain

import yjson.JsonNode
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCanonicalComparisonTests {
    @TestCase
    func wholeOriginalCanonicalOracleMatchesEveryTypeAndPair(): Unit {
        let values = [nullValue(), boolValue(false), boolValue(true), numberValue("-0"),
            numberValue("0"), numberValue("1.50e2"), textValue("雪🙂\u{0}\n:"),
            textValue(""), listValue([]), objectValue([]),
            objectValue([ValueField("z", textValue("9:")), ValueField("a", listValue([
                numberValue("-0"), nullValue(), objectValue([ValueField("雪", boolValue(true)),
                    ValueField("a", textValue("\"\\\u{0}"))])]))])]
        for (left in values) { for (right in values) {
            let witness = canonicalAgentValue(right)
            @Expect(canonicalAgentValueMatches(left, witness), canonicalAgentValue(left) == witness)
        } }
    }
    @TestCase
    func lateValueRawNumberFramesAndTrailingBytesCannotMatch(): Unit {
        let value = objectValue([ValueField("b", textValue("tail雪🙂")),
            ValueField("a", listValue([numberValue("-0"), textValue("1:[]{}"), nullValue()]))])
        let witness = canonicalAgentValue(value)
        @Expect(canonicalAgentValueMatches(value, witness), true)
        @Expect(canonicalAgentValueMatches(value, witness + "\u{0}"), false)
        @Expect(canonicalAgentValueMatches(value, witness[..witness.size - 1]), false)
        @Expect(canonicalAgentValueMatches(value, "x" + witness), false)
        @Expect(canonicalAgentValueMatches(numberValue("-0"), canonicalAgentValue(numberValue("0"))), false)
        @Expect(canonicalAgentValueMatches(textValue("雪"), "s1:雪"), false)
        let changed = objectValue([ValueField("a", listValue([numberValue("-0"), textValue("1:[]{}"), nullValue()])),
            ValueField("b", textValue("tail雪🙃"))])
        @Expect(canonicalAgentValueMatches(changed, witness), false)
    }
    @TestCase
    func fullNeutralModelHistoryAndLateToolArgumentsRemainCompared(): Unit {
        let prior = ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "完整前序历史雪🙂")])
        let original = modelRequestSnapshotValue(ModelRequest("model", [prior,
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, callId: "call", name: "tool",
                arguments: objectValue([ValueField("early", textValue("same")), ValueField("late", textValue("original"))]))])],
            system: "system", streaming: true, requestId: "data-only-comparison"))
        let witness = canonicalAgentValue(original)
        let reordered = parseUnifiedJson(original.stringify())
        @Expect(canonicalAgentValueMatches(reordered, witness), true)
        let changed = modelRequestSnapshotValue(ModelRequest("model", [prior,
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, callId: "call", name: "tool",
                arguments: objectValue([ValueField("early", textValue("same")), ValueField("late", textValue("changed"))]))])],
            system: "system", streaming: true, requestId: "data-only-comparison"))
        @Expect(canonicalAgentValueMatches(changed, witness), false)
    }
    @TestCase
    func fullEightMiBNulAndItsExistingWitnessStayInOriginalBank(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let owner = pool.acquire(8388608)
        owner.ensureRetainedPeak(67174400)
        try { modelCanonicalCompareLargeFixture() } finally { owner.close() }
        // The helper frame and all complete raw/witness references ended
        // before retirement. This is a data-only bank control, no Source/ACK.
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}

private func modelCanonicalCompareLargeFixture(): Unit {
    let raw = String.fromUtf8(Array<Byte>(8388608, repeat: 0))
    let actual = textValue(raw)
    // Independent original scalar framing; no second canonical serialization.
    let witness = "s8388608:" + raw
    @Expect(canonicalAgentValueMatches(actual, witness), true)
    @Expect(canonicalAgentValueMatches(actual, witness + "x"), false)
    let changed = textValue(raw[..raw.size - 1] + "x")
    @Expect(canonicalAgentValueMatches(changed, witness), false)
}
