package llm4cj

import json4cj.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Llm4CjTests {
    @TestCase
    func parsesFragmentedAndMultipleSseEvents() {
        let decoder = SseDecoder(maxEventBytes: 1024)
        match (decoder.push("event: delta\ndata: hel")) {
            case LlmResult.Ok(events) => @Expect(events.size, 0)
            case LlmResult.Err(error) => @Fail(error.message)
        }
        match (decoder.push("lo\n\ndata: one\ndata: two\n\n")) {
            case LlmResult.Ok(events) =>
                @Expect(events.size, 2)
                @Expect(events[0].event, "delta")
                @Expect(events[0].data, "hello")
                @Expect(events[1].data, "one\ntwo")
            case LlmResult.Err(error) => @Fail(error.message)
        }
        @Expect(decoder.finish().isOk(), true)
    }

    @TestCase
    func rejectsOversizedSseAndBodies() {
        let decoder = SseDecoder(maxEventBytes: 4)
        @Expect(decoder.push("data: hello\n\n").isOk(), false)

        let body = ByteBuffer()
        body.write("hello".toArray())
        @Expect(readLlmHttpBody(body, Some(5), 4).isOk(), false)
    }

    @TestCase
    func parsesRetryAfterWithoutOwningAgentBackoffPolicy() {
        @Expect(parseRetryAfterMillis("5"), 5000)
        @Expect(parseRetryAfterMillis("-1"), 0)
        @Expect(extractRetryAfterMillis("x: y\nRetry-After: 7\n"), 7000)
        @Expect(parseRetryAfterMillis("9223372036854775807"), Int64.Max)
    }

    @TestCase
    func ownsProviderRequestCodecs() {
        let request = LlmWireRequest(
            "model-x",
            [LlmWireMessage(LlmWireRole.User, [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")])],
            tools: [LlmWireTool("lookup", "find", JsonValue.objectValue([JsonField("type", JsonValue.stringValue("object"))]))],
            maxOutputTokens: 64,
            streaming: true,
            structuredOutput: Some(LlmWireStructuredOutput("answer", JsonValue.objectValue([JsonField("type", JsonValue.stringValue("object"))])))
        )
        @Expect(encodeResponsesWireRequest(request).contains("\"max_output_tokens\":64"), true)
        @Expect(encodeChatCompletionsWireRequest(request).contains("\"response_format\""), true)
        let messagesRequest = LlmWireRequest(
            request.model,
            request.messages,
            tools: request.tools,
            thinking: LlmWireThinkingControl.Budget(8192),
            maxOutputTokens: request.maxOutputTokens,
            streaming: request.streaming,
            structuredOutput: request.structuredOutput
        )
        let messagesPayload = encodeMessagesWireRequest(messagesRequest)
        @Expect(messagesPayload.contains("\"input_schema\""), true)
        @Expect(messagesPayload.contains("\"budget_tokens\":8192"), true)
    }

    @TestCase
    func deepSeekMessagesUsesExplicitEffortDialect() {
        let request = LlmWireRequest(
            "deepseek-model",
            [LlmWireMessage(
                LlmWireRole.User,
                [LlmWireBlock(LlmWireBlockKind.Text, text: "hello")]
            )],
            thinking: LlmWireThinkingControl.Effort(LlmWireThinkingLevel.Max),
            maxOutputTokens: 4096,
            structuredOutput: Some(LlmWireStructuredOutput(
                "answer",
                JsonValue.objectValue([JsonField(
                    "type", JsonValue.stringValue("object")
                )])
            ))
        )
        let payload = encodeDeepSeekMessagesWireRequest(request)
        @Expect(payload.contains("\"thinking\":{\"type\":\"enabled\"}"), true)
        @Expect(payload.contains("\"output_config\":{\"format\":"), true)
        @Expect(payload.contains("\"effort\":\"max\""), true)
        @Expect(payload.contains("budget_tokens"), false)

        let disabled = encodeDeepSeekMessagesWireRequest(LlmWireRequest(
            request.model,
            request.messages,
            thinking: LlmWireThinkingControl.Toggle(false),
            maxOutputTokens: request.maxOutputTokens
        ))
        @Expect(disabled.contains("\"thinking\":{\"type\":\"disabled\"}"), true)

        try {
            let _ = encodeDeepSeekMessagesWireRequest(LlmWireRequest(
                request.model,
                request.messages,
                thinking: LlmWireThinkingControl.Budget(2048),
                maxOutputTokens: request.maxOutputTokens
            ))
            @Fail("DeepSeek Messages must reject numeric thinking budgets")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.deepseek_thinking_mode_invalid")
        }
    }

    @TestCase
    func decodesAllProviderRepliesAndPreservesUsage() {
        let messages = decodeMessagesWireReply("{\"id\":\"m1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"lookup\",\"input\":{\"q\":\"x\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}")
        @Expect(messages.blocks[0].name, "lookup")
        @Expect(messages.usage.inputTokens, 3)

        let responses = decodeResponsesWireReply("{\"id\":\"r1\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}")
        @Expect(responses.blocks[0].text, "ok")
        @Expect(responses.responseId, "r1")

        let chat = decodeChatCompletionsWireReply("{\"id\":\"c1\",\"choices\":[{\"message\":{\"content\":\"done\",\"tool_calls\":[]},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
        @Expect(chat.stopReason, "stop")
        @Expect(chat.usage.outputTokens, 2)
    }

    @TestCase
    func decodesProviderStreamsAndStructuredErrors() {
        let responses = decodeLlmWireEventStream(
            LlmWireProtocol.Responses,
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"o\"}\n\n" +
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
        )
        match (responses.events[0].kind) {
            case LlmWireEventKind.StreamStarted => ()
            case _ => @Fail("expected stream start")
        }
        match (responses.events[1].kind) {
            case LlmWireEventKind.TextDelta => ()
            case _ => @Fail("expected text delta")
        }
        @Expect(decodeResponsesWireReply(responses.terminalSource).blocks[0].text, "ok")

        try {
            let _ = decodeMessagesWireReply("{\"error\":{\"type\":\"invalid_request_error\",\"code\":\"bad\",\"message\":\"invalid\"}}", provider: "anthropic")
            @Fail("provider error should be structured")
        } catch (error: LlmTransportError) {
            @Expect(error.provider, "anthropic")
            @Expect(error.providerErrorCode, "bad")
            @Expect(error.providerErrorType, "invalid_request_error")
        }
    }

    @TestCase
    func requiresProviderTerminalEvidenceBeforeCompletingDecision() {
        let complete = decodeLlmWireEventStream(
            LlmWireProtocol.Messages,
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"usage\":{}}}\n\n" +
            "data: {\"type\":\"content_block_start\",\"index\":0," +
                "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" +
            "data: {\"type\":\"content_block_delta\",\"index\":0," +
                "\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" +
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}," +
                "\"usage\":{\"output_tokens\":1}}\n\n" +
            "data: {\"type\":\"message_stop\"}\n\n"
        )
        var terminalObserved = false
        var blockCompleted = false
        var usageCompleted = false
        for (event in complete.events) {
            match (event.kind) {
                case LlmWireEventKind.MessageTerminalObserved => terminalObserved = true
                case LlmWireEventKind.ContentBlockCompleted => blockCompleted = true
                case LlmWireEventKind.UsageCompleted => usageCompleted = true
                case _ => ()
            }
        }
        @Expect(terminalObserved && blockCompleted && usageCompleted, true)

        try {
            let _ = decodeLlmWireEventStream(
                LlmWireProtocol.Messages,
                "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"usage\":{}}}\n\n" +
                "data: {\"type\":\"content_block_start\",\"index\":0," +
                    "\"content_block\":{\"type\":\"text\",\"text\":\"partial\"}}\n\n"
            )
            @Fail("partial Messages stream must not become a decision")
        } catch (error: LlmTransportError) {
            @Expect(error.code, "llm.messages_terminal_missing")
        }
    }
}
