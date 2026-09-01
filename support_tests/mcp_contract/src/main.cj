package mcp_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_mcp.*
import agent_protocol.*
import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import stdx.log.NoopLogger
import stdx.net.http.*

class RawMcpHttpResponse {
    let status: UInt16
    let body: String

    init(status: UInt16, body: String) {
        this.status = status
        this.body = body
    }
}

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size > 1 && arguments[1] == "--mcp-stdio-server") {
        return runFixtureStdioServer()
    }
    if (arguments.size > 1 && arguments[1] == "--mcp-stdio-limit-server") {
        return runLimitedStdioServer()
    }
    if (arguments.size > 1 && arguments[1] == "--mcp-stdio-shutdown-server") {
        return runIncompleteShutdownStdioServer()
    }
    runJsonRpcContracts()
    runAliasAndConfigContracts()
    runClientServerContracts()
    runFinalWireAndMrtrContracts()
    runStdioAdmissionAndShutdownContracts()
    runStdioLoopbackContract()
    runHttpLoopbackContract()
    println("mcp contract passed")
    0
}

func runJsonRpcContracts(): Unit {
    let request = JsonRpcEnvelope.Request(JsonRpcRequest(
        jsonRpcNumberId(7),
        "tools/list",
        params: objectValue([ValueField("cursor", textValue("next"))])
    ))
    let encoded = encodeJsonRpc(request)
    match (decodeJsonRpc(encoded)) {
        case Result.Ok(JsonRpcEnvelope.Request(decoded)) =>
            expect(
                decoded.method == "tools/list" &&
                decoded.id.kind == JsonRpcIdKind.Number &&
                decoded.id.value == "7",
                "JSON-RPC request round trips with typed id"
            )
        case _ => throw IllegalStateException("JSON-RPC request did not round trip")
    }
    match (decodeJsonRpc("{not-json")) {
        case Result.Err(error) => expect(
            error.code == "json_rpc.parse_error" &&
            error.field("json_rpc_code") == Some("-32700"),
            "JSON parse errors retain the standard code"
        )
        case _ => throw IllegalStateException("malformed JSON-RPC was accepted")
    }
    match (decodeJsonRpc("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}")) {
        case Result.Err(error) => expect(
            error.code == "json_rpc.invalid_request",
            "response result and error are mutually exclusive"
        )
        case _ => throw IllegalStateException("invalid JSON-RPC response was accepted")
    }

    let correlation = JsonRpcCorrelation()
    let id = jsonRpcTextId("request-1")
    expect(correlation.reserve(id).isOk(), "correlation reserves an id")
    expect(correlation.reserve(id).isError(), "correlation rejects duplicate ids")
    expect(correlation.pendingCount() == 1, "correlation exposes pending count")
    expect(correlation.complete(id).isOk(), "correlation completes a request")
    expect(correlation.complete(id).isError(), "correlation completion is single-use")
}

func runAliasAndConfigContracts(): Unit {
    expect(
        mcpToolAlias("git hub", "read-file") == "mcp__git_hub__read_file",
        "MCP aliases are model-safe"
    )
    let longAlias = mcpToolAlias(
        "server-with-a-very-long-identity-that-needs-truncation",
        "tool-with-a-very-long-identity-that-needs-truncation"
    )
    expect(longAlias.size == 64, "long MCP aliases are capped and hashed")
    expect(
        longAlias == mcpToolAlias(
            "server-with-a-very-long-identity-that-needs-truncation",
            "tool-with-a-very-long-identity-that-needs-truncation"
        ),
        "MCP alias hashing is stable"
    )
    let aliases = McpToolAliasRegistry()
    let first = aliases.register("a-b", "read").value().getOrThrow()
    let second = aliases.register("a_b", "read").value().getOrThrow()
    expect(first.alias != second.alias, "sanitization collisions receive a stable hash suffix")
    expect(
        aliases.resolve(second.alias).getOrThrow().serverId == "a_b",
        "MCP aliases map back to the original identity"
    )

    let _ = McpStdioTransportConfig(
        "/usr/bin/example-mcp",
        arguments: ["--stdio"],
        environment: [McpEnvironmentBinding("TOKEN", "MCP_TOKEN")]
    )
    expect(
        McpFramingConfig().maxConcurrentRequests == 16 &&
            rejects({ => McpFramingConfig(maxConcurrentRequests: 0) }),
        "stdio framing defaults to sixteen concurrent requests and rejects an empty limit"
    )
    let framer = McpJsonLineFramer(config: McpFramingConfig(maxFrameBytes: 1024))
    expect(framer.push("{\"one\":1}\n{\"two\"").value().getOrThrow().size == 1,
           "stdio framing emits complete JSON lines only")
    let completed = framer.push(":2}\r\n").value().getOrThrow()
    expect(completed == ["{\"two\":2}"], "stdio framing preserves partial input and accepts CRLF")
    expect(rejects({ =>
        McpStreamableHttpClientConfig("http://remote.example/mcp")
    }), "remote MCP clients require HTTPS")
    let _ = McpStreamableHttpClientConfig(
        "https://mcp.example/mcp",
        bearerTokenEnvironment: "MCP_BEARER"
    )
    expect(rejects({ =>
        McpStreamableHttpClientConfig("http://127.0.0.1.evil.example/mcp")
    }), "loopback HTTP validation rejects host-prefix confusion")
    expect(rejects({ =>
        McpStreamableHttpClientConfig(
            "https://mcp.example/mcp",
            headers: [McpHttpHeaderBinding("Authorization", "MCP_BEARER")]
        )
    }), "custom header bindings cannot replace security headers")
    expect(rejects({ =>
        McpStreamableHttpServerConfig(bindHost: "0.0.0.0", bearerTokenEnvironment: "MCP_BEARER")
    }), "non-loopback HTTP refuses missing external TLS trust")
    let httpServer = McpStreamableHttpServerConfig(
        bindHost: "0.0.0.0",
        bearerTokenEnvironment: "MCP_BEARER",
        externalTls: true,
        trustProxy: true,
        originAllowlist: ["https://app.example"]
    )
    expect(McpNativeTransportWiring().httpRequest.indexOf("POST /mcp").isSome(),
           "native Streamable HTTP wiring point is explicit")
    match (openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
        "https://mcp.example/mcp",
        bearerTokenEnvironment: "MCP_HTTP_CONTRACT_MISSING"
    ))) {
        case Result.Err(error) => expect(
            error.code == "mcp.http_environment_missing",
            "Streamable HTTP resolves secret references before opening"
        )
        case _ => throw IllegalStateException("missing Streamable HTTP secret was accepted")
    }
    setVariable("MCP_HTTP_CONTRACT_INVALID", "secret\r\nX-Injected: yes")
    match (openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
        "https://mcp.example/mcp",
        bearerTokenEnvironment: "MCP_HTTP_CONTRACT_INVALID"
    ))) {
        case Result.Err(error) => expect(
            error.code == "mcp.http_environment_value_invalid" &&
            error.describe().indexOf("X-Injected").isNone(),
            "HTTP secret values reject header injection without leaking the value"
        )
        case _ => throw IllegalStateException("HTTP header injection value was accepted")
    }
    let httpMetadata = McpHttpRequestMetadata(
        MCP_PROTOCOL_VERSION,
        MCP_METHOD_TOOLS_CALL,
        name: "echo",
        origin: "https://app.example"
    )
    expect(
        httpMetadata.validateBody(
            MCP_METHOD_TOOLS_CALL,
            objectValue([
                ValueField("name", textValue("echo")),
                ValueField("_meta", McpRequestMeta(
                    clientInfo: McpImplementationInfo("contract", "1")
                ).toValue())
            ])
        ).isOk() &&
        mcpOriginAllowed(httpServer, httpMetadata.origin) &&
        !mcpOriginAllowed(httpServer, "https://evil.example") &&
        mcpBearerAuthorized("Bearer secret", "secret") &&
        !mcpBearerAuthorized("Bearer wrong", "secret"),
        "HTTP headers, exact Origin allowlist, and bearer auth are enforced"
    )
}

func runStdioAdmissionAndShutdownContracts(): Unit {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        let executable = getCommandLine()[0]
        let limitInput = root + "/limit.jsonl"
        var frames = ""
        for (id in 1..4) { frames += stdioSlowCallFrame(id) + "\n" }
        File.writeTo(limitInput, frames.toArray())
        let (limitCode, limitOutput, limitError) = runStdioContractChild(
            executable,
            "--mcp-stdio-limit-server",
            limitInput
        )
        expect(
            limitCode == 0 && String.fromUtf8(limitError).trimAscii() == "",
            "limited stdio fixture exits cleanly"
        )
        var completed: Int64 = 0
        var busy = false
        for (line in String.fromUtf8(limitOutput).split("\n") where line.trimAscii() != "") {
            let envelope = decodeJsonRpc(line).value().getOrThrow()
            match (envelope) {
                case JsonRpcEnvelope.Response(response) => match (response.payload) {
                    case JsonRpcResponsePayload.Success(_) =>
                        if (response.id.kind == JsonRpcIdKind.Number &&
                            (response.id.value == "1" || response.id.value == "2")) {
                            completed += 1
                        }
                    case JsonRpcResponsePayload.Failure(error) =>
                        if (sameJsonRpcId(response.id, jsonRpcNumberId(3))) {
                            let maximum = error.data.field("max_concurrent_requests").getOrThrow()
                            busy = error.code == JSON_RPC_INTERNAL_ERROR &&
                                requiredText(error.data, "code") == "mcp.stdio_server_busy" &&
                                maximum.unifiedKind == ValueKind.Number && maximum.number == "2" &&
                                line.size <= 512
                        }
                }
                case _ => throw IllegalStateException("stdio child emitted a non-response envelope")
            }
        }
        expect(
            completed == 2 && busy,
            "stdio admission reserves atomically and rejects excess work with a bounded server_busy response"
        )

        let shutdownInput = root + "/shutdown.jsonl"
        File.writeTo(shutdownInput, (stdioSlowCallFrame(41) + "\n").toArray())
        let (shutdownCode, _, shutdownError) = runStdioContractChild(
            executable,
            "--mcp-stdio-shutdown-server",
            shutdownInput
        )
        expect(
            shutdownCode == 0 &&
                String.fromUtf8(shutdownError).trimAscii() ==
                    "mcp.stdio_shutdown_incomplete:Stopping:1",
            "stdio shutdown waits, cancels, waits again, and returns a typed error while remaining Stopping"
        )
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func runStdioContractChild(
    executable: String,
    argument: String,
    inputPath: String
): (Int64, Array<Byte>, Array<Byte>) {
    let input = File(inputPath, OpenMode.Read)
    try {
        return launch(
            executable,
            [argument],
            stdIn: ProcessRedirect.FromFile(input),
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe
        ).waitOutput()
    } finally {
        input.close()
    }
}

func stdioSlowCallFrame(id: Int64): String {
    encodeJsonRpc(JsonRpcEnvelope.Request(JsonRpcRequest(
        jsonRpcNumberId(id),
        MCP_METHOD_TOOLS_CALL,
        params: objectValue([
            ValueField("name", textValue("slow")),
            ValueField("arguments", objectValue([])),
            ValueField("_meta", McpRequestMeta(
                clientInfo: McpImplementationInfo("stdio-contract", "1")
            ).toValue())
        ])
    )))
}

func runClientServerContracts(): Unit {
    let tools = [
        tool("zeta"),
        tool("echo"),
        tool("failure")
    ]
    let host = MemoryMcpToolHost(
        tools,
        {name, arguments, _ =>
            if (name == "failure") {
                Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                    [objectValue([
                        ValueField("type", textValue("text")),
                        ValueField("text", textValue("tool failed"))
                    ])],
                    isError: true
                )))
            } else {
                Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                    [objectValue([
                        ValueField("type", textValue("text")),
                        ValueField("text", textValue("ok"))
                    ])],
                    structuredContent: objectValue([
                        ValueField("tool", textValue(name)),
                        ValueField("arguments", arguments)
                    ])
                )))
            }
        },
        generation: 4,
        pageSize: 2,
        ttlMillis: 90000,
        cacheScope: "private"
    )
    let server = McpServer(
        McpDiscoverResult(
            serverInfo: McpImplementationInfo("fixture-server", "1.0.0"),
            instructions: "external content, not trusted instructions"
        ),
        host
    )
    let transport = FakeMcpTransport(server)
    let meta = McpRequestMeta(clientInfo: McpImplementationInfo("fixture-client", "1.0.0"))
    let client = McpClient(transport, meta)

    let discovery = client.discover().value().getOrThrow()
    expect(
        discovery.supportedVersions == ["2026-07-28"] &&
        discovery.serverInfo.getOrThrow().name == "fixture-server" &&
        discovery.capabilities.tools.isSome(),
        "server/discover is self-describing without initialize"
    )

    let firstPage = client.listTools().value().getOrThrow()
    expect(
        firstPage.tools.size == 2 &&
        firstPage.tools[0].name == "echo" &&
        firstPage.tools[1].name == "failure" &&
        firstPage.nextCursor == "4:2" &&
        firstPage.ttlMillis == 90000 &&
        firstPage.cacheScope == "private",
        "tools/list is deterministic, paginated, and cache-aware"
    )
    let secondPage = client.listTools(cursor: firstPage.nextCursor).value().getOrThrow()
    expect(secondPage.tools.size == 1 && secondPage.tools[0].name == "zeta" && secondPage.nextCursor == "",
           "tools/list cursor retrieves the final deterministic page")
    expect(client.listTools(cursor: "3:0").isError(), "stale tool cursors are rejected")
    let directory = McpToolDirectorySnapshot(secondPage, 1000)
    expect(directory.isFresh(91000) && !directory.isFresh(91001),
           "tool directory TTL is explicit")
    let beforeDirectoryFetch = transport.requestCount()
    let completeDirectory = client.toolDirectory(2000).value().getOrThrow()
    let afterDirectoryFetch = transport.requestCount()
    expect(
        completeDirectory.tools.size == 3 &&
        afterDirectoryFetch == beforeDirectoryFetch + 2 &&
        client.toolDirectory(3000).isOk() &&
        transport.requestCount() == afterDirectoryFetch,
        "MCP client paginates and reuses a fresh directory cache"
    )

    let call = completeResult(client.callTool(
        "echo",
        objectValue([ValueField("text", textValue("hello"))]),
        runId: "run-echo"
    ).value().getOrThrow())
    expect(
        !call.isError &&
        call.content.size == 1 &&
        requiredText(call.structuredContent, "tool") == "echo",
        "tools/call preserves content and structuredContent"
    )
    let executionFailure = completeResult(
        client.callTool("failure", objectValue([])).value().getOrThrow()
    )
    expect(executionFailure.isError, "tool execution errors are results, not JSON-RPC failures")

    let countBeforeLoss = transport.requestCount()
    transport.failNextAfterDispatch()
    match (client.callTool("echo", objectValue([]))) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.RecoveryRequired &&
            transport.requestCount() == countBeforeLoss + 1,
            "ambiguous tools/call loss is not retried"
        )
        case _ => throw IllegalStateException("lost MCP response was reported as success")
    }

    expect(
        transport.cancel(jsonRpcNumberId(99), "test cancellation", meta).isOk() &&
        host.cancellations() == ["99"],
        "MCP cancellation reaches the tool host"
    )
    let missingMeta = server.handleRequest(JsonRpcRequest(
        jsonRpcNumberId(100),
        "ping",
        params: objectValue([])
    ))
    match (missingMeta.payload) {
        case JsonRpcResponsePayload.Failure(error) => expect(
            error.code == JSON_RPC_INVALID_PARAMS,
            "MCP 2026-07-28 rejects requests without _meta"
        )
        case _ => throw IllegalStateException("MCP request without _meta was accepted")
    }
    let oldInitialize = server.handleRequest(JsonRpcRequest(
        jsonRpcNumberId(101),
        "initialize",
        params: objectValue([ValueField("_meta", meta.toValue())])
    ))
    match (oldInitialize.payload) {
        case JsonRpcResponsePayload.Failure(error) => expect(
            error.code == JSON_RPC_METHOD_NOT_FOUND,
            "legacy initialize is not implemented"
        )
        case _ => throw IllegalStateException("legacy initialize was accepted")
    }
    expect(client.close().isOk() && transport.state() == McpLifecycleState.Stopped,
           "client close owns transport shutdown")
}

func runFinalWireAndMrtrContracts(): Unit {
    let requiredSchema = objectValue([
        ValueField("type", textValue("object")),
        ValueField("properties", objectValue([
            ValueField("value", objectValue([ValueField("type", textValue("string"))]))
        ])),
        ValueField("required", listValue([textValue("value")])),
        ValueField("additionalProperties", boolValue(false))
    ])
    let host = MemoryMcpToolHost(
        [McpTool("mrtr", "multi round trip", requiredSchema), tool("remote-error")],
        {name, arguments, continuation =>
            if (name == "remote-error") {
                return Result.Err(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "mcp.fixture_approval_required",
                    "fixture requires approval",
                    fields: [
                        ErrorField("operation_id", "fixture-operation"),
                        ErrorField("retry_safe", "false")
                    ]
                ))
            }
            if (!continuation.isRetry()) {
                Result.Ok(McpCallToolOutcome.InputRequired(McpInputRequiredResult(
                    inputRequests: objectValue([
                        ValueField("confirm", objectValue([
                            ValueField("method", textValue("elicitation/create")),
                            ValueField("params", objectValue([
                                ValueField("mode", textValue("form")),
                                ValueField("message", textValue("Continue?")),
                                ValueField("requestedSchema", objectValue([
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([]))
                                ]))
                            ]))
                        ]))
                    ]),
                    requestState: "opaque-state"
                )))
            } else {
                expect(
                    continuation.requestState == "opaque-state" &&
                    continuation.inputResponses.field("confirm").isSome(),
                    "MRTR retry echoes request state and keyed input responses"
                )
                Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                    [objectValue([
                        ValueField("type", textValue("text")),
                        ValueField("text", textValue("completed"))
                    ])],
                    structuredContent: arguments
                )))
            }
        },
        ttlMillis: 1234,
        cacheScope: "private"
    )
    let server = McpServer(
        McpDiscoverResult(
            serverInfo: McpImplementationInfo("wire-server", "2.0.0"),
            capabilities: McpServerCapabilities(tools: Some(McpCapabilityFeature())),
            ttlMillis: 4321,
            cacheScope: "private"
        ),
        host
    )
    let transport = FakeMcpTransport(server)
    let client = McpClient(
        transport,
        McpRequestMeta(
            clientInfo: McpImplementationInfo("wire-client", "1.0.0"),
            clientCapabilities: McpClientCapabilities(
                elicitation: Some(McpElicitationCapability())
            )
        )
    )
    let discovery = client.discover().value().getOrThrow()
    expect(
        discovery.supportedVersions == [MCP_PROTOCOL_VERSION] &&
        discovery.ttlMillis == 4321 && discovery.cacheScope == "private" &&
        !discovery.capabilities.tools.getOrThrow().listChanged,
        "server/discover uses supportedVersions, capabilities, ttlMs, and private cache scope"
    )
    let discoverRequest = transport.requestSnapshot()[0]
    let requestMeta = discoverRequest.params.field("_meta").getOrThrow()
    expect(
        requestMeta.field(MCP_META_PROTOCOL_VERSION).isSome() &&
        requestMeta.field(MCP_META_CLIENT_INFO).isSome() &&
        requestMeta.field(MCP_META_CLIENT_CAPABILITIES).isSome() &&
        requestMeta.field("protocolVersion").isNone() &&
        requestMeta.field("clientInfo").isNone(),
        "request _meta uses only final namespaced protocol keys"
    )
    let rawDiscovery = server.handleRequest(discoverRequest)
    match (rawDiscovery.payload) {
        case JsonRpcResponsePayload.Success(value) => expect(
            requiredText(value, "resultType") == "complete" &&
            value.field("supportedVersions").isSome() &&
            value.field("protocolVersion").isNone() &&
            value.field("serverInfo").isNone() &&
            value.field("_meta").getOrThrow().field(MCP_META_SERVER_INFO).isSome() &&
            value.field("capabilities").getOrThrow().field("subscriptions").isNone(),
            "success results carry resultType and namespaced serverInfo without legacy fields"
        )
        case _ => throw IllegalStateException("final discovery wire was not successful")
    }

    let page = client.listTools().value().getOrThrow()
    expect(
        page.tools.size == 2 && page.ttlMillis == 1234 && page.cacheScope == "private",
        "final tools/list result has deterministic cache metadata"
    )
    match (client.callTool("remote-error", objectValue([]))) {
        case Result.Err(error) => expect(
            error.code == "mcp.fixture_approval_required" &&
            error.field("remote_code") == Some("mcp.fixture_approval_required") &&
            error.field("operation_id") == Some("fixture-operation") &&
            error.field("retry_safe") == Some("false") &&
            error.field("json_rpc_code") == Some(JSON_RPC_INTERNAL_ERROR.toString()),
            "client preserves bounded remote host error code and scalar data fields"
        )
        case _ => throw IllegalStateException("remote host error was accepted")
    }
    match (client.callTool("mrtr", objectValue([]))) {
        case Result.Err(error) => expect(
            error.code == "mcp.invalid_params",
            "server validates tools/call arguments against inputSchema"
        )
        case _ => throw IllegalStateException("invalid tool input was accepted")
    }
    let arguments = objectValue([ValueField("value", textValue("ok"))])
    let pending = match (client.callTool("mrtr", arguments).value().getOrThrow()) {
        case McpCallToolOutcome.InputRequired(value) => value
        case _ => throw IllegalStateException("MRTR input_required result was not decoded")
    }
    expect(
        pending.requestState == "opaque-state" && pending.inputRequests.field("confirm").isSome(),
        "tools/call decodes the input_required MRTR union"
    )
    expect(
        client.retryToolCall("mrtr", arguments, pending, objectValue([])).isError(),
        "MRTR retry rejects missing keyed responses before dispatch"
    )
    let beforeRetry = transport.requestCount()
    let completed = client.retryToolCall(
        "mrtr",
        arguments,
        pending,
        objectValue([
            ValueField("confirm", objectValue([
                ValueField("action", textValue("accept")),
                ValueField("content", objectValue([]))
            ]))
        ])
    ).value().getOrThrow()
    expect(
        completeResult(completed).content.size == 1 &&
        transport.requestCount() == beforeRetry + 1,
        "MRTR retry sends one new JSON-RPC request and completes"
    )
    let requests = transport.requestSnapshot()
    expect(
        requests[requests.size - 1].id.display() != requests[requests.size - 2].id.display() &&
        requests[requests.size - 1].params.field("inputResponses").isSome() &&
        requiredText(requests[requests.size - 1].params, "requestState") == "opaque-state",
        "MRTR retry uses a fresh request id with inputResponses and opaque requestState"
    )
    let subscription = server.handleRequest(JsonRpcRequest(
        jsonRpcNumberId(500),
        "subscriptions/listen",
        params: objectValue([ValueField("_meta", McpRequestMeta(
            clientInfo: McpImplementationInfo("wire-client", "1")
        ).toValue())])
    ))
    match (subscription.payload) {
        case JsonRpcResponsePayload.Failure(error) => expect(
            error.code == JSON_RPC_METHOD_NOT_FOUND,
            "server does not advertise or implement a fake subscriptions stream"
        )
        case _ => throw IllegalStateException("unsupported subscriptions/listen was accepted")
    }
    let _ = client.close()
}

func runStdioLoopbackContract(): Unit {
    let executable = getCommandLine()[0]
    let transport = openStdioMcpTransport(McpStdioTransportConfig(
        executable,
        arguments: ["--mcp-stdio-server"],
        environment: [McpEnvironmentBinding("LD_LIBRARY_PATH", "LD_LIBRARY_PATH")],
        framing: McpFramingConfig(
            maxFrameBytes: 65536,
            requestTimeoutMillis: 5000,
            gracefulShutdownMillis: 1000
        )
    )).value().getOrThrow()
    let client = McpClient(
        transport,
        McpRequestMeta(clientInfo: McpImplementationInfo("loopback-client", "1.0.0"))
    )
    expect(client.discover().value().getOrThrow().serverInfo.getOrThrow().name == "loopback-server",
           "real stdio transport performs server/discover")
    let page = client.listTools().value().getOrThrow()
    expect(page.tools.size == 2 && page.tools[0].name == "echo" && page.tools[1].name == "slow",
           "real stdio transport performs tools/list")
    let result = completeResult(client.callTool(
        "echo",
        objectValue([ValueField("value", textValue("over-stdio"))])
    ).value().getOrThrow())
    expect(
        requiredText(result.structuredContent, "value") == "over-stdio",
        "real stdio transport performs tools/call"
    )
    let slow = spawn {
        client.callTool("slow", objectValue([]), runId: "run-slow")
    }
    var waited: Int64 = 0
    while (client.activeRequestId("run-slow").isNone() && waited < 1000) {
        sleep(Duration.millisecond * 5)
        waited += 5
    }
    expect(client.cancel("run-slow").isOk(), "stdio cancellation notification is written")
    match (slow.get()) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.Cancelled,
            "real stdio cancellation wins over a late tool response"
        )
        case _ => throw IllegalStateException("cancelled stdio tool call completed normally")
    }
    expect(client.close().isOk() && transport.state() == McpLifecycleState.Stopped,
           "real stdio child is terminated and reaped")
    expect(transport.stderrSnapshot() == "", "stdio server keeps diagnostics off protocol stdout")
}

func runFixtureStdioServer(): Int64 {
    let host = MemoryMcpToolHost(
        [tool("echo"), tool("slow")],
        {name, arguments, _ =>
            if (name == "slow") { sleep(Duration.millisecond * 200) }
            Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue("loopback"))
                ])],
                structuredContent: arguments
            )))
        }
    )
    let server = StdioMcpServer(McpServer(
        McpDiscoverResult(serverInfo: McpImplementationInfo("loopback-server", "1.0.0")),
        host
    ))
    match (server.serveConsole()) {
        case Result.Ok(_) => 0
        case Result.Err(_) => 1
    }
}

func runLimitedStdioServer(): Int64 {
    let host = MemoryMcpToolHost(
        [tool("slow")],
        {_, arguments, _ =>
            sleep(Duration.millisecond * 150)
            Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue("limited"))
                ])],
                structuredContent: arguments
            )))
        }
    )
    let server = StdioMcpServer(
        McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("limited-server", "1.0.0")),
            host
        ),
        framing: McpFramingConfig(
            maxFrameBytes: 65536,
            gracefulShutdownMillis: 1000,
            maxConcurrentRequests: 2
        )
    )
    match (server.serveConsole()) {
        case Result.Ok(_) => 0
        case Result.Err(error) =>
            eprintln(error.describe())
            1
    }
}

func runIncompleteShutdownStdioServer(): Int64 {
    let host = MemoryMcpToolHost(
        [tool("slow")],
        {_, arguments, _ =>
            sleep(Duration.millisecond * 300)
            Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue("late"))
                ])],
                structuredContent: arguments
            )))
        }
    )
    let server = StdioMcpServer(
        McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("shutdown-server", "1.0.0")),
            host
        ),
        framing: McpFramingConfig(
            maxFrameBytes: 65536,
            gracefulShutdownMillis: 20,
            maxConcurrentRequests: 1
        )
    )
    match (server.serveConsole()) {
        case Result.Err(error) =>
            if (error.kind == AgentErrorKind.Timeout &&
                error.code == "mcp.stdio_shutdown_incomplete" &&
                error.field("active_requests") == Some("1") &&
                server.state() == McpLifecycleState.Stopping &&
                host.cancellations() == ["41"]) {
                eprintln(error.code + ":Stopping:1")
                0
            } else {
                eprintln(error.describe())
                2
            }
        case Result.Ok(_) =>
            eprintln("stdio shutdown unexpectedly completed")
            3
    }
}

func runHttpLoopbackContract(): Unit {
    let secretEnvironment = "MCP_HTTP_CONTRACT_TOKEN"
    setVariable(secretEnvironment, "contract-secret")
    let slowStarted = AtomicBool(false)
    let host = MemoryMcpToolHost(
        [
            tool("echo"),
            tool("explode"),
            tool("slow"),
            httpHeaderTool(),
            invalidHttpHeaderTool(),
            tool("天气")
        ],
        {name, arguments, _ =>
            if (name == "explode") {
                throw IllegalStateException("fixture loses the response after dispatch")
            }
            if (name == "slow") {
                slowStarted.store(true)
                sleep(Duration.millisecond * 200)
            }
            Result.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [objectValue([
                    ValueField("type", textValue("text")),
                    ValueField("text", textValue("loopback-http"))
                ])],
                structuredContent: arguments
            )))
        }
    )
    let server = match (openStreamableHttpMcpServer(
        McpStreamableHttpServerConfig(
            port: 0,
            bearerTokenEnvironment: secretEnvironment,
            originAllowlist: ["http://127.0.0.1"],
            framing: McpFramingConfig(
                maxFrameBytes: 65536,
                requestTimeoutMillis: 5000,
                gracefulShutdownMillis: 1000
            )
        ),
        McpServer(
            McpDiscoverResult(serverInfo: McpImplementationInfo("http-loopback-server", "1.0.0")),
            host
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "failed to open HTTP fixture: " + error.describe()
        )
    }
    let serving = spawn { server.serve() }
    var waited: Int64 = 0
    while (server.state() != McpLifecycleState.Ready && waited < 3000) {
        sleep(Duration.millisecond * 5)
        waited += 5
    }
    expect(server.state() == McpLifecycleState.Ready && server.port() > 0,
           "loopback Streamable HTTP server binds an ephemeral port")
    let endpoint = "http://127.0.0.1:" + server.port().toString() + "/mcp"
    let meta = McpRequestMeta(clientInfo: McpImplementationInfo("http-loopback-client", "1.0.0"))

    let mismatch = rawMcpHttpPost(
        endpoint,
        "contract-secret",
        "http://127.0.0.1",
        MCP_PROTOCOL_VERSION,
        "wrong/method",
        "",
        encodeJsonRpc(JsonRpcEnvelope.Request(JsonRpcRequest(
            jsonRpcNumberId(700),
            "ping",
            params: objectValue([ValueField("_meta", meta.toValue())])
        )))
    )
    expectHttpError(mismatch, 400, MCP_HEADER_MISMATCH,
                    "header/body mismatch maps to HTTP 400 and HeaderMismatch")

    let futureMeta = objectValue([
        ValueField(MCP_META_PROTOCOL_VERSION, textValue("2099-01-01")),
        ValueField(MCP_META_CLIENT_INFO, McpImplementationInfo("future-client", "1").toValue()),
        ValueField(MCP_META_CLIENT_CAPABILITIES, objectValue([]))
    ])
    let unsupported = rawMcpHttpPost(
        endpoint,
        "contract-secret",
        "http://127.0.0.1",
        "2099-01-01",
        "ping",
        "",
        encodeJsonRpc(JsonRpcEnvelope.Request(JsonRpcRequest(
            jsonRpcNumberId(701),
            "ping",
            params: objectValue([ValueField("_meta", futureMeta)])
        )))
    )
    expectHttpError(unsupported, 400, MCP_UNSUPPORTED_PROTOCOL_VERSION,
                    "unsupported version maps to HTTP 400 and UnsupportedProtocolVersion")

    let unknown = rawMcpHttpPost(
        endpoint,
        "contract-secret",
        "http://127.0.0.1",
        MCP_PROTOCOL_VERSION,
        "unknown/method",
        "",
        encodeJsonRpc(JsonRpcEnvelope.Request(JsonRpcRequest(
            jsonRpcNumberId(702),
            "unknown/method",
            params: objectValue([ValueField("_meta", meta.toValue())])
        )))
    )
    expectHttpError(unknown, 404, JSON_RPC_METHOD_NOT_FOUND,
                    "unknown method maps to HTTP 404 and JSON-RPC MethodNotFound")

    let jsonTransport = openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
        endpoint,
        bearerTokenEnvironment: secretEnvironment,
        origin: "http://127.0.0.1"
    )).value().getOrThrow()
    let jsonClient = McpClient(jsonTransport, meta)
    expect(
        jsonClient.discover().value().getOrThrow().serverInfo.getOrThrow().name == "http-loopback-server",
        "Streamable HTTP performs POST JSON server/discover"
    )
    expect(jsonClient.close().isOk(), "JSON HTTP client closes local transport resources")

    setVariable(secretEnvironment, "wrong-secret")
    let denied = McpClient(
        openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            endpoint,
            bearerTokenEnvironment: secretEnvironment,
            origin: "http://127.0.0.1"
        )).value().getOrThrow(),
        meta
    )
    match (denied.discover()) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.Authentication && error.field("http_status") == Some("401"),
            "Streamable HTTP bearer validation fails closed"
        )
        case _ => throw IllegalStateException("invalid HTTP bearer token was accepted")
    }
    let _ = denied.close()
    setVariable(secretEnvironment, "contract-secret")

    let badOrigin = McpClient(
        openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            endpoint,
            bearerTokenEnvironment: secretEnvironment,
            origin: "http://localhost"
        )).value().getOrThrow(),
        meta
    )
    match (badOrigin.discover()) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.PermissionDenied && error.field("http_status") == Some("403"),
            "Streamable HTTP Origin allowlist uses exact matching"
        )
        case _ => throw IllegalStateException("unlisted HTTP Origin was accepted")
    }
    let _ = badOrigin.close()

    let sseTransport = openStreamableHttpMcpTransport(McpStreamableHttpClientConfig(
        endpoint,
        bearerTokenEnvironment: secretEnvironment,
        origin: "http://127.0.0.1",
        preferSse: true,
        framing: McpFramingConfig(
            maxFrameBytes: 65536,
            requestTimeoutMillis: 5000,
            gracefulShutdownMillis: 1000
        )
    )).value().getOrThrow()
    let sseClient = McpClient(sseTransport, meta)
    let page = match (sseClient.listTools()) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "SSE tools/list failed: " + error.code + ": " + error.message
        )
    }
    expect(
        page.tools.size == 5 && containsTool(page.tools, "echo") &&
        containsTool(page.tools, "routed") && containsTool(page.tools, "天气") &&
        !containsTool(page.tools, "invalid-header"),
        "Streamable HTTP parses SSE and excludes malformed x-mcp-header tools")
    let result = completeResult(sseClient.callTool(
        "echo",
        objectValue([ValueField("value", textValue("over-http"))])
    ).value().getOrThrow())
    expect(requiredText(result.structuredContent, "value") == "over-http",
           "Streamable HTTP preserves tools/call structuredContent")
    let routed = completeResult(sseClient.callTool(
        "routed",
        objectValue([
            ValueField("region", textValue("中国")),
            ValueField("options", objectValue([
                ValueField("trusted", boolValue(true))
            ]))
        ])
    ).value().getOrThrow())
    expect(
        requiredText(routed.structuredContent, "region") == "中国",
        "Streamable HTTP extracts nested x-mcp-header values and base64-encodes UTF-8"
    )
    expect(
        completeResult(sseClient.callTool("天气", objectValue([])).value().getOrThrow()).content.size == 1,
        "Streamable HTTP base64-encodes and validates a non-ASCII Mcp-Name"
    )
    match (sseClient.callTool("explode", objectValue([]))) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.Provider &&
            error.code == "mcp.remote_protocol_error" &&
            error.message == "fixture loses the response after dispatch",
            "SSE tools/call emits a terminal JSON-RPC failure when host execution throws"
        )
        case _ => throw IllegalStateException("SSE tools/call host failure was accepted")
    }

    let slow = spawn { sseClient.callTool("slow", objectValue([]), runId: "http-slow") }
    waited = 0
    while (sseClient.activeRequestId("http-slow").isNone() && waited < 1000) {
        sleep(Duration.millisecond * 5)
        waited += 5
    }
    let slowRequestId = sseClient.activeRequestId("http-slow").getOrThrow()
    waited = 0
    while (!slowStarted.load() && waited < 1000) {
        sleep(Duration.millisecond * 5)
        waited += 5
    }
    expect(slowStarted.load(), "HTTP cancellation fixture reached host execution")
    expect(sseClient.cancel("http-slow").isOk(),
           "HTTP cancellation posts notifications/cancelled and closes the active request")
    match (slow.get()) {
        case Result.Err(error) => expect(
            error.kind == AgentErrorKind.Cancelled,
            "cancelled Streamable HTTP tool call cannot win with a late response"
        )
        case _ => throw IllegalStateException("cancelled HTTP tool call completed normally")
    }
    expect(host.cancellations() == [slowRequestId.display()],
           "HTTP cancellation reaches the remote host with the active request identity")
    expect(sseClient.close().isOk(), "SSE HTTP client closes local transport resources")
    expect(server.close().isOk(), "loopback Streamable HTTP server closes gracefully")
    match (serving.get()) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException("HTTP server failed: " + error.describe())
    }
}

func tool(name: String): McpTool {
    McpTool(
        name,
        "fixture " + name,
        objectValue([
            ValueField("type", textValue("object"))
        ])
    )
}

func httpHeaderTool(): McpTool {
    McpTool(
        "routed",
        "fixture with routable parameters",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                ValueField("region", objectValue([
                    ValueField("type", textValue("string")),
                    ValueField("x-mcp-header", textValue("Region"))
                ])),
                ValueField("options", objectValue([
                    ValueField("type", textValue("object")),
                    ValueField("properties", objectValue([
                        ValueField("trusted", objectValue([
                            ValueField("type", textValue("boolean")),
                            ValueField("x-mcp-header", textValue("Trusted"))
                        ]))
                    ]))
                ]))
            ])),
            ValueField("required", listValue([textValue("region")]))
        ])
    )
}

func invalidHttpHeaderTool(): McpTool {
    McpTool(
        "invalid-header",
        "must be excluded over HTTP",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                ValueField("ratio", objectValue([
                    ValueField("type", textValue("number")),
                    ValueField("x-mcp-header", textValue("Ratio"))
                ]))
            ]))
        ])
    )
}

func containsTool(tools: Array<McpTool>, name: String): Bool {
    for (tool in tools where tool.name == name) { return true }
    false
}

func rawMcpHttpPost(
    url: String,
    token: String,
    origin: String,
    protocolVersion: String,
    method: String,
    name: String,
    body: String
): RawMcpHttpResponse {
    let client = ClientBuilder().autoRedirect(false).logger(NoopLogger()).build()
    let builder = HttpRequestBuilder()
        .url(url)
        .post()
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Authorization", "Bearer " + token)
        .header("Origin", origin)
        .header(MCP_HEADER_PROTOCOL_VERSION, protocolVersion)
        .header(MCP_HEADER_METHOD, method)
        .body(body)
    if (name != "") { builder.header(MCP_HEADER_NAME, name) }
    let response = client.send(builder.build())
    try {
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = response.body.read(buffer)
            if (count <= 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        RawMcpHttpResponse(response.status, String.fromUtf8(output.toArray()))
    } finally {
        try { response.close() } catch (_: Exception) {}
        try { client.close() } catch (_: Exception) {}
    }
}

func expectHttpError(
    response: RawMcpHttpResponse,
    status: UInt16,
    code: Int64,
    message: String
): Unit {
    let envelope = decodeJsonRpc(response.body).value().getOrThrow()
    match (envelope) {
        case JsonRpcEnvelope.Response(value) => match (value.payload) {
            case JsonRpcResponsePayload.Failure(error) => expect(
                response.status == status && error.code == code,
                message
            )
            case _ => throw IllegalStateException("HTTP error body was a success response")
        }
        case _ => throw IllegalStateException("HTTP error body was not a JSON-RPC response")
    }
}

func completeResult(outcome: McpCallToolOutcome): McpCallToolResult {
    match (outcome) {
        case McpCallToolOutcome.Complete(value) => value
        case McpCallToolOutcome.InputRequired(_) => throw IllegalStateException(
            "expected a complete MCP tool result"
        )
        case McpCallToolOutcome.Task(_) => throw IllegalStateException(
            "expected an immediate MCP tool result, got a task"
        )
        case McpCallToolOutcome.Extension(_, _) => throw IllegalStateException(
            "expected a standard complete MCP tool result"
        )
    }
}

func requiredText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

func rejects(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}
