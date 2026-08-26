package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import std.collection.*
import std.convert.*
import std.sync.*

class McpActiveRequest {
    let owner: String
    let id: JsonRpcId
    init(owner: String, id: JsonRpcId) { this.owner = owner; this.id = id }
}

// Generic MCP protocol client. Transport delivery, correlation and lifecycle
// live here; callers decide authorization, retry and durable operation policy.
public class McpClient {
    private let transport: McpTransport
    private let meta: McpRequestMeta
    private let correlation = JsonRpcCorrelation()
    private let directoryCache = McpToolDirectoryCache()
    private let lifecycle = McpLifecycle()
    private let lock = Mutex()
    private let active = ArrayList<McpActiveRequest>()
    private let knownTools = ArrayList<McpTool>()
    private var sequence: Int64 = 0

    public init(transport: McpTransport, meta: McpRequestMeta) {
        this.transport = transport
        this.meta = meta
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
    }

    public func state(): McpLifecycleState { lifecycle.state() }
    public func pendingCount(): Int64 { correlation.pendingCount() }

    public func discover(): McpResult<McpDiscoverResult> {
        match (send(MCP_METHOD_DISCOVER, jsonObject([]))) {
            case McpResult.Ok(value) => decodeMcpDiscover(value)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func ping(): McpResult<Unit> {
        match (send(MCP_METHOD_PING, jsonObject([]))) {
            case McpResult.Ok(value) =>
                if (mcpText(value, "resultType") == MCP_RESULT_COMPLETE) { McpResult.Ok(()) }
                else { invalidMcp<Unit>("mcp.ping_result_invalid", "ping result must be complete") }
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func listTools(cursor!: String = ""): McpResult<McpToolListPage> {
        let fields = ArrayList<JsonObjectEntry>()
        if (cursor != "") { fields.add(JsonObjectEntry("cursor", jsonString(cursor))) }
        match (send(MCP_METHOD_TOOLS_LIST, jsonObject(fields.toArray()))) {
            case McpResult.Ok(value) => match (decodeMcpToolPage(value)) {
                case McpResult.Ok(page) => rememberTools(page.tools); McpResult.Ok(page)
                case McpResult.Err(error) => McpResult.Err(error)
            }
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func toolDirectory(
        nowMillis: Int64,
        forceRefresh!: Bool = false
    ): McpResult<McpToolDirectorySnapshot> {
        if (!forceRefresh) {
            match (directoryCache.fresh(nowMillis)) {
                case Some(value) => return McpResult.Ok(value)
                case None => ()
            }
        }
        let tools = ArrayList<McpTool>()
        let cursors = ArrayList<String>()
        var cursor = ""
        var ttl: Int64 = -1
        var scope = ""
        var pages: Int64 = 0
        while (true) {
            pages++
            if (pages > 1024) {
                return invalidMcp<McpToolDirectorySnapshot>(
                    "mcp.tool_directory_page_limit", "tools/list exceeded the page limit"
                )
            }
            let page = match (listTools(cursor: cursor)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            if (ttl < 0) { ttl = page.ttlMillis; scope = page.cacheScope }
            else if (ttl != page.ttlMillis || scope != page.cacheScope) {
                return invalidMcp<McpToolDirectorySnapshot>(
                    "mcp.tool_directory_metadata_changed",
                    "tools/list changed cache metadata during pagination"
                )
            }
            for (tool in page.tools) { tools.add(tool) }
            if (page.nextCursor == "") { break }
            for (seen in cursors where seen == page.nextCursor) {
                return invalidMcp<McpToolDirectorySnapshot>(
                    "mcp.tool_directory_cursor_repeated", "tools/list repeated a cursor"
                )
            }
            cursors.add(page.nextCursor)
            cursor = page.nextCursor
        }
        let finalPage = McpToolListPage(tools.toArray(), ttlMillis: ttl, cacheScope: scope)
        let snapshot = McpToolDirectorySnapshot(finalPage, nowMillis)
        directoryCache.store(snapshot)
        McpResult.Ok(snapshot)
    }

    public func invalidateToolDirectory(): Unit {
        directoryCache.invalidate()
        lock.lock(); try { knownTools.clear() } finally { lock.unlock() }
    }

    public func callTool(
        name: String,
        arguments: JsonNode,
        continuation!: McpToolCallContinuation = McpToolCallContinuation(),
        owner!: String = ""
    ): McpResult<McpCallToolOutcome> {
        if (name.trimAscii() == "" || arguments.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<McpCallToolOutcome>(
                "mcp.call_invalid", "MCP tool call requires a name and object arguments"
            )
        }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("name", jsonString(name)))
        fields.add(JsonObjectEntry("arguments", arguments))
        if (!continuation.inputResponses.fields.isEmpty()) {
            fields.add(JsonObjectEntry("inputResponses", continuation.inputResponses))
        }
        if (continuation.requestState != "") {
            fields.add(JsonObjectEntry("requestState", jsonString(continuation.requestState)))
        }
        match (send(MCP_METHOD_TOOLS_CALL, jsonObject(fields.toArray()), owner: owner)) {
            case McpResult.Ok(value) => decodeMcpCallOutcome(value, knownTool(name))
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func retryToolCall(
        name: String,
        arguments: JsonNode,
        pending: McpInputRequiredResult,
        inputResponses: JsonNode,
        owner!: String = ""
    ): McpResult<McpCallToolOutcome> {
        match (validateMcpInputResponses(pending, inputResponses)) {
            case McpResult.Ok(_) => callTool(
                name, arguments,
                continuation: McpToolCallContinuation(
                    inputResponses: inputResponses, requestState: pending.requestState
                ),
                owner: owner
            )
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func notify(method: String, params!: JsonNode = jsonObject([])): McpResult<Unit> {
        if (state() != McpLifecycleState.Ready) {
            return lifecycleFailure<Unit>("mcp.client_not_ready", "MCP client is not ready")
        }
        transport.notify(JsonRpcNotification(method, params: withMcpRequestMeta(params, meta)))
    }

    public func cancel(owner: String, reason!: String = "cancelled by caller"): McpResult<Unit> {
        match (activeRequestId(owner)) {
            case Some(id) =>
                let _ = correlation.cancel(id)
                transport.cancel(id, reason)
            case None => McpResult.Ok(())
        }
    }

    public func activeRequestId(owner: String): ?JsonRpcId {
        lock.lock()
        try { for (item in active where item.owner == owner) { return Some(item.id) }; None }
        finally { lock.unlock() }
    }

    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        let ids = activeSnapshot()
        for (id in ids) { let _ = correlation.cancel(id); let _ = correlation.release(id) }
        clearActive()
        match (transport.close()) {
            case McpResult.Ok(_) => let _ = lifecycle.transition(McpLifecycleState.Stopped); McpResult.Ok(())
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    private func send(method: String, params: JsonNode, owner!: String = ""): McpResult<JsonNode> {
        if (state() != McpLifecycleState.Ready) {
            return lifecycleFailure<JsonNode>("mcp.client_not_ready", "MCP client is not ready")
        }
        let id = nextRequestId()
        match (correlation.reserve(id)) {
            case JsonRpcResult.Ok(_) => ()
            case JsonRpcResult.Err(error) => return invalidMcp<JsonNode>(error.code, error.message)
        }
        if (owner != "") { addActive(owner, id) }
        let response = transport.request(JsonRpcRequest(id, method, params: withMcpRequestMeta(params, meta)))
        if (owner != "") { removeActive(owner, id) }
        match (response) {
            case McpResult.Err(error) =>
                let _ = correlation.cancel(id); let _ = correlation.release(id); McpResult.Err(error)
            case McpResult.Ok(value) =>
                if (!sameJsonRpcId(id, value.id)) {
                    let _ = correlation.cancel(id); let _ = correlation.release(id)
                    return invalidMcp<JsonNode>(
                        "mcp.response_id_mismatch", "MCP response id does not match request"
                    )
                }
                match (correlation.state(id)) {
                    case Some(JsonRpcPendingState.Cancelled) =>
                        let _ = correlation.release(id)
                        return McpResult.Err(McpError(
                            McpErrorKind.Cancelled, "mcp.request_cancelled", "MCP request was cancelled"
                        ))
                    case _ => ()
                }
                let _ = correlation.complete(id)
                let result = match (value.payload) {
                    case JsonRpcResponsePayload.Success(result) => validateMcpResult(result)
                    case JsonRpcResponsePayload.Failure(error) => remoteMcpError<JsonNode>(error)
                }
                let _ = correlation.release(id)
                result
        }
    }

    private func nextRequestId(): JsonRpcId {
        lock.lock(); try { sequence++; jsonRpcNumberId(sequence) } finally { lock.unlock() }
    }
    private func addActive(owner: String, id: JsonRpcId): Unit {
        lock.lock(); try { active.add(McpActiveRequest(owner, id)) } finally { lock.unlock() }
    }
    private func removeActive(owner: String, id: JsonRpcId): Unit {
        lock.lock(); try {
            for (index in 0..active.size) {
                if (active[index].owner == owner && sameJsonRpcId(active[index].id, id)) {
                    active.remove(at: index); return
                }
            }
        } finally { lock.unlock() }
    }
    private func activeSnapshot(): Array<JsonRpcId> {
        lock.lock(); try { let ids = ArrayList<JsonRpcId>(); for (item in active) { ids.add(item.id) }; ids.toArray() }
        finally { lock.unlock() }
    }
    private func clearActive(): Unit { lock.lock(); try { active.clear() } finally { lock.unlock() } }
    private func rememberTools(values: Array<McpTool>): Unit {
        lock.lock(); try {
            for (tool in values) {
                var found = false
                for (index in 0..knownTools.size where knownTools[index].name == tool.name) {
                    knownTools[index] = tool; found = true; break
                }
                if (!found) { knownTools.add(tool) }
            }
        } finally { lock.unlock() }
    }
    private func knownTool(name: String): ?McpTool {
        lock.lock(); try { for (tool in knownTools where tool.name == name) { return Some(tool) }; None }
        finally { lock.unlock() }
    }
}

func withMcpRequestMeta(params: JsonNode, meta: McpRequestMeta): JsonNode {
    let fields = ArrayList<JsonObjectEntry>()
    if (params.unifiedKind == UnifiedJsonKind.Object) {
        for (field in params.fields where field.name != "_meta") { fields.add(field) }
    }
    fields.add(JsonObjectEntry("_meta", meta.toValue()))
    jsonObject(fields.toArray())
}

func validateMcpResult(value: JsonNode): McpResult<JsonNode> {
    if (value.unifiedKind != UnifiedJsonKind.Object || mcpText(value, "resultType") == "") {
        return invalidMcp<JsonNode>("mcp.result_invalid", "MCP result must be an object with resultType")
    }
    match (mcpServerInfo(value)) {
        case McpResult.Ok(_) => McpResult.Ok(value)
        case McpResult.Err(error) => McpResult.Err(error)
    }
}

func mcpServerInfo(value: JsonNode): McpResult<McpImplementationInfo> {
    let meta = match (value.field("_meta")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Object) { item } else {
            return invalidMcp<McpImplementationInfo>("mcp.result_meta_invalid", "MCP result _meta must be an object")
        }
        case None => return invalidMcp<McpImplementationInfo>("mcp.result_meta_missing", "MCP result omitted _meta")
    }
    match (meta.field(MCP_META_SERVER_INFO)) {
        case Some(item) => decodeMcpImplementationInfo(item)
        case None => invalidMcp<McpImplementationInfo>("mcp.server_info_missing", "MCP result omitted serverInfo")
    }
}

func decodeMcpDiscover(value: JsonNode): McpResult<McpDiscoverResult> {
    if (mcpText(value, "resultType") != MCP_RESULT_COMPLETE) {
        return invalidMcp<McpDiscoverResult>("mcp.discover_invalid", "server/discover result must be complete")
    }
    let versionsValue = match (value.field("supportedVersions")) {
        case Some(item) => item
        case None => return invalidMcp<McpDiscoverResult>("mcp.discover_versions_missing", "server/discover omitted supportedVersions")
    }
    if (versionsValue.unifiedKind != UnifiedJsonKind.List || versionsValue.items.isEmpty()) {
        return invalidMcp<McpDiscoverResult>("mcp.discover_versions_invalid", "supportedVersions must be a non-empty array")
    }
    let versions = ArrayList<String>(); var current = false
    for (item in versionsValue.items) {
        if (item.unifiedKind != UnifiedJsonKind.Text || item.text == "") {
            return invalidMcp<McpDiscoverResult>("mcp.discover_versions_invalid", "supportedVersions contains an invalid version")
        }
        versions.add(item.text); if (item.text == MCP_PROTOCOL_VERSION) { current = true }
    }
    if (!current) { return invalidMcp<McpDiscoverResult>("mcp.version_unsupported", "server does not support requested protocol version") }
    let info = match (mcpServerInfo(value)) {
        case McpResult.Ok(found) => found
        case McpResult.Err(error) => return McpResult.Err(error)
    }
    let capabilities = match (value.field("capabilities")) {
        case Some(item) => item
        case None => return invalidMcp<McpDiscoverResult>("mcp.capabilities_missing", "server/discover omitted capabilities")
    }
    if (capabilities.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpDiscoverResult>("mcp.capabilities_invalid", "server capabilities must be an object")
    }
    var tools = false; var changed = false
    match (capabilities.field("tools")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Object) { tools = true; changed = mcpBool(item, "listChanged", false) }
        case None => ()
    }
    let ttl = mcpInteger(value, "ttlMs"); let scope = mcpText(value, "cacheScope")
    if (ttl < 0 || !validMcpCacheScope(scope)) {
        return invalidMcp<McpDiscoverResult>("mcp.cache_metadata_invalid", "server/discover cache metadata is invalid")
    }
    try { McpResult.Ok(McpDiscoverResult(
        info, capabilities: McpServerCapabilities(tools: tools, toolListChanged: changed),
        instructions: mcpText(value, "instructions"), supportedVersions: versions.toArray(),
        ttlMillis: ttl, cacheScope: scope
    )) } catch (error: Exception) { invalidMcp<McpDiscoverResult>("mcp.discover_invalid", error.message) }
}

func decodeMcpImplementationInfo(value: JsonNode): McpResult<McpImplementationInfo> {
    if (value.unifiedKind != UnifiedJsonKind.Object || mcpText(value, "name") == "" || mcpText(value, "version") == "") {
        return invalidMcp<McpImplementationInfo>("mcp.implementation_info_invalid", "implementation info requires name and version")
    }
    McpResult.Ok(McpImplementationInfo(mcpText(value, "name"), mcpText(value, "version"), title: mcpText(value, "title")))
}

public func decodeMcpToolPage(value: JsonNode): McpResult<McpToolListPage> {
    if (mcpText(value, "resultType") != MCP_RESULT_COMPLETE) {
        return invalidMcp<McpToolListPage>("mcp.tool_page_invalid", "tools/list result must be complete")
    }
    let source = match (value.field("tools")) {
        case Some(item) => item
        case None => return invalidMcp<McpToolListPage>("mcp.tools_missing", "tools/list omitted tools")
    }
    if (source.unifiedKind != UnifiedJsonKind.List) { return invalidMcp<McpToolListPage>("mcp.tools_invalid", "tools must be an array") }
    let tools = ArrayList<McpTool>()
    for (item in source.items) { match (decodeMcpTool(item)) {
        case McpResult.Ok(tool) => tools.add(tool)
        case McpResult.Err(error) => return McpResult.Err(error)
    } }
    let ttl = mcpInteger(value, "ttlMs"); let scope = mcpText(value, "cacheScope")
    if (ttl < 0 || !validMcpCacheScope(scope)) { return invalidMcp<McpToolListPage>("mcp.cache_metadata_invalid", "tools/list cache metadata is invalid") }
    McpResult.Ok(McpToolListPage(tools.toArray(), nextCursor: mcpText(value, "nextCursor"), ttlMillis: ttl, cacheScope: scope))
}

func decodeMcpTool(value: JsonNode): McpResult<McpTool> {
    if (value.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<McpTool>("mcp.tool_invalid", "tool descriptor must be an object") }
    let schema = match (value.field("inputSchema")) { case Some(item) => item; case None => jsonNull() }
    if (mcpText(value, "name") == "" || schema.unifiedKind != UnifiedJsonKind.Object || mcpText(schema, "type") != "object") {
        return invalidMcp<McpTool>("mcp.tool_invalid", "tool has invalid name or inputSchema")
    }
    try { McpResult.Ok(McpTool(
        mcpText(value, "name"), mcpText(value, "description"), schema,
        outputSchema: mcpField(value, "outputSchema", jsonNull()),
        annotations: mcpObject(value, "annotations"), meta: mcpObject(value, "_meta")
    )) } catch (error: Exception) { invalidMcp<McpTool>("mcp.tool_invalid", error.message) }
}

func decodeMcpCallOutcome(value: JsonNode, tool: ?McpTool): McpResult<McpCallToolOutcome> {
    let resultType = mcpText(value, "resultType")
    if (resultType == MCP_RESULT_COMPLETE) {
            let content = mcpField(value, "content", jsonNull())
            if (content.unifiedKind != UnifiedJsonKind.List) { return invalidMcp<McpCallToolOutcome>("mcp.call_content_invalid", "tools/call content must be an array") }
            for (block in content.items where block.unifiedKind != UnifiedJsonKind.Object) {
                return invalidMcp<McpCallToolOutcome>("mcp.call_content_invalid", "content block must be an object")
            }
            let structured = mcpField(value, "structuredContent", jsonNull())
            match (tool) {
                case Some(descriptor) => if (descriptor.outputSchema.unifiedKind != UnifiedJsonKind.Null && !mcpBool(value, "isError", false) && structured.unifiedKind == UnifiedJsonKind.Null) {
                    return invalidMcp<McpCallToolOutcome>("mcp.structured_content_missing", "tools/call omitted structuredContent")
                }
                case None => ()
            }
            McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                content.items, structuredContent: structured,
                isError: mcpBool(value, "isError", false), meta: mcpObject(value, "_meta")
            )))
    } else if (resultType == MCP_RESULT_INPUT_REQUIRED) {
        try { McpResult.Ok(McpCallToolOutcome.InputRequired(McpInputRequiredResult(
            inputRequests: mcpObject(value, "inputRequests"),
            requestState: mcpText(value, "requestState"), meta: mcpObject(value, "_meta")
        ))) } catch (error: Exception) { invalidMcp<McpCallToolOutcome>("mcp.input_required_invalid", error.message) }
    } else {
        invalidMcp<McpCallToolOutcome>("mcp.call_result_invalid", "tools/call returned unsupported resultType")
    }
}

func validateMcpInputResponses(pending: McpInputRequiredResult, responses: JsonNode): McpResult<Unit> {
    if (responses.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<Unit>("mcp.input_responses_invalid", "inputResponses must be an object") }
    for (request in pending.inputRequests.fields) { match (responses.field(request.name)) {
        case Some(value) => if (value.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<Unit>("mcp.input_response_invalid", "input response must be an object") }
        case None => return invalidMcp<Unit>("mcp.input_response_missing", "retry must answer every input request")
    } }
    for (response in responses.fields where pending.inputRequests.field(response.name).isNone()) {
        return invalidMcp<Unit>("mcp.input_response_unknown", "retry contains an unknown input response")
    }
    McpResult.Ok(())
}

func remoteMcpError<T>(error: JsonRpcError): McpResult<T> {
    var remoteCode = ""
    if (error.data.unifiedKind == UnifiedJsonKind.Object) {
        match (error.data.field("code")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Text) { remoteCode = value.text }
            case None => ()
        }
    }
    let code = if (remoteCode != "") { remoteCode }
        else if (error.code == JSON_RPC_METHOD_NOT_FOUND) { "mcp.method_not_found" }
        else if (error.code == JSON_RPC_INVALID_PARAMS) { "mcp.invalid_params" }
        else { "mcp.remote_protocol_error" }
    McpResult.Err(McpError(
        McpErrorKind.Remote,
        code,
        error.message,
        rpcCode: Some(error.code),
        remoteCode: remoteCode,
        data: error.data
    ))
}

func invalidMcp<T>(code: String, message: String): McpResult<T> {
    McpResult.Err(McpError(McpErrorKind.Protocol, code, message))
}
func lifecycleFailure<T>(code: String, message: String): McpResult<T> {
    McpResult.Err(McpError(McpErrorKind.Lifecycle, code, message))
}
func mcpText(value: JsonNode, name: String): String { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }; case None => "" } }
func mcpBool(value: JsonNode, name: String, fallback: Bool): Bool { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Boolean) { item.boolean } else { fallback }; case None => fallback } }
func mcpInteger(value: JsonNode, name: String): Int64 { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) { try { Int64.parse(item.number) } catch (_: Exception) { -1 } } else { -1 }; case None => -1 } }
func mcpField(value: JsonNode, name: String, fallback: JsonNode): JsonNode { match (value.field(name)) { case Some(item) => item; case None => fallback } }
func mcpObject(value: JsonNode, name: String): JsonNode { let found = mcpField(value, name, jsonObject([])); if (found.unifiedKind == UnifiedJsonKind.Object) { found } else { jsonObject([]) } }
