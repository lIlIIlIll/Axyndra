package model_adapters_contract

import yjson_support.*

import yjson.*

import agent_domain as domain
import agent_ports as ports
import model_adapters.*
import std.collection.*
import std.sync.*

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
            expect(match (restored.unifiedKind) {
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
    let deepSeekResponsesPayload = encodeDeepSeekResponsesRequest(request)
    expect(
        deepSeekResponsesPayload.contains("\"max_output_tokens\":32768") &&
        deepSeekResponsesPayload.contains("\"reasoning\":{\"effort\":\"high\"}") &&
        !deepSeekResponsesPayload.contains("parallel_tool_calls"),
        "DeepSeek Responses owns its native thinking and omits unsupported parallel calls")
    let deepSeekChatPayload = encodeDeepSeekChatRequest(request)
    expect(
        deepSeekChatPayload.contains("\"max_tokens\":32768") &&
        deepSeekChatPayload.contains("\"thinking\":{\"type\":\"enabled\"}") &&
        deepSeekChatPayload.contains("\"reasoning_effort\":\"high\"") &&
        !deepSeekChatPayload.contains("parallel_tool_calls"),
        "DeepSeek Chat owns its native thinking and omits unsupported parallel calls")
    let completionsPayload = encodeCompletionsRequest(request)
    expect(
        completionsPayload.contains("\"max_completion_tokens\":32768") &&
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
        encodeMessagesRequest(offRequest).contains(
            "\"thinking\":{\"type\":\"disabled\"}"
        ) &&
        !encodeResponsesRequest(offRequest).contains("\"reasoning\"") &&
        encodeCompletionsRequest(offRequest).contains(
            "\"reasoning_effort\":\"none\""
        ),
        "thinking off reaches every provider protocol"
    )
    let messagesReplayRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.Assistant,
            [
                domain.ModelBlock(
                    domain.ModelBlockKind.Reasoning,
                    opaqueState: Some(domain.OpaqueProviderState(
                        "messages-fixture",
                        "messages",
                        "{\"protocol\":\"messages\",\"dialect_id\":" +
                        "\"anthropic.messages.v1\",\"native_type\":\"thinking\"," +
                        "\"schema_version\":1,\"scope\":\"assistant_turn\"," +
                        "\"assistant_turn_index\":0,\"block_order\":0," +
                        "\"complete\":true,\"payload\":{\"type\":\"thinking\"," +
                        "\"thinking\":\"signed\",\"signature\":\"opaque-signature\"}}",
                        replayRequired: true
                    ))
                )
            ]
        )],
        thinking: domain.ThinkingLevel.Off
    )
    let responsesReplayRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.Assistant,
            [
                domain.ModelBlock(
                    domain.ModelBlockKind.ToolCall,
                    callId: "call_1",
                    name: "echo",
                    arguments: domain.objectValue([])
                )
            ]
        ), domain.ModelMessage(
            domain.ModelRole.User,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolResult,
                callId: "call_1",
                text: "ok"
            )]
        )],
        thinking: domain.ThinkingLevel.Off
    )
    expect(
        encodeMessagesRequest(messagesReplayRequest).contains("opaque-signature"),
        "Messages replays opaque signed reasoning"
    )
    let unknownReplayRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(domain.ModelRole.Assistant, [domain.ModelBlock(
            domain.ModelBlockKind.Unknown,
            opaqueState: messagesReplayRequest.messages[0].blocks[0].opaqueState
        )])],
        thinking: domain.ThinkingLevel.Off
    )
    expect(
        encodeMessagesRequest(unknownReplayRequest).contains("opaque-signature"),
        "Messages replays opaque provider blocks whose display kind is unknown"
    )
    expect(
        encodeResponsesRequest(responsesReplayRequest).contains("\"call_id\":\"call_1\""),
        "Responses replays canonical function-call input"
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
        encodeMessagesRequest(toolResultRequest).contains("model-visible file content") &&
        encodeResponsesRequest(toolResultRequest).contains("model-visible file content") &&
        encodeCompletionsRequest(toolResultRequest).contains("model-visible file content"),
        "all provider protocols receive model-visible structured tool content"
    )
    let failedToolResultRequest = domain.ModelRequest(
        "fixture-model",
        [domain.ModelMessage(
            domain.ModelRole.Assistant,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "call_failed",
                name: "read",
                arguments: domain.objectValue([])
            )]
        ), domain.ModelMessage(
            domain.ModelRole.User,
            [domain.ModelBlock(
                domain.ModelBlockKind.ToolResult,
                callId: "call_failed",
                name: "read",
                text: "permission denied",
                isError: true
            )]
        )]
    )
    expect(
        encodeDeepSeekMessagesRequest(failedToolResultRequest).contains("[tool_error]") &&
        !encodeDeepSeekMessagesRequest(failedToolResultRequest).contains("\"is_error\":true") &&
        encodeMessagesRequest(failedToolResultRequest).contains("\"is_error\":true"),
        "DeepSeek Messages marks failed tool results without claiming native is_error support"
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
    var orphanResultRejected = false
    try {
        let _ = encodeMessagesRequest(orphanResultRequest)
    } catch (_: Exception) {
        orphanResultRejected = true
    }
    expect(orphanResultRejected, "orphan tool results fail closed before provider wire")

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
        "Messages sync usage totals cache buckets without losing their breakdown"
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
        "\"name\":\"find\",\"input\":{}}}\n\n" +
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
                "Messages stream usage totals cache buckets without losing their breakdown"
            )
        case domain.Result.Err(error) =>
            throw IllegalStateException(error.message)
    }

    let deepSeekMessagesRequest = domain.ModelRequest(
        "fixture-model",
        request.messages,
        tools: request.tools,
        thinking: domain.ThinkingLevel.High,
        maxOutputTokens: 32768,
        streaming: true,
        parallelToolCalls: false
    )
    let malformedMessagesToolStream =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":" +
        "\"msg_bad\",\"content\":[],\"usage\":{\"input_tokens\":3}}}\n\n" +
        "data: {\"type\":\"content_block_start\",\"index\":0," +
        "\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_bad\"," +
        "\"name\":\"task\",\"input\":{}}}\n\n" +
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" +
        "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"tasks\\\":[{\\\"name\\\":\\\"review\\\"}\"}}\n\n" +
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":" +
        "\"tool_use\"},\"usage\":{\"output_tokens\":4}}\n\n" +
        "data: {\"type\":\"message_stop\"}\n\n"
    let malformedMessagesPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "messages-malformed-tool-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            provider: "deepseek",
            dialect: Some(ProviderDialect.DeepSeekMessages)
        ),
        transport: ChunkedStaticTransport(malformedMessagesToolStream)
    )
    let malformedEvents = ArrayList<domain.ModelEvent>()
    match (malformedMessagesPort.execute(deepSeekMessagesRequest, { event => malformedEvents.add(event) })) {
        case domain.Result.Err(error) =>
            expect(
                error.code == "llm.tool_arguments_not_executable" &&
                error.retryable && malformedEvents.size > 0 &&
                match (error.attemptFailure) {
                    case Some(value) => match (value.kind) {
                        case domain.AttemptFailureKind.MalformedToolArguments => true
                        case _ => false
                    }
                    case None => false
                },
                "DeepSeek Messages malformed terminal tool JSON is a retryable attempt failure"
            )
        case domain.Result.Ok(_) =>
            expect(false, "DeepSeek Messages malformed terminal tool JSON must not produce a reply")
    }

    let truncatedMessagesToolStream =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":" +
        "\"msg_eof\",\"content\":[],\"usage\":{\"input_tokens\":3}}}\n\n" +
        "data: {\"type\":\"content_block_start\",\"index\":0," +
        "\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_eof\"," +
        "\"name\":\"task\",\"input\":{}}}\n\n" +
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":" +
        "{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"tasks\\\":[\"}}\n\n"
    let truncatedMessagesPort: ports.ModelPort = providerModelPort(
        ProviderSpec(
            "messages-truncated-tool-fixture",
            ProviderProtocol.Messages,
            "fixture-model",
            "https://fixture.invalid",
            "FIXTURE_API_KEY",
            provider: "deepseek",
            dialect: Some(ProviderDialect.DeepSeekMessages)
        ),
        transport: ChunkedStaticTransport(truncatedMessagesToolStream)
    )
    let truncatedEvents = ArrayList<domain.ModelEvent>()
    match (truncatedMessagesPort.execute(deepSeekMessagesRequest, { event => truncatedEvents.add(event) })) {
        case domain.Result.Err(error) =>
            expect(
                error.code == "llm.stream_terminal_missing" &&
                error.retryable && truncatedEvents.size > 0 &&
                match (error.attemptFailure) {
                    case Some(value) => match (value.kind) {
                        case domain.AttemptFailureKind.ProviderTerminalMissing => true
                        case _ => false
                    }
                    case None => false
                },
                "DeepSeek Messages transport EOF is a retryable provider-terminal failure"
            )
        case domain.Result.Ok(_) =>
            expect(false, "truncated DeepSeek Messages stream must not produce a reply")
    }

    let responsesStream =
        "data: {\"type\":\"response.created\",\"response\":{" +
        "\"id\":\"resp_stream\",\"model\":\"fixture-model\"}}\n\n" +
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0," +
        "\"item\":{\"id\":\"item_stream\",\"type\":\"message\"}}\n\n" +
        "data: {\"type\":\"response.content_part.added\"," +
        "\"item_id\":\"item_stream\",\"output_index\":0,\"content_index\":0," +
        "\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" +
        "data: {\"type\":\"response.output_text.delta\"," +
        "\"item_id\":\"item_stream\",\"output_index\":0,\"content_index\":0," +
        "\"delta\":\"response stream\"}\n\n" +
        "data: {\"type\":\"response.output_text.done\"," +
        "\"item_id\":\"item_stream\",\"output_index\":0,\"content_index\":0," +
        "\"text\":\"response stream\"}\n\n" +
        "data: {\"type\":\"response.content_part.done\"," +
        "\"item_id\":\"item_stream\",\"output_index\":0,\"content_index\":0," +
        "\"part\":{\"type\":\"output_text\",\"text\":\"response stream\"}}\n\n" +
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0," +
        "\"item_id\":\"item_stream\",\"item\":{" +
        "\"id\":\"item_stream\",\"type\":\"message\"}}\n\n" +
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
        wireMaxOutputTokens: Some(16384),
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
    let deepSeekReplay = domain.ModelRequest(
        "deepseek", [domain.ModelMessage(domain.ModelRole.Assistant, [
            domain.ModelBlock(domain.ModelBlockKind.Reasoning, text: "opaque reasoning"),
            domain.ModelBlock(
                domain.ModelBlockKind.ToolCall,
                callId: "replay-call", name: "echo", arguments: domain.objectValue([])
            )
        ])],
        thinking: domain.ThinkingLevel.High
    )
    var displayReasoningReplayRejected = false
    try {
        let _ = encodeDeepSeekChatRequest(deepSeekReplay)
    } catch (_: Exception) {
        displayReasoningReplayRejected = true
    }
    expect(displayReasoningReplayRejected,
        "DeepSeek Chat rejects display-only reasoning without native replay state")
    let partialToolStream =
        "data: {\"id\":\"limited\",\"model\":\"deepseek\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\",\"tool_calls\":[{\"index\":0,\"id\":\"partial\",\"function\":{\"name\":\"echo\",\"arguments\":\"{\\\"text\\\":\"}}]},\"finish_reason\":null}],\"usage\":null}\n\n" +
        "data: {\"id\":\"limited\",\"model\":\"deepseek\",\"choices\":[{\"index\":0,\"delta\":null,\"finish_reason\":\"length\"}],\"usage\":{\"completion_tokens\":100,\"completion_tokens_details\":{\"reasoning_tokens\":90}}}\n\n" +
        "data: [DONE]\n\n"
    let partialReply = replyOrThrow(providerModelPort(
        ProviderSpec(
            "deepseek-partial", ProviderProtocol.Completions, "deepseek",
            "https://fixture.invalid", "KEY", dialect: Some(ProviderDialect.DeepSeekChat)
        ),
        transport: StaticTransport(partialToolStream)
    ).execute(domain.ModelRequest(
        "deepseek", request.messages, thinking: domain.ThinkingLevel.High,
        streaming: true
    ), { _ => () }))
    var partialTools: Int64 = 0
    for (block in partialReply.blocks) {
        if (let domain.ModelBlockKind.ToolCall <- block.kind) { partialTools += 1 }
    }
    expect(match (partialReply.completionDisposition) {
            case domain.CompletionDisposition.OutputLimited => true
            case _ => false
        } &&
        partialReply.reasoningTokens == 90 && partialReply.outputTokens == 100 &&
        match (partialReply.usage.source) {
            case domain.ModelUsageSource.ProviderStreamFinal => true
            case _ => false
        } &&
        partialReply.usage.evidence.getOrThrow().eventKind == "finish_reason" &&
        partialReply.usage.evidence.getOrThrow().providerResponseId == "limited" &&
        partialTools == 0 && !partialReply.acceptedOutput,
        "output-limited partial tool JSON remains diagnostic-only while usage and terminal facts survive")
    outputLimitedPositionContract(request)
    unifiedRuntimeContract(request)
    cancellableCredentialResolutionContract(request)
    println("model_adapters contract passed")
    0
}

func outputLimitedPositionContract(request: domain.ModelRequest): Unit {
    let deltas = [
        ("thinking", "{\"reasoning_content\":\"still thinking\"}"),
        ("text", "{\"content\":\"partial answer\"}"),
        ("tool_name", "{\"tool_calls\":[{\"index\":0,\"id\":\"partial-name\",\"function\":{\"name\":\"ec\",\"arguments\":\"{}\"}}]}"),
        ("tool_arguments", "{\"tool_calls\":[{\"index\":0,\"id\":\"partial-args\",\"function\":{\"name\":\"echo\",\"arguments\":\"{\\\"text\\\":\"}}]}" )
    ]
    for ((position, delta) in deltas) {
        let stream =
            "data: {\"id\":\"limited-" + position + "\",\"model\":\"deepseek\",\"choices\":[{\"index\":0,\"delta\":" + delta + ",\"finish_reason\":null}],\"usage\":null}\n\n" +
            "data: {\"id\":\"limited-" + position + "\",\"model\":\"deepseek\",\"choices\":[{\"index\":0,\"delta\":null,\"finish_reason\":\"length\"}],\"usage\":{\"completion_tokens\":32,\"completion_tokens_details\":{\"reasoning_tokens\":16}}}\n\n" +
            "data: [DONE]\n\n"
        let reply = replyOrThrow(providerModelPort(
            ProviderSpec(
                "deepseek-limited-" + position,
                ProviderProtocol.Completions,
                "deepseek",
                "https://fixture.invalid",
                "KEY",
                dialect: Some(ProviderDialect.DeepSeekChat)
            ),
            transport: StaticTransport(stream)
        ).execute(domain.ModelRequest(
            "deepseek", request.messages,
            thinking: domain.ThinkingLevel.High,
            streaming: true
        ), { _ => () }))
        var toolCalls: Int64 = 0
        for (block in reply.blocks) {
            if (let domain.ModelBlockKind.ToolCall <- block.kind) { toolCalls += 1 }
        }
        expect(match (reply.completionDisposition) {
                case domain.CompletionDisposition.OutputLimited => true
                case _ => false
            } && !reply.acceptedOutput && toolCalls == 0,
            "output limit during " + position + " cannot produce an accepted or executable tool Decision")
    }
}

func cancellableCredentialResolutionContract(request: domain.ModelRequest): Unit {
    let credentials = BlockingCredentialResolver()
    let port = providerModelPort(
        ProviderSpec(
            "credential-cancel", ProviderProtocol.Completions, "fixture-model",
            "http://127.0.0.1:1", "UNUSED_KEY"
        ),
        transport: NativeProviderTransport(credentials: credentials)
    )
    let running = spawn {
        port.execute(domain.ModelRequest(
            request.model, request.messages, requestId: "credential-cancel-request"
        ), { _ => () })
    }
    var waits: Int64 = 0
    while (credentials.started.fetchAdd(0) == 0 && waits < 1000) {
        sleep(Duration.millisecond)
        waits += 1
    }
    expect(credentials.started.fetchAdd(0) == 1,
        "credential resolver begins before provider I/O")
    expect(port.cancel("credential-cancel-request").isOk(),
        "ModelPort cancellation reaches credential resolution")
    let result = running.get()
    expect(match (result) {
        case domain.Result.Err(error) => match (error.kind) {
            case domain.AgentErrorKind.Cancelled => error.code == "model.cancelled" &&
                error.fields.size == 1 && error.fields[0].value == "credential-cancel-request"
            case _ => false
        }
        case domain.Result.Ok(_) => false
    } && credentials.completed.fetchAdd(0) == 1,
        "credential cancellation is terminal, prompt, and contains no secret diagnostics")
}

class BlockingCredentialResolver <: ProviderCredentialResolver {
    let started = AtomicInt64(0)
    let cancelled = AtomicInt64(0)
    let completed = AtomicInt64(0)

    public func resolve(
        provider: ProviderSpec,
        requestId: String
    ): domain.Result<String> {
        let _ = provider
        started.fetchAdd(1)
        var waits: Int64 = 0
        while (cancelled.fetchAdd(0) == 0 && waits < 5000) {
            sleep(Duration.millisecond)
            waits += 1
        }
        if (cancelled.fetchAdd(0) > 0) {
            domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Cancelled,
                "model.cancelled",
                "credential resolution cancelled",
                fields: [domain.ErrorField("request_id", requestId)]
            ))
        } else {
            domain.Result.Err(domain.AgentError(
                domain.AgentErrorKind.Timeout,
                "fixture.credential_timeout",
                "credential resolver was not cancelled"
            ))
        }
    }

    public func cancel(requestId: String): domain.Result<Unit> {
        let _ = requestId
        cancelled.fetchAdd(1)
        domain.Result.Ok(())
    }

    public func complete(requestId: String): Unit {
        let _ = requestId
        completed.fetchAdd(1)
    }
}

func unifiedRuntimeContract(request: domain.ModelRequest): Unit {
    let transport = DispatchTransport()
    let profiles = [
        RuntimeProviderProfile(
            "gateway-a", "gateway", "https://fixture.invalid", "KEY_A",
            defaultHeaders: [ProviderHeader("x-profile", "a"), ProviderHeader("x-route", "profile")]
        ),
        RuntimeProviderProfile(
            "gateway-b", "gateway", "https://fixture.invalid", "KEY_B",
            defaultHeaders: [ProviderHeader("x-profile", "b")]
        )
    ]
    let capabilities = domain.ModelCapabilities(
        toolCalling: true, parallelToolCalling: true, reasoning: true,
        contextWindowTokens: 128000, maxOutputTokens: 32768,
        thinking: Some(domain.ThinkingCapabilities(
            domain.ThinkingControlMode.Effort,
            supportedLevels: [
                domain.ThinkingLevel.Low,
                domain.ThinkingLevel.High,
                domain.ThinkingLevel.Max
            ]
        ))
    )
    let models = [
        RuntimeModelDescriptor(
            "gateway-a/deepseek", "gateway-a", "deepseek",
            ModelApiBinding(
                LlmApiId.OpenAiChatCompletions,
                TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.DeepSeek)
            ), capabilities,
            defaultHeaders: [ProviderHeader("x-route", "model")]
        ),
        RuntimeModelDescriptor(
            "gateway-a/responses", "gateway-a", "responses",
            ModelApiBinding(
                LlmApiId.OpenAiResponses,
                TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.OpenAi)
            ), capabilities
        ),
        RuntimeModelDescriptor(
            "gateway-a/deepseek-responses", "gateway-a", "deepseek-responses",
            ModelApiBinding(
                LlmApiId.OpenAiResponses,
                TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.DeepSeek)
            ), capabilities
        ),
        RuntimeModelDescriptor(
            "gateway-a/messages", "gateway-a", "messages",
            ModelApiBinding(
                LlmApiId.AnthropicMessages,
                TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.DeepSeek)
            ), capabilities
        ),
        RuntimeModelDescriptor(
            "gateway-b/deepseek", "gateway-b", "deepseek",
            ModelApiBinding(
                LlmApiId.OpenAiChatCompletions,
                TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.DeepSeek)
            ), capabilities
        )
    ]
    let runtime: ports.ModelPort = UnifiedModelRuntime(
        profiles, models, defaultLlmApiRegistry(transport: transport)
    )
    for (model in [
        "gateway-a/deepseek", "gateway-a/responses",
        "gateway-a/messages", "gateway-b/deepseek"
    ]) {
        let routed = domain.ModelRequest(
            model, request.messages, thinking: domain.ThinkingLevel.High,
            maxOutputTokens: 4096, streaming: false,
            resolvedPolicy: Some(domain.ResolvedModelRequestPolicy(
                domain.ThinkingResolution(
                    domain.ThinkingLevel.High,
                    domain.ThinkingLevel.High,
                    domain.ThinkingControlMode.Effort
                ),
                domain.OutputLimitResolution(4096, 4096)
            ))
        )
        expect(runtime.execute(routed, { _ => () }).isOk(),
            "unified runtime dispatches " + model)
    }
    expect(
        transport.protocols.size == 4 &&
        transport.protocols[0] == "chat" && transport.protocols[1] == "responses" &&
        transport.protocols[2] == "messages" && transport.protocols[3] == "chat" &&
        transport.profileIds[0] == "gateway-a" && transport.profileIds[3] == "gateway-b" &&
        transport.payloads[0].contains("\"max_tokens\":4096") &&
        transport.payloads[0].contains("\"thinking\":{\"type\":\"enabled\"}") &&
        transport.payloads[0].contains("\"reasoning_effort\":\"high\"") &&
        !transport.payloads[0].contains("parallel_tool_calls") &&
        transport.headers[0].contains("x-profile:a") &&
        transport.headers[0].contains("x-route:model") &&
        transport.headers[0].contains("content-type:application/json") &&
        transport.headers[3].contains("x-profile:b") &&
        !transport.headers[3].contains("x-profile:a"),
        "profiles reuse one API adapter while one profile dispatches mixed APIs with typed DeepSeek lowering"
    )
    let deepSeekResponses = models[2]
    let deepSeekRuntime = UnifiedModelRuntime(
        profiles, [deepSeekResponses], defaultLlmApiRegistry(transport: transport)
    )
    expect(
        deepSeekRuntime.execute(
            domain.ModelRequest(
                "gateway-a/deepseek-responses", request.messages,
                thinking: domain.ThinkingLevel.High, maxOutputTokens: 4096
            ),
            { _ => () }
        ).isOk() &&
        transport.protocols.size == 5 &&
        transport.protocols[4] == "responses" &&
        transport.payloads[4].contains("\"reasoning\":{\"effort\":\"high\"}") &&
        !transport.payloads[4].contains("parallel_tool_calls"),
        "DeepSeek Responses uses its dedicated codec through the Responses adapter"
    )
    var secretHeaderRejected = false
    try {
        let _ = ProviderHeader("authorization", "secret")
    } catch (_: IllegalArgumentException) { secretHeaderRejected = true }
    expect(secretHeaderRejected,
        "profile and model headers cannot inject authentication secrets")
    let missingApi = UnifiedModelRuntime(
        profiles, [models[0]], LlmApiAdapterRegistry([])
    ).execute(domain.ModelRequest(
        "gateway-a/deepseek", request.messages, thinking: domain.ThinkingLevel.Off
    ), { _ => () })
    expectErrorCode(
        missingApi, "model.api_adapter_not_registered",
        "an unregistered model API fails closed before transport"
    )
    var mismatchRejected = false
    try {
        let _ = ModelApiBinding(
            LlmApiId.AnthropicMessages,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.Generic)
        )
    } catch (_: IllegalArgumentException) {
        mismatchRejected = true
    }
    expect(mismatchRejected, "typed dialect/API mismatch is rejected before transport")
}

class DispatchTransport <: ProviderTransport {
    let protocols = ArrayList<String>()
    let profileIds = ArrayList<String>()
    let payloads = ArrayList<String>()
    let headers = ArrayList<String>()

    public func post(
        provider: ProviderSpec,
        payload: String,
        streaming: Bool,
        requestId: String,
        chunks: (String) -> Unit
    ): domain.Result<String> {
        let _ = streaming
        let _ = requestId
        let _ = chunks
        profileIds.add(provider.id)
        payloads.add(payload)
        var merged = ""
        for (header in effectiveProviderHeaders(provider, streaming)) {
            merged += header.name + ":" + header.value + "\n"
        }
        headers.add(merged)
        match (provider.protocol) {
            case ProviderProtocol.Completions =>
                protocols.add("chat")
                domain.Result.Ok(
                    "{\"id\":\"chat\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{}}"
                )
            case ProviderProtocol.Responses =>
                protocols.add("responses")
                domain.Result.Ok(
                    "{\"id\":\"responses\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{}}"
                )
            case ProviderProtocol.Messages =>
                protocols.add("messages")
                domain.Result.Ok(
                    "{\"id\":\"messages\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{}}"
                )
        }
    }
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

class ChunkedStaticTransport <: ProviderTransport {
    private let response: String

    public init(response: String) {
        this.response = response
    }

    public func post(
        _provider: ProviderSpec,
        _payload: String,
        _streaming: Bool,
        _requestId: String,
        chunks: (String) -> Unit
    ): domain.Result<String> {
        chunks(response)
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
        message + ": actual=" + reply.inputTokens.toString() + "," +
            reply.outputTokens.toString() + "," + reply.reasoningTokens.toString() + "," +
            reply.cacheReadTokens.toString() + "," + reply.cacheWriteTokens.toString()
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
