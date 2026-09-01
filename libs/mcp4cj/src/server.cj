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

public interface McpCompletionProvider {
    func complete(
        requestId: JsonRpcId, reference: JsonNode, argument: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpCompletionResult>>
}

public interface McpPromptProvider {
    func listPrompts(cursor: String): McpResult<McpPage>
    func getPrompt(
        requestId: JsonRpcId, name: String, arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpPromptResult>>
}

public interface McpResourceProvider {
    func listResources(cursor: String): McpResult<McpPage>
    func listResourceTemplates(cursor: String): McpResult<McpPage>
    func readResource(
        requestId: JsonRpcId, uri: String, continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpReadResourceResult>>
}

public interface McpNotificationProvider {
    func open(requestId: JsonRpcId, filter: McpSubscriptionFilter): McpResult<McpSubscriptionSource>
    func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit>
}

// Generic MCP protocol dispatcher. The host callback is the sole execution
// boundary; this class has no knowledge of product tools or authorization.
public class McpServer {
    private let discovery: McpDiscoverResult
    private let host: ?McpToolHost
    private let completions: ?McpCompletionProvider
    private let prompts: ?McpPromptProvider
    private let resources: ?McpResourceProvider
    private let notifications: ?McpNotificationProvider
    private let tasks: ?McpTaskProvider
    private let lifecycle = McpLifecycle()

    public init(
        discovery: McpDiscoverResult,
        host!: ?McpToolHost = None,
        completions!: ?McpCompletionProvider = None,
        prompts!: ?McpPromptProvider = None,
        resources!: ?McpResourceProvider = None,
        notifications!: ?McpNotificationProvider = None,
        tasks!: ?McpTaskProvider = None
    ) {
        this.discovery = discovery
        this.host = host
        this.completions = completions
        this.prompts = prompts
        this.resources = resources
        this.notifications = notifications
        this.tasks = tasks
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
    }

    public func state(): McpLifecycleState { lifecycle.state() }

    public func handleRequest(
        request: JsonRpcRequest,
        notificationSink!: (JsonRpcNotification) -> Unit = { _ => }
    ): JsonRpcResponse {
        if (state() != McpLifecycleState.Ready) {
            return mcpFailureResponse(request.id, JSON_RPC_INTERNAL_ERROR, "MCP server is closed")
        }
        match (validateMcpRequestMeta(request.params)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => return mcpFailureResponse(
                request.id,
                if (error.code == "mcp.version_unsupported") { MCP_UNSUPPORTED_PROTOCOL_VERSION } else { JSON_RPC_INVALID_PARAMS },
                error.message,
                data: if (error.code == "mcp.version_unsupported") {
                    jsonObject([
                        JsonObjectEntry("supported", jsonArray([jsonString(MCP_PROTOCOL_VERSION)])),
                        JsonObjectEntry("requested", jsonString(mcpRequestedProtocolVersion(request.params)))
                    ])
                } else { jsonNull() }
            )
        }
        if (request.method == MCP_METHOD_DISCOVER) {
            mcpSuccessResponse(request.id, discovery.toValue(), discovery.serverInfo)
        } else if (request.method == MCP_METHOD_TOOLS_LIST) {
            match (host) {
                case Some(provider) => match (provider.listTools(mcpText(request.params, "cursor"))) {
                    case McpResult.Ok(page) => mcpSuccessResponse(request.id, page.toValue(), discovery.serverInfo)
                    case McpResult.Err(error) => mcpHostFailure(request.id, error)
                }
                case None => mcpFailureResponse(request.id, JSON_RPC_METHOD_NOT_FOUND, "MCP method not available: tools/list")
            }
        } else if (request.method == MCP_METHOD_TOOLS_CALL) {
            handleToolCall(request, notificationSink)
        } else if (request.method == MCP_METHOD_COMPLETION_COMPLETE) {
            handleCompletion(request, notificationSink)
        } else if (request.method == MCP_METHOD_PROMPTS_LIST) {
            handlePromptList(request)
        } else if (request.method == MCP_METHOD_PROMPTS_GET) {
            handlePromptGet(request, notificationSink)
        } else if (request.method == MCP_METHOD_RESOURCES_LIST) {
            handleResourceList(request)
        } else if (request.method == MCP_METHOD_RESOURCE_TEMPLATES_LIST) {
            handleResourceTemplateList(request)
        } else if (request.method == MCP_METHOD_RESOURCES_READ) {
            handleResourceRead(request, notificationSink)
        } else if (request.method == MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
            handleListen(request)
        } else if (request.method == MCP_METHOD_TASKS_GET) {
            handleTaskGet(request)
        } else if (request.method == MCP_METHOD_TASKS_UPDATE) {
            handleTaskUpdate(request)
        } else if (request.method == MCP_METHOD_TASKS_CANCEL) {
            handleTaskCancel(request)
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
        let reason = mcpText(notification.params, "reason")
        match (host) {
            case Some(provider) => match (provider.cancel(id, reason)) {
                case McpResult.Ok(_) => ()
                case McpResult.Err(error) => return McpResult.Err(error)
            }
            case None => ()
        }
        match (notifications) {
            case Some(provider) => provider.cancel(id, reason)
            case None => McpResult.Ok(())
        }
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

    public func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionSource> {
        if (state() != McpLifecycleState.Ready) {
            return invalidMcp<McpSubscriptionSource>("mcp.server_not_ready", "MCP server is not ready")
        }
        if (request.method != MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
            return invalidMcp<McpSubscriptionSource>("mcp.subscription_method_invalid", "subscription request method is invalid")
        }
        match (validateMcpRequestMeta(request.params)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        let filter = match (decodeMcpSubscriptionFilter(request.params)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        if (!filter.taskIds.isEmpty() && !mcpRequestSupportsTasks(request.params)) {
            return invalidMcp<McpSubscriptionSource>(
                "mcp.subscription_tasks_capability_missing", "task subscriptions require the Tasks extension"
            )
        }
        match (notifications) {
            case Some(provider) => provider.open(request.id, filter)
            case None => invalidMcp<McpSubscriptionSource>("mcp.subscription_unavailable", "subscriptions/listen is not available")
        }
    }

    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        let _ = lifecycle.transition(McpLifecycleState.Stopped)
        McpResult.Ok(())
    }

    private func handleToolCall(
        request: JsonRpcRequest, notificationSink: (JsonRpcNotification) -> Unit
    ): JsonRpcResponse {
        let name = mcpText(request.params, "name")
        if (name == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tools/call requires name") }
        let arguments = mcpField(request.params, "arguments", jsonObject([]))
        if (arguments.unifiedKind != UnifiedJsonKind.Object) {
            return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tools/call arguments must be an object")
        }
        let continuation = match (decodeMcpContinuation(request.params, notificationSink)) {
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
        match (tool.execution) {
            case Some(execution) => if (execution.taskSupport == McpTaskSupport.Required &&
                !mcpRequestSupportsTasks(request.params)) {
                return mcpFailureResponse(
                    request.id, MCP_MISSING_REQUIRED_CLIENT_CAPABILITY,
                    "Missing required client capability", data: mcpTasksRequiredCapability()
                )
            }
            case None => ()
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
        let provider = match (host) {
            case Some(value) => value
            case None => return mcpFailureResponse(request.id, JSON_RPC_METHOD_NOT_FOUND, "MCP method not available: tools/call")
        }
        match (provider.callTool(request.id, name, arguments, continuation)) {
            case McpResult.Ok(outcome) => match (outcome) {
                case McpCallToolOutcome.Task(_) => if (!mcpRequestSupportsTasks(request.params)) {
                    mcpFailureResponse(
                        request.id, MCP_MISSING_REQUIRED_CLIENT_CAPABILITY,
                        "Missing required client capability", data: mcpTasksRequiredCapability()
                    )
                } else if (tool.execution.isNone() ||
                    tool.execution.getOrThrow().taskSupport == McpTaskSupport.Forbidden) {
                    mcpFailureResponse(
                        request.id, JSON_RPC_INTERNAL_ERROR,
                        "tool returned a task despite declaring task support forbidden"
                    )
                } else { mcpCheckedOperationResponse(request, mcpCallToolOutcomeValue(outcome), discovery.serverInfo) }
                case _ => mcpCheckedOperationResponse(request, mcpCallToolOutcomeValue(outcome), discovery.serverInfo)
            }
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handleCompletion(
        request: JsonRpcRequest, notificationSink: (JsonRpcNotification) -> Unit
    ): JsonRpcResponse {
        let provider = match (completions) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_COMPLETION_COMPLETE)
        }
        let reference = mcpField(request.params, "ref", jsonNull())
        let argument = mcpField(request.params, "argument", jsonNull())
        if (reference.unifiedKind != UnifiedJsonKind.Object || argument.unifiedKind != UnifiedJsonKind.Object) {
            return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "completion/complete requires object ref and argument")
        }
        let continuation = match (decodeMcpContinuation(request.params, notificationSink)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return mcpHostFailure(request.id, error)
        }
        match (provider.complete(request.id, reference, argument, continuation)) {
            case McpResult.Ok(outcome) => mcpCheckedOperationResponse(
                request, mcpOperationOutcomeValue(outcome, { value => value.toValue() }), discovery.serverInfo
            )
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handlePromptList(request: JsonRpcRequest): JsonRpcResponse {
        match (prompts) {
            case Some(provider) => match (provider.listPrompts(mcpText(request.params, "cursor"))) {
                case McpResult.Ok(page) => mcpSuccessResponse(request.id, page.toValue("prompts"), discovery.serverInfo)
                case McpResult.Err(error) => mcpHostFailure(request.id, error)
            }
            case None => unavailableMcpMethod(request, MCP_METHOD_PROMPTS_LIST)
        }
    }

    private func handlePromptGet(
        request: JsonRpcRequest, notificationSink: (JsonRpcNotification) -> Unit
    ): JsonRpcResponse {
        let provider = match (prompts) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_PROMPTS_GET)
        }
        let name = mcpText(request.params, "name")
        let arguments = match (request.params.field("arguments")) {
            case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else {
                return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "prompts/get arguments must be an object")
            }
            case None => jsonObject([])
        }
        if (name == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "prompts/get requires name") }
        let continuation = match (decodeMcpContinuation(request.params, notificationSink)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return mcpHostFailure(request.id, error)
        }
        match (provider.getPrompt(request.id, name, arguments, continuation)) {
            case McpResult.Ok(outcome) => mcpCheckedOperationResponse(
                request, mcpOperationOutcomeValue(outcome, { value => value.toValue() }), discovery.serverInfo
            )
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handleResourceList(request: JsonRpcRequest): JsonRpcResponse {
        match (resources) {
            case Some(provider) => match (provider.listResources(mcpText(request.params, "cursor"))) {
                case McpResult.Ok(page) => mcpSuccessResponse(request.id, page.toValue("resources"), discovery.serverInfo)
                case McpResult.Err(error) => mcpHostFailure(request.id, error)
            }
            case None => unavailableMcpMethod(request, MCP_METHOD_RESOURCES_LIST)
        }
    }

    private func handleResourceTemplateList(request: JsonRpcRequest): JsonRpcResponse {
        match (resources) {
            case Some(provider) => match (provider.listResourceTemplates(mcpText(request.params, "cursor"))) {
                case McpResult.Ok(page) => mcpSuccessResponse(request.id, page.toValue("resourceTemplates"), discovery.serverInfo)
                case McpResult.Err(error) => mcpHostFailure(request.id, error)
            }
            case None => unavailableMcpMethod(request, MCP_METHOD_RESOURCE_TEMPLATES_LIST)
        }
    }

    private func handleResourceRead(
        request: JsonRpcRequest, notificationSink: (JsonRpcNotification) -> Unit
    ): JsonRpcResponse {
        let provider = match (resources) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_RESOURCES_READ)
        }
        let uri = mcpText(request.params, "uri")
        if (uri == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "resources/read requires uri") }
        let continuation = match (decodeMcpContinuation(request.params, notificationSink)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) => return mcpHostFailure(request.id, error)
        }
        match (provider.readResource(request.id, uri, continuation)) {
            case McpResult.Ok(outcome) => mcpCheckedOperationResponse(
                request, mcpOperationOutcomeValue(outcome, { value => value.toValue() }), discovery.serverInfo
            )
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handleListen(request: JsonRpcRequest): JsonRpcResponse {
        match (notifications) {
            case Some(_) => mcpFailureResponse(
                request.id, JSON_RPC_INTERNAL_ERROR,
                "subscriptions/listen must be opened through a streaming transport"
            )
            case None => unavailableMcpMethod(request, MCP_METHOD_SUBSCRIPTIONS_LISTEN)
        }
    }

    private func handleTaskGet(request: JsonRpcRequest): JsonRpcResponse {
        if (!mcpRequestSupportsTasks(request.params)) { return mcpMissingTasksCapability(request.id) }
        let provider = match (tasks) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_TASKS_GET)
        }
        let taskId = mcpText(request.params, "taskId")
        if (taskId == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tasks/get requires taskId") }
        match (provider.getTask(taskId)) {
            case McpResult.Ok(task) => mcpSuccessResponse(request.id, task.toValue(), discovery.serverInfo)
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handleTaskUpdate(request: JsonRpcRequest): JsonRpcResponse {
        if (!mcpRequestSupportsTasks(request.params)) { return mcpMissingTasksCapability(request.id) }
        let provider = match (tasks) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_TASKS_UPDATE)
        }
        let taskId = mcpText(request.params, "taskId")
        let responses = mcpField(request.params, "inputResponses", jsonNull())
        if (taskId == "" || responses.unifiedKind != UnifiedJsonKind.Object) {
            return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tasks/update requires taskId and object inputResponses")
        }
        for (field in responses.fields where field.value.unifiedKind != UnifiedJsonKind.Object) {
            return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "task input responses must be objects")
        }
        match (provider.updateTask(taskId, responses)) {
            case McpResult.Ok(_) => mcpSuccessResponse(request.id, jsonObject([]), discovery.serverInfo)
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func handleTaskCancel(request: JsonRpcRequest): JsonRpcResponse {
        if (!mcpRequestSupportsTasks(request.params)) { return mcpMissingTasksCapability(request.id) }
        let provider = match (tasks) {
            case Some(value) => value
            case None => return unavailableMcpMethod(request, MCP_METHOD_TASKS_CANCEL)
        }
        let taskId = mcpText(request.params, "taskId")
        if (taskId == "") { return mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, "tasks/cancel requires taskId") }
        match (provider.cancelTask(taskId)) {
            case McpResult.Ok(_) => mcpSuccessResponse(request.id, jsonObject([]), discovery.serverInfo)
            case McpResult.Err(error) => mcpHostFailure(request.id, error)
        }
    }

    private func unavailableMcpMethod(request: JsonRpcRequest, method: String): JsonRpcResponse {
        mcpFailureResponse(request.id, JSON_RPC_METHOD_NOT_FOUND, "MCP method not available: " + method)
    }

    private func findTool(name: String): McpResult<?McpTool> {
        let provider = match (host) {
            case Some(value) => value
            case None => return McpResult.Ok(None)
        }
        let cursors = ArrayList<String>(); var cursor = ""; var pages: Int64 = 0
        while (true) {
            pages++
            if (pages > 1024) { return invalidMcp<?McpTool>("mcp.tool_directory_page_limit", "tool directory exceeded page limit") }
            let page = match (provider.listTools(cursor)) {
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

public class McpServerBuilder {
    private let serverInfo: ?McpImplementationInfo
    private let instructions: String
    private var tools: ?McpToolHost = None
    private var completions: ?McpCompletionProvider = None
    private var prompts: ?McpPromptProvider = None
    private var resources: ?McpResourceProvider = None
    private var notifications: ?McpNotificationProvider = None
    private var tasks: ?McpTaskProvider = None
    private var experimental = jsonObject([])
    private var extensions = jsonObject([])

    public init(
        serverInfo!: ?McpImplementationInfo = None,
        instructions!: String = ""
    ) {
        this.serverInfo = serverInfo; this.instructions = instructions
    }

    public func toolProvider(value: McpToolHost): McpServerBuilder {
        tools = Some(value); this
    }
    public func completionProvider(value: McpCompletionProvider): McpServerBuilder {
        completions = Some(value); this
    }
    public func promptProvider(value: McpPromptProvider): McpServerBuilder {
        prompts = Some(value); this
    }
    public func resourceProvider(value: McpResourceProvider): McpServerBuilder {
        resources = Some(value); this
    }
    public func notificationProvider(value: McpNotificationProvider): McpServerBuilder {
        notifications = Some(value); this
    }
    public func taskProvider(value: McpTaskProvider): McpServerBuilder {
        tasks = Some(value); this
    }
    public func experimentalCapabilities(value: JsonNode): McpServerBuilder {
        requireObject(value, "MCP experimental server capabilities")
        experimental = value; this
    }
    public func extensionCapabilities(value: JsonNode): McpServerBuilder {
        requireObject(value, "MCP server capability extensions")
        extensions = value; this
    }

    public func build(): McpServer {
        let capabilities = McpServerCapabilities(
            completion: completions.isSome(),
            prompts: if (prompts.isSome()) { Some(McpCapabilityFeature()) } else { None },
            resources: if (resources.isSome()) { Some(McpCapabilityFeature(subscribe: notifications.isSome())) } else { None },
            tools: if (tools.isSome()) { Some(McpCapabilityFeature()) } else { None },
            experimental: experimental,
            extensions: if (tasks.isSome()) { withMcpTasksExtension(extensions) } else { extensions }
        )
        McpServer(
            McpDiscoverResult(
                serverInfo: serverInfo, capabilities: capabilities, instructions: instructions
            ),
            host: tools, completions: completions, prompts: prompts,
            resources: resources, notifications: notifications, tasks: tasks
        )
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
    let protocolVersion = mcpText(meta, MCP_META_PROTOCOL_VERSION)
    if (protocolVersion == "") {
        return invalidMcp<Unit>("mcp.protocol_version_missing", "request requires protocolVersion")
    }
    if (protocolVersion != MCP_PROTOCOL_VERSION) {
        return invalidMcp<Unit>("mcp.version_unsupported", "unsupported MCP protocol version")
    }
    match (meta.field(MCP_META_CLIENT_INFO)) {
        case Some(value) => match (decodeMcpImplementationInfo(value)) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => return McpResult.Err(error)
        }
        case None => ()
    }
    match (meta.field(MCP_META_CLIENT_CAPABILITIES)) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { McpResult.Ok(()) } else {
            invalidMcp<Unit>("mcp.client_capabilities_invalid", "clientCapabilities must be an object")
        }
        case None => invalidMcp<Unit>("mcp.client_capabilities_missing", "request requires clientCapabilities")
    }
}

func mcpRequestSupportsTasks(params: JsonNode): Bool {
    let meta = mcpObject(params, "_meta")
    let capabilities = mcpObject(meta, MCP_META_CLIENT_CAPABILITIES)
    let extensions = mcpObject(capabilities, "extensions")
    match (extensions.field(MCP_TASKS_EXTENSION)) {
        case Some(value) => value.unifiedKind == UnifiedJsonKind.Object
        case None => false
    }
}

func mcpRequestedProtocolVersion(params: JsonNode): String {
    mcpText(mcpObject(params, "_meta"), MCP_META_PROTOCOL_VERSION)
}

func mcpTasksRequiredCapability(): JsonNode {
    jsonObject([JsonObjectEntry("requiredCapabilities", jsonObject([
        JsonObjectEntry("extensions", jsonObject([
            JsonObjectEntry(MCP_TASKS_EXTENSION, jsonObject([]))
        ]))
    ]))])
}

func mcpMissingTasksCapability(id: JsonRpcId): JsonRpcResponse {
    mcpFailureResponse(
        id, MCP_MISSING_REQUIRED_CLIENT_CAPABILITY,
        "Missing required client capability", data: mcpTasksRequiredCapability()
    )
}

func decodeMcpSubscriptionFilter(params: JsonNode): McpResult<McpSubscriptionFilter> {
    let notifications = match (params.field("notifications")) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else {
            return invalidMcp<McpSubscriptionFilter>("mcp.subscription_filter_invalid", "notifications must be an object")
        }
        case None => return invalidMcp<McpSubscriptionFilter>("mcp.subscription_filter_missing", "subscriptions/listen requires notifications")
    }
    let resources = ArrayList<String>(); let tasks = ArrayList<String>()
    match (decodeMcpStringArray(notifications, "resourceSubscriptions", resources)) {
        case McpResult.Ok(_) => ()
        case McpResult.Err(error) => return McpResult.Err(error)
    }
    match (decodeMcpStringArray(notifications, "taskIds", tasks)) {
        case McpResult.Ok(_) => ()
        case McpResult.Err(error) => return McpResult.Err(error)
    }
    for (name in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"]) {
        match (notifications.field(name)) {
            case Some(value) => if (value.unifiedKind != UnifiedJsonKind.Boolean) {
                return invalidMcp<McpSubscriptionFilter>(
                    "mcp.subscription_filter_invalid", name + " must be a boolean"
                )
            }
            case None => ()
        }
    }
    McpResult.Ok(McpSubscriptionFilter(
        toolsListChanged: mcpBool(notifications, "toolsListChanged", false),
        promptsListChanged: mcpBool(notifications, "promptsListChanged", false),
        resourcesListChanged: mcpBool(notifications, "resourcesListChanged", false),
        resourceSubscriptions: resources.toArray(), taskIds: tasks.toArray()
    ))
}

func decodeMcpStringArray(source: JsonNode, name: String, output: ArrayList<String>): McpResult<Unit> {
    match (source.field(name)) {
        case Some(value) =>
            if (value.unifiedKind != UnifiedJsonKind.List) {
                return invalidMcp<Unit>("mcp.subscription_filter_invalid", name + " must be an array")
            }
            for (item in value.items) {
                if (item.unifiedKind != UnifiedJsonKind.Text || item.text.trimAscii() == "") {
                    return invalidMcp<Unit>("mcp.subscription_filter_invalid", name + " entries must be non-empty strings")
                }
                output.add(item.text)
            }
        case None => ()
    }
    McpResult.Ok(())
}

func mcpSuccessResponse(id: JsonRpcId, value: JsonNode, serverInfo: ?McpImplementationInfo): JsonRpcResponse {
    JsonRpcResponse(id, JsonRpcResponsePayload.Success(withMcpServerMeta(value, serverInfo)))
}

func mcpCheckedOperationResponse(
    request: JsonRpcRequest, value: JsonNode, serverInfo: ?McpImplementationInfo
): JsonRpcResponse {
    if (mcpText(value, "resultType") == MCP_RESULT_INPUT_REQUIRED) {
        let required = missingMcpInputCapabilities(request.params, mcpObject(value, "inputRequests"))
        if (!required.fields.isEmpty()) {
            return mcpFailureResponse(
                request.id, MCP_MISSING_REQUIRED_CLIENT_CAPABILITY,
                "Missing required client capability",
                data: jsonObject([JsonObjectEntry("requiredCapabilities", required)])
            )
        }
    }
    if (mcpText(value, "resultType") == MCP_RESULT_TASK && !mcpRequestSupportsTasks(request.params)) {
        return mcpFailureResponse(
            request.id, MCP_MISSING_REQUIRED_CLIENT_CAPABILITY,
            "Missing required client capability", data: mcpTasksRequiredCapability()
        )
    }
    mcpSuccessResponse(request.id, value, serverInfo)
}

func missingMcpInputCapabilities(params: JsonNode, requests: JsonNode): JsonNode {
    let capabilities = mcpObject(mcpObject(params, "_meta"), MCP_META_CLIENT_CAPABILITIES)
    var roots = false; var sampling = false; var samplingTools = false; var samplingContext = false
    var elicitation = false; var elicitationUrl = false
    for (entry in requests.fields) {
        let request = match (decodeMcpInputRequest(entry.value)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(_) => continue
        }
        match (request) {
            case McpInputRequest.Roots(_) =>
                if (capabilities.field("roots").isNone()) { roots = true }
            case McpInputRequest.Sampling(value) =>
                let declared = match (capabilities.field("sampling")) {
                    case Some(found) => if (found.unifiedKind == UnifiedJsonKind.Object) { found } else { jsonObject([]) }
                    case None => jsonObject([])
                }
                if (capabilities.field("sampling").isNone()) { sampling = true }
                if (value.field("tools").isSome() && declared.field("tools").isNone()) { samplingTools = true }
                let context = mcpText(value, "includeContext")
                if (context != "" && context != "none" && declared.field("context").isNone()) { samplingContext = true }
            case McpInputRequest.Elicitation(value) =>
                let declared = match (capabilities.field("elicitation")) {
                    case Some(found) => if (found.unifiedKind == UnifiedJsonKind.Object) { found } else { jsonObject([]) }
                    case None => jsonObject([])
                }
                if (capabilities.field("elicitation").isNone()) { elicitation = true }
                if (mcpText(value, "mode") == "url" && declared.field("url").isNone()) { elicitationUrl = true }
        }
    }
    let required = ArrayList<JsonObjectEntry>()
    if (roots) { required.add(JsonObjectEntry("roots", jsonObject([]))) }
    if (sampling || samplingTools || samplingContext) {
        let details = ArrayList<JsonObjectEntry>()
        if (samplingTools) { details.add(JsonObjectEntry("tools", jsonObject([]))) }
        if (samplingContext) { details.add(JsonObjectEntry("context", jsonObject([]))) }
        required.add(JsonObjectEntry("sampling", jsonObject(details.toArray())))
    }
    if (elicitation || elicitationUrl) {
        let details = ArrayList<JsonObjectEntry>()
        if (elicitationUrl) { details.add(JsonObjectEntry("url", jsonObject([]))) }
        required.add(JsonObjectEntry("elicitation", jsonObject(details.toArray())))
    }
    jsonObject(required.toArray())
}

func withMcpServerMeta(value: JsonNode, serverInfo: ?McpImplementationInfo): JsonNode {
    let fields = ArrayList<JsonObjectEntry>(); var meta = jsonObject([]); var resultType = false
    if (value.unifiedKind == UnifiedJsonKind.Object) { for (field in value.fields) {
        if (field.name == "_meta") { if (field.value.unifiedKind == UnifiedJsonKind.Object) { meta = field.value } }
        else { fields.add(field); if (field.name == "resultType") { resultType = true } }
    } }
    if (!resultType) { fields.add(JsonObjectEntry("resultType", jsonString(MCP_RESULT_COMPLETE))) }
    let metadata = ArrayList<JsonObjectEntry>()
    for (field in meta.fields where field.name != MCP_META_SERVER_INFO) { metadata.add(field) }
    match (serverInfo) {
        case Some(info) => metadata.add(JsonObjectEntry(MCP_META_SERVER_INFO, info.toValue()))
        case None => ()
    }
    if (!metadata.isEmpty()) { fields.add(JsonObjectEntry("_meta", jsonObject(metadata.toArray()))) }
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

func decodeMcpContinuation(
    params: JsonNode, notificationSink: (JsonRpcNotification) -> Unit
): McpResult<McpToolCallContinuation> {
    let responses = match (params.field("inputResponses")) {
        case Some(value) => if (value.unifiedKind == UnifiedJsonKind.Object) { value } else {
            return invalidMcp<McpToolCallContinuation>(
                "mcp.input_responses_invalid", "inputResponses must be an object"
            )
        }
        case None => jsonObject([])
    }
    for (field in responses.fields where field.value.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpToolCallContinuation>("mcp.input_response_invalid", "input response must be an object")
    }
    McpResult.Ok(McpToolCallContinuation(
        inputResponses: responses, requestState: mcpText(params, "requestState"),
        tasksSupported: mcpRequestSupportsTasks(params),
        progressToken: mcpField(mcpObject(params, "_meta"), "progressToken", jsonNull()),
        notificationSink: notificationSink
    ))
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
