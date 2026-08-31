package model_adapters

import agent_domain as domain
import llm4cj.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class UsageProjectionTests {
    @TestCase
    func messagesTerminalUsageIncludesCacheBuckets(): Unit {
        let projected = ArrayList<domain.ModelEvent>()
        emitLlmWireEvent(
            LlmWireEvent.TerminalObserved(LlmWireTerminal.Completed(LlmWireReply(
                usage: LlmWireUsage(
                    inputTokens: Some(3), outputTokens: Some(4),
                    cacheReadTokens: Some(2), cacheWriteTokens: Some(1)
                )
            ))),
            ProviderProtocol.Messages,
            { event => projected.add(event) }
        )
        var completedInput: Int64 = -1
        for (event in projected) {
            match (event) {
                case domain.ModelEvent.ProviderProgress(
                    domain.ProviderStreamEvent.UsageCompleted(input, _)
                ) => completedInput = input
                case _ => ()
            }
        }
        @Expect(completedInput, 6)
    }
}

@Test
class CurlResponseCaptureTests {
    @TestCase
    func responseHeadersNeverShareModelBodyStdout(): Unit {
        let arguments = ArrayList<String>()
        appendCurlResponseCaptureArguments(arguments, "/tmp/response.headers")

        @Expect(arguments.size, 4)
        @Expect(arguments[2], "--dump-header")
        @Expect(arguments[3], "/tmp/response.headers")
        @Expect(!arguments.contains("-"))
    }
}

@Test
class RetryAfterParsingTests {
    @TestCase
    func retryAfterIsBoundedBeforeMillisConversion(): Unit {
        @Expect(parseRetryAfter("5"), 5000)
        @Expect(parseRetryAfter("9"), 8000)
        @Expect(parseRetryAfter("9223372036854775807"), 8000)
        // llm4cj saturates numeric overflow before the adapter applies its
        // bounded retry policy.
        @Expect(parseRetryAfter("9223372036854775808"), 8000)
        @Expect(parseRetryAfter("-1"), 0)
        @Expect(extractRetryAfterHeader(
            "Retry-After: 9223372036854775807\n"
        ), 8000)
        @Expect(retryAfterMillis(domain.AgentError(
            domain.AgentErrorKind.RateLimited,
            "model.rate_limited",
            "retry later",
            fields: [domain.ErrorField("retry_after_ms", "9223372036854775807")]
        )), 8000)
    }
}

@Test
class NativeProviderTlsConfigurationTests {
    @TestCase
    func endpointSchemeControlsTlsConfiguration(): Unit {
        let timeoutMillis: Int64 = 1000
        let http = nativeProviderClient("http://127.0.0.1:8080", timeoutMillis)
        let https = nativeProviderClient("https://provider.example", timeoutMillis)
        try {
            @Expect(http.getTlsConfig().isNone(), true)
            @Expect(https.getTlsConfig().isSome(), true)
            @Expect(nativeProviderRequiresTls("http://127.0.0.1:8080"), false)
            @Expect(nativeProviderRequiresTls("https://provider.example"), true)
        } finally {
            http.close()
            https.close()
        }
    }

    @TestCase
    func zeroProviderTimeoutDisablesDefaultClientReadDeadline(): Unit {
        let client = nativeProviderClient("https://provider.example", 0)
        try {
            @Expect(client.readTimeout, Duration.Max)
        } finally {
            client.close()
        }
    }
}

@Test
class ProviderDialectContractTests {
    @TestCase
    func unsupportedScaleTierFailsClosed(): Unit {
        try {
            let _ = toLlmWireServiceTier("scale", ProviderDialect.OpenAiResponses)
            @Fail("scale must not be silently dropped")
        } catch (_: IllegalArgumentException) {
            @Expect(true, true)
        }
    }

    @TestCase
    func anthropicPriorityUsesFastModeWithoutAServiceTier(): Unit {
        @Expect(
            toLlmWireServiceTier("priority", ProviderDialect.AnthropicMessages) ==
                LlmWireServiceTier.ProviderDefault,
            true
        )
    }

    @TestCase
    func rejectsDialectProtocolMismatch(): Unit {
        try {
            let _ = ProviderSpec(
                "fixture",
                ProviderProtocol.Responses,
                "fixture-model",
                "https://provider.example",
                "FIXTURE_API_KEY",
                dialect: Some(ProviderDialect.DeepSeekMessages)
            )
            @Fail("provider dialect and endpoint protocol must agree")
        } catch (_: IllegalArgumentException) {
            @Expect(true, true)
        }
    }

    @TestCase
    func deepSeekMessagesOmitsDisabledParallelToolCalls(): Unit {
        let encoded = encodeDeepSeekMessagesRequest(domain.ModelRequest(
            "deepseek-chat",
            [domain.ModelMessage(
                domain.ModelRole.User,
                [domain.ModelBlock(domain.ModelBlockKind.Text, text: "hello")]
            )],
            tools: [domain.ModelToolDefinition(
                "read",
                "Read a file",
                domain.objectValue([])
            )],
            thinking: domain.ThinkingLevel.Off,
            parallelToolCalls: false
        ))

        @Expect(encoded.contains("parallel_tool_calls"), false)
    }
}

@Test
class OrphanToolResultEncodingTests {
    private func request(messages: Array<domain.ModelMessage>): domain.ModelRequest {
        domain.ModelRequest(
            "fixture-model",
            messages
        )
    }

    private func resultBlock(
        callId: String,
        text: String
    ): domain.ModelBlock {
        domain.ModelBlock(
            domain.ModelBlockKind.ToolResult,
            text: text,
            callId: callId,
            name: "read"
        )
    }

    private func callBlock(callId: String): domain.ModelBlock {
        domain.ModelBlock(
            domain.ModelBlockKind.ToolCall,
            callId: callId,
            name: "read",
            arguments: domain.objectValue([])
        )
    }

    @TestCase
    func messagesProtocolDropsOrphanToolResultBlocks(): Unit {
        let encoded = encodeMessagesRequest(request([
            domain.ModelMessage(
                domain.ModelRole.User,
                [
                    domain.ModelBlock(domain.ModelBlockKind.Text, text: "keep"),
                    resultBlock("call_orphan", "orphan output")
                ]
            )
        ]))
        @Expect(encoded.contains("keep"), true)
        @Expect(encoded.contains("call_orphan"), false)
        @Expect(encoded.contains("orphan output"), false)
    }

    @TestCase
    func messagesProtocolRejectsOrphanOnlyMessages(): Unit {
        var rejected = false
        try {
            let _ = encodeMessagesRequest(request([
                domain.ModelMessage(
                    domain.ModelRole.User,
                    [resultBlock("call_orphan", "orphan output")]
                )
            ]))
        } catch (_: Exception) {
            rejected = true
        }
        @Expect(rejected, true)
    }

    @TestCase
    func messagesProtocolKeepsPairedToolResultBlocks(): Unit {
        let encoded = encodeMessagesRequest(request([
            domain.ModelMessage(
                domain.ModelRole.Assistant,
                [callBlock("call_read")]
            ),
            domain.ModelMessage(
                domain.ModelRole.User,
                [resultBlock("call_read", "paired output")]
            )
        ]))
        @Expect(encoded.contains("call_read"), true)
        @Expect(encoded.contains("paired output"), true)
    }

    @TestCase
    func completionsProtocolDropsOrphanToolMessages(): Unit {
        let encoded = encodeCompletionsRequest(request([
            domain.ModelMessage(
                domain.ModelRole.User,
                [
                    domain.ModelBlock(domain.ModelBlockKind.Text, text: "keep"),
                    resultBlock("call_orphan", "orphan output")
                ]
            )
        ]))
        @Expect(encoded.contains("keep"), true)
        @Expect(encoded.contains("call_orphan"), false)
        @Expect(encoded.contains("orphan output"), false)
    }

    @TestCase
    func completionsProtocolKeepsPairedToolMessages(): Unit {
        let encoded = encodeCompletionsRequest(request([
            domain.ModelMessage(
                domain.ModelRole.Assistant,
                [callBlock("call_read")]
            ),
            domain.ModelMessage(
                domain.ModelRole.User,
                [resultBlock("call_read", "paired output")]
            )
        ]))
        @Expect(encoded.contains("call_read"), true)
        @Expect(encoded.contains("paired output"), true)
    }
}
