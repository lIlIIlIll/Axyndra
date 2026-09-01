package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import std.io.*
import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Mcp4CjTests {
    @TestCase
    func modelsDiscoveryPaginationAndCallsWithoutAgentTypes() {
        let client = McpImplementationInfo("test-client", "1")
        let meta = McpRequestMeta(clientInfo: client)
        @Expect(meta.protocolVersion, MCP_PROTOCOL_VERSION)

        let tool = McpTool(
            "read_file",
            "read a file",
            jsonObject([JsonObjectEntry("type", jsonString("object"))])
        )
        let page = McpToolListPage([tool], nextCursor: "next")
        @Expect(page.tools.size, 1)
        @Expect(page.nextCursor, "next")

        let outcome = McpCallToolOutcome.Complete(McpCallToolResult(
            [jsonObject([
                JsonObjectEntry("type", jsonString("text")),
                JsonObjectEntry("text", jsonString("ok"))
            ])], isError: false
        ))
        @Expect(mcpCallToolOutcomeValue(outcome).field("resultType").getOrThrow().text, MCP_RESULT_COMPLETE)

        let extension = McpCallToolOutcome.Extension("com.example/result", jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("value", jsonString("extension"))
        ]))
        @Expect(mcpCallToolOutcomeValue(extension).field("resultType").getOrThrow().text, "com.example/result")
    }

    @TestCase
    func validatesLifecycleAndCancellationEnvelope() {
        let lifecycle = McpLifecycle()
        @Expect(lifecycle.transition(McpLifecycleState.Ready).isOk(), false)
        @Expect(lifecycle.transition(McpLifecycleState.Starting).isOk(), true)
        @Expect(lifecycle.transition(McpLifecycleState.Ready).isOk(), true)

        let notification = mcpCancellationNotification(jsonRpcTextId("r1"), "user cancelled")
        @Expect(notification.method, MCP_METHOD_CANCELLED)
        @Expect(notification.params.field("requestId").getOrThrow().text, "r1")
    }

    @TestCase
    func rejectsMissingProtocolVersionAndReportsProgressWithOriginalToken() {
        match (validateMcpRequestMeta(jsonObject([JsonObjectEntry("_meta", jsonObject([
            JsonObjectEntry(MCP_META_CLIENT_CAPABILITIES, jsonObject([]))
        ]))]))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.protocol_version_missing")
            case _ => @Fail("missing protocolVersion was accepted")
        }
        match (validateMcpRequestMeta(jsonObject([JsonObjectEntry("_meta", jsonObject([
            JsonObjectEntry(MCP_META_PROTOCOL_VERSION, jsonString(MCP_PROTOCOL_VERSION)),
            JsonObjectEntry(MCP_META_CLIENT_CAPABILITIES, jsonObject([
                JsonObjectEntry("sampling", jsonBool(true))
            ]))
        ]))]))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.client_capabilities_invalid")
            case _ => @Fail("non-object sampling capability was accepted")
        }
        match (validateMcpRequestMeta(jsonObject([JsonObjectEntry("_meta", jsonObject([
            JsonObjectEntry(MCP_META_PROTOCOL_VERSION, jsonString(MCP_PROTOCOL_VERSION)),
            JsonObjectEntry(MCP_META_CLIENT_CAPABILITIES, jsonObject([
                JsonObjectEntry("sampling", jsonObject([JsonObjectEntry("tools", jsonBool(false))]))
            ]))
        ]))]))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.client_capabilities_invalid")
            case _ => @Fail("non-object nested sampling capability was accepted")
        }

        let notifications = ArrayList<JsonRpcNotification>()
        let continuation = McpToolCallContinuation(
            progressToken: jsonString("progress-1"),
            notificationSink: { notification => notifications.add(notification) }
        )
        continuation.reportProgress(50.0, total: Some(100.0), message: "halfway")
        @Expect(notifications.size, 1)
        @Expect(notifications[0].method, "notifications/progress")
        @Expect(notifications[0].params.field("progressToken").getOrThrow().text, "progress-1")
        @Expect(notifications[0].params.field("progress").getOrThrow().number, "50.000000")
        @Expect(notifications[0].params.field("total").getOrThrow().number, "100.000000")
    }

    @TestCase
    func boundsStdioSubscriptionNotifications() {
        let cancellations = ArrayList<Unit>()
        let handle = StdioMcpSubscriptionHandle(jsonRpcNumberId(1), { _ =>
            cancellations.add(())
            McpResult.Ok(())
        })
        for (_ in 0..257) {
            handle.push(JsonRpcNotification(MCP_NOTIFICATION_TOOLS_LIST_CHANGED))
        }
        match (handle.next()) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.subscription_queue_overflow")
            case _ => @Fail("subscription queue overflow was not rejected")
        }
        @Expect(cancellations.size, 1)
    }

    @TestCase
    func boundsHttpOperationProgressNotifications() {
        let stream = McpOperationSseInput(jsonRpcNumberId(1), 8388608, { sink =>
            for (_ in 0..257) {
                sink(JsonRpcNotification(MCP_NOTIFICATION_PROGRESS, params: jsonObject([])))
            }
            JsonRpcEnvelope.Response(JsonRpcResponse(
                jsonRpcNumberId(1), JsonRpcResponsePayload.Success(jsonObject([]))
            ))
        })
        sleep(Duration.millisecond * 20)
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        @Expect(
            String.fromUtf8(output.toArray()).contains(
                "MCP operation progress consumer did not keep up with notifications"
            ),
            true
        )
    }

    @TestCase
    func httpOperationCapacityReleasesOnlyAfterCancelledWorkerStops() {
        let probe = SseWorkerLifecycleProbe()
        let stream = McpOperationSseInput(
            jsonRpcNumberId(1), 8388608,
            { _ => probe.run() },
            cancelAction: { => probe.cancel() },
            releaseAction: { => probe.release() }
        )
        stream.close()
        probe.waitUntilReleased()
        @Expect(probe.wasCancelled(), true)
        @Expect(probe.wasReleased(), true)
        @Expect(probe.wasReleasedBeforeDone(), false)
    }

    @TestCase
    func rejectsOversizedHttpOperationProgressNotification() {
        let stream = McpOperationSseInput(jsonRpcNumberId(1), 1024, { sink =>
            sink(JsonRpcNotification(MCP_NOTIFICATION_PROGRESS, params: jsonObject([
                JsonObjectEntry("message", jsonString(String.fromUtf8(Array<Byte>(2048, repeat: 120))))
            ])))
            JsonRpcEnvelope.Response(JsonRpcResponse(
                jsonRpcNumberId(1), JsonRpcResponsePayload.Success(jsonObject([]))
            ))
        })
        sleep(Duration.millisecond * 20)
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        @Expect(String.fromUtf8(output.toArray()).contains("exceeded the frame limit"), true)

        let terminal = McpOperationSseInput(jsonRpcNumberId(2), 1024, { _ =>
            JsonRpcEnvelope.Response(JsonRpcResponse(jsonRpcNumberId(2), JsonRpcResponsePayload.Success(
                jsonObject([JsonObjectEntry("value", jsonString(String.fromUtf8(Array<Byte>(2048, repeat: 120))))])
            )))
        })
        sleep(Duration.millisecond * 20)
        let terminalOutput = ArrayList<Byte>()
        while (true) {
            let count = terminal.read(buffer)
            if (count <= 0) { break }
            for (index in 0..count) { terminalOutput.add(buffer[index]) }
        }
        @Expect(String.fromUtf8(terminalOutput.toArray()).contains("response exceeded the frame limit"), true)
    }

    @TestCase
    func rejectsMalformedInputRequiredRequestMaps() {
        match (validatedMcpInputRequests(jsonObject([
            JsonObjectEntry("inputRequests", jsonString("invalid"))
        ]))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.input_required_invalid")
            case _ => @Fail("non-object inputRequests was accepted")
        }
        @Expect(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString(MCP_METHOD_SAMPLING_CREATE_MESSAGE)),
            JsonObjectEntry("params", jsonObject([
                JsonObjectEntry("messages", jsonArray([jsonBool(true)])),
                JsonObjectEntry("maxTokens", jsonNumber("32"))
            ]))
        ])).isOk(), false)
        let sampling = requireMcpInputRequest(decodeMcpInputRequest(jsonObject([
            JsonObjectEntry("method", jsonString(MCP_METHOD_SAMPLING_CREATE_MESSAGE)),
            JsonObjectEntry("params", jsonObject([
                JsonObjectEntry("messages", jsonArray([])),
                JsonObjectEntry("maxTokens", jsonNumber("32"))
            ]))
        ])))
        @Expect(decodeMcpInputResponse(sampling, jsonObject([
            JsonObjectEntry("role", jsonString("assistant")),
            JsonObjectEntry("content", jsonBool(true)),
            JsonObjectEntry("model", jsonString("fixture"))
        ])).isOk(), false)
    }

    @TestCase
    func resolvedToolCallPreservesProgressToken() {
        let progressObservations = ArrayList<Bool>()
        let tool = McpTool("echo", "echo", jsonObject([
            JsonObjectEntry("type", jsonString("object"))
        ]))
        let host = MemoryMcpToolHost([tool], {
            _: String, _: JsonNode, continuation: McpToolCallContinuation =>
                progressObservations.add(continuation.hasProgressToken())
                McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([])))
        })
        let client = McpClient(InMemoryMcpTransport(McpServer(
            McpDiscoverResult(), host: host
        )), McpRequestMeta())
        @Expect(client.callToolResolved(
            "echo", jsonObject([]), FixtureMcpResolver(),
            progressToken: jsonString("progress-1")
        ).isOk(), true)
        @Expect(progressObservations.size, 1)
        @Expect(progressObservations[0], true)
    }

    @TestCase
    func stdioTransportFramesAndCorrelatesResponse() {
        let script = "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}'"
        let transport = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", script]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        match (transport.request(JsonRpcRequest(jsonRpcNumberId(1), MCP_METHOD_DISCOVER))) {
            case McpResult.Ok(response) => match (response.payload) {
                case JsonRpcResponsePayload.Success(value) => @Expect(value.field("ok").getOrThrow().boolean, true)
                case _ => @Fail("expected successful response")
            }
            case McpResult.Err(error) => @Fail(error.message)
        }
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func cancellationReachesSubscriptionsAfterToolHostErrors() {
        let notifications = CancellationTrackingProvider()
        let server = McpServer(
            McpDiscoverResult(), host: FailingCancellationHost(), notifications: notifications
        )
        let result = server.handleNotification(mcpCancellationNotification(jsonRpcNumberId(41), "done"))
        @Expect(result.isOk(), false)
        @Expect(notifications.cancelled, true)
    }

    @TestCase
    func stdioSubscriptionReturnsAcknowledgedHandleAndRoutesNotifications() {
        let script = "IFS= read -r line; " +
            "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"toolsListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}'; " +
            "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}'; " +
            "IFS= read -r cancelled"
        let transport = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", script]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let client = McpClient(transport, McpRequestMeta(
            clientCapabilities: McpClientCapabilities(
                elicitation: Some(McpElicitationCapability())
            )
        ))
        let handle = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        @Expect(handle.acknowledged().toolsListChanged, true)
        match (handle.next()) {
            case McpResult.Ok(Some(value)) => @Expect(value.method, MCP_NOTIFICATION_TOOLS_LIST_CHANGED)
            case _ => @Fail("STDIO subscription notification was not routed")
        }
        @Expect(handle.close().isOk(), true)
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func stdioTransportRemovesNaturallyTerminatedSubscriptions() {
        let script = "IFS= read -r line; " +
            "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"toolsListChanged\":true},\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}'; " +
            "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}'"
        let transport = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", script]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let handle = match (transport.openSubscription(JsonRpcRequest(
            jsonRpcNumberId(1), MCP_METHOD_SUBSCRIPTIONS_LISTEN,
            params: withMcpRequestMeta(
                McpSubscriptionFilter(toolsListChanged: true).toValue(), McpRequestMeta()
            )
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        match (handle.next()) {
            case McpResult.Ok(None) => ()
            case _ => @Fail("naturally terminated subscription did not close")
        }
        @Expect(transport.activeSubscriptionCount(), 0)
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func preservesProgressTokensAndRejectsMalformedContinuationResponses() {
        let pending = McpInputRequiredResult(inputRequests: jsonObject([
            JsonObjectEntry("confirm", jsonObject([
                JsonObjectEntry("method", jsonString(MCP_METHOD_ELICITATION_CREATE)),
                JsonObjectEntry("params", fixtureElicitationParams())
            ]))
        ]))
        match (resolveMcpInput(
            pending, FixtureMcpResolver(), 1, McpResolutionPolicy(), jsonString("progress-next")
        )) {
            case McpResult.Ok(value) => @Expect(value.requestProgressToken().text, "progress-next")
            case McpResult.Err(error) => @Fail(error.message)
        }
        @Expect(decodeMcpContinuation(jsonObject([
            JsonObjectEntry("inputResponses", jsonString("malformed"))
        ]), { _ => }).isOk(), false)
    }

    @TestCase
    func classifiesMalformedFramesAndSpawnFailures() {
        let malformed = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", "IFS= read -r line; printf 'not-json\\n'"]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        match (malformed.request(JsonRpcRequest(jsonRpcNumberId(2), MCP_METHOD_DISCOVER))) {
            case McpResult.Err(error) => @Expect(error.code, "json_rpc.parse_error")
            case _ => @Fail("malformed frame must fail")
        }

        match (openStdioMcpTransport(McpStdioConfig("/definitely/missing/mcp-server"))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.stdio_start_failed")
            case McpResult.Ok(transport) => match (transport.request(JsonRpcRequest(
                jsonRpcNumberId(3), MCP_METHOD_DISCOVER
            ))) {
                case McpResult.Err(error) => @Expect(error.kind == McpErrorKind.Transport, true)
                case _ => @Fail("missing executable must fail on first I/O")
            }
        }
    }

    @TestCase
    func parsesSseEventsAndEnforcesBodyLimits() {
        let expected = jsonRpcTextId("wanted")
        let stream = ": keepalive\n\n" +
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"progress\"}\n\n" +
            "data: {\"jsonrpc\":\"2.0\",\"id\":\"wanted\",\"result\":{}\n" +
            "data: }\n\n"
        match (decodeMcpSseResponse(stream, expected, 4096)) {
            case McpResult.Ok(response) => @Expect(response.id.value, "wanted")
            case McpResult.Err(error) => @Fail(error.message)
        }
        @Expect(decodeMcpSseResponse("data: not-json\n\n", expected, 4096).isOk(), false)

        let incremental = ByteBuffer()
        incremental.write((
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"progress\"}\n\n" +
            "data: {\"jsonrpc\":\"2.0\",\"id\":\"wanted\",\"result\":{}}\n\n"
        ).toArray())
        @Expect(readMcpSseResponse(incremental, expected, 64).isOk(), true)

        let progressStream = ByteBuffer()
        progressStream.write((
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" +
            "data: {\"jsonrpc\":\"2.0\",\"id\":\"wanted\",\"result\":{}}\n\n"
        ).toArray())
        let progress = ArrayList<JsonRpcNotification>()
        @Expect(readMcpSseResponse(
            progressStream, expected, 4096,
            notificationSink: { notification => progress.add(notification) }
        ).isOk(), true)
        @Expect(progress.size, 1)

        let body = ByteBuffer()
        body.write("12345".toArray())
        @Expect(readMcpHttpBody(body, Some(5), 4).isOk(), false)
    }

    @TestCase
    func httpSubscriptionKeepsSseStreamAndRoutesTaggedNotifications() {
        let provider = FixtureMcpProviders()
        let protocol = McpServerBuilder().notificationProvider(provider).build()
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0), protocol
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        var waited: Int64 = 0
        while (server.state() != McpLifecycleState.Ready && waited < 3000) {
            sleep(Duration.millisecond * 5); waited += 5
        }
        @Expect(server.state() == McpLifecycleState.Ready, true)
        let transport = StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp", preferSse: true
        ))
        let client = McpClient(transport, McpRequestMeta())
        let handle = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        @Expect(handle.acknowledged().toolsListChanged, true)
        match (handle.next()) {
            case McpResult.Ok(Some(value)) => @Expect(value.method, MCP_NOTIFICATION_TOOLS_LIST_CHANGED)
            case _ => @Fail("HTTP subscription notification was not routed")
        }
        @Expect(handle.close().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(server.close().isOk(), true)
        let _ = serving.get()
    }

    @TestCase
    func httpServerBoundsConcurrentSubscriptionStreams() {
        let protocol = McpServerBuilder().notificationProvider(HoldingNotificationProvider()).build()
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0, maxConcurrentRequests: 1), protocol
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        var waited: Int64 = 0
        while (server.state() != McpLifecycleState.Ready && waited < 3000) {
            sleep(Duration.millisecond * 5); waited += 5
        }
        let client = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp", preferSse: true
        )), McpRequestMeta())
        let first = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        @Expect(client.listen(McpSubscriptionFilter(toolsListChanged: true)).isOk(), false)
        @Expect(first.close().isOk(), true)
        sleep(Duration.millisecond * 100)
        let reopened = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        @Expect(reopened.close().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(server.close().isOk(), true)
        let _ = serving.get()
    }

    @TestCase
    func httpSubscriptionNaturalEndReleasesStreamCapacity() {
        let protocol = McpServerBuilder().notificationProvider(FixtureMcpProviders()).build()
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0, maxConcurrentRequests: 1), protocol
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        var waited: Int64 = 0
        while (server.state() != McpLifecycleState.Ready && waited < 3000) {
            sleep(Duration.millisecond * 5); waited += 5
        }
        let client = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp", preferSse: true
        )), McpRequestMeta())
        for (_ in 0..2) {
            let handle = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => throw error
            }
            @Expect(handle.next().isOk(), true)
            match (handle.next()) {
                case McpResult.Ok(None) => @Expect(true, true)
                case _ => @Fail("HTTP subscription did not terminate naturally")
            }
        }
        @Expect(client.close().isOk(), true)
        @Expect(server.close().isOk(), true)
        let _ = serving.get()
    }

    @TestCase
    func httpServerBoundsConcurrentJsonRequests() {
        let operation = HoldingToolOperation()
        let host = MemoryMcpToolHost([
            McpTool("slow", "slow", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ], { requestId, arguments, continuation =>
            operation.execute(requestId, arguments, continuation)
        })
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0, maxConcurrentRequests: 1),
            McpServerBuilder().toolProvider(host).build()
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        var waited: Int64 = 0
        while (server.state() != McpLifecycleState.Ready && waited < 3000) {
            sleep(Duration.millisecond * 5); waited += 5
        }
        let url = "http://127.0.0.1:" + server.port().toString() + "/mcp"
        let first = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(url)), McpRequestMeta())
        let second = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(url)), McpRequestMeta())
        @Expect(first.listTools().isOk(), true)
        @Expect(second.listTools().isOk(), true)
        let running = spawn {
            let result = first.callTool("slow", jsonObject([]), owner: "slow-owner")
            match (result) {
                case McpResult.Err(error) => operation.recordFailure(error.code + ":" + error.message)
                case McpResult.Ok(_) => ()
            }
            result
        }
        operation.waitUntilStarted()
        let activeId = first.activeRequestId("slow-owner").getOrThrow()
        @Expect(first.notify(
            MCP_METHOD_CANCELLED,
            params: mcpCancellationNotification(activeId, "test cancellation").params
        ).isOk(), true)
        @Expect(second.callTool("slow", jsonObject([])).isOk(), false)
        operation.release()
        @Expect(running.get().isOk(), true)
        @Expect(first.close().isOk(), true)
        @Expect(second.close().isOk(), true)
        @Expect(server.close().isOk(), true)
        let _ = serving.get()
    }

    @TestCase
    func httpClientDecodesStructuredJsonRpcErrorsFromNonSuccessStatus() {
        let host = MemoryMcpToolHost([
            McpTool("fail", "fail", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ], { _: String, _: JsonNode, _: McpToolCallContinuation =>
            McpResult.Err(McpError(
                McpErrorKind.Protocol,
                "fixture.remote_error",
                "structured remote error"
            ))
        })
        let protocol = McpServerBuilder().toolProvider(host).build()
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0), protocol
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        var waited: Int64 = 0
        while (server.state() != McpLifecycleState.Ready && waited < 3000) {
            sleep(Duration.millisecond * 5); waited += 5
        }
        @Expect(server.state() == McpLifecycleState.Ready, true)
        let client = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp"
        )), McpRequestMeta())
        @Expect(client.listTools().isOk(), true)
        match (client.callTool("fail", jsonObject([]))) {
            case McpResult.Err(error) =>
                @Expect(error.kind == McpErrorKind.Protocol, true)
                @Expect(error.code, "mcp.http_status_error")
                @Expect(error.httpStatus.getOrThrow(), 400)
            case _ => @Fail("HTTP client discarded a structured JSON-RPC error response")
        }
        @Expect(client.close().isOk(), true)
        @Expect(server.close().isOk(), true)
        match (serving.get()) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => throw error
        }
    }

    @TestCase
    func clientAndServerOwnLifecyclePaginationCallsAndCancellation() {
        let tool = McpTool("echo", "echo", jsonObject([
            JsonObjectEntry("type", jsonString("object")),
            JsonObjectEntry("properties", jsonObject([
                JsonObjectEntry("value", jsonObject([JsonObjectEntry("type", jsonString("string"))]))
            ])),
            JsonObjectEntry("required", jsonArray([jsonString("value")]))
        ]))
        let host = MemoryMcpToolHost([tool], { _: String, arguments: JsonNode, _: McpToolCallContinuation =>
            McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([], structuredContent: arguments)))
        }, pageSize: 1)
        let server = McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("server", "1")),
            host: host
        )
        let transport = InMemoryMcpTransport(server)
        let client = McpClient(transport, McpRequestMeta(
            clientInfo: McpImplementationInfo("client", "1")
        ))
        @Expect(client.discover().isOk(), true)
        @Expect(client.listTools().isOk(), true)
        match (client.callTool("echo", jsonObject([JsonObjectEntry("value", jsonString("ok"))]))) {
            case McpResult.Ok(McpCallToolOutcome.Complete(value)) => @Expect(value.structuredContent.field("value").getOrThrow().text, "ok")
            case _ => @Fail("generic tools/call failed")
        }
        @Expect(client.callTool("echo", jsonObject([])).isOk(), false)
        let retry = McpInputRequiredResult(requestState: "retry-state")
        @Expect(client.retryToolCall(
            "echo", jsonObject([JsonObjectEntry("value", jsonString("retry"))]),
            retry, jsonObject([]), progressToken: jsonString("retry-progress")
        ).isOk(), true)
        let retryMeta = mcpObject(transport.requests[transport.requests.size - 1].params, "_meta")
        @Expect(retryMeta.field("progressToken").getOrThrow().text, "retry-progress")
        @Expect(client.notify("notifications/test").isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.discover().isOk(), false)
        @Expect(transport.closed, true)
        @Expect(server.close().isOk(), true)
    }

    @TestCase
    func builderDispatchesTyped2026ProvidersAndPreservesMrtrState() {
        let provider = FixtureMcpProviders()
        let server = McpServerBuilder(
            serverInfo: McpImplementationInfo("typed-server", "1")
        ).completionProvider(provider).promptProvider(provider)
            .resourceProvider(provider).notificationProvider(provider).build()
        let transport = InMemoryMcpTransport(server)
        let client = McpClient(transport, McpRequestMeta(
            clientCapabilities: McpClientCapabilities(
                elicitation: Some(McpElicitationCapability())
            )
        ))

        let discovery = match (client.discover()) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        @Expect(discovery.serverInfo.isSome(), true)
        @Expect(discovery.capabilities.prompts.isSome(), true)
        @Expect(discovery.capabilities.resources.isSome(), true)
        @Expect(discovery.capabilities.completion, true)
        @Expect(McpRequestMeta().toValue().field(MCP_META_CLIENT_INFO).isNone(), true)

        match (client.complete(
            jsonObject([JsonObjectEntry("type", jsonString("ref/prompt"))]),
            jsonObject([JsonObjectEntry("name", jsonString("topic"))])
        )) {
            case McpResult.Ok(McpOperationOutcome.Extension(kind, value)) =>
                @Expect(kind, "com.example/deferred")
                @Expect(value.field("resultType").getOrThrow().text, "com.example/deferred")
                @Expect(value.field("token").getOrThrow().text, "later")
            case _ => @Fail("completion extension result was not preserved")
        }
        @Expect(client.listPrompts().isOk(), true)
        @Expect(client.listResources().isOk(), true)
        @Expect(client.listResourceTemplates().isOk(), true)

        let before = transport.requestIds.size
        let resolver = FixtureMcpResolver()
        match (client.getPromptResolved("review", resolver)) {
            case McpResult.Ok(McpOperationOutcome.Complete(value)) =>
                @Expect(value.messages.size, 1)
            case _ => @Fail("prompts/get MRTR did not complete")
        }
        @Expect(resolver.requestState, "opaque-state-ß")
        @Expect(transport.requestIds.size, before + 2)
        @Expect(transport.requestIds[before] != transport.requestIds[before + 1], true)

        match (client.readResource("file:///readme")) {
            case McpResult.Ok(McpOperationOutcome.Complete(value)) => @Expect(value.contents.size, 1)
            case _ => @Fail("resources/read did not complete")
        }
        match (client.listen(McpSubscriptionFilter(resourcesListChanged: true))) {
            case McpResult.Ok(handle) =>
                @Expect(handle.acknowledged().resourcesListChanged, true)
                @Expect(handle.close().isOk(), true)
            case McpResult.Err(error) => @Fail(error.message)
        }
    }

    @TestCase
    func rejectsMalformedListDescriptors() {
        let page = jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("prompts", jsonArray([jsonObject([])])),
            JsonObjectEntry("ttlMs", jsonNumber("300000")),
            JsonObjectEntry("cacheScope", jsonString("private"))
        ])
        @Expect(decodeMcpPage(page, "prompts").isOk(), false)
        @Expect(decodeMcpCallOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("content", jsonArray([jsonObject([])]))
        ]), None).isOk(), false)
        @Expect(decodeMcpCallOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("content", jsonArray([jsonObject([
                JsonObjectEntry("type", jsonString("text"))
            ])]))
        ]), None).isOk(), false)
        @Expect(decodeMcpReadResourceOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("contents", jsonArray([jsonObject([])]))
        ])).isOk(), false)
        @Expect(decodeMcpReadResourceOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("contents", jsonArray([jsonObject([
                JsonObjectEntry("uri", jsonString("file:///missing-content"))
            ])]))
        ])).isOk(), false)
        @Expect(decodeMcpCompletionOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("completion", jsonObject([]))
        ])).isOk(), false)
        @Expect(decodeMcpCompletionOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("completion", jsonObject([
                JsonObjectEntry("values", jsonArray([jsonString("one"), jsonString("two")])),
                JsonObjectEntry("total", jsonNumber("1")),
                JsonObjectEntry("hasMore", jsonString("false"))
            ]))
        ])).isOk(), false)
        @Expect(decodeMcpPromptOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("messages", jsonArray([jsonObject([])]))
        ])).isOk(), false)
        @Expect(decodeMcpPromptOutcome(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("messages", jsonArray([jsonObject([
                JsonObjectEntry("role", jsonString("system")),
                JsonObjectEntry("content", jsonObject([
                    JsonObjectEntry("type", jsonString("text")),
                    JsonObjectEntry("text", jsonString("invalid role"))
                ]))
            ])]))
        ])).isOk(), false)
        @Expect(decodeMcpDiscover(jsonObject([
            JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE)),
            JsonObjectEntry("supportedVersions", jsonArray([jsonString(MCP_PROTOCOL_VERSION)])),
            JsonObjectEntry("capabilities", jsonObject([
                JsonObjectEntry("extensions", jsonBool(true))
            ]))
        ])).isOk(), false)
    }

    @TestCase
    func negotiatesAndDispatchesSep2663Tasks() {
        let task = McpTask(
            "task-1", McpTaskStatus.InputRequired,
            "2026-08-27T00:00:00Z", "2026-08-27T00:01:00Z", Some(60000),
            inputRequests: jsonObject([JsonObjectEntry("confirm", jsonObject([
                JsonObjectEntry("method", jsonString("elicitation/create")),
                JsonObjectEntry("params", fixtureElicitationParams())
            ]))])
        )
        let host = MemoryMcpToolHost([
            McpTool(
                "async", "async", jsonObject([JsonObjectEntry("type", jsonString("object"))]),
                execution: Some(McpToolExecution(taskSupport: McpTaskSupport.Optional))
            )
        ], { _: String, _: JsonNode, _: McpToolCallContinuation =>
            McpResult.Ok(McpCallToolOutcome.Task(task))
        })
        let tasks = FixtureMcpTaskProvider(task)
        let server = McpServerBuilder().toolProvider(host).taskProvider(tasks).build()

        let unsupported = McpClient(InMemoryMcpTransport(server), McpRequestMeta())
        match (unsupported.callTool("async", jsonObject([]))) {
            case McpResult.Err(error) => @Expect(error.message, "Missing required client capability")
            case _ => @Fail("server returned a task without negotiated capability")
        }

        let capabilities = McpClientCapabilities(extensions: jsonObject([
            JsonObjectEntry(MCP_TASKS_EXTENSION, jsonObject([]))
        ]))
        let missingTaskProvider = McpClient(
            InMemoryMcpTransport(McpServerBuilder().toolProvider(host).build()),
            McpRequestMeta(clientCapabilities: capabilities)
        )
        match (missingTaskProvider.callTool("async", jsonObject([]))) {
            case McpResult.Err(error) => @Expect(
                error.message, "tool returned a task but the server has no task provider"
            )
            case _ => @Fail("server returned a task without a task provider")
        }
        let client = McpClient(InMemoryMcpTransport(server), McpRequestMeta(
            clientCapabilities: capabilities
        ))
        match (client.discover()) {
            case McpResult.Ok(value) => @Expect(
                value.capabilities.extensions.field(MCP_TASKS_EXTENSION).isSome(), true
            )
            case _ => @Fail("task capability was not advertised")
        }
        match (client.callTool("async", jsonObject([]))) {
            case McpResult.Ok(McpCallToolOutcome.Task(value)) => @Expect(value.taskId, "task-1")
            case _ => @Fail("negotiated tools/call task result was not decoded")
        }
        match (client.getTask("task-1")) {
            case McpResult.Ok(value) => @Expect(value.status == McpTaskStatus.InputRequired, true)
            case _ => @Fail("tasks/get failed")
        }
        @Expect(client.updateTask("task-1", jsonObject([JsonObjectEntry(
            "confirm", jsonObject([
                JsonObjectEntry("action", jsonString("accept")),
                JsonObjectEntry("content", jsonObject([]))
            ])
        )])).isOk(), true)
        @Expect(tasks.updated, true)
        @Expect(client.updateTask("task-1", jsonObject([JsonObjectEntry(
            "unknown", jsonObject([JsonObjectEntry("action", jsonString("accept"))])
        )])).isOk(), false)
        @Expect(client.cancelTask("task-1").isOk(), true)
        @Expect(tasks.cancelled, true)

        let taskValue = task.toValue(resultType: MCP_RESULT_TASK)
        let forbiddenTool = McpTool(
            "sync", "sync", jsonObject([JsonObjectEntry("type", jsonString("object"))])
        )
        @Expect(decodeMcpCallOutcome(taskValue, Some(forbiddenTool)).isOk(), false)

        let requiredTool = McpTool(
            "required", "required", jsonObject([JsonObjectEntry("type", jsonString("object"))]),
            execution: Some(McpToolExecution(taskSupport: McpTaskSupport.Required))
        )
        let completeValue = McpCallToolResult([]).toValue()
        @Expect(decodeMcpCallOutcome(completeValue, Some(requiredTool)).isOk(), false)

        let urlOnlyParams = jsonObject([JsonObjectEntry("_meta", McpRequestMeta(
            clientCapabilities: McpClientCapabilities(
                elicitation: Some(McpElicitationCapability(form: false, url: true))
            )
        ).toValue())])
        let requiredCapabilities = missingMcpInputCapabilities(urlOnlyParams, jsonObject([
            JsonObjectEntry("confirm", jsonObject([
                JsonObjectEntry("method", jsonString(MCP_METHOD_ELICITATION_CREATE)),
                JsonObjectEntry("params", fixtureElicitationParams())
            ]))
        ]))
        @Expect(
            requiredCapabilities.field("elicitation").getOrThrow().field("form").isSome(), true
        )
    }
}

class InMemoryMcpTransport <: McpTransport {
    let server: McpServer
    let requestIds = ArrayList<String>()
    let requests = ArrayList<JsonRpcRequest>()
    var closed = false
    init(server: McpServer) { this.server = server }
    public func kind(): McpTransportKind { McpTransportKind.Stdio }
    public func state(): McpLifecycleState { if (closed) { McpLifecycleState.Stopped } else { McpLifecycleState.Ready } }
    public func request(request: JsonRpcRequest): McpResult<JsonRpcResponse> {
        requestIds.add(request.id.display())
        requests.add(request)
        if (closed) { McpResult.Err(McpError(McpErrorKind.Lifecycle, "closed", "closed")) }
        else { McpResult.Ok(server.handleRequest(request)) }
    }
    public func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionHandle> {
        match (server.openSubscription(request)) {
            case McpResult.Ok(source) => McpResult.Ok(FixtureMcpSubscriptionHandle(request.id, source))
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }
    public func notify(notification: JsonRpcNotification): McpResult<Unit> { server.handleNotification(notification) }
    public func cancel(
        requestId: JsonRpcId,
        reason: String,
        meta: McpRequestMeta
    ): McpResult<Unit> {
        server.handleNotification(mcpCancellationNotification(requestId, reason, meta: meta))
    }
    public func registerTools(tools: Array<McpTool>): McpResult<Unit> { let _ = tools; McpResult.Ok(()) }
    public func close(): McpResult<Unit> { closed = true; McpResult.Ok(()) }
}

class HoldingToolOperation {
    private let lock = Mutex()
    private var started = false
    private var released = false
    private var failure = ""
    func execute(
        name: String,
        arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpCallToolOutcome> {
        let _ = name; let _ = arguments; let _ = continuation
        lock.lock(); try { started = true } finally { lock.unlock() }
        while (true) {
            lock.lock(); let done = try { released } finally { lock.unlock() }
            if (done) { break }
            sleep(Duration.millisecond * 5)
        }
        McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([
            jsonObject([
                JsonObjectEntry("type", jsonString("text")),
                JsonObjectEntry("text", jsonString("done"))
            ])
        ])))
    }
    func waitUntilStarted(): Unit {
        var waited: Int64 = 0
        while (waited < 3000) {
            lock.lock(); let (value, failed) = try { (started, failure) } finally { lock.unlock() }
            if (value) { return }
            if (failed != "") { throw IllegalStateException("holding tool request failed: " + failed) }
            sleep(Duration.millisecond * 5); waited += 5
        }
        throw IllegalStateException("holding tool operation did not start")
    }
    func recordFailure(message: String): Unit {
        lock.lock(); try { failure = message } finally { lock.unlock() }
    }
    func release(): Unit { lock.lock(); try { released = true } finally { lock.unlock() } }
}

class SseWorkerLifecycleProbe {
    private let lock = Mutex()
    private var cancelled = false
    private var operationDone = false
    private var released = false
    private var releasedBeforeDone = false
    func run(): JsonRpcEnvelope {
        while (true) {
            lock.lock(); let stop = try { cancelled } finally { lock.unlock() }
            if (stop) { break }
            sleep(Duration.millisecond * 5)
        }
        lock.lock(); try { operationDone = true } finally { lock.unlock() }
        JsonRpcEnvelope.Response(JsonRpcResponse(
            jsonRpcNumberId(1), JsonRpcResponsePayload.Success(jsonObject([]))
        ))
    }
    func cancel(): Unit {
        lock.lock(); try { cancelled = true } finally { lock.unlock() }
    }
    func release(): Unit {
        lock.lock(); try {
            releasedBeforeDone = !operationDone
            released = true
        } finally { lock.unlock() }
    }
    func waitUntilReleased(): Unit {
        var waited: Int64 = 0
        while (waited < 3000) {
            lock.lock(); let done = try { released } finally { lock.unlock() }
            if (done) { return }
            sleep(Duration.millisecond * 5); waited += 5
        }
        throw IllegalStateException("SSE worker reservation was not released")
    }
    func wasCancelled(): Bool { lock.lock(); try { cancelled } finally { lock.unlock() } }
    func wasReleased(): Bool { lock.lock(); try { released } finally { lock.unlock() } }
    func wasReleasedBeforeDone(): Bool {
        lock.lock(); try { releasedBeforeDone } finally { lock.unlock() }
    }
}

func fixtureElicitationParams(): JsonNode {
    jsonObject([
        JsonObjectEntry("mode", jsonString("form")),
        JsonObjectEntry("message", jsonString("Continue?")),
        JsonObjectEntry("requestedSchema", jsonObject([
            JsonObjectEntry("type", jsonString("object")),
            JsonObjectEntry("properties", jsonObject([]))
        ]))
    ])
}

class FixtureMcpResolver <: McpInputResolver {
    var requestState = ""
    public func resolve(requests: JsonNode, requestState: String): McpResult<JsonNode> {
        this.requestState = requestState
        let responses = ArrayList<JsonObjectEntry>()
        for (request in requests.fields) {
            responses.add(JsonObjectEntry(request.name, jsonObject([
                JsonObjectEntry("action", jsonString("accept")),
                JsonObjectEntry("content", jsonObject([]))
            ])))
        }
        McpResult.Ok(jsonObject(responses.toArray()))
    }
}

class FixtureMcpSubscriptionHandle <: McpSubscriptionHandle {
    let id: JsonRpcId
    let source: McpSubscriptionSource
    init(id: JsonRpcId, source: McpSubscriptionSource) { this.id = id; this.source = source }
    public func subscriptionId(): JsonRpcId { id }
    public func acknowledged(): McpSubscriptionFilter { source.acknowledged() }
    public func next(): McpResult<?JsonRpcNotification> { source.next() }
    public func close(): McpResult<Unit> { source.close() }
}

class FailingCancellationHost <: McpToolHost {
    public func listTools(cursor: String): McpResult<McpToolListPage> {
        let _ = cursor
        McpResult.Ok(McpToolListPage([]))
    }
    public func callTool(
        requestId: JsonRpcId, name: String, arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpCallToolOutcome> {
        let _ = requestId; let _ = name; let _ = arguments; let _ = continuation
        invalidMcp<McpCallToolOutcome>("fixture.unknown_id", "unknown request id")
    }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = requestId; let _ = reason
        invalidMcp<Unit>("fixture.unknown_id", "unknown request id")
    }
}

class CancellationTrackingProvider <: McpNotificationProvider {
    var cancelled = false
    public func open(requestId: JsonRpcId, filter: McpSubscriptionFilter): McpResult<McpSubscriptionSource> {
        let _ = requestId; let _ = filter
        invalidMcp<McpSubscriptionSource>("fixture.unavailable", "not used")
    }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = requestId; let _ = reason
        cancelled = true
        McpResult.Ok(())
    }
}

class FixtureMcpSubscriptionSource <: McpSubscriptionSource {
    let filter: McpSubscriptionFilter
    var emitted = false
    init(filter: McpSubscriptionFilter) { this.filter = filter }
    public func acknowledged(): McpSubscriptionFilter { filter }
    public func next(): McpResult<?JsonRpcNotification> {
        if (emitted) { return McpResult.Ok(None) }
        emitted = true
        McpResult.Ok(Some(JsonRpcNotification(MCP_NOTIFICATION_TOOLS_LIST_CHANGED, params: jsonObject([]))))
    }
    public func close(): McpResult<Unit> { McpResult.Ok(()) }
}

class HoldingNotificationProvider <: McpNotificationProvider {
    public func open(requestId: JsonRpcId, filter: McpSubscriptionFilter): McpResult<McpSubscriptionSource> {
        let _ = requestId
        McpResult.Ok(HoldingSubscriptionSource(filter))
    }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = requestId; let _ = reason
        McpResult.Ok(())
    }
}

class HoldingSubscriptionSource <: McpSubscriptionSource {
    private let filter: McpSubscriptionFilter
    private let lock = Mutex()
    private var closed = false
    init(filter: McpSubscriptionFilter) { this.filter = filter }
    public func acknowledged(): McpSubscriptionFilter { filter }
    public func next(): McpResult<?JsonRpcNotification> {
        sleep(Duration.millisecond * 10)
        lock.lock(); let done = try { closed } finally { lock.unlock() }
        if (done) { McpResult.Ok(None) }
        else { McpResult.Ok(Some(JsonRpcNotification(
            MCP_NOTIFICATION_TOOLS_LIST_CHANGED, params: jsonObject([])
        ))) }
    }
    public func close(): McpResult<Unit> {
        lock.lock(); try { closed = true } finally { lock.unlock() }
        McpResult.Ok(())
    }
}

class FixtureMcpTaskProvider <: McpTaskProvider {
    let task: McpTask
    var updated = false
    var cancelled = false
    init(task: McpTask) { this.task = task }
    public func getTask(taskId: String): McpResult<McpTask> {
        if (taskId == task.taskId) { McpResult.Ok(task) }
        else { invalidMcp<McpTask>("mcp.tasks.not_found", "MCP task was not found") }
    }
    public func updateTask(taskId: String, inputResponses: JsonNode): McpResult<Unit> {
        if (taskId != task.taskId || inputResponses.field("confirm").isNone()) {
            return invalidMcp<Unit>("mcp.tasks.update_invalid", "invalid fixture task update")
        }
        updated = true; McpResult.Ok(())
    }
    public func cancelTask(taskId: String): McpResult<Unit> {
        if (taskId != task.taskId) { return invalidMcp<Unit>("mcp.tasks.not_found", "MCP task was not found") }
        cancelled = true; McpResult.Ok(())
    }
}

class FixtureMcpProviders <: McpCompletionProvider & McpPromptProvider & McpResourceProvider & McpNotificationProvider {
    var promptCalls: Int64 = 0

    public func complete(
        requestId: JsonRpcId, reference: JsonNode, argument: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpCompletionResult>> {
        let _ = requestId; let _ = reference; let _ = argument; let _ = continuation
        McpResult.Ok(McpOperationOutcome.Extension("com.example/deferred", jsonObject([
            JsonObjectEntry("token", jsonString("later"))
        ])))
    }

    public func listPrompts(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([McpPrompt("review").toValue()]))
    }

    public func getPrompt(
        requestId: JsonRpcId, name: String, arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpPromptResult>> {
        let _ = requestId; let _ = name; let _ = arguments
        promptCalls++
        if (continuation.requestState == "") {
            McpResult.Ok(McpOperationOutcome.InputRequired(McpInputRequiredResult(
                inputRequests: jsonObject([JsonObjectEntry("ask", jsonObject([
                    JsonObjectEntry("method", jsonString("elicitation/create")),
                    JsonObjectEntry("params", fixtureElicitationParams())
                ]))]),
                requestState: "opaque-state-ß"
            )))
        } else if (continuation.requestState == "opaque-state-ß") {
            let message = jsonObject([
                JsonObjectEntry("role", jsonString("user")),
                JsonObjectEntry("content", jsonObject([
                    JsonObjectEntry("type", jsonString("text")),
                    JsonObjectEntry("text", jsonString("review"))
                ]))
            ])
            McpResult.Ok(McpOperationOutcome.Complete(McpPromptResult([message])))
        } else {
            invalidMcp<McpOperationOutcome<McpPromptResult>>("fixture.state_changed", "requestState changed")
        }
    }

    public func listResources(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([McpResource("file:///readme", "readme").toValue()]))
    }
    public func listResourceTemplates(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([McpResourceTemplate("file:///{path}", "file").toValue()]))
    }
    public func readResource(
        requestId: JsonRpcId, uri: String, continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpReadResourceResult>> {
        let _ = requestId; let _ = continuation
        let content = jsonObject([
            JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("text", jsonString("ok"))
        ])
        McpResult.Ok(McpOperationOutcome.Complete(McpReadResourceResult([content])))
    }
    public func open(
        requestId: JsonRpcId, filter: McpSubscriptionFilter
    ): McpResult<McpSubscriptionSource> {
        let _ = requestId
        McpResult.Ok(FixtureMcpSubscriptionSource(filter))
    }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = requestId; let _ = reason; McpResult.Ok(())
    }
}
