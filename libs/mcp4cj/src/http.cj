package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import process4cj.*
import std.collection.*
import std.io.*
import std.sync.*
import stdx.log.NoopLogger
import stdx.net.http.*

public class McpHttpHeader {
    public let name: String
    public let value: String
    public init(name: String, value: String) {
        if (!validHttpToken(name) || !validHttpValue(value)) {
            throw IllegalArgumentException("invalid MCP HTTP header")
        }
        this.name = name; this.value = value
    }
}

public class McpStreamableHttpClientConfig {
    public let url: String
    public let bearerToken: String
    public let headers: Array<McpHttpHeader>
    public let origin: String
    public let preferSse: Bool
    public let framing: McpFramingConfig
    public init(
        url: String,
        bearerToken!: String = "",
        headers!: Array<McpHttpHeader> = [],
        origin!: String = "",
        preferSse!: Bool = false,
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (!secureMcpHttpUrl(url) || !validHttpValue(bearerToken) ||
            (origin != "" && !secureMcpHttpOrigin(origin))) {
            throw IllegalArgumentException("invalid MCP Streamable HTTP client configuration")
        }
        for (header in headers where reservedMcpHeader(header.name)) {
            throw IllegalArgumentException("custom header replaces an MCP protocol header")
        }
        this.url = url; this.bearerToken = bearerToken; this.headers = headers
        this.origin = origin; this.preferSse = preferSse; this.framing = framing
    }
}

public class McpStreamableHttpServerConfig {
    public let bindHost: String
    public let port: Int64
    public let bearerToken: String
    public let originAllowlist: Array<String>
    public let maxConcurrentRequests: Int64
    public let framing: McpFramingConfig
    public init(
        bindHost!: String = "127.0.0.1",
        port!: Int64 = 0,
        bearerToken!: String = "",
        originAllowlist!: Array<String> = [],
        maxConcurrentRequests!: Int64 = 16,
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (bindHost.trimAscii() == "" || port < 0 || port > 65535 ||
            maxConcurrentRequests <= 0 || !validHttpValue(bearerToken)) {
            throw IllegalArgumentException("invalid MCP Streamable HTTP server configuration")
        }
        if (!loopbackMcpHost(bindHost) && bearerToken == "") {
            throw IllegalArgumentException("non-loopback MCP HTTP requires bearer authentication")
        }
        for (origin in originAllowlist where !secureMcpHttpOrigin(origin)) {
            throw IllegalArgumentException("invalid MCP HTTP origin allowlist")
        }
        this.bindHost = bindHost; this.port = port; this.bearerToken = bearerToken
        this.originAllowlist = originAllowlist; this.maxConcurrentRequests = maxConcurrentRequests
        this.framing = framing
    }
}

class McpHttpActiveRequest {
    let id: JsonRpcId
    let client: Client
    var response: ?HttpResponse = None
    var cancelled = false
    init(id: JsonRpcId, client: Client) { this.id = id; this.client = client }
}

// MCP 2026-07-28 transport used by the project is request-scoped and
// stateless: every message is a POST and SSE is a response representation.
public class StreamableHttpMcpTransport <: McpTransport {
    private let config: McpStreamableHttpClientConfig
    private let lifecycle = McpLifecycle()
    private let activeLock = Mutex()
    private let active = ArrayList<McpHttpActiveRequest>()
    private let toolLock = Mutex()
    private let tools = ArrayList<McpTool>()

    public init(config: McpStreamableHttpClientConfig) {
        this.config = config
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
    }
    public func kind(): McpTransportKind { McpTransportKind.StreamableHttp }
    public func state(): McpLifecycleState { lifecycle.state() }

    public func request(request: JsonRpcRequest): McpResult<JsonRpcResponse> {
        requestWithNotifications(request, {_ =>})
    }

    public func requestWithNotifications(
        request: JsonRpcRequest,
        notificationSink: (JsonRpcNotification) -> Unit
    ): McpResult<JsonRpcResponse> {
        match (post(
            JsonRpcEnvelope.Request(request), request.method, request.params, Some(request.id),
            notificationSink: notificationSink
        )) {
            case McpResult.Ok(Some(response)) => McpResult.Ok(response)
            case McpResult.Ok(None) => httpMcpFailure<JsonRpcResponse>(
                McpErrorKind.Protocol, "mcp.http_response_missing",
                "MCP HTTP request completed without a response", retrySafe: false
            )
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionHandle> {
        if (request.method != MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
            return invalidMcp<McpSubscriptionHandle>("mcp.subscription_method_invalid", "subscription request method is invalid")
        }
        let prepared = match (prepare(
            JsonRpcEnvelope.Request(request), request.method, request.params,
            preferSse: true, subscription: true
        )) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let (client, nativeRequest) = prepared
        let activeRequest = McpHttpActiveRequest(request.id, client); addActive(activeRequest)
        try {
            let response = client.send(nativeRequest)
            activeLock.lock(); try { activeRequest.response = Some(response) } finally { activeLock.unlock() }
            let contentType = (response.headers.getFirst("content-type") ?? "").toAsciiLower()
            if (Int64(response.status) < 200 || Int64(response.status) >= 300 || !contentType.startsWith("text/event-stream")) {
                let details = match (readMcpHttpBody(response.body, response.bodySize, config.framing.maxFrameBytes)) {
                    case McpResult.Ok(value) => value
                    case McpResult.Err(_) => ""
                }
                try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                removeActive(activeRequest)
                if (contentType.startsWith("application/json") && details != "") {
                    match (decodeMcpHttpSubscriptionRejection(details, request.id, config.framing.maxFrameBytes)) {
                        case McpResult.Ok(error) => return McpResult.Err(error)
                        case McpResult.Err(_) => ()
                    }
                }
                return httpMcpFailure<McpSubscriptionHandle>(
                    McpErrorKind.Protocol, "mcp.http_subscription_response_invalid",
                    "subscriptions/listen requires a successful SSE response; status=" +
                        response.status.toString() + " content-type=" + contentType + " body=" + details,
                    retrySafe: true
                )
            }
            let first = match (readMcpSseEnvelope(response.body, config.framing.maxFrameBytes)) {
                case McpResult.Ok(Some(value)) => value
                case McpResult.Ok(None) =>
                    try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                    removeActive(activeRequest)
                    return httpMcpFailure<McpSubscriptionHandle>(McpErrorKind.Transport, "mcp.http_subscription_eof", "subscription closed before acknowledgement", retrySafe: true)
                case McpResult.Err(error) =>
                    try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                    removeActive(activeRequest); return McpResult.Err(error)
            }
            let acknowledgement = match (first) {
                case JsonRpcEnvelope.Notification(value) => if (value.method == MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED) {
                    if (!notificationBelongsToSubscription(value, request.id)) {
                        try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                        removeActive(activeRequest)
                        return invalidMcp<McpSubscriptionHandle>(
                            "mcp.subscription_id_mismatch", "subscription acknowledgement omitted or changed subscriptionId"
                        )
                    }
                    match (decodeMcpSubscriptionFilter(value.params)) {
                        case McpResult.Ok(filter) => filter
                        case McpResult.Err(error) =>
                            try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                            removeActive(activeRequest); return McpResult.Err(error)
                    }
                } else {
                    try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                    removeActive(activeRequest)
                    return invalidMcp<McpSubscriptionHandle>("mcp.subscription_ack_missing", "first subscription event must be acknowledged")
                }
                case _ =>
                    try { response.close() } catch (_: Exception) {}; try { client.close() } catch (_: Exception) {}
                    removeActive(activeRequest)
                    return invalidMcp<McpSubscriptionHandle>("mcp.subscription_ack_missing", "first subscription event must be an acknowledgement notification")
            }
            McpResult.Ok(HttpMcpSubscriptionHandle(
                request.id, acknowledgement, response, client,
                config.framing.maxFrameBytes,
                { => removeActive(activeRequest) },
                { => let _ = closeHttpSubscription(request) }
            ))
        } catch (error: Exception) {
            try { client.close() } catch (_: Exception) {}; removeActive(activeRequest)
            httpMcpFailure<McpSubscriptionHandle>(McpErrorKind.Transport, "mcp.http_subscription_open_failed", error.message, retrySafe: true)
        }
    }

    public func notify(notification: JsonRpcNotification): McpResult<Unit> {
        match (post(JsonRpcEnvelope.Notification(notification), notification.method, notification.params, None)) {
            case McpResult.Ok(_) => McpResult.Ok(())
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    private func closeHttpSubscription(request: JsonRpcRequest): McpResult<Unit> {
        notify(JsonRpcNotification(MCP_METHOD_CANCELLED, params: jsonObject([
            JsonObjectEntry("requestId", requestIdValue(request.id)),
            JsonObjectEntry("reason", jsonString("subscription closed by caller")),
            JsonObjectEntry("_meta", mcpObject(request.params, "_meta"))
        ])))
    }

    public func cancel(
        requestId: JsonRpcId,
        reason: String,
        meta: McpRequestMeta
    ): McpResult<Unit> {
        let matches = ArrayList<McpHttpActiveRequest>()
        activeLock.lock(); try {
            for (item in active where sameJsonRpcId(item.id, requestId)) {
                item.cancelled = true; matches.add(item)
            }
        } finally { activeLock.unlock() }
        let notified = notify(mcpCancellationNotification(requestId, reason, meta: meta))
        for (item in matches) { closeHttpActive(item) }
        notified
    }

    public func registerTools(values: Array<McpTool>): McpResult<Unit> {
        toolLock.lock()
        try {
            for (tool in values) {
                var found = false
                for (index in 0..tools.size where tools[index].name == tool.name) {
                    tools[index] = tool; found = true; break
                }
                if (!found) { tools.add(tool) }
            }
            McpResult.Ok(())
        } finally { toolLock.unlock() }
    }

    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        let requests = activeSnapshot()
        for (item in requests) { activeLock.lock(); try { item.cancelled = true } finally { activeLock.unlock() }; closeHttpActive(item) }
        let _ = lifecycle.transition(McpLifecycleState.Stopped)
        McpResult.Ok(())
    }

    private func post(
        envelope: JsonRpcEnvelope,
        operation: String,
        params: JsonNode,
        expectedId: ?JsonRpcId,
        notificationSink!: (JsonRpcNotification) -> Unit = { _ => }
    ): McpResult<?JsonRpcResponse> {
        if (state() != McpLifecycleState.Ready) {
            return httpMcpFailure<?JsonRpcResponse>(McpErrorKind.Lifecycle, "mcp.http_not_ready", "MCP HTTP transport is not ready", retrySafe: true)
        }
        let prepared = match (prepare(envelope, operation, params)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let (client, request) = prepared
        let activeRequest: ?McpHttpActiveRequest = match (expectedId) {
            case Some(id) => let item = McpHttpActiveRequest(id, client); addActive(item); Some(item)
            case None => None
        }
        try {
            let response = client.send(request)
            match (activeRequest) {
                case Some(item) => activeLock.lock(); try { item.response = Some(response) } finally { activeLock.unlock() }
                case None => ()
            }
            let result = try { decodeResponse(
                response, operation, expectedId, notificationSink: notificationSink
            ) }
                finally { try { response.close() } catch (_: Exception) {} }
            match (activeRequest) {
                case Some(item) => if (isHttpCancelled(item)) { cancelledHttpMcp<?JsonRpcResponse>() } else { result }
                case None => result
            }
        } catch (error: Exception) {
            match (activeRequest) {
                case Some(item) => if (isHttpCancelled(item)) { return cancelledHttpMcp<?JsonRpcResponse>() }
                case None => ()
            }
            ambiguousHttpMcp<?JsonRpcResponse>(operation, error.message)
        } finally {
            try { client.close() } catch (_: Exception) {}
            match (activeRequest) { case Some(item) => removeActive(item); case None => () }
        }
    }

    private func prepare(
        envelope: JsonRpcEnvelope,
        operation: String,
        params: JsonNode,
        preferSse!: Bool = config.preferSse,
        subscription!: Bool = false
    ): McpResult<(Client, HttpRequest)> {
        try {
            let timeout = Duration.millisecond * config.framing.requestTimeoutMillis
            let readTimeout = if (subscription) { Duration.Max } else { timeout }
            let client = ClientBuilder().autoRedirect(false).readTimeout(readTimeout).writeTimeout(timeout).logger(NoopLogger()).build()
            let protocolVersion = mcpProtocolVersion(params)
            if (protocolVersion == "") { try { client.close() } catch (_: Exception) {}; return httpMcpFailure<(Client, HttpRequest)>(McpErrorKind.Protocol, "mcp.http_protocol_metadata_missing", "request omitted protocolVersion", retrySafe: true) }
            let builder = HttpRequestBuilder()
                .url(config.url).post().readTimeout(readTimeout).writeTimeout(timeout)
                .header("Content-Type", "application/json")
                .header("Accept", if (preferSse) { "text/event-stream, application/json" } else { "application/json, text/event-stream" })
                .header(MCP_HEADER_PROTOCOL_VERSION, protocolVersion)
                .header(MCP_HEADER_METHOD, operation)
                .body(encodeJsonRpc(envelope))
            let name = mcpStandardName(operation, params)
            if (mcpMethodRequiresName(operation)) {
                if (name == "") {
                    try { client.close() } catch (_: Exception) {}
                    return httpMcpFailure<(Client, HttpRequest)>(
                        McpErrorKind.Protocol, "mcp.http_name_missing",
                        "request omitted the value required for Mcp-Name", retrySafe: true
                    )
                }
                builder.header(MCP_HEADER_NAME, encodeMcpHeader(name))
            }
            if (operation == MCP_METHOD_TOOLS_CALL) {
                let schema = toolSchema(name)
                if (schema.unifiedKind == UnifiedJsonKind.Null) {
                    try { client.close() } catch (_: Exception) {}
                    return httpMcpFailure<(Client, HttpRequest)>(
                        McpErrorKind.Lifecycle, "mcp.http_tool_schema_missing",
                        "call listTools or toolDirectory before invoking a Streamable HTTP tool",
                        retrySafe: true
                    )
                }
                match (projectMcpParameterHeaders(schema, mcpObject(params, "arguments"))) {
                    case McpResult.Ok(headers) => for (header in headers) {
                        builder.header(header.name, header.value)
                    }
                    case McpResult.Err(error) =>
                        try { client.close() } catch (_: Exception) {}
                        return McpResult.Err(error)
                }
            }
            if (config.origin != "") { builder.header("Origin", config.origin) }
            if (config.bearerToken != "") { builder.header("Authorization", "Bearer " + config.bearerToken) }
            for (header in config.headers) { builder.header(header.name, header.value) }
            McpResult.Ok((client, builder.build()))
        } catch (error: Exception) {
            httpMcpFailure<(Client, HttpRequest)>(McpErrorKind.Transport, "mcp.http_request_prepare_failed", error.message, retryable: true, retrySafe: true)
        }
    }

    private func decodeResponse(
        response: HttpResponse,
        operation: String,
        expectedId: ?JsonRpcId,
        notificationSink!: (JsonRpcNotification) -> Unit = { _ => }
    ): McpResult<?JsonRpcResponse> {
        let status = Int64(response.status)
        let successful = status >= 200 && status < 300
        match (expectedId) {
            case None => if (successful) {
                McpResult.Ok(None)
            } else {
                httpStatusMcpFailure<?JsonRpcResponse>(operation, status)
            }
            case Some(id) =>
                let contentType = (response.headers.getFirst("content-type") ?? "").toAsciiLower()
                let envelope = if (contentType.startsWith("text/event-stream")) {
                    match (readMcpSseResponse(
                        response.body, id, config.framing.maxFrameBytes,
                        notificationSink: notificationSink
                    )) {
                        case McpResult.Ok(value) => JsonRpcEnvelope.Response(value)
                        case McpResult.Err(error) => return if (!successful) {
                            httpStatusMcpFailure<?JsonRpcResponse>(operation, status)
                        } else if (operation == MCP_METHOD_TOOLS_CALL) {
                            ambiguousHttpMcp<?JsonRpcResponse>(operation, error.message)
                        } else { McpResult.Err(error) }
                    }
                } else if (contentType.startsWith("application/json")) {
                    let body = match (readMcpHttpBody(response.body, response.bodySize, config.framing.maxFrameBytes)) {
                        case McpResult.Ok(value) => value
                        case McpResult.Err(error) => return if (!successful) {
                            httpStatusMcpFailure<?JsonRpcResponse>(operation, status)
                        } else if (operation == MCP_METHOD_TOOLS_CALL) {
                            ambiguousHttpMcp<?JsonRpcResponse>(operation, error.message)
                        } else { McpResult.Err(error) }
                    }
                    match (decodeJsonRpc(body, maxBytes: config.framing.maxFrameBytes)) {
                        case JsonRpcResult.Ok(value) => value
                        case JsonRpcResult.Err(error) => return if (successful) {
                            invalidMcp<?JsonRpcResponse>(error.code, error.message)
                        } else { httpStatusMcpFailure<?JsonRpcResponse>(operation, status) }
                    }
                } else { return if (successful) {
                    httpMcpFailure<?JsonRpcResponse>(McpErrorKind.Protocol, "mcp.http_content_type_invalid", "response must be JSON or SSE", retrySafe: false)
                } else { httpStatusMcpFailure<?JsonRpcResponse>(operation, status) } }
                if (!successful) {
                    return httpStatusMcpFailure<?JsonRpcResponse>(operation, status)
                }
                match (envelope) {
                    case JsonRpcEnvelope.Response(value) => if (sameJsonRpcId(value.id, id)) { McpResult.Ok(Some(value)) } else { invalidMcp<?JsonRpcResponse>("mcp.http_response_id_mismatch", "response id mismatch") }
                    case _ => invalidMcp<?JsonRpcResponse>("mcp.http_response_envelope_invalid", "response envelope is not JSON-RPC response")
                }
        }
    }

    private func addActive(item: McpHttpActiveRequest): Unit { activeLock.lock(); try { active.add(item) } finally { activeLock.unlock() } }
    private func removeActive(item: McpHttpActiveRequest): Unit { activeLock.lock(); try { for (index in 0..active.size where sameJsonRpcId(active[index].id, item.id)) { active.remove(at: index); return } } finally { activeLock.unlock() } }
    private func activeSnapshot(): Array<McpHttpActiveRequest> { activeLock.lock(); try { active.toArray() } finally { activeLock.unlock() } }
    private func isHttpCancelled(item: McpHttpActiveRequest): Bool { activeLock.lock(); try { item.cancelled } finally { activeLock.unlock() } }
    private func closeHttpActive(item: McpHttpActiveRequest): Unit { match (item.response) { case Some(response) => try { response.close() } catch (_: Exception) {}; case None => () }; try { item.client.close() } catch (_: Exception) {} }
    private func toolSchema(name: String): JsonNode {
        toolLock.lock(); try {
            for (tool in tools where tool.name == name) { return tool.inputSchema }
            jsonNull()
        } finally { toolLock.unlock() }
    }
}

class HttpMcpSubscriptionHandle <: McpSubscriptionHandle {
    private let id: JsonRpcId
    private let accepted: McpSubscriptionFilter
    private let response: HttpResponse
    private let client: Client
    private let maxEventBytes: Int64
    private let onDone: () -> Unit
    private let closeAction: () -> Unit
    private let lock = Mutex()
    private let queued = ArrayList<JsonRpcNotification>()
    private var stopped = false
    private var failure: ?McpError = None
    private var reader: ?Future<Unit> = None
    private var closeRequested = false
    private var resourcesClosed = false

    init(
        id: JsonRpcId, accepted: McpSubscriptionFilter,
        response: HttpResponse, client: Client, maxEventBytes: Int64,
        onDone: () -> Unit, closeAction: () -> Unit
    ) {
        this.id = id; this.accepted = accepted; this.response = response
        this.client = client; this.maxEventBytes = maxEventBytes; this.onDone = onDone
        this.closeAction = closeAction
        reader = Some(spawn { pump() })
    }

    public func subscriptionId(): JsonRpcId { id }
    public func acknowledged(): McpSubscriptionFilter { accepted }
    public func next(): McpResult<?JsonRpcNotification> {
        while (true) {
            lock.lock()
            try {
                if (!queued.isEmpty()) {
                    let value = queued[0]; queued.remove(at: 0); return McpResult.Ok(Some(value))
                }
                match (failure) { case Some(error) => return McpResult.Err(error); case None => () }
                if (stopped) { return McpResult.Ok(None) }
            } finally { lock.unlock() }
            sleep(Duration.millisecond * 5)
        }
        McpResult.Ok(None)
    }
    public func close(): McpResult<Unit> {
        var notify = false
        lock.lock(); try {
            if (!closeRequested) { closeRequested = true; notify = true }
        } finally { lock.unlock() }
        if (notify) { closeAction() }
        finish(None)
        McpResult.Ok(())
    }

    private func pump(): Unit {
        while (true) {
            let envelope = match (readMcpSseEnvelope(response.body, maxEventBytes)) {
                case McpResult.Ok(Some(value)) => value
                case McpResult.Ok(None) => finish(None); return
                case McpResult.Err(error) => finish(Some(error)); return
            }
            match (envelope) {
                case JsonRpcEnvelope.Notification(notification) =>
                    if (!notificationBelongsToSubscription(notification, id)) {
                        finish(Some(McpError(
                            McpErrorKind.Protocol, "mcp.subscription_id_mismatch",
                            "subscription notification omitted or changed subscriptionId"
                        ))); return
                    }
                    var overflow = false
                    lock.lock(); try {
                        if (!stopped) {
                            if (queued.size >= MCP_SUBSCRIPTION_QUEUE_LIMIT) {
                                queued.clear()
                                overflow = true
                            } else { queued.add(notification) }
                        }
                    } finally { lock.unlock() }
                    if (overflow) {
                        finish(Some(McpError(
                            McpErrorKind.Protocol, "mcp.subscription_queue_overflow",
                            "MCP subscription consumer did not keep up with notifications"
                        )))
                        return
                    }
                case JsonRpcEnvelope.Response(value) =>
                    if (sameJsonRpcId(value.id, id)) {
                        match (value.payload) {
                            case JsonRpcResponsePayload.Success(_) => finish(None)
                            case JsonRpcResponsePayload.Failure(error) => match (remoteMcpError<Unit>(error)) {
                                case McpResult.Err(value) => finish(Some(value))
                                case McpResult.Ok(_) => finish(Some(McpError(
                                    McpErrorKind.Protocol, "mcp.http_subscription_terminal_invalid",
                                    "subscription terminal response did not contain an error"
                                )))
                            }
                        }
                        return
                    }
                    finish(Some(McpError(McpErrorKind.Protocol, "mcp.subscription_response_id_mismatch", "subscription close response id mismatch"))); return
                case JsonRpcEnvelope.Request(_) =>
                    finish(Some(McpError(McpErrorKind.Protocol, "mcp.subscription_reverse_request", "subscription stream contained a request"))); return
            }
        }
    }

    private func finish(error: ?McpError): Unit {
        var notify = false
        var cleanup = false
        lock.lock(); try {
            if (!stopped) { stopped = true; failure = error; notify = true }
            if (!resourcesClosed) { resourcesClosed = true; cleanup = true }
        } finally { lock.unlock() }
        if (notify) { onDone() }
        if (cleanup) {
            try { response.close() } catch (_: Exception) {}
            try { client.close() } catch (_: Exception) {}
        }
    }
}

public func openStreamableHttpMcpTransport(
    config: McpStreamableHttpClientConfig
): McpResult<StreamableHttpMcpTransport> {
    try { McpResult.Ok(StreamableHttpMcpTransport(config)) }
    catch (error: Exception) { httpMcpFailure<StreamableHttpMcpTransport>(McpErrorKind.Transport, "mcp.http_prepare_failed", error.message, retrySafe: true) }
}

func readMcpSseEnvelope(stream: InputStream, maxEventBytes: Int64): McpResult<?JsonRpcEnvelope> {
    var data = ""
    while (true) {
        let line = try {
            match (readLineBounded(stream, maxEventBytes, allowPartialAtEof: true)) {
                case Some(value) => value
                case None => if (data == "") { return McpResult.Ok(None) } else { "" }
            }
        } catch (error: Exception) {
            return McpResult.Err(McpError(McpErrorKind.Transport, "mcp.http_sse_read_failed", error.message))
        }
        if (line == "") {
            if (data == "") { continue }
            return match (decodeJsonRpc(data, maxBytes: maxEventBytes)) {
                case JsonRpcResult.Ok(value) => McpResult.Ok(Some(value))
                case JsonRpcResult.Err(error) => McpResult.Err(McpError(
                    McpErrorKind.Protocol, error.code, error.message, rpcCode: Some(error.rpcCode)
                ))
            }
        }
        if (line.startsWith(":")) { continue }
        if (line == "data") { if (data != "") { data += "\n" }; continue }
        if (line.startsWith("data:")) {
            var value = line[5..]; if (value.startsWith(" ")) { value = value[1..] }
            if (data != "") { data += "\n" }; data += value
            if (utf8ByteSize(data) > maxEventBytes) {
                return invalidMcp<?JsonRpcEnvelope>("mcp.http_sse_event_too_large", "MCP SSE event exceeds configured limit")
            }
        }
    }
    McpResult.Ok(None)
}

func readMcpSseResponse(
    stream: InputStream,
    expectedId: JsonRpcId,
    maxEventBytes: Int64,
    notificationSink!: (JsonRpcNotification) -> Unit = { _ => }
): McpResult<JsonRpcResponse> {
    if (maxEventBytes < 1) {
        return invalidMcp<JsonRpcResponse>(
            "mcp.http_sse_limit_invalid", "MCP SSE event limit must be positive"
        )
    }
    while (true) {
        match (readMcpSseEnvelope(stream, maxEventBytes)) {
            case McpResult.Err(error) => return McpResult.Err(error)
            case McpResult.Ok(None) => return invalidMcp<JsonRpcResponse>(
                "mcp.http_sse_response_missing",
                "MCP SSE stream ended without the matching JSON-RPC response"
            )
            case McpResult.Ok(Some(JsonRpcEnvelope.Response(response))) =>
                if (sameJsonRpcId(response.id, expectedId)) { return McpResult.Ok(response) }
            case McpResult.Ok(Some(JsonRpcEnvelope.Notification(notification))) => notificationSink(notification)
            case McpResult.Ok(Some(JsonRpcEnvelope.Request(_))) => return invalidMcp<JsonRpcResponse>(
                "mcp.http_sse_reverse_request_unsupported",
                "MCP SSE response contained an unsupported reverse request"
            )
        }
    }
    invalidMcp<JsonRpcResponse>("mcp.http_sse_response_missing", "MCP SSE response was not found")
}

func notificationBelongsToSubscription(notification: JsonRpcNotification, id: JsonRpcId): Bool {
    let meta = mcpObject(notification.params, "_meta")
    match (meta.field(MCP_META_SUBSCRIPTION_ID)) {
        case Some(value) => match (decodeMcpRequestId(value)) {
            case McpResult.Ok(found) => sameJsonRpcId(found, id)
            case McpResult.Err(_) => false
        }
        case None => false
    }
}

public class StreamableHttpMcpServer {
    private let config: McpStreamableHttpServerConfig
    private let mcp: McpServer
    private let native: Server
    private let lifecycle = McpLifecycle()
    private let requestLock = Mutex()
    private let activeStreams = ArrayList<JsonRpcId>()
    private let activeSubscriptions = ArrayList<JsonRpcId>()

    init(config: McpStreamableHttpServerConfig, mcp: McpServer, native: Server) {
        this.config = config; this.mcp = mcp; this.native = native
    }
    public func state(): McpLifecycleState { lifecycle.state() }
    public func port(): Int64 { Int64(native.port) }
    public func serve(): McpResult<Unit> {
        if (state() != McpLifecycleState.Created) { return lifecycleFailure<Unit>("mcp.http_server_already_started", "HTTP server can only be served once") }
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        try {
            native.serve()
            if (state() == McpLifecycleState.Ready) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
            if (state() == McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopped) }
            McpResult.Ok(())
        } catch (error: Exception) {
            if (state() == McpLifecycleState.Starting || state() == McpLifecycleState.Ready) { let _ = lifecycle.transition(McpLifecycleState.Failed) }
            httpMcpFailure<Unit>(McpErrorKind.Transport, "mcp.http_server_failed", error.message, retryable: true, retrySafe: true)
        }
    }
    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current == McpLifecycleState.Created) { let _ = lifecycle.transition(McpLifecycleState.Stopped); try { native.close() } catch (_: Exception) {}; let _ = mcp.close(); return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        try { native.closeGracefully(); let _ = mcp.close(); let _ = lifecycle.transition(McpLifecycleState.Stopped); McpResult.Ok(()) }
        catch (error: Exception) { httpMcpFailure<Unit>(McpErrorKind.Transport, "mcp.http_server_close_failed", error.message, retrySafe: true) }
    }
    func markReady(): Unit { if (state() == McpLifecycleState.Starting) { let _ = lifecycle.transition(McpLifecycleState.Ready) } }

    func handle(context: HttpContext): Unit {
        let request = context.request
        if (request.method != "POST") { writeHttpProblem(context, 405, "MCP endpoint only accepts POST"); return }
        let contentType = (request.headers.getFirst("content-type") ?? "").toAsciiLower()
        if (!contentType.startsWith("application/json")) { writeHttpProblem(context, 415, "MCP request must be application/json"); return }
        let accept = (request.headers.getFirst("accept") ?? "").toAsciiLower()
        if (!accept.contains("application/json") || !accept.contains("text/event-stream")) { writeHttpProblem(context, 406, "MCP client must accept JSON and SSE"); return }
        let origin = request.headers.getFirst("origin") ?? ""
        if (!originAllowed(config.originAllowlist, origin)) { writeHttpProblem(context, 403, "MCP request Origin is not allowed"); return }
        if (!bearerAuthorized(request.headers.getFirst("authorization") ?? "", config.bearerToken)) {
            context.responseBuilder.header("WWW-Authenticate", "Bearer"); writeHttpProblem(context, 401, "MCP bearer authorization failed"); return
        }
        let body = match (readMcpHttpBody(request.body, request.bodySize, config.framing.maxFrameBytes)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => writeHttpProblem(context, 413, error.message); return
        }
        let envelope = match (decodeJsonRpc(body, maxBytes: config.framing.maxFrameBytes)) {
            case JsonRpcResult.Ok(value) => value
            case JsonRpcResult.Err(error) => writeMcpHttpEnvelope(context, 400, JsonRpcEnvelope.Response(mcpFailureResponse(jsonRpcNullId(), error.rpcCode, error.message))); return
        }
        match (envelope) {
            case JsonRpcEnvelope.Request(value) => if (!reserveStream(value.id)) {
                writeHttpProblem(context, 503, "MCP HTTP server is at its concurrent request limit")
                return
            }
            case _ => ()
        }
        match (validateHttpMetadata(request, envelope, mcp)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) =>
                match (envelope) {
                    case JsonRpcEnvelope.Request(value) => releaseStream(value.id)
                    case _ => ()
                }
                writeMcpHttpEnvelope(
                    context,
                    400,
                    JsonRpcEnvelope.Response(mcpFailureResponse(
                        envelopeId(envelope),
                        if (error.code == "mcp.version_unsupported") {
                            MCP_UNSUPPORTED_PROTOCOL_VERSION
                        } else {
                            MCP_HEADER_MISMATCH
                        },
                        error.message,
                        data: if (error.code == "mcp.version_unsupported") {
                            jsonObject([
                                JsonObjectEntry("supported", jsonArray([jsonString(MCP_PROTOCOL_VERSION)])),
                                JsonObjectEntry("requested", jsonString(request.headers.getFirst(MCP_HEADER_PROTOCOL_VERSION) ?? ""))
                            ])
                        } else { jsonNull() }
                    ))
                )
                return
        }
        match (envelope) {
            case JsonRpcEnvelope.Request(value) => if (value.method == MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
                match (mcp.openSubscription(value)) {
                    case McpResult.Ok(source) =>
                        markSubscription(value.id)
                        context.responseBuilder.status(200)
                            .header("Content-Type", "text/event-stream; charset=utf-8")
                            .header("Cache-Control", "no-store")
                            .header("Transfer-Encoding", "chunked")
                            .body(McpSubscriptionSseInput(
                                value.id, source, config.framing.maxFrameBytes,
                                releaseAction: { => releaseStream(value.id) }
                            ))
                    case McpResult.Err(error) =>
                        releaseStream(value.id)
                        writeMcpHttpEnvelope(
                            context, 400, JsonRpcEnvelope.Response(mcpFailureResponse(
                                value.id,
                                if (error.code == "mcp.subscription_tasks_capability_missing") {
                                    MCP_MISSING_REQUIRED_CLIENT_CAPABILITY
                                } else { JSON_RPC_INVALID_PARAMS },
                                error.message
                            ))
                        )
                }
                return
            }
            case _ => ()
        }
        match (envelope) {
            case JsonRpcEnvelope.Request(value) =>
                let progressToken = mcpField(mcpObject(value.params, "_meta"), "progressToken", jsonNull())
                if (accept.trimAscii().startsWith("text/event-stream") ||
                    progressToken.unifiedKind != UnifiedJsonKind.Null) {
                    context.responseBuilder.status(200)
                        .header("Content-Type", "text/event-stream; charset=utf-8")
                        .header("Cache-Control", "no-store")
                        .header("Transfer-Encoding", "chunked")
                        .body(McpOperationSseInput(
                            value.id, config.framing.maxFrameBytes,
                            { notificationSink =>
                                projectMcpHttpResponse(
                                    envelope,
                                    JsonRpcEnvelope.Response(mcp.handleRequest(
                                        value, notificationSink: notificationSink
                                    ))
                                )
                            },
                            cancelAction: { =>
                                let _ = mcp.handleNotification(mcpCancellationNotification(
                                    value.id, "HTTP SSE client disconnected"
                                ))
                            },
                            releaseAction: { => releaseStream(value.id) }
                        ))
                    return
                }
            case _ => ()
        }
        let progressNotifications = ArrayList<JsonRpcNotification>()
        let handled: McpResult<?JsonRpcEnvelope> = match (envelope) {
            case JsonRpcEnvelope.Request(value) => McpResult.Ok(Some(JsonRpcEnvelope.Response(
                mcp.handleRequest(value, notificationSink: { notification => progressNotifications.add(notification) })
            )))
            case JsonRpcEnvelope.Notification(value) => handleHttpNotification(value)
            case JsonRpcEnvelope.Response(_) => mcp.handle(envelope)
        }
        try {
            match (handled) {
                case McpResult.Err(error) => writeMcpHttpEnvelope(context, 500, JsonRpcEnvelope.Response(mcpFailureResponse(envelopeId(envelope), JSON_RPC_INTERNAL_ERROR, error.message)))
                case McpResult.Ok(None) => context.responseBuilder.status(202)
                case McpResult.Ok(Some(rawResponse)) =>
                    let response = projectMcpHttpResponse(envelope, rawResponse)
                    let asSse = accept.trimAscii().startsWith("text/event-stream") || !progressNotifications.isEmpty()
                    if (asSse && responseStatus(response) == 200) {
                        var body = ""
                        for (notification in progressNotifications) {
                            body += "event: message\ndata: " + encodeJsonRpc(JsonRpcEnvelope.Notification(notification)) + "\n\n"
                        }
                        body += "event: message\ndata: " + encodeJsonRpc(response) + "\n\n"
                        context.responseBuilder.status(200).header("Content-Type", "text/event-stream; charset=utf-8").header("Cache-Control", "no-store").body(body)
                    } else { writeMcpHttpEnvelope(context, responseStatus(response), response) }
            }
        } finally {
            match (envelope) {
                case JsonRpcEnvelope.Request(value) => releaseStream(value.id)
                case _ => ()
            }
        }
    }

    private func handleHttpNotification(
        notification: JsonRpcNotification
    ): McpResult<?JsonRpcEnvelope> {
        let cancelledSubscription: ?JsonRpcId = if (notification.method == MCP_METHOD_CANCELLED) {
            match (notification.params.field("requestId")) {
                case Some(rawId) => match (decodeMcpRequestId(rawId)) {
                    case McpResult.Ok(id) => if (isActiveSubscription(id)) { Some(id) } else { None }
                    case McpResult.Err(_) => None
                }
                case None => None
            }
        } else { None }
        match (mcp.handleNotification(notification)) {
            case McpResult.Ok(_) =>
                match (cancelledSubscription) {
                    case Some(id) => releaseStream(id)
                    case None => ()
                }
                McpResult.Ok(None)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    private func reserveStream(id: JsonRpcId): Bool {
        requestLock.lock(); try {
            if (activeStreams.size >= config.maxConcurrentRequests) { false }
            else { activeStreams.add(id); true }
        } finally { requestLock.unlock() }
    }

    private func releaseStream(id: JsonRpcId): Unit {
        requestLock.lock(); try {
            for (index in 0..activeSubscriptions.size where sameJsonRpcId(activeSubscriptions[index], id)) {
                activeSubscriptions.remove(at: index)
                break
            }
            for (index in 0..activeStreams.size where sameJsonRpcId(activeStreams[index], id)) {
                activeStreams.remove(at: index)
                return
            }
        }
        finally { requestLock.unlock() }
    }

    private func markSubscription(id: JsonRpcId): Unit {
        requestLock.lock(); try { activeSubscriptions.add(id) } finally { requestLock.unlock() }
    }

    private func isActiveSubscription(id: JsonRpcId): Bool {
        requestLock.lock(); try {
            for (active in activeSubscriptions where sameJsonRpcId(active, id)) { return true }
            false
        } finally { requestLock.unlock() }
    }
}

let MCP_OPERATION_PROGRESS_QUEUE_LIMIT: Int64 = 256

class McpOperationSseInput <: InputStream & Resource {
    private let id: JsonRpcId
    private let maxFrameBytes: Int64
    private let lock = Mutex()
    private let queued = ArrayList<Array<Byte>>()
    private var pending: Array<Byte> = []
    private var offset: Int64 = 0
    private var done = false
    private var closed = false
    private var overflowed = false
    private var worker: ?Future<Unit> = None
    private let cancelAction: () -> Unit
    private let releaseAction: () -> Unit

    init(
        id: JsonRpcId,
        maxFrameBytes: Int64,
        operation: ((JsonRpcNotification) -> Unit) -> JsonRpcEnvelope,
        cancelAction!: () -> Unit = { => },
        releaseAction!: () -> Unit = { => }
    ) {
        this.id = id
        this.maxFrameBytes = maxFrameBytes
        this.cancelAction = cancelAction
        this.releaseAction = releaseAction
        let running = spawn {
            let response = try {
                operation({ notification => enqueueProgress(JsonRpcEnvelope.Notification(notification)) })
            } catch (error: Exception) {
                JsonRpcEnvelope.Response(mcpFailureResponse(
                    id, JSON_RPC_INTERNAL_ERROR, error.message
                ))
            }
            enqueueFinal(response)
        }
        worker = Some(running)
        spawn {
            try { let _ = running.get() } finally { releaseAction() }
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.isEmpty()) { return 0 }
        while (offset >= pending.size) {
            var finished = false
            lock.lock()
            try {
                if (closed) { return 0 }
                if (!queued.isEmpty()) {
                    pending = queued[0]
                    queued.remove(at: 0)
                    offset = 0
                    break
                }
                if (done) { finished = true }
            } finally { lock.unlock() }
            if (finished) { close(); return 0 }
            sleep(Duration.millisecond * 5)
        }
        let count = min(buffer.size, pending.size - offset)
        for (index in 0..count) { buffer[index] = pending[offset + index] }
        offset += count
        count
    }

    public func close(): Unit {
        var cancel = false
        lock.lock(); try {
            if (!closed) {
                closed = true; queued.clear(); pending = []
                cancel = !done
            }
        } finally { lock.unlock() }
        if (cancel) { cancelAction() }
    }
    public func isClosed(): Bool { lock.lock(); try { closed } finally { lock.unlock() } }

    private func encodedEnvelope(envelope: JsonRpcEnvelope): Array<Byte> {
        ("event: message\ndata: " + encodeJsonRpc(envelope) + "\n\n").toArray()
    }

    private func enqueueProgress(envelope: JsonRpcEnvelope): Unit {
        let bytes = encodedEnvelope(envelope)
        lock.lock(); try {
            if (!closed && !overflowed) {
                if (bytes.size > maxFrameBytes) {
                    queued.clear()
                    queued.add(encodedEnvelope(JsonRpcEnvelope.Response(mcpFailureResponse(
                        id, JSON_RPC_INTERNAL_ERROR,
                        "MCP operation progress notification exceeded the frame limit"
                    ))))
                    overflowed = true
                    done = true
                } else if (queued.size >= MCP_OPERATION_PROGRESS_QUEUE_LIMIT) {
                    queued.clear()
                    queued.add(encodedEnvelope(JsonRpcEnvelope.Response(mcpFailureResponse(
                        id, JSON_RPC_INTERNAL_ERROR,
                        "MCP operation progress consumer did not keep up with notifications"
                    ))))
                    overflowed = true
                    done = true
                } else { queued.add(bytes) }
            }
        } finally { lock.unlock() }
    }

    private func enqueueFinal(envelope: JsonRpcEnvelope): Unit {
        let bytes = encodedEnvelope(envelope)
        lock.lock(); try {
            if (!closed && !overflowed) {
                if (bytes.size > maxFrameBytes) {
                    queued.add(encodedEnvelope(JsonRpcEnvelope.Response(mcpFailureResponse(
                        id, JSON_RPC_INTERNAL_ERROR,
                        "MCP operation response exceeded the frame limit"
                    ))))
                    overflowed = true
                } else { queued.add(bytes) }
            }
            done = true
        } finally { lock.unlock() }
    }
}

class McpSubscriptionSseInput <: InputStream & Resource {
    private let id: JsonRpcId
    private let source: McpSubscriptionSource
    private let maxFrameBytes: Int64
    private let releaseAction: () -> Unit
    private var pending: Array<Byte> = []
    private var offset: Int64 = 0
    private var first = true
    private var closed = false
    private var finishAfterPending = false
    init(
        id: JsonRpcId, source: McpSubscriptionSource, maxFrameBytes: Int64,
        releaseAction!: () -> Unit = { => }
    ) {
        this.id = id; this.source = source; this.maxFrameBytes = maxFrameBytes
        this.releaseAction = releaseAction
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (closed || buffer.isEmpty()) { return 0 }
        while (offset >= pending.size) {
            if (finishAfterPending) { close(); return 0 }
            let envelope: JsonRpcEnvelope = if (first) {
                first = false
                JsonRpcEnvelope.Notification(tagMcpSubscriptionNotification(JsonRpcNotification(
                    MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED,
                    params: source.acknowledged().toValue()
                ), id))
            } else {
                match (source.next()) {
                    case McpResult.Ok(Some(notification)) => JsonRpcEnvelope.Notification(
                        tagMcpSubscriptionNotification(notification, id)
                    )
                    case McpResult.Ok(None) =>
                        finishAfterPending = true
                        JsonRpcEnvelope.Response(mcpSuccessResponse(id, jsonObject([]), None))
                    case McpResult.Err(error) =>
                        finishAfterPending = true
                        JsonRpcEnvelope.Response(mcpHostFailure(id, error))
                }
            }
            let bytes = ("event: message\ndata: " + encodeJsonRpc(envelope) + "\n\n").toArray()
            if (bytes.size > maxFrameBytes) {
                pending = ("event: message\ndata: " + encodeJsonRpc(JsonRpcEnvelope.Response(
                    mcpFailureResponse(id, JSON_RPC_INTERNAL_ERROR, "MCP subscription event exceeded the frame limit")
                )) + "\n\n").toArray()
                finishAfterPending = true
            } else { pending = bytes }
            offset = 0
        }
        let count = min(buffer.size, pending.size - offset)
        for (index in 0..count) { buffer[index] = pending[offset + index] }
        offset += count; count
    }
    public func close(): Unit {
        if (closed) { return }
        closed = true; let _ = source.close(); releaseAction()
    }
    public func isClosed(): Bool { closed }
}

func tagMcpSubscriptionNotification(
    notification: JsonRpcNotification, id: JsonRpcId
): JsonRpcNotification {
    let params = ArrayList<JsonObjectEntry>(); var metadata = jsonObject([])
    for (field in notification.params.fields) {
        if (field.name == "_meta" && field.value.unifiedKind == UnifiedJsonKind.Object) { metadata = field.value }
        else { params.add(field) }
    }
    let meta = ArrayList<JsonObjectEntry>()
    for (field in metadata.fields where field.name != MCP_META_SUBSCRIPTION_ID) { meta.add(field) }
    meta.add(JsonObjectEntry(MCP_META_SUBSCRIPTION_ID, requestIdValue(id)))
    params.add(JsonObjectEntry("_meta", jsonObject(meta.toArray())))
    JsonRpcNotification(notification.method, params: jsonObject(params.toArray()))
}

public func openStreamableHttpMcpServer(
    config: McpStreamableHttpServerConfig,
    mcp: McpServer
): McpResult<StreamableHttpMcpServer> {
    try {
        let native = ServerBuilder().addr(config.bindHost).port(UInt16(config.port))
            .maxRequestBodySize(config.framing.maxFrameBytes).logger(NoopLogger()).build()
        let server = StreamableHttpMcpServer(config, mcp, native)
        native.distributor.register("/mcp", { context => server.handle(context) })
        native.afterBind({ => server.markReady() })
        McpResult.Ok(server)
    } catch (error: Exception) {
        httpMcpFailure<StreamableHttpMcpServer>(McpErrorKind.Transport, "mcp.http_server_prepare_failed", error.message, retrySafe: true)
    }
}

func validateHttpMetadata(request: HttpRequest, envelope: JsonRpcEnvelope, mcp: McpServer): McpResult<Unit> {
    let method = request.headers.getFirst(MCP_HEADER_METHOD) ?? ""
    let protocol = request.headers.getFirst(MCP_HEADER_PROTOCOL_VERSION) ?? ""
    let (bodyMethod, params) = match (envelope) {
        case JsonRpcEnvelope.Request(value) => (value.method, value.params)
        case JsonRpcEnvelope.Notification(value) => (value.method, value.params)
        case JsonRpcEnvelope.Response(_) => return invalidMcp<Unit>("mcp.http_client_response_unexpected", "server does not accept client responses")
    }
    let bodyProtocol = mcpProtocolVersion(params)
    if (protocol == "" || method == "" || (bodyProtocol != "" && protocol != bodyProtocol) || method != bodyMethod) {
        return invalidMcp<Unit>("mcp.http_header_mismatch", "MCP headers do not match request body")
    }
    if (protocol != MCP_PROTOCOL_VERSION) {
        return invalidMcp<Unit>("mcp.version_unsupported", "unsupported MCP protocol version")
    }
    if (mcpMethodRequiresName(bodyMethod)) {
        let name = match (decodeMcpHeader(request.headers.getFirst(MCP_HEADER_NAME) ?? "")) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (name == "" || name != mcpStandardName(bodyMethod, params)) {
            return invalidMcp<Unit>("mcp.http_header_mismatch", "Mcp-Name header does not match request body")
        }
    }
    if (bodyMethod == MCP_METHOD_TOOLS_CALL) {
        let name = mcpText(params, "name")
        let tool = match (mcp.tool(name)) {
            case McpResult.Ok(Some(value)) => value
            case McpResult.Ok(None) => return invalidMcp<Unit>("mcp.http_header_mismatch", "tool is unavailable for header validation")
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let expected = match (projectMcpParameterHeaders(tool.inputSchema, mcpObject(params, "arguments"))) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        for (header in expected) {
            let actual = request.headers.getFirst(header.name) ?? ""
            let decoded = match (decodeMcpHeader(actual)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            let wanted = match (decodeMcpHeader(header.value)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            if (decoded != wanted) {
                return invalidMcp<Unit>("mcp.http_header_mismatch", header.name + " does not match tools/call arguments")
            }
        }
    }
    McpResult.Ok(())
}

func httpMcpFailure<T>(kind: McpErrorKind, code: String, message: String, retryable!: Bool = false, retrySafe!: Bool = false, status!: ?Int64 = None): McpResult<T> {
    McpResult.Err(McpError(kind, code, message, retryable: retryable, retrySafe: retrySafe, httpStatus: status))
}

func decodeMcpHttpSubscriptionRejection(
    body: String, expectedId: JsonRpcId, maxBytes: Int64
): McpResult<McpError> {
    let response = match (decodeJsonRpc(body, maxBytes: maxBytes)) {
        case JsonRpcResult.Ok(JsonRpcEnvelope.Response(value)) => value
        case _ => return invalidMcp<McpError>(
            "mcp.http_subscription_rejection_invalid", "subscription rejection was not a JSON-RPC response"
        )
    }
    if (!sameJsonRpcId(response.id, expectedId)) {
        return invalidMcp<McpError>(
            "mcp.subscription_response_id_mismatch", "subscription rejection response id mismatch"
        )
    }
    match (response.payload) {
        case JsonRpcResponsePayload.Failure(error) => match (remoteMcpError<Unit>(error)) {
            case McpResult.Err(value) => McpResult.Ok(value)
            case McpResult.Ok(_) => invalidMcp<McpError>(
                "mcp.http_subscription_rejection_invalid", "subscription rejection did not contain an error"
            )
        }
        case JsonRpcResponsePayload.Success(_) => invalidMcp<McpError>(
            "mcp.http_subscription_rejection_invalid", "non-SSE subscription response was not an error"
        )
    }
}
func httpStatusMcpFailure<T>(operation: String, status: Int64): McpResult<T> {
    if (operation == MCP_METHOD_TOOLS_CALL && status >= 500) {
        return httpMcpFailure<T>(
            McpErrorKind.Transport,
            "mcp.http_call_response_lost",
            "MCP tools/call may have executed before the server returned an error",
            retrySafe: false,
            status: Some(status)
        )
    }
    let retrySafe = operation != MCP_METHOD_TOOLS_CALL || (status >= 400 && status < 500 && status != 408)
    let kind = if (status == 401) { McpErrorKind.Authentication }
        else if (status == 403) { McpErrorKind.Authorization }
        else if (status == 408 || status == 504) { McpErrorKind.Deadline }
        else if (status >= 500) { McpErrorKind.Transport } else { McpErrorKind.Protocol }
    httpMcpFailure<T>(kind, "mcp.http_status_error", "MCP HTTP server returned status " + status.toString(), retryable: retrySafe && (status == 408 || status == 429 || status >= 500), retrySafe: retrySafe, status: Some(status))
}
func ambiguousHttpMcp<T>(operation: String, message: String): McpResult<T> {
    let call = operation == MCP_METHOD_TOOLS_CALL
    httpMcpFailure<T>(McpErrorKind.Transport, if (call) { "mcp.http_call_response_lost" } else { "mcp.http_response_lost" }, if (call) { "MCP tools/call may have executed before its response was lost" } else { "MCP HTTP response was lost: " + message }, retrySafe: false)
}
func cancelledHttpMcp<T>(): McpResult<T> { httpMcpFailure<T>(McpErrorKind.Cancelled, "mcp.http_request_cancelled", "MCP HTTP request was cancelled", retrySafe: false) }
func mcpProtocolVersion(params: JsonNode): String { match (params.field("_meta")) { case Some(meta) => if (meta.unifiedKind == UnifiedJsonKind.Object) { mcpText(meta, MCP_META_PROTOCOL_VERSION) } else { "" }; case None => "" } }
func envelopeId(envelope: JsonRpcEnvelope): JsonRpcId { match (envelope) { case JsonRpcEnvelope.Request(value) => value.id; case JsonRpcEnvelope.Response(value) => value.id; case JsonRpcEnvelope.Notification(_) => jsonRpcNullId() } }
func responseStatus(envelope: JsonRpcEnvelope): UInt16 { match (envelope) {
    case JsonRpcEnvelope.Response(value) => match (value.payload) {
        case JsonRpcResponsePayload.Failure(error) =>
            if (error.code == JSON_RPC_METHOD_NOT_FOUND) { 404 }
            else if (error.code == JSON_RPC_INVALID_PARAMS || error.code == MCP_HEADER_MISMATCH ||
                error.code == MCP_MISSING_REQUIRED_CLIENT_CAPABILITY || error.code == MCP_UNSUPPORTED_PROTOCOL_VERSION) { 400 }
            else { 200 }
        case _ => 200
    }
    case _ => 200
} }
func writeHttpProblem(context: HttpContext, status: UInt16, message: String): Unit { context.responseBuilder.status(status).header("Content-Type", "text/plain; charset=utf-8").header("Cache-Control", "no-store").body(message) }
func writeMcpHttpEnvelope(context: HttpContext, status: UInt16, envelope: JsonRpcEnvelope): Unit { context.responseBuilder.status(status).header("Content-Type", "application/json; charset=utf-8").header("Cache-Control", "no-store").body(encodeJsonRpc(envelope)) }
func originAllowed(allowed: Array<String>, origin: String): Bool {
    if (origin == "") { return true }
    for (value in allowed where value == origin) { return true }
    if (!allowed.isEmpty() || !secureMcpHttpOrigin(origin)) { return false }
    loopbackMcpAuthority(mcpHttpAuthority(
        origin, if (origin.startsWith("https://")) { "https://" } else { "http://" }
    ))
}
func bearerAuthorized(value: String, token: String): Bool { if (token == "") { return value == "" }; value == "Bearer " + token }
func validHttpToken(value: String): Bool { if (value == "") { return false }; for (byte in unsafe { value.rawData() }) { if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') || byte == b'-')) { return false } }; true }
func validHttpValue(value: String): Bool { for (byte in unsafe { value.rawData() }) { if (byte != b'\t' && (byte < 32 || byte > 126)) { return false } }; true }
func reservedMcpHeader(value: String): Bool {
    let lower = value.toAsciiLower()
    lower == "authorization" || lower == "content-type" || lower == "accept" ||
        lower == "origin" || lower == MCP_HEADER_PROTOCOL_VERSION.toAsciiLower() ||
        lower == MCP_HEADER_METHOD.toAsciiLower() || lower == MCP_HEADER_NAME.toAsciiLower() ||
        lower.startsWith(MCP_HEADER_PARAM_PREFIX.toAsciiLower())
}
func loopbackMcpHost(value: String): Bool { value == "127.0.0.1" || value == "localhost" || value == "::1" }
func secureMcpHttpUrl(value: String): Bool {
    if (value.startsWith("https://")) {
        let authority = mcpHttpAuthority(value, "https://")
        return authority != "" && authority.indexOf("@").isNone() && authority.indexOf(" ").isNone()
    }
    if (!value.startsWith("http://")) { return false }
    loopbackMcpAuthority(mcpHttpAuthority(value, "http://"))
}
func secureMcpHttpOrigin(value: String): Bool {
    let prefix = if (value.startsWith("https://")) { "https://" }
        else if (value.startsWith("http://")) { "http://" }
        else { return false }
    let remainder = value[prefix.size..]
    mcpHttpAuthority(value, prefix).size == remainder.size && secureMcpHttpUrl(value)
}
func mcpHttpAuthority(value: String, prefix: String): String {
    let remainder = value[prefix.size..]
    var end = remainder.size
    for (separator in ["/", "?", "#"]) {
        match (remainder.indexOf(separator)) {
            case Some(index) => end = min(end, index)
            case None => ()
        }
    }
    remainder[..end]
}
func loopbackMcpAuthority(authority: String): Bool {
    if (authority == "127.0.0.1" || authority == "localhost" || authority == "[::1]") { return true }
    for (host in ["127.0.0.1", "localhost", "[::1]"]) {
        let prefix = host + ":"
        if (authority.startsWith(prefix) && asciiMcpDecimal(authority[prefix.size..])) { return true }
    }
    false
}
func asciiMcpDecimal(value: String): Bool {
    if (value == "") { return false }
    for (byte in unsafe { value.rawData() } where byte < b'0' || byte > b'9') { return false }
    true
}
func projectMcpHttpResponse(request: JsonRpcEnvelope, response: JsonRpcEnvelope): JsonRpcEnvelope {
    let method = match (request) {
        case JsonRpcEnvelope.Request(value) => value.method
        case JsonRpcEnvelope.Notification(value) => value.method
        case JsonRpcEnvelope.Response(_) => ""
    }
    if (method != MCP_METHOD_TOOLS_LIST) { return response }
    match (response) {
        case JsonRpcEnvelope.Response(value) => match (value.payload) {
            case JsonRpcResponsePayload.Success(result) =>
                let tools = match (result.field("tools")) {
                    case Some(candidate) => candidate
                    case None => return response
                }
                if (tools.unifiedKind != UnifiedJsonKind.List) { return response }
                let accepted = ArrayList<JsonNode>()
                for (tool in tools.items) {
                    let schema = match (tool.field("inputSchema")) {
                        case Some(candidate) => candidate
                        case None => jsonNull()
                    }
                    if (validMcpHttpSchema(schema)) { accepted.add(tool) }
                }
                let fields = ArrayList<JsonObjectEntry>()
                for (field in result.fields) {
                    fields.add(if (field.name == "tools") {
                        JsonObjectEntry("tools", jsonArray(accepted.toArray()))
                    } else { field })
                }
                JsonRpcEnvelope.Response(JsonRpcResponse(
                    value.id,
                    JsonRpcResponsePayload.Success(jsonObject(fields.toArray()))
                ))
            case _ => response
        }
        case _ => response
    }
}

func validMcpHttpSchema(schema: JsonNode): Bool {
    if (schema.unifiedKind != UnifiedJsonKind.Object) { return false }
    match (schema.field("x-mcp-header")) {
        case Some(header) =>
            if (header.unifiedKind != UnifiedJsonKind.Text || !validHttpToken(header.text)) { return false }
            let kind = mcpText(schema, "type")
            if (kind != "string" && kind != "integer" && kind != "boolean") { return false }
        case None => ()
    }
    match (schema.field("properties")) {
        case Some(properties) =>
            if (properties.unifiedKind != UnifiedJsonKind.Object) { return false }
            for (field in properties.fields) { if (!validMcpHttpSchema(field.value)) { return false } }
        case None => ()
    }
    match (schema.field("items")) {
        case Some(items) => if (!validMcpHttpSchema(items)) { return false }
        case None => ()
    }
    true
}

func projectMcpParameterHeaders(schema: JsonNode, value: JsonNode): McpResult<Array<McpHttpHeader>> {
    let headers = ArrayList<McpHttpHeader>()
    if (schema.unifiedKind == UnifiedJsonKind.Null) { return McpResult.Ok([]) }
    match (appendMcpParameterHeaders(schema, value, headers)) {
        case McpResult.Ok(_) => McpResult.Ok(headers.toArray())
        case McpResult.Err(error) => McpResult.Err(error)
    }
}

func appendMcpParameterHeaders(
    schema: JsonNode, value: JsonNode, headers: ArrayList<McpHttpHeader>
): McpResult<Unit> {
    if (schema.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<Unit>("mcp.http_schema_invalid", "tool input schema must be an object")
    }
    match (schema.field("x-mcp-header")) {
        case Some(header) =>
            if (header.unifiedKind != UnifiedJsonKind.Text || !validHttpToken(header.text)) {
                return invalidMcp<Unit>("mcp.http_schema_invalid", "x-mcp-header must be a valid token")
            }
            let encoded = match (mcpHeaderScalar(schema, value)) {
                case McpResult.Ok(found) => found
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            let fullName = MCP_HEADER_PARAM_PREFIX + header.text
            for (existing in headers where existing.name.toAsciiLower() == fullName.toAsciiLower()) {
                return invalidMcp<Unit>("mcp.http_schema_invalid", "duplicate x-mcp-header name")
            }
            try { headers.add(McpHttpHeader(fullName, encodeMcpHeader(encoded))) }
            catch (error: Exception) { return invalidMcp<Unit>("mcp.http_header_invalid", error.message) }
        case None => ()
    }
    match (schema.field("properties")) {
        case Some(properties) =>
            if (properties.unifiedKind != UnifiedJsonKind.Object || value.unifiedKind != UnifiedJsonKind.Object) {
                return McpResult.Ok(())
            }
            for (property in properties.fields) {
                match (value.field(property.name)) {
                    case Some(child) => match (appendMcpParameterHeaders(property.value, child, headers)) {
                        case McpResult.Ok(_) => ()
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                    case None => ()
                }
            }
        case None => ()
    }
    McpResult.Ok(())
}

func mcpHeaderScalar(schema: JsonNode, value: JsonNode): McpResult<String> {
    let kind = mcpText(schema, "type")
    if (kind == "string" && value.unifiedKind == UnifiedJsonKind.Text) { return McpResult.Ok(value.text) }
    if (kind == "boolean" && value.unifiedKind == UnifiedJsonKind.Boolean) {
        return McpResult.Ok(if (value.boolean) { "true" } else { "false" })
    }
    if (kind == "integer" && value.unifiedKind == UnifiedJsonKind.Number && mcpIntegerText(value.number)) {
        return McpResult.Ok(value.number)
    }
    invalidMcp<String>("mcp.http_header_value_invalid", "x-mcp-header value does not match string, integer, or boolean schema")
}

func mcpIntegerText(value: String): Bool {
    if (value == "") { return false }
    let bytes = unsafe { value.rawData() }; var start: Int64 = 0
    if (bytes[0] == b'-') { if (bytes.size == 1) { return false }; start = 1 }
    for (index in start..bytes.size where bytes[index] < b'0' || bytes[index] > b'9') { return false }
    true
}

func encodeMcpHeader(value: String): String {
    if (plainMcpHeaderValue(value) && !(value.startsWith("=?base64?") && value.endsWith("?="))) {
        return value
    }
    "=?base64?" + mcpBase64(unsafe { value.rawData() }) + "?="
}
func decodeMcpHeader(value: String): McpResult<String> {
    if (value.startsWith("=?base64?") && value.endsWith("?=")) {
        return decodeMcpBase64(value[9..value.size - 2])
    }
    if (!plainMcpHeaderValue(value)) {
        return invalidMcp<String>("mcp.http_header_invalid", "MCP header value is not safe ASCII")
    }
    McpResult.Ok(value)
}

func plainMcpHeaderValue(value: String): Bool {
    if (value == "" || value.trimAscii() != value) { return false }
    for (byte in unsafe { value.rawData() } where byte != b'\t' && (byte < 32 || byte > 126)) { return false }
    true
}

func mcpMethodRequiresName(method: String): Bool {
    method == MCP_METHOD_TOOLS_CALL || method == MCP_METHOD_PROMPTS_GET ||
        method == MCP_METHOD_RESOURCES_READ || method == MCP_METHOD_TASKS_GET ||
        method == MCP_METHOD_TASKS_UPDATE || method == MCP_METHOD_TASKS_CANCEL
}

func mcpStandardName(method: String, params: JsonNode): String {
    if (method == MCP_METHOD_RESOURCES_READ) { mcpText(params, "uri") }
    else if (method == MCP_METHOD_TASKS_GET || method == MCP_METHOD_TASKS_UPDATE ||
        method == MCP_METHOD_TASKS_CANCEL) { mcpText(params, "taskId") }
    else { mcpText(params, "name") }
}

func mcpBase64(bytes: Array<UInt8>): String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let chars = ArrayList<UInt8>(); var index: Int64 = 0
    while (index < bytes.size) {
        let first = UInt32(bytes[index])
        let second = if (index + 1 < bytes.size) { UInt32(bytes[index + 1]) } else { UInt32(0) }
        let third = if (index + 2 < bytes.size) { UInt32(bytes[index + 2]) } else { UInt32(0) }
        let packed = (first << 16) | (second << 8) | third
        let data = unsafe { alphabet.rawData() }
        chars.add(data[Int64((packed >> 18) & 63)]); chars.add(data[Int64((packed >> 12) & 63)])
        if (index + 1 < bytes.size) { chars.add(data[Int64((packed >> 6) & 63)]) } else { chars.add(b'=') }
        if (index + 2 < bytes.size) { chars.add(data[Int64(packed & 63)]) } else { chars.add(b'=') }
        index += 3
    }
    String.fromUtf8(chars.toArray())
}

func decodeMcpBase64(value: String): McpResult<String> {
    let source = unsafe { value.rawData() }
    if (source.size == 0 || source.size % 4 != 0) { return invalidMcp<String>("mcp.http_header_invalid", "invalid MCP base64 header") }
    let output = ArrayList<UInt8>(); var index: Int64 = 0
    while (index < source.size) {
        let a = mcpBase64Digit(source[index]); let b = mcpBase64Digit(source[index + 1])
        let c = if (source[index + 2] == b'=') { -1 } else { mcpBase64Digit(source[index + 2]) }
        let d = if (source[index + 3] == b'=') { -1 } else { mcpBase64Digit(source[index + 3]) }
        if (a < 0 || b < 0 || (c < 0 && source[index + 2] != b'=') || (d < 0 && source[index + 3] != b'=')) {
            return invalidMcp<String>("mcp.http_header_invalid", "invalid MCP base64 header")
        }
        let packed = (UInt32(a) << 18) | (UInt32(b) << 12) |
            (if (c < 0) { UInt32(0) } else { UInt32(c) } << 6) |
            if (d < 0) { UInt32(0) } else { UInt32(d) }
        output.add(UInt8((packed >> 16) & 255))
        if (c >= 0) { output.add(UInt8((packed >> 8) & 255)) }
        if (d >= 0) { output.add(UInt8(packed & 255)) }
        index += 4
    }
    try { McpResult.Ok(String.fromUtf8(output.toArray())) }
    catch (_: Exception) { invalidMcp<String>("mcp.http_header_invalid", "MCP header is not UTF-8") }
}

func mcpBase64Digit(value: UInt8): Int64 {
    if (value >= b'A' && value <= b'Z') { Int64(value - b'A') }
    else if (value >= b'a' && value <= b'z') { Int64(value - b'a') + 26 }
    else if (value >= b'0' && value <= b'9') { Int64(value - b'0') + 52 }
    else if (value == b'+') { 62 }
    else if (value == b'/') { 63 }
    else { -1 }
}
