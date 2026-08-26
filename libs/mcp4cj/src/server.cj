package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import std.collection.*
import std.convert.*
import std.sync.*

public interface McpToolHost {
    func listTools(cursor: String): McpResult<McpToolListPage>
    func callTool(
        requestId: JsonRpcId,
        name: String,
        arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpCallToolOutcome>
    func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit>
}

// Generic MCP protocol dispatcher. The host callback is the sole execution
// boundary; this class has no knowledge of product tools or authorization.
public class McpServer {
    private let discovery: McpDiscoverResult
    private let host: McpToolHost
    private let lifecycle = McpLifecycle()

    public init(discovery: McpDiscoverResult, host: McpToolHost) {
        this.discovery = discovery
        this.host = host
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
    }

    public func state(): McpLifecycleState { lifecycle.state() }

    public func handleRequest(request: JsonRpcRequest): JsonRpcResponse {
        if (state() != McpLifecycleState.Ready) {
            return mcpFailureResponse(request.id, JSON_RPC_INTERNAL_ERROR, "MCP server is closed")
        }
        match (validateMcpRequestMeta(request.params)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => return mcpFailureResponse(
                request.id,
                if (error.code == "mcp.version_unsupported") { MCP_UNSUPPORTED_PROTOCOL_VERSION } else { JSON_RPC_INVALID_PARAMS },
                error.message
            )
        }
        if (request.method == MCP_METHOD_DISCOVER) {
            mcpSuccessResponse(request.id, discovery.toValue(), discovery.serverInfo)
        } else if (request.method == MCP_METHOD_PING) {
            mcpSuccessResponse(
                request.id,
                jsonObject([JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE))]),
                discovery.serverInfo
            )
        } else if (request.method == MCP_METHOD_TOOLS_LIST) {
            match (host.listTools(mcpText(request.params, "cursor"))) {
                case McpResult.Ok(page) => mcpSuccessResponse(request.id, page.toValue(), discovery.serverInfo)
                case McpResult.Err(error) => mcpHostFailure(request.id, error)
            }
        } else if (request.method == MCP_METHOD_TOOLS_CALL) {
            handleToolCall(request)
        } else {
            mcpFailureResponse(request.id, JSON_RPC_METHOD_NOT_FOUND, "MCP method not found: " + request.method)
        }
    }

    public func handleNotification(notification: JsonRpcNotification): McpResult<Unit> {
        if (state() != McpLifecycleState.Ready) {
            return lifecycleFailure<Unit>("mcp.server_closed", "MCP server is closed")
        }
        if (notification.method != MCP_METHOD_CANCELLED) { return McpResult.Ok(()) }
        if (notification.params.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<Unit>("mcp.cancel_params_invalid", "cancellation params must be an object")
        }
        let id = match (notification.params.field("requestId")) {
            case Some(value) => match (decodeMcpRequestId(value)) {
                case McpResult.Ok(found) => found
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            case None => return invalidMcp<Unit>("mcp.cancel_id_missing", "cancellation requires requestId")
        }
        host.cancel(id, mcpText(notification.params, "reason"))
    }

    public func handle(envelope: JsonRpcEnvelope): McpResult<?JsonRpcEnvelope> {
        match (envelope) {
            case JsonRpcEnvelope.Request(request) => McpResult.Ok(Some(JsonRpcEnvelope.Response(handleRequest(request))))
            case JsonRpcEnvelope.Notification(notification) => match (handleNotification(notification)) {
                case McpResult.Ok(_) => McpResult.Ok(None)
                case McpResult.Err(error) => McpResult.Err(error)
            }
            case JsonRpcEnvelope.Response(_) => invalidMcp<?JsonRpcEnvelope>(
                "mcp.server_unexpected_response", "MCP server cannot dispatch a response as a request"
            )
        }
    }

    public func tool(name: String): McpResult<?McpTool> { findTool(name) }

    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        let _ = lifecycle.transition(McpLifecycleState.Stopped)
        McpResult.Ok(())
    }

    private func handleToolCall(request: JsonRpcRequest): JsonRpcResponse {
        let name = mcpText(request.params, "name")
        if (name == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tools/call requires name") }
        let arguments = mcpField(request.params, "arguments", jsonObject([]))
        if (arguments.unifiedKind != UnifiedJsonKind.Object) {
            return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tools/call arguments must be an object")
        }
        let continuation = match (decodeMcpContinuation(request.params)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return mcpHostFailure(request.id, error)
        }
        let tool = match (findTool(name)) {
            case McpResult.Ok(Some(found)) => found
            case McpResult.Ok(None) => return mcpFailureResponse(
                request.id, JSON_RPC_INVALID_PARAMS, "MCP tool was not found",
                data: jsonObject([JsonObjectEntry("tool", jsonString(name))])
            )
            case McpResult.Err(error) => return mcpHostFailure(request.id, error)
        }
        match (validateUnifiedJsonSchema(tool.inputSchema, arguments)) {
            case Some(error) => return mcpFailureResponse(
                request.id, JSON_RPC_INVALID_PARAMS, "MCP tool arguments violate inputSchema",
                data: jsonObject([
                    JsonObjectEntry("code", jsonString("mcp.invalid_params")),
                    JsonObjectEntry("path", jsonString(error.path)),
                    JsonObjectEntry("keyword", jsonString(error.keyword))
                ])
            )
            case None => ()
        }
        match (host.callTool(request.id, name, arguments, continuation)) {
            case McpResult.Ok(outcome) => mcpSuccessResponse(
                request.id, mcpCallToolOutcomeValue(outcome), discovery.serverInfo
            )
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func findTool(name: String): McpResult<?McpTool> {
        let cursors = ArrayList<String>(); var cursor = ""; var pages: Int64 = 0
        while (true) {
            pages++
            if (pages > 1024) { return invalidMcp<?McpTool>("mcp.tool_directory_page_limit", "tool directory exceeded page limit") }
            let page = match (host.listTools(cursor)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            for (tool in page.tools where tool.name == name) { return McpResult.Ok(Some(tool)) }
            if (page.nextCursor == "") { return McpResult.Ok(None) }
            for (seen in cursors where seen == page.nextCursor) {
                return invalidMcp<?McpTool>("mcp.tool_directory_cursor_repeated", "tool directory repeated cursor")
            }
            cursors.add(page.nextCursor); cursor = page.nextCursor
        }
        McpResult.Ok(None)
    }
}

public type McpToolHandler = (
    String, JsonNode, McpToolCallContinuation
) -> McpResult<McpCallToolOutcome>

public class MemoryMcpToolHost <: McpToolHost {
    private let tools: Array<McpTool>
    private let handler: McpToolHandler
    private let generation: Int64
    private let pageSize: Int64
    private let ttlMillis: Int64
    private let cacheScope: String
    private let cancelled = ArrayList<String>()
    private let lock = Mutex()

    public init(
        tools: Array<McpTool>, handler: McpToolHandler,
        generation!: Int64 = 1, pageSize!: Int64 = 50,
        ttlMillis!: Int64 = 300000, cacheScope!: String = "private"
    ) {
        if (generation <= 0 || pageSize <= 0 || ttlMillis < 0 || !validMcpCacheScope(cacheScope)) {
            throw IllegalArgumentException("invalid memory MCP host configuration")
        }
        let sorted = ArrayList<McpTool>(tools); sortMcpTools(sorted)
        this.tools = sorted.toArray(); this.handler = handler; this.generation = generation
        this.pageSize = pageSize; this.ttlMillis = ttlMillis; this.cacheScope = cacheScope
    }

    public func listTools(cursor: String): McpResult<McpToolListPage> {
        let offset = match (decodeMcpCursor(cursor, generation)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (offset > tools.size) { return invalidMcp<McpToolListPage>("mcp.cursor_invalid", "cursor outside directory") }
        let values = ArrayList<McpTool>(); let end = min(tools.size, offset + pageSize)
        for (index in offset..end) { values.add(tools[index]) }
        McpResult.Ok(McpToolListPage(
            values.toArray(),
            nextCursor: if (end < tools.size) { generation.toString() + ":" + end.toString() } else { "" },
            ttlMillis: ttlMillis, cacheScope: cacheScope
        ))
    }

    public func callTool(
        requestId: JsonRpcId, name: String, arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpCallToolOutcome> {
        let _ = requestId
        for (tool in tools where tool.name == name) { return handler(name, arguments, continuation) }
        invalidMcp<McpCallToolOutcome>("mcp.tool_not_found", "MCP tool was not found")
    }

    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = reason
        lock.lock(); try { cancelled.add(requestId.display()) } finally { lock.unlock() }
        McpResult.Ok(())
    }
    public func cancellations(): Array<String> { lock.lock(); try { cancelled.toArray() } finally { lock.unlock() } }
}

func validateMcpRequestMeta(params: JsonNode): McpResult<Unit> {
    if (params.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<Unit>("mcp.params_invalid", "request params must be an object") }
    let meta = match (params.field("_meta")) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else {
            return invalidMcp<Unit>("mcp.meta_invalid", "request _meta must be an object")
        }
        case None => return invalidMcp<Unit>("mcp.meta_missing", "MCP request requires _meta")
    }
    if (mcpText(meta, MCP_META_PROTOCOL_VERSION) != MCP_PROTOCOL_VERSION) {
        return invalidMcp<Unit>("mcp.version_unsupported", "unsupported MCP protocol version")
    }
    match (meta.field(MCP_META_CLIENT_CAPABILITIES)) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { McpResult.Ok(()) } else {
            invalidMcp<Unit>("mcp.client_capabilities_invalid", "clientCapabilities must be an object")
        }
        case None => invalidMcp<Unit>("mcp.client_capabilities_missing", "request requires clientCapabilities")
    }
}

func mcpSuccessResponse(id: JsonRpcId, value: JsonNode, serverInfo: McpImplementationInfo): JsonRpcResponse {
    JsonRpcResponse(id, JsonRpcResponsePayload.Success(withMcpServerMeta(value, serverInfo)))
}

func withMcpServerMeta(value: JsonNode, serverInfo: McpImplementationInfo): JsonNode {
    let fields = ArrayList<JsonObjectEntry>(); var meta = jsonObject([]); var resultType = false
    if (value.unifiedKind == UnifiedJsonKind.Object) { for (field in value.fields) {
        if (field.name == "_meta") { if (field.value.unifiedKind == UnifiedJsonKind.Object) { meta = field.value } }
        else { fields.add(field); if (field.name == "resultType") { resultType = true } }
    } }
    if (!resultType) { fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE))) }
    let metadata = ArrayList<JsonObjectEntry>()
    for (field in meta.fields where field.name != MCP_META_SERVER_INFO) { metadata.add(field) }
    metadata.add(JsonObjectEntry(MCP_META_SERVER_INFO, serverInfo.toValue()))
    fields.add(JsonObjectEntry("_meta", jsonObject(metadata.toArray())))
    jsonObject(fields.toArray())
}

func mcpFailureResponse(
    id: JsonRpcId, code: Int64, message: String,
    data!: JsonNode = jsonNull()
): JsonRpcResponse {
    JsonRpcResponse(id, JsonRpcResponsePayload.Failure(JsonRpcError(code, message, data: data)))
}

func mcpHostFailure(id: JsonRpcId, error: McpError): JsonRpcResponse {
    let code = if (error.kind == McpErrorKind.Protocol) { JSON_RPC_INVALID_PARAMS } else { JSON_RPC_INTERNAL_ERROR }
    let fields = ArrayList<JsonObjectEntry>()
    fields.add(JsonObjectEntry("code", jsonString(error.code)))
    if (error.data.unifiedKind == UnifiedJsonKind.Object) {
        for (field in error.data.fields where field.name != "code") { fields.add(field) }
    }
    mcpFailureResponse(id, code, error.message, data: jsonObject(fields.toArray()))
}

func decodeMcpContinuation(params: JsonNode): McpResult<McpToolCallContinuation> {
    let responses = mcpObject(params, "inputResponses")
    for (field in responses.fields where field.value.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpToolCallContinuation>("mcp.input_response_invalid", "input response must be an object")
    }
    McpResult.Ok(McpToolCallContinuation(inputResponses: responses, requestState: mcpText(params, "requestState")))
}

func decodeMcpRequestId(value: JsonNode): McpResult<JsonRpcId> {
    try { match (value.unifiedKind) {
        case UnifiedJsonKind.Text => McpResult.Ok(jsonRpcTextId(value.text))
        case UnifiedJsonKind.Number => McpResult.Ok(JsonRpcId(JsonRpcIdKind.Number, value: value.number))
        case _ => invalidMcp<JsonRpcId>("mcp.request_id_invalid", "request id must be string or integer")
    } } catch (error: Exception) { invalidMcp<JsonRpcId>("mcp.request_id_invalid", error.message) }
}

func decodeMcpCursor(source: String, generation: Int64): McpResult<Int64> {
    if (source == "") { return McpResult.Ok(0) }
    let parts = source.split(":")
    if (parts.size != 2) { return invalidMcp<Int64>("mcp.cursor_invalid", "invalid cursor") }
    try {
        if (Int64.parse(parts[0]) != generation) { return invalidMcp<Int64>("mcp.cursor_stale", "stale cursor") }
        let offset = Int64.parse(parts[1]); if (offset < 0) { return invalidMcp<Int64>("mcp.cursor_invalid", "invalid cursor") }
        McpResult.Ok(offset)
    } catch (_: Exception) { invalidMcp<Int64>("mcp.cursor_invalid", "invalid cursor") }
}

func sortMcpTools(values: ArrayList<McpTool>): Unit {
    var index: Int64 = 1
    while (index < values.size) {
        var current = index
        while (current > 0 && values[current].name < values[current - 1].name) {
            let previous = values[current - 1]; values[current - 1] = values[current]; values[current] = previous; current--
        }
        index++
    }
}
