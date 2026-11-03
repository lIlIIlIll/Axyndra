package mcp4cj

import jsonrpc4cj.*
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func awaitHttpExchangeFlag(flag: AtomicBool): Unit {
    let deadline = MonoTime.now() + Duration.millisecond * 3000
    while (!flag.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
    if (!flag.load()) { throw IllegalStateException("HTTP exchange test did not reach its phase") }
}

func exchangeTestRequest(method!: String = MCP_METHOD_DISCOVER): JsonRpcRequest {
    JsonRpcRequest(jsonRpcNumberId(7), method, params: withMcpRequestMeta(
        if (method == MCP_METHOD_TOOLS_CALL) { jsonObject([
            JsonObjectEntry("name", jsonString("echo")), JsonObjectEntry("arguments", jsonObject([]))
        ]) } else { jsonObject([]) }, McpRequestMeta()))
}

func expectHttpExchangeError<T>(result: McpResult<T>, code: String): Unit {
    match (result) {
        case McpResult.Err(error) =>
            @Expect(error.code, code)
            @Expect(error.retrySafe, false)
            @Expect(error.message.indexOf("private-http-fixture").isNone(), true)
        case McpResult.Ok(_) => @Fail("HTTP exchange unexpectedly succeeded: " + code)
    }
}

class RecordingRealMcpHttpPort <: McpHttpExchangePort {
    private let delegate = StdXMcpHttpExchangePort("")
    private let lock = Mutex()
    private let observed = ArrayList<McpHttpExchangeRequest>()
    public func prepare(request: McpHttpExchangeRequest): McpHttpExchange {
        lock.lock(); try { observed.add(request) } finally { lock.unlock() }
        // The returned array must not mutate the frozen request handed to StdX.
        let exported = request.headers
        if (!exported.isEmpty()) { exported[0] = McpHttpHeader("X-Caller-Mutation", "bad") }
        delegate.prepare(request)
    }
    func requests(): Array<McpHttpExchangeRequest> {
        lock.lock(); try { observed.toArray() } finally { lock.unlock() }
    }
}

class ControlledMcpHttpBody <: InputStream {
    let entered = AtomicBool(false)
    let closed = AtomicBool(false)
    private let mode: String
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    init(mode: String) {
        this.mode = mode
        bytes = if (mode == "oversize") { Array<Byte>(2048, repeat: 120) }
            else if (mode == "subscription-fail") {
                ("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{" +
                    "\"notifications\":{\"toolsListChanged\":true},\"_meta\":{" +
                    "\"io.modelcontextprotocol/subscriptionId\":7}}}\n\n").toArray()
            }
            else { "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}".toArray() }
    }
    public func read(buffer: Array<Byte>): Int64 {
        entered.store(true)
        if (mode == "body-block") {
            while (!closed.load()) { sleep(Duration.millisecond * 5) }
            throw IllegalStateException("private-http-fixture body cancelled")
        }
        if (mode == "body-fail") { throw IllegalStateException("private-http-fixture body lost") }
        if (mode == "subscription-fail" && offset >= bytes.size) {
            throw IllegalStateException("private-http-fixture subscription body lost")
        }
        if (closed.load() || offset >= bytes.size) { return 0 }
        let count = min(buffer.size, bytes.size - offset)
        for (index in 0..count) { buffer[index] = bytes[offset + index] }
        offset += count
        count
    }
    func close(): Unit { closed.store(true) }
}

class ControlledMcpHttpResponse <: McpHttpExchangeResponse {
    private let mode: String
    let input: ControlledMcpHttpBody
    let closed = AtomicBool(false)
    init(mode: String) { this.mode = mode; input = ControlledMcpHttpBody(mode) }
    public prop status: Int64 { get() { 200 } }
    public prop contentType: String {
        get() { if (mode == "subscription-fail") { "text/event-stream" } else { "application/json" } }
    }
    public prop bodySize: ?Int64 { get() { None } }
    public prop body: InputStream { get() { input } }
    public func close(): Unit { closed.store(true); input.close() }
}

class ControlledMcpHttpExchange <: McpHttpExchange {
    let mode: String
    let entered = AtomicBool(false)
    let closed = AtomicBool(false)
    let response: ControlledMcpHttpResponse
    init(mode: String) { this.mode = mode; response = ControlledMcpHttpResponse(mode) }
    public func send(): McpHttpExchangeResponse {
        entered.store(true)
        if (mode == "headers-block" || mode == "late-headers") {
            while (!closed.load()) { sleep(Duration.millisecond * 5) }
            if (mode == "late-headers") { return response }
            throw IllegalStateException("private-http-fixture headers cancelled")
        }
        if (closed.load()) { throw IllegalStateException("private-http-fixture closed before send") }
        response
    }
    public func close(): Unit {
        closed.store(true)
        if (mode != "late-headers") { response.close() }
    }
}

class ControlledMcpHttpPort <: McpHttpExchangePort {
    let entered = AtomicBool(false)
    let releasePrepare = AtomicBool(false)
    let exchange: ControlledMcpHttpExchange
    private let pausePrepare: Bool
    init(mode: String, pausePrepare!: Bool = false) {
        exchange = ControlledMcpHttpExchange(mode); this.pausePrepare = pausePrepare
    }
    public func prepare(request: McpHttpExchangeRequest): McpHttpExchange {
        let _ = request
        entered.store(true)
        if (pausePrepare) {
            while (!releasePrepare.load()) { sleep(Duration.millisecond * 5) }
        }
        exchange
    }
}

func injectedHttpTransport(port: McpHttpExchangePort): StreamableHttpMcpTransport {
    StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
        "http://127.0.0.1:1/mcp", framing: McpFramingConfig(maxFrameBytes: 1024)
    ), port)
}

@Test
class McpInjectedHttpTests {
    @TestCase
    func injectedStdXPreservesRealProtocolHeadersAuthenticationAndJsonCalls() {
        let called = AtomicBool(false)
        let host = MemoryMcpToolHost([
            McpTool("echo", "echo", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ], { _: String, arguments: JsonNode, _: McpToolCallContinuation =>
            called.store(true)
            McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult([
                jsonObject([JsonObjectEntry("type", jsonString("text")),
                    JsonObjectEntry("text", jsonString(mcpText(arguments, "query")))])
            ])))
        })
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0, bearerToken: "local-test-token"),
            McpServerBuilder().toolProvider(host).build()
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        let ready = MonoTime.now() + Duration.millisecond * 3000
        while (server.state() != McpLifecycleState.Ready && MonoTime.now() < ready) {
            sleep(Duration.millisecond * 5)
        }
        let port = RecordingRealMcpHttpPort()
        let transport = StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp",
            bearerToken: "local-test-token", headers: [McpHttpHeader("X-Fixture", "preserved")]
        ), port)
        let client = McpClient(transport, McpRequestMeta())
        try {
            @Expect(client.listTools().isOk(), true)
            match (client.callTool("echo", jsonObject([JsonObjectEntry("query", jsonString("雪 &+"))]))) {
                case McpResult.Ok(McpCallToolOutcome.Complete(value)) =>
                    @Expect(value.isError, false)
                    @Expect(value.content.size, 1)
                    @Expect(value.content[0].field("text").getOrThrow().text, "雪 &+")
                case _ => @Fail("real injected HTTP call lost the Unicode result")
            }
            @Expect(called.load(), true)
            let requests = port.requests()
            @Expect(requests.size, 2)
            var hasProtocol = false
            var hasClient = false
            var hasName = false
            var hasCustom = false
            var hasContentType = false
            for (header in requests[1].headers) {
                if (header.name == MCP_HEADER_PROTOCOL_VERSION) { hasProtocol = header.value == MCP_PROTOCOL_VERSION }
                if (header.name == MCP_HEADER_CLIENT_INSTANCE_ID) { hasClient = header.value != "" }
                if (header.name == MCP_HEADER_NAME) { hasName = header.value == encodeMcpHeader("echo") }
                if (header.name == "X-Fixture") { hasCustom = header.value == "preserved" }
                if (header.name == "Content-Type") { hasContentType = header.value == "application/json" }
            }
            @Expect(hasProtocol && hasClient && hasName && hasCustom && hasContentType, true)
            @Expect(requests[1].method, "POST")
            @Expect(requests[1].readTimeoutMillis.isSome(), true)
        } finally {
            let _ = client.close()
            let _ = server.close()
            let _ = serving.get()
        }
    }

    @TestCase
    func injectedStdXPreservesRealSseSubscriptionAndCancellation() {
        let notifications = HoldingNotificationProvider()
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0),
            McpServerBuilder().notificationProvider(notifications).build()
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        let ready = MonoTime.now() + Duration.millisecond * 3000
        while (server.state() != McpLifecycleState.Ready && MonoTime.now() < ready) { sleep(Duration.millisecond * 5) }
        let port = RecordingRealMcpHttpPort()
        let client = McpClient(StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp", preferSse: true
        ), port), McpRequestMeta())
        try {
            let handle = match (client.listen(McpSubscriptionFilter(toolsListChanged: true))) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => throw error
            }
            @Expect(handle.acknowledged().toolsListChanged, true)
            match (handle.next()) {
                case McpResult.Ok(Some(value)) => @Expect(value.method, MCP_NOTIFICATION_TOOLS_LIST_CHANGED)
                case _ => @Fail("injected HTTP subscription lost its streamed notification")
            }
            @Expect(port.requests()[0].readTimeoutMillis.isNone(), true)
            @Expect(handle.close().isOk(), true)
            let deadline = MonoTime.now() + Duration.millisecond * 2000
            while (notifications.closedSources() != 1 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(notifications.closedSources(), 1)
            @Expect(port.requests().size, 2)
        } finally {
            let _ = client.close()
            let _ = server.close()
            let _ = serving.get()
        }
    }

    @TestCase
    func injectedStdXCloseInterruptsARealInFlightHeaderWait() {
        let operation = HoldingToolOperation()
        let host = MemoryMcpToolHost([
            McpTool("slow", "slow", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ], { name, arguments, continuation => operation.execute(name, arguments, continuation) })
        let server = match (openStreamableHttpMcpServer(
            McpStreamableHttpServerConfig(port: 0), McpServerBuilder().toolProvider(host).build()
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => throw error
        }
        let serving = spawn { server.serve() }
        let ready = MonoTime.now() + Duration.millisecond * 3000
        while (server.state() != McpLifecycleState.Ready && MonoTime.now() < ready) { sleep(Duration.millisecond * 5) }
        let transport = StreamableHttpMcpTransport(McpStreamableHttpClientConfig(
            "http://127.0.0.1:" + server.port().toString() + "/mcp"
        ), RecordingRealMcpHttpPort())
        let client = McpClient(transport, McpRequestMeta())
        @Expect(client.listTools().isOk(), true)
        let completed = AtomicBool(false)
        let running = spawn {
            try { client.callTool("slow", jsonObject([])) }
            finally { completed.store(true) }
        }
        try {
            operation.waitUntilStarted()
            let before = MonoTime.now()
            @Expect(transport.close().isOk(), true)
            let deadline = before + Duration.millisecond * 2000
            while (!completed.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(completed.load(), true)
            if (completed.load()) { expectHttpExchangeError(running.get(), "mcp.http_request_cancelled") }
        } finally {
            operation.release()
            let _ = client.close()
            let _ = running.get()
            let _ = server.close()
            let _ = serving.get()
        }
    }

    @TestCase
    func closeWhilePreparingPreventsSendAndReleasesTheLateExchange() {
        let port = ControlledMcpHttpPort("complete", pausePrepare: true)
        let transport = injectedHttpTransport(port)
        let running = spawn { transport.request(exchangeTestRequest()) }
        try {
            awaitHttpExchangeFlag(port.entered)
            @Expect(transport.close().isOk(), true)
            port.releasePrepare.store(true)
            expectHttpExchangeError(running.get(), "mcp.http_request_cancelled")
            @Expect(port.exchange.entered.load(), false)
            @Expect(port.exchange.closed.load(), true)
        } finally {
            port.releasePrepare.store(true)
            port.exchange.close()
            let _ = transport.close()
            let _ = running.get()
        }
    }

    @TestCase
    func closeBeforeHeadersInterruptsTheExchange() {
        let port = ControlledMcpHttpPort("headers-block")
        let transport = injectedHttpTransport(port)
        let running = spawn { transport.request(exchangeTestRequest()) }
        try {
            awaitHttpExchangeFlag(port.exchange.entered)
            @Expect(transport.close().isOk(), true)
            expectHttpExchangeError(running.get(), "mcp.http_request_cancelled")
        } finally { port.exchange.close(); let _ = transport.close(); let _ = running.get() }
    }

    @TestCase
    func closeAlsoOwnsNotificationExchangesWithoutRpcIds() {
        let port = ControlledMcpHttpPort("headers-block")
        let transport = injectedHttpTransport(port)
        let running = spawn {
            transport.notify(JsonRpcNotification("fixture/notify",
                params: withMcpRequestMeta(jsonObject([]), McpRequestMeta())))
        }
        try {
            awaitHttpExchangeFlag(port.exchange.entered)
            @Expect(transport.close().isOk(), true)
            expectHttpExchangeError(running.get(), "mcp.http_request_cancelled")
        } finally { port.exchange.close(); let _ = transport.close(); let _ = running.get() }
    }

    @TestCase
    func closeDuringUnknownLengthBodyReadUnblocksItAndClosesTheResponse() {
        let port = ControlledMcpHttpPort("body-block")
        let transport = injectedHttpTransport(port)
        let running = spawn { transport.request(exchangeTestRequest()) }
        try {
            awaitHttpExchangeFlag(port.exchange.response.input.entered)
            @Expect(transport.close().isOk(), true)
            expectHttpExchangeError(running.get(), "mcp.http_request_cancelled")
            @Expect(port.exchange.response.closed.load(), true)
        } finally { port.exchange.close(); let _ = transport.close(); let _ = running.get() }
    }

    @TestCase
    func responseArrivingAfterCloseIsReleasedWithoutReadingTheBody() {
        let port = ControlledMcpHttpPort("late-headers")
        let transport = injectedHttpTransport(port)
        let running = spawn { transport.request(exchangeTestRequest()) }
        try {
            awaitHttpExchangeFlag(port.exchange.entered)
            @Expect(transport.close().isOk(), true)
            expectHttpExchangeError(running.get(), "mcp.http_request_cancelled")
            @Expect(port.exchange.response.closed.load(), true)
            @Expect(port.exchange.response.input.entered.load(), false)
        } finally { port.exchange.close(); let _ = transport.close(); let _ = running.get() }
    }

    @TestCase
    func unknownLengthBodyStillUsesTheExistingCumulativeLimit() {
        let port = ControlledMcpHttpPort("oversize")
        let transport = injectedHttpTransport(port)
        try {
            expectHttpExchangeError(transport.request(exchangeTestRequest()), "mcp.http_body_too_large")
            @Expect(port.exchange.response.closed.load(), true)
        } finally { let _ = transport.close() }
    }

    @TestCase
    func lostDispatchedToolResponseRetainsAmbiguityAndCannotRetrySafely() {
        let port = ControlledMcpHttpPort("body-fail")
        let transport = injectedHttpTransport(port)
        let _ = transport.registerTools([
            McpTool("echo", "echo", jsonObject([JsonObjectEntry("type", jsonString("object"))]))
        ])
        try {
            expectHttpExchangeError(transport.request(exchangeTestRequest(method: MCP_METHOD_TOOLS_CALL)), "mcp.http_call_response_lost")
            @Expect(port.exchange.entered.load(), true)
            @Expect(port.exchange.response.closed.load(), true)
        } finally { let _ = transport.close() }
    }

    @TestCase
    func nonCallBodyFailureDoesNotExposeInjectedCallbackDiagnostics() {
        let port = ControlledMcpHttpPort("body-fail")
        let transport = injectedHttpTransport(port)
        try {
            expectHttpExchangeError(transport.request(exchangeTestRequest()), "mcp.http_body_read_failed")
            @Expect(port.exchange.entered.load(), true)
            @Expect(port.exchange.response.closed.load(), true)
        } finally { let _ = transport.close() }
    }

    @TestCase
    func subscriptionBodyFailureRetainsItsTypedErrorWithoutPrivateDiagnostics() {
        let port = ControlledMcpHttpPort("subscription-fail")
        let transport = injectedHttpTransport(port)
        try {
            let handle = match (transport.openSubscription(JsonRpcRequest(
                jsonRpcNumberId(7), MCP_METHOD_SUBSCRIPTIONS_LISTEN,
                params: withMcpRequestMeta(McpSubscriptionFilter(toolsListChanged: true).toValue(), McpRequestMeta())
            ))) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => throw error
            }
            try {
                @Expect(handle.acknowledged().toolsListChanged, true)
                expectHttpExchangeError(handle.next(), "mcp.http_sse_read_failed")
                @Expect(port.exchange.response.input.entered.load(), true)
            } finally { let _ = handle.close() }
            awaitHttpExchangeFlag(port.exchange.response.closed)
            @Expect(port.exchange.response.closed.load(), true)
        } finally { let _ = transport.close() }
    }
}
