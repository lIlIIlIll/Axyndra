package model_provider_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class CompactReplyCounter {
    var value: Int64
    init(value: Int64) { this.value = value }
}

func compactTestReply(): ModelReply {
    ModelReply([ModelBlock(ModelBlockKind.Text, text: "alpha 雪"),
        ModelBlock(ModelBlockKind.Reasoning, text: "reason λ"), ModelBlock(ModelBlockKind.Text, text: " omega")],
        providerId: "fixture", responseId: "response", stopReason: "stop",
        terminalEvidence: Some(TerminalEvidence("fixture", "terminal", rawStopReason: "stop",
            messageTerminalObserved: true, streamEofObserved: true, adapterVersion: "fixture-1")),
        completionDisposition: CompletionDisposition.Complete, decisionOutcome: DecisionOutcome.Response,
        validationVersion: 1)
}
func compactTestRejected(value: AgentValue, text: String, reasoning: String): Bool {
    try { let _ = restoreModelProviderStreamReply(value, text, reasoning); false }
    catch (_: Exception) { true }
}

@Test
class CompactModelReplyTests {
    @TestCase
    func compactReferencesCannotBypassOrdinaryEncodedFinalFrameLimit(): Unit {
        let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint()
        let text = String.fromUtf8(Array<UInt8>(270000, repeat: 120u8))
        endpoint.action = { dispatch, frames =>
            let identity = dispatch.identity(); let sequence = CompactReplyCounter(1)
            let send = { kind: String, payload: AgentValue =>
                let result = frames(modelProviderFrame(identity, sequence.value, kind, payload)); sequence.value++; result }
            let _ = send("event", objectValue([ValueField("kind", textValue("started")), ValueField("protocol", textValue("fixture"))]))
            for (offset in [0, 90000, 180000]) {
                let _ = send("event", objectValue([ValueField("kind", textValue("text")), ValueField("text", textValue(text[offset..offset + 90000]))]))
            }
            let _ = send("event", objectValue([ValueField("kind", textValue("terminal")),
                ValueField("evidence", modelProviderTerminalValue(providerTestReply().terminalEvidence.getOrThrow()))]))
            let _ = send("event", objectValue([ValueField("kind", textValue("transport_closed"))]))
            send("reply_stream", modelProviderStreamReplyValue(providerTestReply(text: text)))
        }
        let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { _ => () })
        @Expect(result.error().getOrThrow().code, "model.provider_output_limit")
    }
    @TestCase
    func exactUnicodeRangesPreserveNeutralBlocksAndMetadata(): Unit {
        let reply = compactTestReply()
        let value = modelProviderStreamReplyValue(reply)
        for (block in value.field("reply").getOrThrow().field("blocks").getOrThrow().items) {
            @Expect(block.field("text").getOrThrow().text == "")
        }
        let restored = restoreModelProviderStreamReply(value, "alpha 雪 omega", "reason λ")
        @Expect(canonicalAgentValue(restored) == canonicalAgentValue(modelProviderReplyValue(reply)))
        @Expect(providerReply(restored).blocks[0].text == "alpha 雪")
    }

    @TestCase
    func malformedOrIncompleteReferencesCannotBorrowObservedBytes(): Unit {
        for (mode in ["offset", "hash", "kind", "index", "overflow", "utf8", "duplicate", "inline", "leftover", "foreign"]) {
            let value = modelProviderStreamReplyValue(compactTestReply())
            let references = value.field("references").getOrThrow()
            let first = references.items[0]
            if (mode == "offset") { first.put("offset", integerValue(1)) }
            if (mode == "hash") { first.put("sha256", textValue(modelPolicySha256Text("other"))) }
            if (mode == "kind") { first.put("kind", textValue("reasoning")) }
            if (mode == "index") { first.put("block_index", integerValue(1)) }
            if (mode == "overflow") { first.put("length", integerValue(Int64.Max)) }
            if (mode == "utf8") { first.put("length", integerValue(7)) }
            if (mode == "duplicate") { value.put("references", listValue([first, first, references.items[2]])) }
            if (mode == "inline") { value.field("reply").getOrThrow().field("blocks").getOrThrow().items[0].put("text", textValue("invented")) }
            @Expect(compactTestRejected(value,
                if (mode == "leftover") { "alpha 雪 omega extra" } else if (mode == "foreign") { "other 雪 omega" } else { "alpha 雪 omega" },
                "reason λ"))
        }
    }

    @TestCase
    func compactFrameRequiresSameAttemptTerminalAndObservedStream(): Unit {
        for (mode in ["success", "foreign", "no_terminal", "cancelled", "duplicate"]) {
            let gate = ProviderTestGate(); let endpoint = ProviderTestEndpoint(); let completed = CompactReplyCounter(0)
            endpoint.action = { dispatch, frames =>
                let identity = dispatch.identity(); let sequence = CompactReplyCounter(1)
                let send = { kind: String, payload: AgentValue =>
                    let result = frames(modelProviderFrame(identity, sequence.value, kind, payload)); sequence.value++; result }
                let _ = send("event", objectValue([ValueField("kind", textValue("started")), ValueField("protocol", textValue("fixture"))]))
                let _ = send("event", objectValue([ValueField("kind", textValue("text")), ValueField("text", textValue("hello"))]))
                if (mode != "no_terminal") {
                    let _ = send("event", objectValue([ValueField("kind", textValue("terminal")),
                        ValueField("evidence", modelProviderTerminalValue(providerTestReply().terminalEvidence.getOrThrow()))]))
                }
                let _ = send("event", objectValue([ValueField("kind", textValue("transport_closed"))]))
                if (mode == "foreign") { identity.put("attempt_id", textValue("another-attempt")) }
                if (mode == "cancelled") { gate.allowed = false }
                let result = send("reply_stream", modelProviderStreamReplyValue(providerTestReply()))
                if (mode == "duplicate") { return send("reply_stream", modelProviderStreamReplyValue(providerTestReply())) }
                result
            }
            let result = PluginModelPort(providerTestBinding(), gate, endpoint).execute(providerTestRequest(), { event =>
                match (event) { case ModelEvent.Completed => completed.value++; case _ => () } })
            @Expect(result.isOk() == (mode == "success"))
            @Expect(completed.value == if (mode == "success") { 1 } else { 0 })
        }
    }

    @TestCase
    func nearEightMiBTextHasSmallTerminalWithoutChangingSemanticLimit(): Unit {
        let text = String.fromUtf8(Array<UInt8>(8387584, repeat: 120u8))
        let reply = providerTestReply(text: text)
        let value = modelProviderStreamReplyValue(reply)
        @Expect(value.stringify().size < 4096)
        let restored = providerReply(restoreModelProviderStreamReply(value, text, ""))
        @Expect(restored.blocks[0].text.size == 8387584)
        @Expect(modelPolicySha256Text(restored.blocks[0].text) == modelPolicySha256Text(text))
    }
}
