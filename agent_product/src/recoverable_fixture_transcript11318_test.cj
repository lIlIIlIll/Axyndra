package agent_product

import agent_domain.*
import model_fixture_runtime as fixture_runtime
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func recoverableFixtureRequest11318(text: String): ModelRequest {
    ModelRequest("fixture-model", [ModelMessage(ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: text)])],
        system: "fixed system雪", tools: [ModelToolDefinition("fixture-checkpoint",
            "fixed tool", objectValue([ValueField("type", textValue("object"))]))],
        thinking: ThinkingLevel.High, wireMaxOutputTokens: Some(1234),
        requestId: "fixture-request11318", streaming: false, parallelToolCalls: false,
        cacheKey: "frozen-cache", toolChoice: ModelToolChoice.Required)
}

@Test
class RecoverableFixtureTranscript11318Tests {
    @TestCase
    func actualFreshFixtureReproducesCompleteRequestAndOrderedPendingScript(): Unit {
        let original = fixture_runtime.FixtureModelPort()
        let reopened = fixture_runtime.FixtureModelPort()
        let arguments = objectValue([ValueField("text", textValue("original\u{0}雪🙂"))])
        original.enqueueToolCallReply("same-call", "fixture-checkpoint", arguments)
        reopened.enqueueToolCallReply("same-call", "fixture-checkpoint", arguments)
        let request = recoverableFixtureRequest11318("same request雪")
        let snapshot = original.transcriptSnapshot(request).getOrThrow()
        @Expect(snapshot != "")
        @Expect(reopened.validateTranscriptSnapshot(snapshot))
        @Expect(reopened.transcriptSnapshot(request).getOrThrow(), snapshot)
        let value = parseUnifiedJson(snapshot)
        @Expect(canonicalAgentValuesEqual(value.field("request").getOrThrow(), modelRequestSnapshotValue(request)))
        @Expect(value.field("request_id").getOrThrow().text, request.requestId)
        @Expect(value.field("calls").getOrThrow().asNumberText(), "0")
        @Expect(original.observedCallCount11318(), 0)
        @Expect(reopened.observedCallCount11318(), 0)
        // A valid different request produces a different transcript; Core's
        // unchanged exact regeneration/digest guard must reject substituting it.
        @Expect(reopened.transcriptSnapshot(recoverableFixtureRequest11318("changed request")).getOrThrow() != snapshot)
        let reply = reopened.execute(request, { _ => () }).value().getOrThrow()
        @Expect(reply.blocks[0].callId, "same-call")
        @Expect(reply.blocks[0].name, "fixture-checkpoint")
        @Expect(canonicalAgentValuesEqual(reply.blocks[0].arguments, arguments))
        @Expect(reopened.observedCallCount11318(), 1)
        @Expect(!reopened.validateTranscriptSnapshot(snapshot))
    }

    @TestCase
    func actualFixtureRejectsMalformedUnknownFaultAndScriptDrift(): Unit {
        let original = fixture_runtime.FixtureModelPort()
        let request = recoverableFixtureRequest11318("same request")
        original.enqueueToolCallReply("first", "fixture-checkpoint", objectValue([]))
        original.enqueueToolCallReply("second", "fixture-checkpoint", objectValue([]))
        let snapshot = original.transcriptSnapshot(request).getOrThrow()
        @Expect(!original.validateTranscriptSnapshot(""))
        @Expect(!original.validateTranscriptSnapshot("{}"))
        @Expect(!original.validateTranscriptSnapshot("{\"schema\":1,\"schema\":2}"))
        let extra = parseUnifiedJson(snapshot)
        let _ = extra.put("unknown", textValue("unaccepted"))
        @Expect(!original.validateTranscriptSnapshot(extra.stringify()))
        let missing = parseUnifiedJson(snapshot)
        let _ = missing.asObject().remove("request")
        @Expect(!original.validateTranscriptSnapshot(missing.stringify()))
        let wrongFault = fixture_runtime.FixtureModelPort(failFirst: true)
        wrongFault.enqueueToolCallReply("first", "fixture-checkpoint", objectValue([]))
        wrongFault.enqueueToolCallReply("second", "fixture-checkpoint", objectValue([]))
        @Expect(!wrongFault.validateTranscriptSnapshot(snapshot))
        let wrongOrder = fixture_runtime.FixtureModelPort()
        wrongOrder.enqueueToolCallReply("second", "fixture-checkpoint", objectValue([]))
        wrongOrder.enqueueToolCallReply("first", "fixture-checkpoint", objectValue([]))
        @Expect(!wrongOrder.validateTranscriptSnapshot(snapshot))
        let changedArguments = fixture_runtime.FixtureModelPort()
        changedArguments.enqueueToolCallReply("first", "fixture-checkpoint", objectValue([ValueField("changed", boolValue(true))]))
        changedArguments.enqueueToolCallReply("second", "fixture-checkpoint", objectValue([]))
        @Expect(!changedArguments.validateTranscriptSnapshot(snapshot))
        let notRestored = fixture_runtime.FixtureModelPort()
        @Expect(!notRestored.validateTranscriptSnapshot(snapshot))
        @Expect(original.observedCallCount11318(), 0)
    }
}
