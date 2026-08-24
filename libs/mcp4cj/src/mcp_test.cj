package mcp4cj

import json4cj.*
import jsonrpc4cj.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Mcp4CjTests {
    @TestCase
    func modelsDiscoveryPaginationAndCallsWithoutAgentTypes() {
        let client = McpImplementationInfo("test-client", "1")
        let meta = McpRequestMeta(client)
        @Expect(meta.protocolVersion, MCP_PROTOCOL_VERSION)

        let tool = McpTool(
            "read_file",
            "read a file",
            JsonValue.objectValue([JsonField("type", JsonValue.stringValue("object"))])
        )
        let page = McpToolListPage([tool], nextCursor: "next")
        @Expect(page.tools.size, 1)
        @Expect(page.nextCursor, "next")

        let outcome = McpCallToolOutcome.Complete(McpCallToolResult(
            [JsonValue.objectValue([
                JsonField("type", JsonValue.stringValue("text")),
                JsonField("text", JsonValue.stringValue("ok"))
            ])], isError: false
        ))
        @Expect(mcpCallToolOutcomeValue(outcome).field("resultType").getOrThrow().text, MCP_RESULT_COMPLETE)
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
    func stdioTransportFramesAndCorrelatesResponse() {
        let script = "IFS= read -r line; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}'"
        let transport = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", script]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        match (transport.request(JsonRpcRequest(jsonRpcNumberId(1), MCP_METHOD_PING))) {
            case McpResult.Ok(response) => match (response.payload) {
                case JsonRpcResponsePayload.Success(value) => @Expect(value.field("ok").getOrThrow().boolean, true)
                case _ => @Fail("expected successful response")
            }
            case McpResult.Err(error) => @Fail(error.message)
        }
        @Expect(transport.close().isOk(), true)
    }

    @TestCase
    func classifiesMalformedFramesAndSpawnFailures() {
        let malformed = match (openStdioMcpTransport(McpStdioConfig(
            "/bin/sh", arguments: ["-c", "IFS= read -r line; printf 'not-json\\n'"]
        ))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        match (malformed.request(JsonRpcRequest(jsonRpcNumberId(2), MCP_METHOD_PING))) {
            case McpResult.Err(error) => @Expect(error.code, "json_rpc.parse_error")
            case _ => @Fail("malformed frame must fail")
        }

        match (openStdioMcpTransport(McpStdioConfig("/definitely/missing/mcp-server"))) {
            case McpResult.Err(error) => @Expect(error.code, "mcp.stdio_start_failed")
            case McpResult.Ok(transport) => match (transport.request(JsonRpcRequest(
                jsonRpcNumberId(3), MCP_METHOD_PING
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

        let body = ByteBuffer()
        body.write("12345".toArray())
        @Expect(readMcpHttpBody(body, Some(5), 4).isOk(), false)
    }

    @TestCase
    func clientAndServerOwnLifecyclePaginationCallsAndCancellation() {
        let tool = McpTool("echo", "echo", JsonValue.objectValue([
            JsonField("type", JsonValue.stringValue("object")),
            JsonField("properties", JsonValue.objectValue([
                JsonField("value", JsonValue.objectValue([JsonField("type", JsonValue.stringValue("string"))]))
            ])),
            JsonField("required", JsonValue.arrayValue([JsonValue.stringValue("value")]))
        ]))
        let host = MemoryMcpToolHost([tool], { _: String, arguments: JsonValue, _: McpToolCallContinuation =>
            McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([], structuredContent: arguments)))
        }, pageSize: 1)
        let server = McpServer(McpDiscoverResult(McpImplementationInfo("server", "1")), host)
        let transport = InMemoryMcpTransport(server)
        let client = McpClient(transport, McpRequestMeta(McpImplementationInfo("client", "1")))
        @Expect(client.discover().isOk(), true)
        @Expect(client.listTools().isOk(), true)
        match (client.callTool("echo", JsonValue.objectValue([JsonField("value", JsonValue.stringValue("ok"))]))) {
            case McpResult.Ok(McpCallToolOutcome.Complete(value)) => @Expect(value.structuredContent.field("value").getOrThrow().text, "ok")
            case _ => @Fail("generic tools/call failed")
        }
        @Expect(client.callTool("echo", JsonValue.objectValue([])).isOk(), false)
        @Expect(client.notify("notifications/test").isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.close().isOk(), true)
        @Expect(client.ping().isOk(), false)
        @Expect(transport.closed, true)
        @Expect(server.close().isOk(), true)
    }
}

class InMemoryMcpTransport <: McpTransport {
    let server: McpServer
    var closed = false
    init(server: McpServer) { this.server = server }
    public func kind(): McpTransportKind { McpTransportKind.Stdio }
    public func state(): McpLifecycleState { if (closed) { McpLifecycleState.Stopped } else { McpLifecycleState.Ready } }
    public func request(request: JsonRpcRequest): McpResult<JsonRpcResponse> { if (closed) { McpResult.Err(McpError(McpErrorKind.Lifecycle, "closed", "closed")) } else { McpResult.Ok(server.handleRequest(request)) } }
    public func notify(notification: JsonRpcNotification): McpResult<Unit> { server.handleNotification(notification) }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> { server.handleNotification(mcpCancellationNotification(requestId, reason)) }
    public func close(): McpResult<Unit> { closed = true; McpResult.Ok(()) }
}
