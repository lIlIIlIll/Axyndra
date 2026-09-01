package agent_mcp

import yjson_support.*
import yjson.*
import agent_domain.*
import agent_protocol.*
import mcp4cj as library
import std.collection.*
import std.convert.*
import std.env.*

public class StdioMcpTransport <: McpTransport {
    private let primitive: library.StdioMcpTransport

    init(primitive: library.StdioMcpTransport) { this.primitive = primitive }

    public func kind(): McpTransportKind { primitive.kind() }

    public func state(): McpLifecycleState { primitive.state() }

    public func request(request: JsonRpcRequest): Result<JsonRpcResponse> {
        requestWithNotifications(request, {_ =>})
    }

    public func requestWithNotifications(
        request: JsonRpcRequest,
        notificationSink: (JsonRpcNotification) -> Unit
    ): Result<JsonRpcResponse> {
        match (primitive.requestWithNotifications(request, notificationSink)) {
            case library.McpResult.Ok(value) => Result.Ok(value)
            case library.McpResult.Err(error) =>
                if (error.code == "mcp.stdio_timeout" && request.method == MCP_METHOD_TOOLS_CALL) {
                    return stdioFailure<JsonRpcResponse>(
                        AgentErrorKind.RecoveryRequired,
                        "mcp.stdio_call_timeout_ambiguous",
                        "MCP tools/call timed out after dispatch and must not be retried automatically",
                        fields: [
                            ErrorField("retry_safe", "false"),
                            ErrorField("mcp_error_kind", mcpLibraryErrorKindName(error.kind))
                        ]
                    )
                }
                Result.Err(mcpLibraryError(error))
        }
    }

    public func openSubscription(request: JsonRpcRequest): Result<McpSubscriptionHandle> {
        mapMcpResult(primitive.openSubscription(request))
    }

    public func notify(notification: JsonRpcNotification): Result<Unit> {
        match (primitive.notify(notification)) {
            case library.McpResult.Ok(_) => Result.Ok(())
            case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
        }
    }

    public func cancel(requestId: JsonRpcId, reason: String, meta: McpRequestMeta): Result<Unit> {
        match (primitive.cancel(requestId, reason, meta)) {
            case library.McpResult.Ok(_) => Result.Ok(())
            case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
        }
    }
    public func registerTools(tools: Array<McpTool>): Result<Unit> {
        mapMcpResult(primitive.registerTools(tools))
    }

    public func stderrSnapshot(): String { primitive.stderrSnapshot() }

    public func close(): Result<Unit> {
        match (primitive.close()) {
            case library.McpResult.Ok(_) => Result.Ok(())
            case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
        }
    }
}

public func openStdioMcpTransport(
    config: McpStdioTransportConfig
): Result<StdioMcpTransport> {
    let environment = match (stdioEnvironment(config)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let primitiveConfig = library.McpStdioConfig(
        config.command,
        arguments: config.arguments,
        cwd: config.cwd,
        environment: environment,
        framing: config.framing
    )
    match (library.openStdioMcpTransport(primitiveConfig)) {
        case library.McpResult.Ok(value) => Result.Ok(StdioMcpTransport(value))
        case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
    }
}

public class StdioMcpServer {
    private let primitive: library.StdioMcpServer
    public init(server: McpServer, framing!: McpFramingConfig = McpFramingConfig()) {
        primitive = library.StdioMcpServer(server.libraryServer(), framing: framing)
    }
    public func state(): McpLifecycleState { primitive.state() }
    public func serveConsole(): Result<Unit> { mapMcpResult(primitive.serve(getStdIn(), getStdOut())) }
    public func close(): Result<Unit> { mapMcpResult(primitive.close()) }
}

func stdioEnvironment(config: McpStdioTransportConfig): Result<HashMap<String, String>> {
    let result = HashMap<String, String>()
    let variables = getVariables()
    for (binding in config.environment) {
        var found = false
        for ((name, value) in variables where name == binding.source) {
            result[binding.target] = value
            found = true
            break
        }
        if (!found) {
            return stdioFailure<HashMap<String, String>>(
                AgentErrorKind.Configuration,
                "mcp.stdio_environment_missing",
                "required MCP stdio environment variable is unavailable",
                fields: [ErrorField("environment", binding.source)]
            )
        }
    }
    Result.Ok(result)
}

func mcpLibraryError(error: library.McpError): AgentError {
    let fields = ArrayList<ErrorField>()
    fields.add(ErrorField("mcp_error_kind", mcpLibraryErrorKindName(error.kind)))
    fields.add(ErrorField("retryable", error.retryable.toString()))
    fields.add(ErrorField("retry_safe", error.retrySafe.toString()))
    match (error.rpcCode) {
        case Some(value) => fields.add(ErrorField("json_rpc_code", value.toString()))
        case None => ()
    }
    match (error.httpStatus) {
        case Some(value) => fields.add(ErrorField("http_status", value.toString()))
        case None => ()
    }
    if (error.remoteCode != "") {
        fields.add(ErrorField("remote_code", error.remoteCode))
    }
    if (error.data.unifiedKind == ValueKind.Object) {
        var accepted: Int64 = 0
        for (field in error.data.fields) {
            if (accepted >= 32 || isMcpEnvelopeField(field.name)) { continue }
            let value: ?String = match (field.value.unifiedKind) {
                case ValueKind.Text => Some(field.value.text)
                case ValueKind.Number => Some(field.value.number)
                case ValueKind.Boolean => Some(if (field.value.boolean) { "true" } else { "false" })
                case _ => None<String>
            }
            match (value) {
                case Some(text) => if (text.size <= 4096) {
                    fields.add(ErrorField(field.name, text)); accepted++
                }
                case None => ()
            }
        }
    }
    AgentError(
        match (error.kind) {
            case library.McpErrorKind.Protocol => AgentErrorKind.Protocol
            case library.McpErrorKind.Transport =>
                if (!error.retrySafe &&
                    (error.code.contains("call") || error.code.contains("response_lost"))) {
                    AgentErrorKind.RecoveryRequired
                } else {
                    AgentErrorKind.Transport
                }
            case library.McpErrorKind.Lifecycle => AgentErrorKind.Conflict
            case library.McpErrorKind.Authentication => AgentErrorKind.Authentication
            case library.McpErrorKind.Authorization => AgentErrorKind.PermissionDenied
            case library.McpErrorKind.Remote => AgentErrorKind.Provider
            case library.McpErrorKind.Cancelled => AgentErrorKind.Cancelled
            case library.McpErrorKind.Deadline => AgentErrorKind.Timeout
        },
        error.code,
        error.message,
        fields: fields.toArray()
    )
}

func isMcpEnvelopeField(name: String): Bool {
    name == "code" || name == "mcp_error_kind" || name == "retryable" ||
        name == "retry_safe" || name == "json_rpc_code" ||
        name == "http_status" || name == "remote_code"
}

func mcpLibraryErrorKindName(kind: library.McpErrorKind): String {
    match (kind) {
        case library.McpErrorKind.Protocol => "protocol"
        case library.McpErrorKind.Transport => "transport"
        case library.McpErrorKind.Lifecycle => "lifecycle"
        case library.McpErrorKind.Authentication => "authentication"
        case library.McpErrorKind.Authorization => "authorization"
        case library.McpErrorKind.Remote => "remote"
        case library.McpErrorKind.Cancelled => "cancelled"
        case library.McpErrorKind.Deadline => "deadline"
    }
}

func stdioFailure<T>(
    kind: AgentErrorKind,
    code: String,
    message: String,
    fields!: Array<ErrorField> = []
): Result<T> {
    Result.Err(AgentError(kind, code, message, fields: fields))
}
