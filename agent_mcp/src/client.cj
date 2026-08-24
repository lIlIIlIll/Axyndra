package agent_mcp

import agent_domain.*
import agent_protocol.*
import mcp4cj as library
import std.collection.*

// Product compatibility facade. All MCP correlation, pagination and lifecycle
// state is owned by mcp4cj; this class only maps library errors to AgentError.
public class McpClient {
    private let primitive: library.McpClient

    public init(transport: McpTransport, meta: McpRequestMeta) {
        primitive = library.McpClient(McpTransportBridge(transport), meta)
    }

    public func state(): McpLifecycleState { primitive.state() }

    public func discover(): Result<McpDiscoverResult> { mapMcpResult(primitive.discover()) }
    public func ping(): Result<Unit> { mapMcpResult(primitive.ping()) }
    public func listTools(cursor!: String = ""): Result<McpToolListPage> {
        mapMcpResult(primitive.listTools(cursor: cursor))
    }
    public func toolDirectory(
        nowMillis: Int64,
        forceRefresh!: Bool = false
    ): Result<McpToolDirectorySnapshot> {
        mapMcpResult(primitive.toolDirectory(nowMillis, forceRefresh: forceRefresh))
    }
    public func invalidateToolDirectory(): Unit { primitive.invalidateToolDirectory() }

    public func callTool(
        name: String,
        arguments: AgentValue,
        continuation!: McpToolCallContinuation = McpToolCallContinuation(),
        runId!: String = ""
    ): Result<McpCallToolOutcome> {
        mapMcpResult(primitive.callTool(name, arguments, continuation: continuation, owner: runId))
    }

    public func retryToolCall(
        name: String,
        arguments: AgentValue,
        pending: McpInputRequiredResult,
        inputResponses: AgentValue,
        runId!: String = ""
    ): Result<McpCallToolOutcome> {
        mapMcpResult(primitive.retryToolCall(
            name, arguments, pending, inputResponses, owner: runId
        ))
    }

    public func cancel(runId: String, reason!: String = "cancelled by caller"): Result<Unit> {
        mapMcpResult(primitive.cancel(runId, reason: reason))
    }

    public func activeRequestId(runId: String): ?JsonRpcId { primitive.activeRequestId(runId) }
    public func close(): Result<Unit> { mapMcpResult(primitive.close()) }
}

class McpTransportBridge <: library.McpTransport {
    private let product: McpTransport
    init(product: McpTransport) { this.product = product }

    public func kind(): McpTransportKind { product.kind() }
    public func state(): McpLifecycleState { product.state() }
    public func request(request: JsonRpcRequest): library.McpResult<JsonRpcResponse> {
        unmapMcpResult(product.request(request))
    }
    public func notify(notification: JsonRpcNotification): library.McpResult<Unit> {
        unmapMcpResult(product.notify(notification))
    }
    public func cancel(requestId: JsonRpcId, reason: String): library.McpResult<Unit> {
        unmapMcpResult(product.cancel(
            requestId, reason,
            McpRequestMeta(McpImplementationInfo("Axyndra-adapter", "1"))
        ))
    }
    public func close(): library.McpResult<Unit> { unmapMcpResult(product.close()) }
}

func mapMcpResult<T>(value: library.McpResult<T>): Result<T> {
    match (value) {
        case library.McpResult.Ok(found) => Result.Ok(found)
        case library.McpResult.Err(error) => Result.Err(mcpLibraryError(error))
    }
}

func unmapMcpResult<T>(value: Result<T>): library.McpResult<T> {
    match (value) {
        case Result.Ok(found) => library.McpResult.Ok(found)
        case Result.Err(error) => library.McpResult.Err(agentMcpLibraryError(error))
    }
}

func agentMcpLibraryError(error: AgentError): library.McpError {
    let kind = match (error.kind) {
        case AgentErrorKind.Cancelled => library.McpErrorKind.Cancelled
        case AgentErrorKind.Timeout => library.McpErrorKind.Deadline
        case AgentErrorKind.Authentication => library.McpErrorKind.Authentication
        case AgentErrorKind.PermissionDenied => library.McpErrorKind.Authorization
        case AgentErrorKind.Protocol | AgentErrorKind.InvalidInput => library.McpErrorKind.Protocol
        case _ => library.McpErrorKind.Transport
    }
    let dataFields = ArrayList<ValueField>()
    dataFields.add(ValueField("code", textValue(error.code)))
    for (field in error.fields) {
        dataFields.add(ValueField(field.name, textValue(field.value)))
    }
    library.McpError(
        kind,
        error.code,
        error.message,
        retryable: error.retryable,
        retrySafe: error.kind != AgentErrorKind.RecoveryRequired,
        remoteCode: error.code,
        data: objectValue(dataFields.toArray())
    )
}
