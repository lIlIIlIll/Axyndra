package agent_mcp

import agent_domain.*
import agent_protocol.*
import mcp4cj as library
import std.collection.*
import std.env.*

// Product facade: environment/secret resolution remains here; HTTP protocol
// lifecycle and cancellation are owned by mcp4cj.
public class StreamableHttpMcpTransport <: McpTransport {
    private let primitive: library.StreamableHttpMcpTransport
    init(primitive: library.StreamableHttpMcpTransport) { this.primitive = primitive }
    public func kind(): McpTransportKind { primitive.kind() }
    public func state(): McpLifecycleState { primitive.state() }
    public func request(request: JsonRpcRequest): Result<JsonRpcResponse> {
        mapMcpResult(primitive.request(request))
    }
    public func requestWithNotifications(
        request: JsonRpcRequest,
        notificationSink: (JsonRpcNotification) -> Unit
    ): Result<JsonRpcResponse> {
        mapMcpResult(primitive.requestWithNotifications(request, notificationSink))
    }
    public func openSubscription(request: JsonRpcRequest): Result<McpSubscriptionHandle> {
        mapMcpResult(primitive.openSubscription(request))
    }
    public func notify(notification: JsonRpcNotification): Result<Unit> {
        mapMcpResult(primitive.notify(notification))
    }
    public func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): Result<Unit> {
        mapMcpResult(primitive.cancel(requestId, reason, meta))
    }
    public func registerTools(tools: Array<McpTool>): Result<Unit> {
        mapMcpResult(primitive.registerTools(tools))
    }
    public func close(): Result<Unit> { mapMcpResult(primitive.close()) }
}

public func openStreamableHttpMcpTransport(
    config: McpStreamableHttpClientConfig
): Result<McpTransport> {
    let bearer = match (resolveHttpSecret(config.bearerTokenEnvironment)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let headers = ArrayList<library.McpHttpHeader>()
    for (binding in config.headers) {
        let value = match (resolveHttpSecret(binding.environment)) {
            case Result.Ok(found) => found
            case Result.Err(error) => return Result.Err(error)
        }
        try { headers.add(library.McpHttpHeader(binding.header, value)) }
        catch (error: Exception) { return mcpHttpProductFailure<McpTransport>(
            "mcp.http_header_invalid", error.message
        ) }
    }
    let primitiveConfig = try {
        library.McpStreamableHttpClientConfig(
            config.url,
            bearerToken: bearer,
            headers: headers.toArray(),
            origin: config.origin,
            preferSse: config.preferSse,
            framing: config.framing
        )
    } catch (error: Exception) {
        return mcpHttpProductFailure<McpTransport>("mcp.http_config_invalid", error.message)
    }
    match (library.openStreamableHttpMcpTransport(primitiveConfig)) {
        case library.McpResult.Ok(value) => Result.Ok(StreamableHttpMcpTransport(value))
        case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
    }
}

public class StreamableHttpMcpServer {
    private let primitive: library.StreamableHttpMcpServer
    init(primitive: library.StreamableHttpMcpServer) { this.primitive = primitive }
    public func state(): McpLifecycleState { primitive.state() }
    public func port(): Int64 { primitive.port() }
    public func serve(): Result<Unit> { mapMcpResult(primitive.serve()) }
    public func close(): Result<Unit> { mapMcpResult(primitive.close()) }
}

public func openStreamableHttpMcpServer(
    config: McpStreamableHttpServerConfig,
    mcpServer: McpServer
): Result<StreamableHttpMcpServer> {
    let bearer = match (resolveHttpSecret(config.bearerTokenEnvironment)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let primitiveConfig = try {
        library.McpStreamableHttpServerConfig(
            bindHost: config.bindHost,
            port: config.port,
            bearerToken: bearer,
            originAllowlist: config.originAllowlist,
            maxConcurrentRequests: config.maxConcurrentRequests,
            framing: config.framing
        )
    } catch (error: Exception) {
        return mcpHttpProductFailure<StreamableHttpMcpServer>(
            "mcp.http_server_config_invalid", error.message
        )
    }
    match (library.openStreamableHttpMcpServer(primitiveConfig, mcpServer.libraryServer())) {
        case library.McpResult.Ok(value) => Result.Ok(StreamableHttpMcpServer(value))
        case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
    }
}

func resolveHttpSecret(environment: String): Result<String> {
    if (environment == "") { return Result.Ok("") }
    match (getVariable(environment)) {
        case Some(value) =>
            if (value == "") {
                mcpHttpProductFailure<String>(
                    "mcp.http_environment_empty",
                    "required MCP HTTP environment variable is empty",
                    fields: [ErrorField("environment", environment)]
                )
            } else if (!validHttpHeaderValue(value)) {
                mcpHttpProductFailure<String>(
                    "mcp.http_environment_value_invalid",
                    "required MCP HTTP environment variable is not a valid header value",
                    fields: [ErrorField("environment", environment)]
                )
            } else { Result.Ok(value) }
        case None => mcpHttpProductFailure<String>(
            "mcp.http_environment_missing",
            "required MCP HTTP environment variable is unavailable",
            fields: [ErrorField("environment", environment)]
        )
    }
}

func validHttpHeaderValue(value: String): Bool {
    for (byte in unsafe { value.rawData() }) {
        if (byte != b'\t' && (byte < 32 || byte > 126)) { return false }
    }
    true
}

func validMcpHeaderToken(value: String): Bool {
    if (value == "") { return false }
    for (byte in unsafe { value.rawData() }) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'!' || byte == b'#' ||
            byte == b'$' || byte == b'%' || byte == b'&' || byte == b'\'' ||
            byte == b'*' || byte == b'+' || byte == b'-' || byte == b'.' ||
            byte == b'^' || byte == b'_' || byte == b'`' || byte == b'|' ||
            byte == b'~')) { return false }
    }
    true
}

func mcpHttpProductFailure<T>(
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Configuration, code, message,
        fields: fields
    ))
}
