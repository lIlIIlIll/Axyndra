package model_adapters_contract

import agent_domain as domain
import agent_ports as ports
import model_adapters.*
import std.collection.*

main(): Int64 {
    expect(
        defaultProviderCapabilities().require(domain.ModelFeature.StructuredOutput).isError() &&
            defaultProviderCapabilities().require(domain.ModelFeature.PromptCache).isError(),
        "provider protocol defaults do not fabricate model-specific structured-output or cache support"
    )
    let schema = domain.objectValue([
        domain.ValueField("type", domain.textValue("object")),
        domain.ValueField("properties", domain.objectValue([
            domain.ValueField("text", domain.objectValue([
                domain.ValueField("type", domain.textValue("string"))
            ]))
        ]))
    ])
    let request = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.User,
            [domain.ModelBlock(
                domain.ModelBlockKind.Text,
                text: "hello adapter"
            )]
        )],
        tools: [domain.ModelToolDefinition("echo", "Echo text.", schema)],
        thinking: domain.ThinkingLevel.High,
        maxOutputTokens: 32768,
        streaming: true
    )
    let deltas = ArrayList<String>()
    let port: ports.ModelPort = fixtureModelPort()
    let result = port.execute(
        request,
        { event =>
            match (event) {
                case domain.ModelEvent.TextDelta(text) => deltas.add(text)
                case _ => ()
            }
        }
    )
    match (result) {
        case domain.Result.Ok(reply) =>
            expect(reply.blocks.size > 0, "adapter produces typed reply")
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let value = domain.objectValue([
        domain.ValueField("text", domain.textValue("hello")),
        domain.ValueField("count", domain.integerValue(2)),
        domain.ValueField("enabled", domain.boolValue(true))
    ])
    let encoded = encodeAgentValue(value)
    let decoded = decodeAgentValue(encoded)
    match (decoded) {
        case domain.Result.Ok(restored) =>
            expect(match (restored.kind) {
                case domain.ValueKind.Object => true
                case _ => false
            },
                   "codec preserves object")
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let messagesPayload = encodeMessagesRequest(request)
    expect(
        messagesPayload.contains("\"max_tokens\":32768") &&
        messagesPayload.contains(
            "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":16384}"
        ),
           "Messages owns its provider JSON")
    let responsesPayload = encodeResponsesRequest(request)
    expect(
        responsesPayload.contains("\"max_output_tokens\":32768") &&
        responsesPayload.contains("\"reasoning\":{\"effort\":\"high\"}"),
           "Responses owns its provider JSON")
    let completionsPayload = encodeCompletionsRequest(request)
    expect(
        completionsPayload.contains("\"max_tokens\":32768") &&
        completionsPayload.contains("\"type\":\"function\"") &&
        completionsPayload.contains("\"reasoning_effort\":\"high\""),
        "Chat Completions owns its provider JSON"
    )
    let structuredSchema = domain.objectValue([
        domain.ValueField("type", domain.textValue("object")),
        domain.ValueField("properties", domain.objectValue([
            domain.ValueField("answer", domain.objectValue([
                domain.ValueField("type", domain.textValue("string"))
            ]))
        ])),
        domain.ValueField("required", domain.listValue([
            domain.textValue("answer")
        ])),
        domain.ValueField("additionalProperties", domain.boolValue(false))
    ])
    let structuredSpec = domain.StructuredOutputSpec(
        "answer_result",
        structuredSchema,
        description: "A typed answer"
    )
    let structuredRequest = domain.ModelRequest(
        "fixture-model",
        request.messages,
        thinking: domain.ThinkingLevel.Off,
        streaming: false,
        structuredOutput: Some(structuredSpec)
    )
    expect(
        encodeMessagesRequest(structuredRequest).contains(
            "\"output_config\":{\"format\":{\"type\":\"json_schema\""
        ) &&
        encodeResponsesRequest(structuredRequest).contains(
            "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"answer_result\""
        ) &&
        encodeCompletionsRequest(structuredRequest).contains(
            "\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"answer_result\""
        ),
        "structured output schema reaches every provider protocol"
    )
    let imageRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(domain.ModelRole.User, [
            domain.ModelBlock(domain.ModelBlockKind.Text, text: "describe"),
            domain.ModelBlock(
                domain.ModelBlockKind.Image,
                image: Some(domain.ModelImage(
                    domain.ModelImageSourceKind.Base64,
                    "aGVsbG8=",
                    mediaType: "image/png",
                    detail: domain.ModelImageDetail.High
                ))
            )
        ])],
        thinking: domain.ThinkingLevel.Off,
        streaming: false
    )
    expect(
        encodeMessagesRequest(imageRequest).contains(
            "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"aGVsbG8=\"}"
        ) &&
        encodeResponsesRequest(imageRequest).contains(
            "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aGVsbG8=\",\"detail\":\"high\""
        ) &&
        encodeCompletionsRequest(imageRequest).contains(
            "\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGVsbG8=\",\"detail\":\"high\"}"
        ),
        "typed image input reaches every provider protocol"
    )
    let cacheRequest = domain.ModelRequest(
        "fixture-model",
        request.messages,
        thinking: domain.ThinkingLevel.Off,
        streaming: false,
        cachePolicy: domain.ModelCachePolicy.StablePrefix,
        cacheKey: "adapter-contract"
    )
    expect(
        encodeMessagesRequest(cacheRequest).contains(
            "\"cache_control\":{\"type\":\"ephemeral\"}"
        ) && encodeResponsesRequest(cacheRequest).contains(
            "\"prompt_cache_key\":\"adapter-contract\""
        ) && encodeCompletionsRequest(cacheRequest).contains(
            "\"prompt_cache_key\":\"adapter-contract\""
        ),
        "stable-prefix prompt caching reaches every provider protocol"
    )
    let offRequest = domain.ModelRequest(
        "fixture-model",
        request.messages,
        thinking: domain.ThinkingLevel.Off
    )
    expect(
        !encodeMessagesRequest(offRequest).contains("\"thinking\"") &&
        encodeResponsesRequest(offRequest).contains(
            "\"reasoning\":{\"enabled\":false}"
        ) &&
        !encodeCompletionsRequest(offRequest).contains(
            "\"reasoning_effort\""
        ),
        "thinking off reaches every provider protocol"
    )
    let replayRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.Assistant,
            [
                domain.ModelBlock(
                    domain.ModelBlockKind.Reasoning,
                    opaqueState: Some(domain.OpaqueProviderState(
                        "messages-fixture",
                        "messages",
                        "{\"type\":\"thinking\",\"thinking\":\"signed\"," +
                        "\"signature\":\"opaque-signature\"}",
                        replayRequired: true
                    ))
                ),
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: "call_1",
                    name: "echo",
                    arguments: domain.objectValue([]),
                    opaqueState: Some(domain.OpaqueProviderState(
                        "responses-fixture",
                        "responses",
                        "{\"type\":\"function_call\",\"id\":\"fc_1\"," +
                        "\"call_id\":\"call_1\",\"name\":\"echo\"," +
                        "\"arguments\":\"{}\"}",
                        itemId: "fc_1",
                        replayRequired: true
                    ))
                )
            ]
        )]
    )
    expect(
        encodeMessagesRequest(replayRequest).contains("opaque-signature"),
        "Messages replays opaque signed reasoning"
    )
    expect(
        encodeResponsesRequest(replayRequest).contains("\"id\":\"fc_1\""),
        "Responses replays opaque function-call item"
    )
    let toolResultRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.Assistant,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "call_read",
                name: "read",
                arguments: domain.objectValue([])
            )]
        ), domain.ModelMessage(
            domain.ModelRole.User,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolResult,
                callId: "call_read",
                name: "read",
                arguments: domain.objectValue([
                    domain.ValueField(
                        "content",
                        domain.textValue("model-visible file content")
                    ),
                    domain.ValueField(
                        "path",
                        domain.textValue("fixture.txt")
                    )
                ])
            )]
        )]
    )
    expect(
        encodeMessagesRequest(toolResultRequest).contains(
            "\"content\":\"model-visible file content\""
        ) &&
        encodeResponsesRequest(toolResultRequest).contains(
            "\"output\":\"model-visible file content\""
        ) &&
        encodeCompletionsRequest(toolResultRequest).contains(
            "\"content\":\"model-visible file content\""
        ),
        "all provider protocols receive model-visible structured tool content"
    )

    let orphanResultRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.User,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolResult,
                callId: "call_orphan",
                name: "read",
                arguments: domain.objectValue([
                    domain.ValueField(
                        "content",
                        domain.textValue("orphan tool output")
                    )
                ])
            )]
        )]
    )
    expect(
        !encodeMessagesRequest(orphanResultRequest).contains("call_orphan") &&
        !encodeCompletionsRequest(orphanResultRequest).contains("call_orphan"),
        "orphan tool results never reach the provider wire"
    )

    let priorityRequest = domain.ModelRequest(
        request.model,
        request.messages,
        tools: request.tools,
        streaming: false,
        serviceTier: "priority"
    )
    let providerRequest = domain.ModelRequest(
        request.model,
        request.messages,
        tools: request.tools,
        streaming: false
    )
    expect(
        encodeMessagesRequest(priorityRequest).contains(
            "\"speed\":\"fast\""
        ) &&
        encodeResponsesRequest(priorityRequest).contains(
            "\"service_tier\":\"priority\""
        ) &&
        encodeCompletionsRequest(priorityRequest).contains(
            "\"service_tier\":\"priority\""
        ),
        "service tier reaches every supported provider wire format"
    )

    let messagesSyncPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "messages-sync-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY"
        ),
        transport: StaticTransport(
            "{\"id\":\"msg_sync\",\"content\":[{\"type\":\"text\"," +
            "\"text\":\"messages answer\"}],\"stop_reason\":\"end_turn\"," +
            "\"usage\":{\"input_tokens\":5,\"output_tokens\":7," +
            "\"cache_read_input_tokens\":2," +
            "\"cache_creation_input_tokens\":3}}"
        )
    )
    let messagesSyncReply = replyOrThrow(
        messagesSyncPort.execute(providerRequest, { _ => () })
    )
    expectUsage(
        messagesSyncReply,
        10,
        7,
        0,
        2,
        3,
        "Messages sync usage normalizes base and cache buckets"
    )

    let provider = ProviderSpec(
        "responses-fixture",
        ProviderProtocol.Responses,
        "fixture-model",
        "https://fixture.invalid",
        "FIXTURE_API_KEY",
        capabilities: domain.ModelCapabilities(
            toolCalling: true,
            parallelToolCalling: true,
            reasoning: true,
            structuredOutput: true,
            promptCache: true,
            contextWindowTokens: 1000000,
            maxOutputTokens: 200000
        )
    )
    let providerPort: ports.ModelPort = providerModelPort(
        provider,
        transport: StaticTransport(
            "{\"id\":\"resp_1\",\"status\":\"completed\"," +
            "\"output\":[{\"type\":\"message\",\"content\":[" +
            "{\"type\":\"output_text\",\"text\":\"provider answer\"}]}]," +
            "\"usage\":{\"input_tokens\":11,\"output_tokens\":7," +
            "\"input_tokens_details\":{\"cached_tokens\":4," +
            "\"cache_write_tokens\":2},\"output_tokens_details\":" +
            "{\"reasoning_tokens\":3}}}"
        )
    )
    let structuredPort: ports.ModelPort = providerModelPort(
        provider,
        transport: StaticTransport(
            "{\"id\":\"resp_structured\",\"status\":\"completed\"," +
            "\"output\":[{\"type\":\"message\",\"content\":[" +
            "{\"type\":\"output_text\",\"text\":\"{\\\"answer\\\":\\\"typed\\\"}\"}]}]," +
            "\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}"
        )
    )
    let structuredReply = replyOrThrow(
        structuredPort.execute(structuredRequest, { _ => () })
    )
    expect(
        match (structuredReply.structuredOutput) {
            case Some(value) => match (value.field("answer")) {
                case Some(answer) => answer.text == "typed"
                case None => false
            }
            case None => false
        },
        "provider reply exposes validated structured output"
    )
    let invalidStructuredPort: ports.ModelPort = providerModelPort(
        provider,
        transport: StaticTransport(
            "{\"id\":\"resp_invalid\",\"status\":\"completed\"," +
            "\"output\":[{\"type\":\"message\",\"content\":[" +
            "{\"type\":\"output_text\",\"text\":\"{\\\"answer\\\":7}\"}]}]," +
            "\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}"
        )
    )
    expectErrorCode(
        invalidStructuredPort.execute(structuredRequest, { _ => () }),
        "model.structured_output_schema_violation",
        "invalid structured output is rejected before Runtime consumption"
    )
    match (providerPort.execute(providerRequest, { _ => () })) {
        case domain.Result.Ok(reply) =>
            expect(
                reply.providerId == "responses-fixture",
                "provider adapter returns canonical metadata"
            )
            expectUsage(
                reply,
                11,
                7,
                3,
                4,
                2,
                "Responses sync usage keeps cached tokens inside input total"
            )
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let completionsPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "completions-fixture",
            ProviderProtocol.Completions,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY"
        ),
        transport: StaticTransport(
            "{\"id\":\"chatcmpl_1\",\"choices\":[{\"index\":0," +
            "\"message\":{\"role\":\"assistant\",\"content\":\"chat answer\"," +
            "\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," +
            "\"function\":{\"name\":\"echo\",\"arguments\":\"{\\\"text\\\":" +
            "\\\"hello\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]," +
            "\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":8," +
            "\"prompt_tokens_details\":{\"cached_tokens\":5," +
            "\"cache_write_tokens\":2},\"completion_tokens_details\":" +
            "{\"reasoning_tokens\":3}}}"
        )
    )
    match (completionsPort.execute(providerRequest, { _ => () })) {
        case domain.Result.Ok(reply) =>
            expect(
                reply.blocks.size == 2 &&
                reply.providerId == "completions-fixture",
                "Chat Completions decodes text and tool calls"
            )
            expectUsage(
                reply,
                12,
                8,
                3,
                5,
                2,
                "Completions sync usage keeps cache inside prompt total"
            )
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let messagesToolStream =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":" +
        "\"msg_tool\",\"content\":[],\"usage\":{\"input_tokens\":3," +
        "\"cache_read_input_tokens\":2," +
        "\"cache_creation_input_tokens\":1}}}\n\n" +
        "data: {\"type\":\"content_block_start\",\"index\":0," +
        "\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_find\"," +
        "\"name\":\"find\",\"input\":{\"path\":\".\"}}}\n\n" +
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" +
        "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":" +
        "\\\".\\\",\\\"pattern\\\":\\\"*.cj\\\"}\"}}\n\n" +
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":" +
        "\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" +
        "data: {\"type\":\"message_stop\"}\n\n"
    let messagesToolPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "messages-tool-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY"
        ),
        transport: StaticTransport(messagesToolStream)
    )
    match (messagesToolPort.execute(request, { _ => () })) {
        case domain.Result.Ok(reply) =>
            expect(
                reply.blocks.size == 1,
                "Messages returns one streamed tool block"
            )
            let block = reply.blocks[0]
            let path = match (block.arguments.field("path")) {
                case Some(value) => value.text
                case None => ""
            }
            let pattern = match (block.arguments.field("pattern")) {
                case Some(value) => value.text
                case None => ""
            }
            expect(
                match (block.kind) {
                    case domain.ModelBlockKind.ToolCall => true
                    case _ => false
                } &&
                block.name == "find" &&
                path == "." &&
                pattern == "*.cj",
                "Messages ignores empty tool input before JSON deltas"
            )
            expect(
                reply.terminalEvidence.isSome() &&
                reply.terminalEvidence.getOrThrow().terminalEventKind == "message_stop" &&
                match (reply.completionDisposition) {
                    case domain.CompletionDisposition.ToolUse => true
                    case _ => false
                } && match (reply.decisionOutcome) {
                    case domain.DecisionOutcome.ToolCalls => true
                    case _ => false
                },
                "Messages keeps terminal facts separate from validated Decision semantics"
            )
            expectUsage(
                reply,
                6,
                4,
                0,
                2,
                1,
                "Messages stream usage normalizes base and cache buckets"
            )
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let responsesStream =
        "data: {\"type\":\"response.output_text.delta\"," +
        "\"delta\":\"response stream\"}\n\n" +
        "data: {\"type\":\"response.completed\",\"response\":{" +
        "\"id\":\"resp_stream\",\"status\":\"completed\",\"output\":[{" +
        "\"type\":\"message\",\"content\":[{\"type\":\"output_text\"," +
        "\"text\":\"response stream\"}]}],\"usage\":{" +
        "\"input_tokens\":13,\"output_tokens\":9," +
        "\"input_tokens_details\":{\"cached_tokens\":5," +
        "\"cache_write_tokens\":3},\"output_tokens_details\":{" +
        "\"reasoning_tokens\":4}}}}\n\n" +
        "data: [DONE]\n\n"
    let responsesStreamReply = replyOrThrow(
        providerModelPort(
            ProviderSpec(
                "responses-stream-fixture",
                ProviderProtocol.Responses,
                "fixture-model",
                "https://fixture.invalid",
                "FIXTURE_API_KEY"
            ),
            transport: StaticTransport(responsesStream)
        ).execute(request, { _ => () })
    )
    expectUsage(
        responsesStreamReply,
        13,
        9,
        4,
        5,
        3,
        "Responses stream usage keeps cached tokens inside input total"
    )

    let completionsStream =
        "data: {\"id\":\"chatcmpl_stream\",\"model\":\"fixture-model\"," +
        "\"choices\":[{\"index\":0,\"delta\":{" +
        "\"content\":\"completion stream\"},\"finish_reason\":null}]," +
        "\"usage\":null}\n\n" +
        "data: {\"id\":\"chatcmpl_stream\",\"model\":\"fixture-model\"," +
        "\"choices\":[{\"index\":0,\"delta\":null," +
        "\"finish_reason\":\"stop\"}],\"usage\":null}\n\n" +
        "data: {\"id\":\"chatcmpl_stream\",\"model\":\"fixture-model\"," +
        "\"choices\":[],\"usage\":{\"prompt_tokens\":14," +
        "\"completion_tokens\":10,\"prompt_tokens_details\":{" +
        "\"cached_tokens\":6,\"cache_write_tokens\":2}," +
        "\"completion_tokens_details\":{\"reasoning_tokens\":5}}}\n\n" +
        "data: [DONE]\n\n"
    let completionsStreamReply = replyOrThrow(
        providerModelPort(
            ProviderSpec(
                "completions-stream-fixture",
                ProviderProtocol.Completions,
                "fixture-model",
                "https://fixture.invalid",
                "FIXTURE_API_KEY"
            ),
            transport: StaticTransport(completionsStream)
        ).execute(request, { _ => () })
    )
    expectUsage(
        completionsStreamReply,
        14,
        10,
        5,
        6,
        2,
        "Completions stream usage keeps cache inside prompt total"
    )

    let anthropicTransport = RecordingTransport(
        "{\"id\":\"msg_fast\",\"content\":[{\"type\":\"text\"," +
        "\"text\":\"fast answer\"}],\"stop_reason\":\"end_turn\"," +
        "\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
    )
    let anthropicFastPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "anthropic-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            provider: "anthropic"
        ),
        transport: anthropicTransport
    )
    let _ = replyOrThrow(
        anthropicFastPort.execute(priorityRequest, { _ => () })
    )
    expect(
        anthropicTransport.calls == 1 &&
        anthropicTransport.lastPayload.contains("\"speed\":\"fast\"") &&
        anthropicTransport.messagesFastMode &&
        anthropicTransport.betaHeaders.size == 1 &&
        anthropicTransport.betaHeaders[0] ==
            "anthropic-beta: fast-mode-2026-02-01",
        "Anthropic priority emits fast body and beta header contract"
    )
    expect(
        providerBetaHeaders(ProviderSpec(
            "messages-ordinary",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY"
        )).isEmpty() &&
        providerBetaHeaders(ProviderSpec(
            "responses-no-beta",
            ProviderProtocol.Responses,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            messagesFastMode: true
        )).isEmpty(),
        "beta header is absent outside Messages fast mode"
    )

    let proxyTransport = RecordingTransport(
        "{\"id\":\"never\",\"content\":[{\"type\":\"text\"," +
        "\"text\":\"must not execute\"}],\"usage\":{}}"
    )
    let proxyMessagesPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "messages-proxy-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            provider: "proxy"
        ),
        transport: proxyTransport
    )
    match (proxyMessagesPort.execute(priorityRequest, { _ => () })) {
        case domain.Result.Err(error) => expect(
            error.code == "model.service_tier_unsupported" &&
            proxyTransport.calls == 0,
            "non-Anthropic Messages fast mode fails closed before transport"
        )
        case domain.Result.Ok(_) => throw IllegalStateException(
            "non-Anthropic Messages fast mode unexpectedly succeeded"
        )
    }

    let capabilityTransport = RecordingTransport(
        "{\"id\":\"must-not-send\",\"status\":\"completed\",\"output\":[]}"
    )
    let capabilityPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "capability-fixture",
            ProviderProtocol.Responses,
            "limited-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            capabilities: domain.ModelCapabilities(
                toolCalling: false,
                parallelToolCalling: false,
                reasoning: false,
                contextWindowTokens: 4096,
                maxOutputTokens: 1024
            )
        ),
        transport: capabilityTransport
    )
    match (capabilityPort.execute(request, { _ => () })) {
        case domain.Result.Err(error) => expect(
            error.code == "model.capability_unsupported" &&
                capabilityTransport.calls == 0,
            "provider capability mismatch fails before transport"
        )
        case domain.Result.Ok(_) => throw IllegalStateException(
            "unsupported model capability unexpectedly reached transport"
        )
    }
    let oversizedRequest = domain.ModelRequest(
        "limited-model",
        request.messages,
        thinking: domain.ThinkingLevel.Off,
        maxOutputTokens: 2048,
        parallelToolCalls: false
    )
    match (capabilityPort.execute(oversizedRequest, { _ => () })) {
        case domain.Result.Err(error) => expect(
            error.code == "model.output_limit_exceeded" &&
                capabilityTransport.calls == 0,
            "provider output limit fails before transport"
        )
        case domain.Result.Ok(_) => throw IllegalStateException(
            "provider output limit unexpectedly reached transport"
        )
    }

    let lifecycle: ports.ModelPort = LifecycleModelPort(
        AlwaysRetryablePort(),
        fixtureModelPort(),
        maxAttempts: 2
    )
    match (lifecycle.execute(request, { _ => () })) {
        case domain.Result.Ok(_) => ()
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }
    let retryControl = RetryControl(enabled: false)
    let disabledPort = EventuallySuccessfulPort(1)
    let controlledDisabled: ports.ModelPort = RetryingModelPort(
        disabledPort,
        retryControl,
        maxAttempts: 3
    )
    expect(
        controlledDisabled.execute(request, { _ => () }).isError() &&
        disabledPort.calls == 1,
        "disabled automatic retry performs exactly one attempt"
    )
    retryControl.setEnabled(true)
    let enabledPort = EventuallySuccessfulPort(2)
    let controlledEnabled: ports.ModelPort = RetryingModelPort(
        enabledPort,
        retryControl,
        maxAttempts: 3
    )
    expect(
        controlledEnabled.execute(request, { _ => () }).isOk() &&
        enabledPort.calls == 3,
        "enabled automatic retry reaches a later successful attempt"
    )
    let abortControl = RetryControl()
    let abortingPort = AbortOnFailurePort(abortControl)
    let controlledAbort: ports.ModelPort = RetryingModelPort(
        abortingPort,
        abortControl,
        maxAttempts: 3
    )
    expect(
        controlledAbort.execute(request, { _ => () }).isError() &&
        abortingPort.calls == 1,
        "abort retry stops the active request before another attempt"
    )
    let deadlineTransport = RecordingTransport(
        "{\"id\":\"deadline-response\",\"content\":[{\"type\":\"text\"," +
        "\"text\":\"after soft deadline\"}],\"stop_reason\":\"end_turn\"," +
        "\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
    )
    let deadlinePort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "deadline-fixture", ProviderProtocol.Messages, "fixture-model",
            "https://fixture.invalid", "FIXTURE_API_KEY",
            timeoutMillis: 120000
        ),
        transport: deadlineTransport
    )
    let deadlineRequest = domain.ModelRequest(
        "fixture-model", request.messages,
        thinking: domain.ThinkingLevel.Medium,
        transportHardTimeoutMillis: 150000
    )
    expect(deadlinePort.execute(deadlineRequest, { _ => () }).isOk() &&
        deadlineTransport.timeoutMillis == 150000,
        "T5 transport receives at least Core's hard budget instead of the legacy 120s cutoff")
    let activeStreamTransport = RecordingTransport(
        "{\"id\":\"active-stream-response\",\"content\":[{\"type\":\"text\"," +
        "\"text\":\"completed\"}],\"stop_reason\":\"end_turn\"," +
        "\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
    )
    let activeStreamPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "active-stream-fixture", ProviderProtocol.Messages, "fixture-model",
            "https://fixture.invalid", "FIXTURE_API_KEY",
            timeoutMillis: 120000
        ),
        transport: activeStreamTransport
    )
    let activeStreamRequest = domain.ModelRequest(
        "fixture-model", request.messages,
        thinking: domain.ThinkingLevel.Medium,
        streaming: true,
        transportHardTimeoutMillis: 0,
        resolvedPolicy: Some(domain.ResolvedModelRequestPolicy(
            domain.ThinkingResolution(
                domain.ThinkingLevel.Medium,
                domain.ThinkingLevel.Medium,
                domain.ThinkingControlMode.Budget,
                budgetTokens: Some(8192)
            ),
            domain.OutputLimitResolution(16384, 16384)
        ))
    )
    let _ = activeStreamPort.execute(activeStreamRequest, { _ => () })
    expect(activeStreamTransport.timeoutMillis == 0,
        "T6 active Core streams omit the provider whole-request timeout")
    println("model_adapters contract passed")
    0
}

class StaticTransport <: ProviderTransport {
    private let response: String

    public init(response: String) {
        this.response = response
    }

    public func post(
        _provider: ProviderSpec,
        _payload: String,
        _streaming: Bool,
        _requestId: String,
        _chunks: (String) -> Unit
    ): domain.Result<String> {
        domain.Result.Ok(response)
    }
}

class RecordingTransport <: ProviderTransport {
    private let response: String
    var calls: Int64 = 0
    var lastPayload: String = ""
    var messagesFastMode: Bool = false
    var betaHeaders: Array<String> = []
    var timeoutMillis: Int64 = 0

    public init(response: String) {
        this.response = response
    }

    public func post(
        provider: ProviderSpec,
        payload: String,
        _streaming: Bool,
        _requestId: String,
        _chunks: (String) -> Unit
    ): domain.Result<String> {
        calls += 1
        lastPayload = payload
        messagesFastMode = provider.messagesFastMode
        timeoutMillis = provider.timeoutMillis
        betaHeaders = providerBetaHeaders(provider)
        domain.Result.Ok(response)
    }
}

class AlwaysRetryablePort <: ports.ModelPort {
    public func execute(
        _request: domain.ModelRequest,
        _events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        domain.Result.Err(domain.AgentError(
            domain.AgentErrorKind.Transport,
            "fixture.transport",
            "retryable fixture transport failure",
            retryable: true,
            fallbackAllowed: true
        ))
    }
}

class EventuallySuccessfulPort <: ports.ModelPort {
    private let failures: Int64
    var calls: Int64 = 0

    init(failures: Int64) {
        this.failures = failures
    }

    public func execute(
        _request: domain.ModelRequest,
        _events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        calls += 1
        if (calls <= failures) {
            return retryableFailure()
        }
        domain.Result.Ok(domain.ModelReply([
            domain.ModelBlock(
                domain.ModelBlockKind.Text,
                text: "retried"
            )
        ]))
    }
}

class AbortOnFailurePort <: ports.ModelPort {
    private let control: RetryControl
    var calls: Int64 = 0

    init(control: RetryControl) {
        this.control = control
    }

    public func execute(
        request: domain.ModelRequest,
        _events: domain.ModelEventSink
    ): domain.Result<domain.ModelReply> {
        calls += 1
        control.abort(request.requestId)
        retryableFailure()
    }
}

func retryableFailure(): domain.Result<domain.ModelReply> {
    domain.Result.Err(domain.AgentError(
        domain.AgentErrorKind.Transport,
        "fixture.retryable",
        "retryable fixture failure",
        retryable: true
    ))
}

func replyOrThrow(
    result: domain.Result<domain.ModelReply>
): domain.ModelReply {
    match (result) {
        case domain.Result.Ok(reply) => reply
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }
}

func expectErrorCode(
    result: domain.Result<domain.ModelReply>,
    code: String,
    message: String
): Unit {
    match (result) {
        case domain.Result.Err(error) => expect(error.code == code, message)
        case domain.Result.Ok(_) => expect(false, message)
    }
}

func expectUsage(
    reply: domain.ModelReply,
    inputTokens: Int64,
    outputTokens: Int64,
    reasoningTokens: Int64,
    cacheReadTokens: Int64,
    cacheWriteTokens: Int64,
    message: String
): Unit {
    expect(
        reply.inputTokens == inputTokens &&
        reply.outputTokens == outputTokens &&
        reply.reasoningTokens == reasoningTokens &&
        reply.cacheReadTokens == cacheReadTokens &&
        reply.cacheWriteTokens == cacheWriteTokens,
        message
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
