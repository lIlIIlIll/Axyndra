package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256

@Test
class ModelCanonicalDigestStreamTests {
    @TestCase
    func everyCanonicalTypeOrderingUnicodeAndFramingMatchesOriginal(): Unit {
        let values = [nullValue(), boolValue(false), boolValue(true), numberValue("-123.5"),
            textValue("雪🙂\u{0}\n:"), listValue([]), objectValue([]),
            objectValue([ValueField("z", textValue("9:")), ValueField("a", listValue([
                numberValue("-0"), nullValue(), objectValue([ValueField("雪", boolValue(true)),
                    ValueField("a", textValue("\"\\\u{0}"))])]))])]
        for (value in values) {
            @Expect(canonicalAgentValueSha256(value), modelPolicySha256Text(canonicalAgentValue(value)))
        }
    }
    @TestCase
    func completeNeutralModelRequestStillUsesOriginalCanonicalSemanticDigest(): Unit {
        let request = ModelRequest("model", [ModelMessage(ModelRole.User, [
            ModelBlock(ModelBlockKind.Text, text: "完整历史雪🙂"),
            ModelBlock(ModelBlockKind.Image, image: Some(ModelImage(ModelImageSourceKind.Url, "https://fixture/image")))]),
            ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, callId: "call", name: "tool",
                arguments: objectValue([ValueField("z", numberValue("2")), ValueField("a", textValue("完整"))]))])],
            tools: [ModelToolDefinition("tool", "description", objectValue([ValueField("type", textValue("object"))]))],
            system: "system", streaming: true, requestId: "digest-only-no-authority")
        let value = modelRequestSnapshotValue(request)
        @Expect(canonicalAgentValueSha256(value), modelPolicySha256Text(canonicalAgentValue(value)))
    }
    @TestCase
    func fullEightMiBNulHashHasNoCompleteCanonicalStringOracle(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let owner = pool.acquire(8388608)
        owner.ensureRetainedPeak(67174400)
        var value: ?AgentValue = None
        try {
            value = Some(textValue(String.fromUtf8(Array<Byte>(8388608, repeat: 0))))
            let expected = SHA256()
            expected.write("s8388608:".toArray())
            let zeros = Array<Byte>(65536, repeat: 0)
            for (_ in 0..128) { expected.write(zeros) }
            @Expect(canonicalAgentValueSha256(value.getOrThrow()), logicalJsonEncodeHex(expected.finish()))
        } finally { value = None; owner.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
