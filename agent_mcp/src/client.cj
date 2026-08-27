package agent_mcp

import yjson_support.*

import agent_domain.*
import agent_protocol.*
import mcp4cj as library
import std.collection.*
import std.convert.*

// Product compatibility facade. All MCP correlation, pagination and lifecycle
// state is owned by mcp4cj; this class only maps library errors to AgentError.
public class McpClient {
    private let primitive: library.McpClient

    public init(transport: McpTransport, meta: McpRequestMeta) {
        primitive = library.McpClient(McpTransportBridge(transport), meta)
    }

    public func state(): McpLifecycleState { primitive.state() }

    public func discover(): Result<McpDiscoverResult> { mapMcpResult(primitive.discover()) }
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

    public func complete(
        reference: AgentValue, argument: AgentValue,
        continuation!: McpToolCallContinuation = McpToolCallContinuation(), runId!: String = ""
    ): Result<McpOperationOutcome<McpCompletionResult>> {
        mapMcpResult(primitive.complete(reference, argument, continuation: continuation, owner: runId))
    }
    public func listPrompts(cursor!: String = ""): Result<McpPage> {
        mapMcpResult(primitive.listPrompts(cursor: cursor))
    }
    public func getPrompt(
        name: String, arguments!: AgentValue = objectValue([]),
        continuation!: McpToolCallContinuation = McpToolCallContinuation(), runId!: String = ""
    ): Result<McpOperationOutcome<McpPromptResult>> {
        mapMcpResult(primitive.getPrompt(name, arguments: arguments, continuation: continuation, owner: runId))
    }
    public func listResources(cursor!: String = ""): Result<McpPage> {
        mapMcpResult(primitive.listResources(cursor: cursor))
    }
    public func listResourceTemplates(cursor!: String = ""): Result<McpPage> {
        mapMcpResult(primitive.listResourceTemplates(cursor: cursor))
    }
    public func readResource(
        uri: String, continuation!: McpToolCallContinuation = McpToolCallContinuation(), runId!: String = ""
    ): Result<McpOperationOutcome<McpReadResourceResult>> {
        mapMcpResult(primitive.readResource(uri, continuation: continuation, owner: runId))
    }
    public func listen(filter: McpSubscriptionFilter): Result<McpSubscriptionHandle> {
        mapMcpResult(primitive.listen(filter))
    }
    public func getTask(taskId: String, runId!: String = ""): Result<McpTask> {
        mapMcpResult(primitive.getTask(taskId, owner: runId))
    }
    public func updateTask(taskId: String, responses: AgentValue, runId!: String = ""): Result<Unit> {
        mapMcpResult(primitive.updateTask(taskId, responses, owner: runId))
    }
    public func cancelTask(taskId: String, runId!: String = ""): Result<Unit> {
        mapMcpResult(primitive.cancelTask(taskId, owner: runId))
    }

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
    public func openSubscription(request: JsonRpcRequest): library.McpResult<library.McpSubscriptionHandle> {
        unmapMcpResult(product.openSubscription(request))
    }
    public func notify(notification: JsonRpcNotification): library.McpResult<Unit> {
        unmapMcpResult(product.notify(notification))
    }
    public func cancel(requestId: JsonRpcId, reason: String): library.McpResult<Unit> {
        unmapMcpResult(product.cancel(
            requestId, reason,
            McpRequestMeta(clientInfo: McpImplementationInfo("Axyndra-adapter", "1"))
        ))
    }
    public func registerTools(tools: Array<McpTool>): library.McpResult<Unit> {
        unmapMcpResult(product.registerTools(tools))
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
        if (isMcpEnvelopeField(field.name)) { continue }
        dataFields.add(ValueField(field.name, textValue(field.value)))
    }
    library.McpError(
        kind,
        error.code,
        error.message,
        retryable: error.retryable,
        retrySafe: agentMcpRetrySafe(error),
        rpcCode: agentMcpIntegerField(error, "json_rpc_code"),
        httpStatus: agentMcpIntegerField(error, "http_status"),
        remoteCode: error.field("remote_code") ?? error.code,
        data: objectValue(dataFields.toArray())
    )
}

func agentMcpRetrySafe(error: AgentError): Bool {
    match (error.field("retry_safe")) {
        case Some("true") => true
        case Some("false") => false
        case _ => error.kind != AgentErrorKind.RecoveryRequired
    }
}

func agentMcpIntegerField(error: AgentError, name: String): ?Int64 {
    match (error.field(name)) {
        case Some(value) => try { Some(Int64.parse(value)) } catch (_: Exception) { None<Int64> }
        case None => None<Int64>
    }
}
