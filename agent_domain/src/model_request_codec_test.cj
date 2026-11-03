package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelRequestCodecTests {
    @TestCase
    func existingCheckpointFieldsAndSemanticDigestRemainExact(): Unit {
        let request = ModelRequest("fixture", [ModelMessage(ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: "hello 雪")])], thinking: ThinkingLevel.Off,
            requestId: "not-part-of-semantic-input", transportHardTimeoutMillis: 1234)
        let expected = parseUnifiedJson("{\"model\":\"fixture\",\"system\":\"\",\"messages\":[{\"role\":\"user\",\"blocks\":[{" +
            "\"kind\":\"text\",\"text\":\"hello 雪\",\"call_id\":\"\",\"name\":\"\",\"arguments\":{},\"is_error\":false," +
            "\"receipt_id\":\"\",\"image\":null,\"opaque_state\":null}]}],\"tools\":[],\"thinking\":\"off\"," +
            "\"wire_max_output_tokens\":2000,\"streaming\":false,\"parallel_tool_calls\":true,\"service_tier\":\"\"," +
            "\"cache_policy\":\"default\",\"cache_key\":\"\",\"tool_choice\":\"auto\",\"structured_output\":null,\"resolved_policy\":null}")
        @Expect(canonicalAgentValue(modelRequestSnapshotValue(request)) == canonicalAgentValue(expected))
        let restored = modelRequestFromSnapshotValue(expected, "new-provider-request").value().getOrThrow()
        @Expect(restored.requestId == "new-provider-request" && restored.transportHardTimeoutMillis == 0)
        @Expect(modelPolicySha256Text(canonicalAgentValue(modelRequestSnapshotValue(restored))) ==
            modelPolicySha256Text(canonicalAgentValue(expected)))
    }
    @TestCase
    func imageOpaqueReplayAndStructuredOutputRoundTripWithoutProviderSdk(): Unit {
        let schema = objectValue([ValueField("type", textValue("object"))])
        let request = ModelRequest("fixture", [ModelMessage(ModelRole.User, [
            ModelBlock(ModelBlockKind.Image, image: Some(ModelImage(ModelImageSourceKind.Base64, "AA==", mediaType: "image/png"))),
            ModelBlock(ModelBlockKind.Unknown, opaqueState: Some(OpaqueProviderState("profile", "wire", "opaque bytes",
                itemId: "remote-item", replayRequired: true)))])], thinking: ThinkingLevel.Off,
            structuredOutput: Some(StructuredOutputSpec("answer", schema)),
            tools: [ModelToolDefinition("read", "read", schema)])
        let frozen = modelRequestSnapshotValue(request).stringify()
        let restored = modelRequestFromSnapshotValue(parseUnifiedJson(frozen), "request").value().getOrThrow()
        @Expect(canonicalAgentValue(modelRequestSnapshotValue(restored)) == canonicalAgentValue(parseUnifiedJson(frozen)))
        @Expect(restored.messages[0].blocks[1].opaqueState.getOrThrow().replayRequired)
        @Expect(restored.messages[0].blocks[0].image.getOrThrow().data == "AA==")
    }
    @TestCase
    func malformedCheckpointRejectsInsteadOfInventingMissingControls(): Unit {
        let original = modelRequestSnapshotValue(ModelRequest("fixture", []))
        let changed = parseUnifiedJson(original.stringify())
        changed.put("tool_choice", textValue("unrecognized-policy"))
        @Expect(modelRequestFromSnapshotValue(changed, "request").isError())
        changed.put("tool_choice", textValue("auto")); changed.put("wire_max_output_tokens", integerValue(0))
        @Expect(modelRequestFromSnapshotValue(changed, "request").isError())
        @Expect(modelRequestFromSnapshotValue(objectValue([]), "request").isError())
    }
    @TestCase
    func wirePolicyKeepsHardTimeoutOutsideSemanticRequest(): Unit {
        let first = ModelRequest("fixture", [], thinking: ThinkingLevel.Off, transportHardTimeoutMillis: 10)
        let second = ModelRequest("fixture", [], thinking: ThinkingLevel.Off, transportHardTimeoutMillis: 11)
        @Expect(canonicalAgentValue(modelRequestSnapshotValue(first)) == canonicalAgentValue(modelRequestSnapshotValue(second)))
        @Expect(modelRequestWirePolicyDigest(first) != modelRequestWirePolicyDigest(second))
        @Expect(modelRequestWirePolicyDigest(first) == modelPolicySha256Text(
            "wire-policy-v1\nfixture\n2000\nauto\ntransport_hard_timeout_millis=10\noff"))
    }
}
