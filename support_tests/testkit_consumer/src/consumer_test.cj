package testkit_consumer

import agent_sdk.*
import json4cj.*
import omp_agent_testkit.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExternalTestkitConsumerTests {
    @TestCase
    func preparesAndDecodesThroughPublicSdkHarness() {
        let harness = ExtensionContractHarness(ConsumerExtension())
        let input = JsonValue.objectValue([
            JsonField("text", JsonValue.stringValue("hello"))
        ])
        let prepared = requireSdkOk(harness.prepare(
            "consumer_echo",
            input,
            callId: SequenceIds(prefix: "external").next(scope: "call")
        ))
        assertCapabilityRequested(prepared.definition, "workspace.read")
        @Expect(harness.prepare("consumer_echo", JsonValue.objectValue([])).isOk(), false)
        let output = requireSdkOk(harness.decode(
            prepared,
            ExecutionResult(JsonValue.objectValue([
                JsonField("text", JsonValue.stringValue("done"))
            ]))
        ))
        @Expect(output.structured.field("text").getOrThrow().text, "done")
    }
}
