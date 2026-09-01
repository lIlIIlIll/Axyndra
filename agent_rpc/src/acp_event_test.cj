package agent_rpc

import yjson_support.*

import yjson.*

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class AcpTypedEventProjectionTests {
    @TestCase
    func typedModelEventsRejectUntypedExtensionDetailCodes(): Unit {
        let event = AgentEvent(
            EventMeta(
                7,
                TraceId("acp-trace"),
                RunId("acp-run"),
                occurredAtMillis: 42,
                requestId: Some(RequestId("acp-request"))
            ),
            AgentEventPayload.TextDelta("hello")
        )

        let update = acpUpdateFromEvent(event).getOrThrow()

        @Expect(acpTestText(update, "sessionUpdate"), "agent_message_chunk")
        @Expect(acpTestText(update, "messageId"), "acp-run")
        @Expect(match (update.field("content")) {
            case Some(value) => acpTestText(value, "text") == "hello"
            case None => false
        })
        @Expect(acpUpdateFromEvent(AgentEvent(
            EventMeta(1, TraceId("extension-trace"), RunId("extension-run")),
            AgentEventPayload.Extension(
                AgentEventKind.Model,
                objectValue([
                    ValueField("code", textValue("model.text_delta")),
                    ValueField("text", textValue("extension"))
                ])
            )
        )).isNone())
    }

    @TestCase
    func typedToolEventsKeepCallCorrelationAndLifecycle(): Unit {
        let started = acpUpdateFromEvent(acpToolEvent(
            1,
            AgentEventPayload.ToolStarted(ToolCallId("call-1"), "bash", 0)
        )).getOrThrow()
        let output = acpUpdateFromEvent(acpToolEvent(
            2,
            AgentEventPayload.ToolOutput(
                ToolCallId("call-1"),
                ToolOutputChannel.Stderr,
                "warning"
            )
        )).getOrThrow()
        let completed = acpUpdateFromEvent(acpToolEvent(
            3,
            AgentEventPayload.ToolCompleted(ToolCallId("call-1"), false, 0)
        )).getOrThrow()

        @Expect(acpTestText(started, "sessionUpdate"), "tool_call")
        @Expect(acpTestText(started, "toolCallId"), "call-1")
        @Expect(acpTestText(started, "status"), "in_progress")
        @Expect(acpTestText(output, "toolCallId"), "call-1")
        @Expect(match (output.field("rawOutput")) {
            case Some(value) => acpTestText(value, "channel") == "stderr" &&
                acpTestText(value, "delta") == "warning"
            case None => false
        })
        @Expect(acpTestText(completed, "toolCallId"), "call-1")
        @Expect(acpTestText(completed, "status"), "failed")
    }
}

func acpToolEvent(sequence: Int64, payload: AgentEventPayload): AgentEvent {
    AgentEvent(
        EventMeta(
            sequence,
            TraceId("acp-tool-trace"),
            RunId("acp-tool-run"),
            occurredAtMillis: sequence,
            toolCallId: Some(ToolCallId("call-1"))
        ),
        payload
    )
}

func acpTestText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}
