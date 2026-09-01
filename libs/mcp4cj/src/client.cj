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

    public func listTools(cursor!: String = ""): McpResult<McpToolListPage> {
        let fields = ArrayList<JsonObjectEntry>()
        if (cursor != "") { fields.add(JsonObjectEntry("cursor", jsonString(cursor))) }
        match (send(MCP_METHOD_TOOLS_LIST, jsonObject(fields.toArray()))) {
            case McpResult.Ok(value) => match (decodeMcpToolPage(value)) {
                case McpResult.Ok(page) =>
                    rememberTools(page.tools)
                    match (transport.registerTools(page.tools)) {
                        case McpResult.Ok(_) => McpResult.Ok(page)
                        case McpResult.Err(error) => McpResult.Err(error)
                    }
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
        if (continuation.hasProgressToken()) {
            fields.add(JsonObjectEntry("_meta", jsonObject([
                JsonObjectEntry("progressToken", continuation.requestProgressToken())
            ])))
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

    public func callToolResolved(
        name: String,
        arguments: JsonNode,
        resolver: McpInputResolver,
        policy!: McpResolutionPolicy = McpResolutionPolicy(),
        progressToken!: JsonNode = jsonNull(),
        owner!: String = ""
    ): McpResult<McpCallToolOutcome> {
        var continuation = McpToolCallContinuation(progressToken: progressToken)
        var rounds: Int64 = 0
        while (true) {
            let outcome = match (callTool(name, arguments, continuation: continuation, owner: owner)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            match (outcome) {
                case McpCallToolOutcome.Complete(_) => return McpResult.Ok(outcome)
                case McpCallToolOutcome.InputRequired(pending) =>
                    rounds++
                    if (rounds > policy.maxRounds) {
                        return invalidMcp<McpCallToolOutcome>(
                            "mcp.input_resolution_limit", "MCP input resolution exceeded the configured round limit"
                        )
                    }
                    let responses = match (resolver.resolve(pending.inputRequests, pending.requestState)) {
                        case McpResult.Ok(value) => value
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                    match (validateMcpInputResponses(pending, responses)) {
                        case McpResult.Ok(_) => continuation = McpToolCallContinuation(
                            inputResponses: responses, requestState: pending.requestState,
                            progressToken: progressToken
                        )
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                case _ => return McpResult.Ok(outcome)
            }
        }
        invalidMcp<McpCallToolOutcome>("mcp.input_resolution_failed", "MCP input resolution failed")
    }

    public func complete(
        reference: JsonNode,
        argument: JsonNode,
        continuation!: McpToolCallContinuation = McpToolCallContinuation(),
        owner!: String = ""
    ): McpResult<McpOperationOutcome<McpCompletionResult>> {
        if (reference.unifiedKind != UnifiedJsonKind.Object || argument.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<McpOperationOutcome<McpCompletionResult>>(
                "mcp.completion_params_invalid", "completion/complete requires object ref and argument"
            )
        }
        let params = mcpOperationParams([
            JsonObjectEntry("ref", reference), JsonObjectEntry("argument", argument)
        ], continuation)
        match (send(MCP_METHOD_COMPLETION_COMPLETE, params, owner: owner)) {
            case McpResult.Ok(value) => decodeMcpCompletionOutcome(value)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func completeResolved(
        reference: JsonNode, argument: JsonNode, resolver: McpInputResolver,
        policy!: McpResolutionPolicy = McpResolutionPolicy(), owner!: String = "",
        progressToken!: JsonNode = jsonNull()
    ): McpResult<McpOperationOutcome<McpCompletionResult>> {
        var continuation = McpToolCallContinuation(progressToken: progressToken); var rounds: Int64 = 0
        while (true) {
            let outcome = match (complete(reference, argument, continuation: continuation, owner: owner)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            match (outcome) {
                case McpOperationOutcome.InputRequired(pending) =>
                    rounds++
                    let next = match (resolveMcpInput(pending, resolver, rounds, policy)) {
                        case McpResult.Ok(value) => value
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                    continuation = next
                case _ => return McpResult.Ok(outcome)
            }
        }
        invalidMcp<McpOperationOutcome<McpCompletionResult>>("mcp.input_resolution_failed", "MCP input resolution failed")
    }

    public func listPrompts(cursor!: String = ""): McpResult<McpPage> {
        listMcpPage(MCP_METHOD_PROMPTS_LIST, "prompts", cursor)
    }

    public func getPrompt(
        name: String,
        arguments!: JsonNode = jsonObject([]),
        continuation!: McpToolCallContinuation = McpToolCallContinuation(),
        owner!: String = ""
    ): McpResult<McpOperationOutcome<McpPromptResult>> {
        if (name.trimAscii() == "" || arguments.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<McpOperationOutcome<McpPromptResult>>(
                "mcp.prompt_params_invalid", "prompts/get requires a name and object arguments"
            )
        }
        let params = mcpOperationParams([
            JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("arguments", arguments)
        ], continuation)
        match (send(MCP_METHOD_PROMPTS_GET, params, owner: owner)) {
            case McpResult.Ok(value) => decodeMcpPromptOutcome(value)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func getPromptResolved(
        name: String, resolver: McpInputResolver,
        arguments!: JsonNode = jsonObject([]),
        policy!: McpResolutionPolicy = McpResolutionPolicy(), owner!: String = "",
        progressToken!: JsonNode = jsonNull()
    ): McpResult<McpOperationOutcome<McpPromptResult>> {
        var continuation = McpToolCallContinuation(progressToken: progressToken); var rounds: Int64 = 0
        while (true) {
            let outcome = match (getPrompt(
                name, arguments: arguments, continuation: continuation, owner: owner
            )) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            match (outcome) {
                case McpOperationOutcome.InputRequired(pending) =>
                    rounds++
                    continuation = match (resolveMcpInput(pending, resolver, rounds, policy)) {
                        case McpResult.Ok(value) => value
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                case _ => return McpResult.Ok(outcome)
            }
        }
        invalidMcp<McpOperationOutcome<McpPromptResult>>("mcp.input_resolution_failed", "MCP input resolution failed")
    }

    public func listResources(cursor!: String = ""): McpResult<McpPage> {
        listMcpPage(MCP_METHOD_RESOURCES_LIST, "resources", cursor)
    }

    public func listResourceTemplates(cursor!: String = ""): McpResult<McpPage> {
        listMcpPage(MCP_METHOD_RESOURCE_TEMPLATES_LIST, "resourceTemplates", cursor)
    }

    public func readResource(
        uri: String,
        continuation!: McpToolCallContinuation = McpToolCallContinuation(),
        owner!: String = ""
    ): McpResult<McpOperationOutcome<McpReadResourceResult>> {
        if (uri.trimAscii() == "") {
            return invalidMcp<McpOperationOutcome<McpReadResourceResult>>(
                "mcp.resource_uri_invalid", "resources/read requires a URI"
            )
        }
        let params = mcpOperationParams([JsonObjectEntry("uri", jsonString(uri))], continuation)
        match (send(MCP_METHOD_RESOURCES_READ, params, owner: owner)) {
            case McpResult.Ok(value) => decodeMcpReadResourceOutcome(value)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func readResourceResolved(
        uri: String, resolver: McpInputResolver,
        policy!: McpResolutionPolicy = McpResolutionPolicy(), owner!: String = "",
        progressToken!: JsonNode = jsonNull()
    ): McpResult<McpOperationOutcome<McpReadResourceResult>> {
        var continuation = McpToolCallContinuation(progressToken: progressToken); var rounds: Int64 = 0
        while (true) {
            let outcome = match (readResource(uri, continuation: continuation, owner: owner)) {
                case McpResult.Ok(value) => value
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            match (outcome) {
                case McpOperationOutcome.InputRequired(pending) =>
                    rounds++
                    continuation = match (resolveMcpInput(pending, resolver, rounds, policy)) {
                        case McpResult.Ok(value) => value
                        case McpResult.Err(error) => return McpResult.Err(error)
                    }
                case _ => return McpResult.Ok(outcome)
            }
        }
        invalidMcp<McpOperationOutcome<McpReadResourceResult>>("mcp.input_resolution_failed", "MCP input resolution failed")
    }

    public func listen(filter: McpSubscriptionFilter): McpResult<McpSubscriptionHandle> {
        if (state() != McpLifecycleState.Ready) {
            return lifecycleFailure<McpSubscriptionHandle>("mcp.client_not_ready", "MCP client is not ready")
        }
        let id = nextRequestId()
        transport.openSubscription(JsonRpcRequest(
            id, MCP_METHOD_SUBSCRIPTIONS_LISTEN,
            params: withMcpRequestMeta(filter.toValue(), meta)
        ))
    }

    public func getTask(taskId: String, owner!: String = ""): McpResult<McpTask> {
        if (taskId.trimAscii() == "") {
            return invalidMcp<McpTask>("mcp.tasks.id_invalid", "tasks/get requires taskId")
        }
        match (send(MCP_METHOD_TASKS_GET, jsonObject([
            JsonObjectEntry("taskId", jsonString(taskId))
        ]), owner: owner)) {
            case McpResult.Ok(value) => if (mcpText(value, "resultType") == MCP_RESULT_COMPLETE) {
                decodeMcpTask(value)
            } else { invalidMcp<McpTask>("mcp.tasks.result_invalid", "tasks/get result must be complete") }
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func updateTask(
        taskId: String, inputResponses: JsonNode, owner!: String = ""
    ): McpResult<Unit> {
        if (taskId.trimAscii() == "" || inputResponses.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<Unit>("mcp.tasks.update_invalid", "tasks/update requires taskId and object inputResponses")
        }
        for (field in inputResponses.fields where field.value.unifiedKind != UnifiedJsonKind.Object) {
            return invalidMcp<Unit>("mcp.tasks.response_invalid", "task input responses must be objects")
        }
        decodeMcpEmptyTaskAck(send(MCP_METHOD_TASKS_UPDATE, jsonObject([
            JsonObjectEntry("taskId", jsonString(taskId)), JsonObjectEntry("inputResponses", inputResponses)
        ]), owner: owner), MCP_METHOD_TASKS_UPDATE)
    }

    public func cancelTask(taskId: String, owner!: String = ""): McpResult<Unit> {
        if (taskId.trimAscii() == "") {
            return invalidMcp<Unit>("mcp.tasks.id_invalid", "tasks/cancel requires taskId")
        }
        decodeMcpEmptyTaskAck(send(MCP_METHOD_TASKS_CANCEL, jsonObject([
            JsonObjectEntry("taskId", jsonString(taskId))
        ]), owner: owner), MCP_METHOD_TASKS_CANCEL)
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
                transport.cancel(id, reason, meta)
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

    private func listMcpPage(method: String, fieldName: String, cursor: String): McpResult<McpPage> {
        let fields = ArrayList<JsonObjectEntry>()
        if (cursor != "") { fields.add(JsonObjectEntry("cursor", jsonString(cursor))) }
        match (send(method, jsonObject(fields.toArray()))) {
            case McpResult.Ok(value) => decodeMcpPage(value, fieldName)
            case McpResult.Err(error) => McpResult.Err(error)
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
    var requestMeta = jsonObject([])
    if (params.unifiedKind == UnifiedJsonKind.Object) {
        for (field in params.fields) {
            if (field.name == "_meta" && field.value.unifiedKind == UnifiedJsonKind.Object) {
                requestMeta = field.value
            } else if (field.name != "_meta") { fields.add(field) }
        }
    }
    let standard = meta.toValue()
    let merged = ArrayList<JsonObjectEntry>()
    for (field in requestMeta.fields where standard.field(field.name).isNone()) { merged.add(field) }
    for (field in standard.fields) { merged.add(field) }
    fields.add(JsonObjectEntry("_meta", jsonObject(merged.toArray())))
    jsonObject(fields.toArray())
}

func mcpOperationParams(
    base: Array<JsonObjectEntry>, continuation: McpToolCallContinuation
): JsonNode {
    let fields = ArrayList<JsonObjectEntry>(base)
    if (!continuation.inputResponses.fields.isEmpty()) {
        fields.add(JsonObjectEntry("inputResponses", continuation.inputResponses))
    }
    if (continuation.requestState != "") {
        fields.add(JsonObjectEntry("requestState", jsonString(continuation.requestState)))
    }
    if (continuation.hasProgressToken()) {
        fields.add(JsonObjectEntry("_meta", jsonObject([
            JsonObjectEntry("progressToken", continuation.requestProgressToken())
        ])))
    }
    jsonObject(fields.toArray())
}

func decodeMcpPage(value: JsonNode, fieldName: String): McpResult<McpPage> {
    if (mcpText(value, "resultType") != MCP_RESULT_COMPLETE) {
        return invalidMcp<McpPage>("mcp.page_result_invalid", fieldName + " result must be complete")
    }
    let source = mcpField(value, fieldName, jsonNull())
    if (source.unifiedKind != UnifiedJsonKind.List) {
        return invalidMcp<McpPage>("mcp.page_values_invalid", fieldName + " must be an array")
    }
    for (item in source.items where item.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpPage>("mcp.page_value_invalid", fieldName + " entries must be objects")
    }
    let ttl = mcpInteger(value, "ttlMs"); let scope = mcpText(value, "cacheScope")
    try {
        McpResult.Ok(McpPage(
            source.items.toArray(), nextCursor: mcpText(value, "nextCursor"),
            ttlMillis: ttl, cacheScope: scope
        ))
    } catch (error: Exception) { invalidMcp<McpPage>("mcp.page_result_invalid", error.message) }
}

func decodeMcpInputRequired<T>(value: JsonNode): McpResult<McpOperationOutcome<T>> {
    let inputRequests = match (validatedMcpInputRequests(value)) {
        case McpResult.Ok(requests) => requests
        case McpResult.Err(error) => return McpResult.Err(error)
    }
    try {
        McpResult.Ok(McpOperationOutcome.InputRequired(McpInputRequiredResult(
            inputRequests: inputRequests,
            requestState: mcpText(value, "requestState"), meta: mcpObject(value, "_meta")
        )))
    } catch (error: Exception) {
        invalidMcp<McpOperationOutcome<T>>("mcp.input_required_invalid", error.message)
    }
}

func validatedMcpInputRequests(value: JsonNode): McpResult<JsonNode> {
    match (value.field("inputRequests")) {
        case Some(requests) => if (requests.unifiedKind != UnifiedJsonKind.Object) {
            invalidMcp<JsonNode>(
                "mcp.input_required_invalid", "inputRequests must be an object when present"
            )
        } else { McpResult.Ok(requests) }
        case None => McpResult.Ok(jsonObject([]))
    }
}

func decodeMcpCompletionOutcome(value: JsonNode): McpResult<McpOperationOutcome<McpCompletionResult>> {
    let kind = mcpText(value, "resultType")
    if (kind == MCP_RESULT_INPUT_REQUIRED) { return decodeMcpInputRequired<McpCompletionResult>(value) }
    if (kind == MCP_RESULT_TASK) { return decodeMcpTaskOutcome<McpCompletionResult>(value) }
    if (kind != MCP_RESULT_COMPLETE) {
        return McpResult.Ok(McpOperationOutcome.Extension(kind, value))
    }
    let completion = mcpField(value, "completion", jsonNull())
    if (completion.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpOperationOutcome<McpCompletionResult>>(
            "mcp.completion_result_invalid", "completion/complete omitted completion"
        )
    }
    McpResult.Ok(McpOperationOutcome.Complete(McpCompletionResult(
        completion, meta: mcpObject(value, "_meta")
    )))
}

func decodeMcpPromptOutcome(value: JsonNode): McpResult<McpOperationOutcome<McpPromptResult>> {
    let kind = mcpText(value, "resultType")
    if (kind == MCP_RESULT_INPUT_REQUIRED) { return decodeMcpInputRequired<McpPromptResult>(value) }
    if (kind == MCP_RESULT_TASK) { return decodeMcpTaskOutcome<McpPromptResult>(value) }
    if (kind != MCP_RESULT_COMPLETE) { return McpResult.Ok(McpOperationOutcome.Extension(kind, value)) }
    let messages = mcpField(value, "messages", jsonNull())
    if (messages.unifiedKind != UnifiedJsonKind.List) {
        return invalidMcp<McpOperationOutcome<McpPromptResult>>(
            "mcp.prompt_result_invalid", "prompts/get omitted messages"
        )
    }
    try { McpResult.Ok(McpOperationOutcome.Complete(McpPromptResult(
        messages.items.toArray(), description: mcpText(value, "description"), meta: mcpObject(value, "_meta")
    ))) } catch (error: Exception) {
        invalidMcp<McpOperationOutcome<McpPromptResult>>("mcp.prompt_result_invalid", error.message)
    }
}

func decodeMcpReadResourceOutcome(value: JsonNode): McpResult<McpOperationOutcome<McpReadResourceResult>> {
    let kind = mcpText(value, "resultType")
    if (kind == MCP_RESULT_INPUT_REQUIRED) { return decodeMcpInputRequired<McpReadResourceResult>(value) }
    if (kind == MCP_RESULT_TASK) { return decodeMcpTaskOutcome<McpReadResourceResult>(value) }
    if (kind != MCP_RESULT_COMPLETE) { return McpResult.Ok(McpOperationOutcome.Extension(kind, value)) }
    let contents = mcpField(value, "contents", jsonNull())
    if (contents.unifiedKind != UnifiedJsonKind.List) {
        return invalidMcp<McpOperationOutcome<McpReadResourceResult>>(
            "mcp.resource_result_invalid", "resources/read omitted contents"
        )
    }
    try { McpResult.Ok(McpOperationOutcome.Complete(McpReadResourceResult(
        contents.items.toArray(), ttlMillis: mcpInteger(value, "ttlMs"),
        cacheScope: mcpText(value, "cacheScope"), meta: mcpObject(value, "_meta")
    ))) } catch (error: Exception) {
        invalidMcp<McpOperationOutcome<McpReadResourceResult>>("mcp.resource_result_invalid", error.message)
    }
}

func decodeMcpTaskOutcome<T>(value: JsonNode): McpResult<McpOperationOutcome<T>> {
    match (decodeMcpTask(value)) {
        case McpResult.Ok(task) => McpResult.Ok(McpOperationOutcome.Task(task))
        case McpResult.Err(error) => McpResult.Err(error)
    }
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

func mcpServerInfo(value: JsonNode): McpResult<?McpImplementationInfo> {
    let meta = match (value.field("_meta")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Object) { item } else {
            return invalidMcp<?McpImplementationInfo>("mcp.result_meta_invalid", "MCP result _meta must be an object")
        }
        case None => return McpResult.Ok(None)
    }
    match (meta.field(MCP_META_SERVER_INFO)) {
        case Some(item) => match (decodeMcpImplementationInfo(item)) {
            case McpResult.Ok(info) => McpResult.Ok(Some(info))
            case McpResult.Err(error) => McpResult.Err(error)
        }
        case None => McpResult.Ok(None)
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
    for (name in ["completions", "logging", "prompts", "resources", "tools", "tasks"]) {
        match (capabilities.field(name)) {
            case Some(feature) => if (feature.unifiedKind != UnifiedJsonKind.Object) {
                return invalidMcp<McpDiscoverResult>(
                    "mcp.capability_invalid", "server capability " + name + " must be an object"
                )
            }
            case None => ()
        }
    }
    let prompts = decodeMcpCapabilityFeature(capabilities, "prompts")
    let resources = decodeMcpCapabilityFeature(capabilities, "resources")
    let tools = decodeMcpCapabilityFeature(capabilities, "tools")
    let experimental = mcpObject(capabilities, "experimental")
    let extensions = mcpObject(capabilities, "extensions")
    let ttl = mcpInteger(value, "ttlMs"); let scope = mcpText(value, "cacheScope")
    if (ttl < 0 || !validMcpCacheScope(scope)) {
        return invalidMcp<McpDiscoverResult>("mcp.cache_metadata_invalid", "server/discover cache metadata is invalid")
    }
    try { McpResult.Ok(McpDiscoverResult(
        serverInfo: info, capabilities: McpServerCapabilities(
            completion: capabilities.field("completions").isSome(),
            logging: capabilities.field("logging").isSome(),
            prompts: prompts, resources: resources, tools: tools,
            experimental: experimental, extensions: extensions
        ),
        instructions: mcpText(value, "instructions"), supportedVersions: versions.toArray(),
        ttlMillis: ttl, cacheScope: scope
    )) } catch (error: Exception) { invalidMcp<McpDiscoverResult>("mcp.discover_invalid", error.message) }
}

func decodeMcpCapabilityFeature(capabilities: JsonNode, name: String): ?McpCapabilityFeature {
    let value = match (capabilities.field(name)) {
        case Some(found) => found
        case None => return None
    }
    if (value.unifiedKind != UnifiedJsonKind.Object) { return None }
    let extensions = ArrayList<JsonObjectEntry>()
    for (field in value.fields where field.name != "listChanged" && field.name != "subscribe") {
        extensions.add(field)
    }
    Some(McpCapabilityFeature(
        listChanged: mcpBool(value, "listChanged", false),
        subscribe: mcpBool(value, "subscribe", false),
        extensions: jsonObject(extensions.toArray())
    ))
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
    let execution: ?McpToolExecution = match (value.field("execution")) {
        case Some(item) =>
            if (item.unifiedKind != UnifiedJsonKind.Object) {
                return invalidMcp<McpTool>("mcp.tool_invalid", "tool execution must be an object")
            }
            match (mcpText(item, "taskSupport")) {
                case "forbidden" => Some(McpToolExecution())
                case "optional" => Some(McpToolExecution(taskSupport: McpTaskSupport.Optional))
                case "required" => Some(McpToolExecution(taskSupport: McpTaskSupport.Required))
                case _ => return invalidMcp<McpTool>("mcp.tool_invalid", "tool execution has invalid taskSupport")
            }
        case None => None
    }
    try { McpResult.Ok(McpTool(
        mcpText(value, "name"), mcpText(value, "description"), schema,
        outputSchema: mcpField(value, "outputSchema", jsonNull()),
        annotations: mcpObject(value, "annotations"), execution: execution,
        meta: mcpObject(value, "_meta")
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
                content.items.toArray(), structuredContent: structured,
                isError: mcpBool(value, "isError", false), meta: mcpObject(value, "_meta")
            )))
    } else if (resultType == MCP_RESULT_INPUT_REQUIRED) {
        let inputRequests = match (validatedMcpInputRequests(value)) {
            case McpResult.Ok(requests) => requests
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        try { McpResult.Ok(McpCallToolOutcome.InputRequired(McpInputRequiredResult(
            inputRequests: inputRequests,
            requestState: mcpText(value, "requestState"), meta: mcpObject(value, "_meta")
        ))) } catch (error: Exception) { invalidMcp<McpCallToolOutcome>("mcp.input_required_invalid", error.message) }
    } else if (resultType == MCP_RESULT_TASK) {
        match (decodeMcpTask(value)) {
            case McpResult.Ok(task) => McpResult.Ok(McpCallToolOutcome.Task(task))
            case McpResult.Err(error) => McpResult.Err(error)
        }
    } else if (resultType != "") { McpResult.Ok(McpCallToolOutcome.Extension(resultType, value)) }
    else { invalidMcp<McpCallToolOutcome>("mcp.call_result_invalid", "tools/call omitted resultType") }
}

func decodeMcpEmptyTaskAck(value: McpResult<JsonNode>, method: String): McpResult<Unit> {
    match (value) {
        case McpResult.Ok(result) =>
            var unexpected = false
            for (field in result.fields where field.name != "resultType" && field.name != "_meta") {
                unexpected = true
            }
            if (mcpText(result, "resultType") == MCP_RESULT_COMPLETE && !unexpected) { McpResult.Ok(()) }
            else { invalidMcp<Unit>("mcp.tasks.ack_invalid", method + " must return an empty complete acknowledgement") }
        case McpResult.Err(error) => McpResult.Err(error)
    }
}

func validateMcpInputResponses(pending: McpInputRequiredResult, responses: JsonNode): McpResult<Unit> {
    if (responses.unifiedKind != UnifiedJsonKind.Object) { return invalidMcp<Unit>("mcp.input_responses_invalid", "inputResponses must be an object") }
    for (request in pending.inputRequests.fields) { match (responses.field(request.name)) {
        case Some(value) =>
            let typedRequest = match (decodeMcpInputRequest(request.value)) {
                case McpResult.Ok(found) => found
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            match (decodeMcpInputResponse(typedRequest, value)) {
                case McpResult.Ok(_) => ()
                case McpResult.Err(error) => return McpResult.Err(error)
            }
        case None => return invalidMcp<Unit>("mcp.input_response_missing", "retry must answer every input request")
    } }
    for (response in responses.fields where pending.inputRequests.field(response.name).isNone()) {
        return invalidMcp<Unit>("mcp.input_response_unknown", "retry contains an unknown input response")
    }
    McpResult.Ok(())
}

func resolveMcpInput(
    pending: McpInputRequiredResult, resolver: McpInputResolver,
    round: Int64, policy: McpResolutionPolicy
): McpResult<McpToolCallContinuation> {
    if (round > policy.maxRounds) {
        return invalidMcp<McpToolCallContinuation>(
            "mcp.input_resolution_limit", "MCP input resolution exceeded the configured round limit"
        )
    }
    let responses = match (resolver.resolve(pending.inputRequests, pending.requestState)) {
        case McpResult.Ok(value) => value
        case McpResult.Err(error) => return McpResult.Err(error)
    }
    match (validateMcpInputResponses(pending, responses)) {
        case McpResult.Ok(_) => McpResult.Ok(McpToolCallContinuation(
            inputResponses: responses, requestState: pending.requestState
        ))
        case McpResult.Err(error) => McpResult.Err(error)
    }
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
