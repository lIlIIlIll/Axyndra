package mcp4cj

import jsonrpc4cj.*
import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func preparedHttpSchema(header: String): JsonNode {
    jsonObject([JsonObjectEntry("type", jsonString("object")), JsonObjectEntry("properties", jsonObject([
        JsonObjectEntry("region", jsonObject([JsonObjectEntry("type", jsonString("string")),
            JsonObjectEntry("x-mcp-header", jsonString(header))]))
    ]))])
}

func preparedHttpHeader(request: McpHttpExchangeRequest, name: String): String {
    for (header in request.headers where header.name.toAsciiLower() == name.toAsciiLower()) { return header.value }
    ""
}

@Test
class McpPreparedHttpTests {
    @TestCase
    func freezesWholeHttpRequestBeforeApprovalAndSendsOriginalHeadersAfterSchemaChange() {
        let calls = AtomicInt64(0)
        let host = MemoryMcpToolHost([McpTool("echo", "echo", preparedHttpSchema("Region"))],
            { _: String, args: JsonNode, _: McpToolCallContinuation =>
                let _ = calls.fetchAdd(1)
                McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([jsonObject([
                    JsonObjectEntry("type", jsonString("text")), JsonObjectEntry("text", jsonString(mcpText(args, "region")))
                ])])))
            })
        let server = requirePrepared(openStreamableHttpMcpServer(McpStreamableHttpServerConfig(
            port: 0, bearerToken: "prepared-local-fixture", originAllowlist: ["http://localhost"]),
            McpServerBuilder().toolProvider(host).build()))
        let serving = spawn { server.serve() }
        let deadline = MonoTime.now() + Duration.millisecond * 3000
        while (server.state() != McpLifecycleState.Ready && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        let port = RecordingRealMcpHttpPort()
        let url = "http://127.0.0.1:" + server.port().toString() + "/mcp"
        let config = McpStreamableHttpClientConfig(url, bearerToken: "prepared-local-fixture",
            headers: [McpHttpHeader("X-Deployment", "before")], origin: "http://localhost", preferSse: true,
            framing: McpFramingConfig(requestTimeoutMillis: 4000))
        let transport = StreamableHttpMcpTransport(config, port)
        let client = McpClient(transport, McpRequestMeta())
        try {
            @Expect(client.listTools().isOk(), true)
            let args = jsonObject([JsonObjectEntry("region", jsonString("雪 &+"))])
            let prepared = requirePrepared(client.prepareToolCall("frozen-http", "echo", args))
            let request = prepared.httpExchange.getOrThrow()
            @Expect(port.requests().size, 1)
            @Expect(calls.load(), 0)
            @Expect(request.url, url)
            @Expect(request.method, "POST")
            @Expect(request.body, prepared.rpcJson)
            @Expect(request.readTimeoutMillis.getOrThrow(), 4000)
            @Expect(request.writeTimeoutMillis, 4000)
            @Expect(preparedHttpHeader(request, "Content-Type"), "application/json")
            @Expect(preparedHttpHeader(request, "Accept"), "text/event-stream, application/json")
            @Expect(preparedHttpHeader(request, MCP_HEADER_PROTOCOL_VERSION), MCP_PROTOCOL_VERSION)
            @Expect(preparedHttpHeader(request, MCP_HEADER_METHOD), MCP_METHOD_TOOLS_CALL)
            @Expect(preparedHttpHeader(request, MCP_HEADER_NAME), encodeMcpHeader("echo"))
            @Expect(preparedHttpHeader(request, MCP_HEADER_CLIENT_INSTANCE_ID) != "", true)
            @Expect(preparedHttpHeader(request, "Origin"), "http://localhost")
            @Expect(preparedHttpHeader(request, "Authorization"), "Bearer prepared-local-fixture")
            @Expect(preparedHttpHeader(request, "Mcp-Param-Region"), encodeMcpHeader("雪 &+"))
            @Expect(preparedHttpHeader(request, "X-Deployment"), "before")

            // Both inputs and the current transport directory can change while
            // approval is pending. Neither may reconstruct the approved send.
            args.put("region", jsonString("changed"))
            config.headers[0] = McpHttpHeader("X-Deployment", "after")
            @Expect(transport.registerTools([McpTool("echo", "changed", preparedHttpSchema("Tenant"))]).isOk(), true)
            let exported = request.headers
            exported[0] = McpHttpHeader("X-Mutated", "bad")
            @Expect(preparedResultText(client.dispatchPreparedToolCall(prepared)), "雪 &+")
            @Expect(calls.load(), 1)
            @Expect(port.requests().size, 2)
            let sent = port.requests()[1]
            @Expect(sent.body, request.body)
            @Expect(sent.url, request.url)
            @Expect(sent.method, request.method)
            @Expect(sent.headers.size, request.headers.size)
            for (index in 0..request.headers.size) {
                @Expect(sent.headers[index].name, request.headers[index].name)
                @Expect(sent.headers[index].value, request.headers[index].value)
            }
            @Expect(preparedHttpHeader(sent, "Mcp-Param-Tenant"), "")
            expectPreparedError(client.dispatchPreparedToolCall(prepared), "mcp.prepared_already_dispatched")
            @Expect(calls.load(), 1)
            @Expect(port.requests().size, 2)
        } finally {
            try { let _ = client.close() }
            finally { let _ = server.close(); let _ = serving.get() }
        }
    }

    @TestCase
    func foreignTransportAndMissingProjectionCannotAllocateOrSendAnExchange() {
        let firstPort = RecordingRealMcpHttpPort()
        let secondPort = RecordingRealMcpHttpPort()
        let first = StreamableHttpMcpTransport(McpStreamableHttpClientConfig("http://127.0.0.1:1/mcp"), firstPort)
        let second = StreamableHttpMcpTransport(McpStreamableHttpClientConfig("http://127.0.0.1:2/mcp"), secondPort)
        let client = McpClient(first, McpRequestMeta())
        try {
            @Expect(first.registerTools([McpTool("echo", "echo", preparedHttpSchema("Region"))]).isOk(), true)
            let prepared = requirePrepared(client.prepareToolCall("bound-transport", "echo", jsonObject([])))
            expectPreparedError(second.requestPrepared(prepared, { _ => }), "mcp.prepared_http_transport_mismatch")
            let raw = McpPreparedToolCall(McpPreparedClientSeal(), prepared.requestId, prepared.rpcJson, "", "")
            expectPreparedError(first.requestPrepared(raw, { _ => }), "mcp.prepared_http_transport_mismatch")
            @Expect(firstPort.requests().size, 0)
            @Expect(secondPort.requests().size, 0)
            let _ = first.close()
            expectPreparedError(first.requestPrepared(prepared, { _ => }), "mcp.http_not_ready")
            @Expect(firstPort.requests().size, 0)
        } finally { let _ = client.close(); let _ = second.close() }
    }

    @TestCase
    func missingDirectoryAndInvalidProjectedParameterFailDuringPurePreparation() {
        let port = RecordingRealMcpHttpPort()
        let transport = StreamableHttpMcpTransport(McpStreamableHttpClientConfig("http://127.0.0.1:1/mcp"), port)
        let client = McpClient(transport, McpRequestMeta())
        try {
            expectPreparedError(client.prepareToolCall("missing-schema", "echo", jsonObject([])), "mcp.http_tool_schema_missing")
            @Expect(port.requests().size, 0)
            @Expect(transport.registerTools([McpTool("echo", "echo", preparedHttpSchema("Region"))]).isOk(), true)
            @Expect(client.prepareToolCall("bad-header", "echo", jsonObject([
                JsonObjectEntry("region", jsonObject([JsonObjectEntry("nested", jsonString("bad"))]))
            ])).isOk(), false)
            @Expect(port.requests().size, 0)
            let valid = requirePrepared(client.prepareToolCall("valid-header", "echo", jsonObject([
                JsonObjectEntry("region", jsonString("cn"))])))
            @Expect(preparedHttpHeader(valid.httpExchange.getOrThrow(), "Mcp-Param-Region"), encodeMcpHeader("cn"))
            @Expect(port.requests().size, 0)
        } finally { let _ = client.close() }
    }
}
