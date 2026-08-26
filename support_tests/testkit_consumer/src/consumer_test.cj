package testkit_consumer

import agent_sdk.*
import yjson.*
import yjson_support.*
import axyndra_agent_testkit.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ExternalTestkitConsumerTests {
    @TestCase
    func preparesAndDecodesThroughPublicSdkHarness() {
        let harness = ExtensionContractHarness(ConsumerExtension())
        let input = jsonObject([
            JsonObjectEntry("text", jsonString("hello"))
        ])
        let prepared = requireSdkOk(harness.prepare(
            "consumer_echo",
            input,
            callId: SequenceIds(prefix: "external").next(scope: "call")
        ))
        assertCapabilityRequested(prepared.definition, "workspace.read")
        @Expect(harness.prepare("consumer_echo", jsonObject([])).isOk(), false)
        let output = requireSdkOk(harness.decode(
            prepared,
            ExecutionResult(jsonObject([
                JsonObjectEntry("text", jsonString("done"))
            ]))
        ))
        @Expect(output.structured.field("text").getOrThrow().text, "done")
    }
}
