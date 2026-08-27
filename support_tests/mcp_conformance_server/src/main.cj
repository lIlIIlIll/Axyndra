package mcp_conformance_server

import mcp4cj.*
import jsonrpc4cj.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.env.*
import std.sync.*

main(): Int64 {
    let arguments = getCommandLine()
    let port = if (arguments.size > 1) { Int64.parse(arguments[1]) } else { 3011 }
    let providers = ConformanceProviders()
    let tools = conformanceTools()
    let host = MemoryMcpToolHost(tools, {
        name: String, arguments: JsonNode, continuation: McpToolCallContinuation =>
        providers.call(name, arguments, continuation)
    })
    let protocol = McpServerBuilder(
        serverInfo: McpImplementationInfo("mcp4cj-conformance", "0.1.0")
    ).toolProvider(host).completionProvider(providers).promptProvider(providers)
        .resourceProvider(providers).notificationProvider(providers).taskProvider(providers).build()
    let server = match (openStreamableHttpMcpServer(
        McpStreamableHttpServerConfig(port: port), protocol
    )) {
        case McpResult.Ok(value) => value
        case McpResult.Err(error) => throw error
    }
    println("mcp4cj conformance server: http://127.0.0.1:" + port.toString() + "/mcp")
    match (server.serve()) {
        case McpResult.Ok(_) => 0
        case McpResult.Err(error) => throw error
    }
}

func conformanceTools(): Array<McpTool> {
    let schema = jsonObject([JsonObjectEntry("type", jsonString("object"))])
    let names = [
        "test_simple_text", "test_image_content", "test_audio_content",
        "test_embedded_resource", "test_multiple_content_types", "test_error_handling",
        "test_tool_with_progress", "test_missing_capability", "test_streaming_elicitation",
        "test_logging_tool", "test_input_required_result_elicitation",
        "test_input_required_result_sampling", "test_input_required_result_list_roots",
        "test_input_required_result_request_state", "test_input_required_result_multiple_inputs",
        "test_input_required_result_multi_round", "test_input_required_result_tampered_state",
        "test_input_required_result_capabilities"
    ]
    let tools = ArrayList<McpTool>()
    for (name in names) { tools.add(McpTool(name, "MCP conformance fixture", schema)) }
    tools.add(McpTool("greet", "Synchronous greeting", schema))
    for (name in ["slow_compute", "confirm_delete", "multi_input", "protocol_error_job"]) {
        tools.add(McpTool(
            name, "Task conformance fixture", schema,
            execution: Some(McpToolExecution(taskSupport: McpTaskSupport.Optional))
        ))
    }
    for (name in ["failing_job", "test_tool_with_task"]) {
        tools.add(McpTool(
            name, "Required task conformance fixture", schema,
            execution: Some(McpToolExecution(taskSupport: McpTaskSupport.Required))
        ))
    }
    tools.toArray()
}

class ConformanceProviders <: McpCompletionProvider & McpPromptProvider & McpResourceProvider & McpNotificationProvider & McpTaskProvider {
    private let taskLock = Mutex()
    private let taskRecords = ArrayList<ConformanceTaskRecord>()
    private var nextTaskId: Int64 = 1

    func call(name: String, arguments: JsonNode, continuation: McpToolCallContinuation): McpResult<McpCallToolOutcome> {
        if (name == "greet") { return completeText("Hello, " + fieldText(arguments, "name") + "!") }
        if (name == "slow_compute") {
            if (!continuation.tasksSupported || fieldInt(arguments, "seconds") == 0) {
                return completeText("Computation complete")
            }
            return createTask("slow", keepWorking: fieldInt(arguments, "seconds") >= 60)
        }
        if (name == "failing_job") { return createTask("tool-error") }
        if (name == "protocol_error_job") {
            if (!continuation.tasksSupported) { return completeText("Protocol job complete") }
            return createTask("protocol-error")
        }
        if (name == "confirm_delete") {
            if (!continuation.tasksSupported) { return completeText("Delete confirmation complete") }
            return createInputTask("confirm", jsonObject([JsonObjectEntry(
                "confirm-delete", inputRequest("elicitation/create", elicitationParams("Confirm delete"))
            )]))
        }
        if (name == "multi_input") {
            if (!continuation.tasksSupported) { return completeText("Multiple inputs complete") }
            return createInputTask("multi", jsonObject([
                JsonObjectEntry("first-input", inputRequest("elicitation/create", elicitationParams("First input"))),
                JsonObjectEntry("second-input", inputRequest("elicitation/create", elicitationParams("Second input")))
            ]))
        }
        if (name == "test_tool_with_task") {
            if (continuation.inputResponses.fields.isEmpty()) {
                return inputOutcome(
                    "user_name", "elicitation/create", elicitationParams("What is your name?"),
                    continuation, "task-composition-state"
                )
            }
            var userName = "Alice"
            match (continuation.inputResponses.field("user_name")) {
                case Some(response) => match (response.field("content")) {
                    case Some(content) => if (fieldText(content, "name") != "") { userName = fieldText(content, "name") }
                    case None => ()
                }
                case None => ()
            }
            return createCompletedTask("composed", "Hello, " + userName + "!")
        }
        if (name == "test_missing_capability") {
            return inputOutcome("sample", "sampling/createMessage", samplingParams(), continuation, "missing-capability-state")
        }
        if (name == "test_input_required_result_elicitation" ||
            name == "test_streaming_elicitation" || name == "test_input_required_result_tampered_state") {
            return elicitationOutcome(name, continuation)
        }
        if (name == "test_input_required_result_sampling" || name == "test_input_required_result_capabilities") {
            return inputOutcome("sample", "sampling/createMessage", samplingParams(), continuation, "sampling-state")
        }
        if (name == "test_input_required_result_list_roots") {
            return inputOutcome("roots", "roots/list", jsonObject([]), continuation, "roots-state")
        }
        if (name == "test_input_required_result_request_state") {
            return inputOutcome("answer", "elicitation/create", elicitationParams("State test"), continuation, "opaque-conformance-state")
        }
        if (name == "test_input_required_result_multiple_inputs") {
            if (continuation.inputResponses.fields.isEmpty()) {
                return McpResult.Ok(McpCallToolOutcome.InputRequired(McpInputRequiredResult(
                    inputRequests: jsonObject([
                        JsonObjectEntry("first", inputRequest("elicitation/create", elicitationParams("First"))),
                        JsonObjectEntry("second", inputRequest("sampling/createMessage", samplingParams())),
                        JsonObjectEntry("third", inputRequest("roots/list", jsonObject([])))
                    ]), requestState: "multiple-state"
                )))
            }
            return completeText("multiple inputs complete")
        }
        if (name == "test_input_required_result_multi_round") {
            if (continuation.requestState == "") {
                return inputOutcome("round1", "elicitation/create", elicitationParams("Round one"), continuation, "round-1")
            }
            if (continuation.requestState == "round-1") {
                return inputOutcome("round2", "elicitation/create", elicitationParams("Round two"), McpToolCallContinuation(), "round-2")
            }
            return completeText("multi round complete")
        }
        if (name == "test_error_handling") {
            return McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                [textBlock("This tool intentionally returns an error for testing")], isError: true
            )))
        }
        if (name == "test_tool_with_progress") {
            continuation.reportProgress(0.0, total: Some(100.0))
            continuation.reportProgress(50.0, total: Some(100.0))
            continuation.reportProgress(100.0, total: Some(100.0))
            return completeText("progress complete")
        }
        if (name == "test_image_content") { return complete([imageBlock()]) }
        if (name == "test_audio_content") { return complete([audioBlock()]) }
        if (name == "test_embedded_resource") { return complete([resourceBlock("test://embedded-resource")]) }
        if (name == "test_multiple_content_types") {
            return complete([textBlock("Multiple content types test:"), imageBlock(), resourceBlock("test://mixed-content-resource")])
        }
        completeText("This is a simple text response for testing.")
    }

    private func createTask(kind: String, keepWorking!: Bool = false): McpResult<McpCallToolOutcome> {
        taskLock.lock(); try {
            let id = "task-" + nextTaskId.toString(); nextTaskId++
            let task = baseTask(id, McpTaskStatus.Working)
            taskRecords.add(ConformanceTaskRecord(task, kind, keepWorking: keepWorking))
            McpResult.Ok(McpCallToolOutcome.Task(task))
        } finally { taskLock.unlock() }
    }

    private func createInputTask(kind: String, requests: JsonNode): McpResult<McpCallToolOutcome> {
        taskLock.lock(); try {
            let id = "task-" + nextTaskId.toString(); nextTaskId++
            let task = baseTask(id, McpTaskStatus.InputRequired, inputRequests: requests)
            taskRecords.add(ConformanceTaskRecord(task, kind))
            McpResult.Ok(McpCallToolOutcome.Task(task))
        } finally { taskLock.unlock() }
    }

    private func createCompletedTask(kind: String, text: String): McpResult<McpCallToolOutcome> {
        taskLock.lock(); try {
            let id = "task-" + nextTaskId.toString(); nextTaskId++
            let task = baseTask(id, McpTaskStatus.Completed, result: taskToolResult(text))
            taskRecords.add(ConformanceTaskRecord(task, kind))
            McpResult.Ok(McpCallToolOutcome.Task(task))
        } finally { taskLock.unlock() }
    }

    public func getTask(taskId: String): McpResult<McpTask> {
        taskLock.lock(); try {
            for (record in taskRecords where record.task.taskId == taskId) {
                if (record.task.status == McpTaskStatus.Working && !record.keepWorking) {
                    record.gets++
                    if (record.gets >= 2) {
                        if (record.kind == "protocol-error") {
                            record.task = baseTask(taskId, McpTaskStatus.Failed, error: jsonObject([
                                JsonObjectEntry("code", jsonNumber("-32603")),
                                JsonObjectEntry("message", jsonString("Protocol task failed"))
                            ]))
                        } else if (record.kind == "tool-error") {
                            record.task = baseTask(taskId, McpTaskStatus.Completed, result: jsonObject([
                                JsonObjectEntry("content", jsonArray([textBlock("Tool execution failed")])),
                                JsonObjectEntry("isError", jsonBool(true))
                            ]))
                        } else {
                            record.task = baseTask(taskId, McpTaskStatus.Completed, result: taskToolResult("Computation complete"))
                        }
                    }
                }
                return McpResult.Ok(record.task)
            }
            McpResult.Err(McpError(McpErrorKind.Protocol, "mcp.tasks.not_found", "MCP task was not found"))
        } finally { taskLock.unlock() }
    }

    public func updateTask(taskId: String, inputResponses: JsonNode): McpResult<Unit> {
        taskLock.lock(); try {
            for (record in taskRecords where record.task.taskId == taskId) {
                if (record.task.status != McpTaskStatus.InputRequired) { return McpResult.Ok(()) }
                let remaining = ArrayList<JsonObjectEntry>()
                for (pending in record.task.inputRequests.fields where inputResponses.field(pending.name).isNone()) {
                    remaining.add(pending)
                }
                if (remaining.isEmpty()) {
                    record.task = baseTask(taskId, McpTaskStatus.Completed, result: taskToolResult("Input accepted"))
                } else if (remaining.size < record.task.inputRequests.fields.size) {
                    record.task = baseTask(taskId, McpTaskStatus.InputRequired, inputRequests: jsonObject(remaining.toArray()))
                }
                return McpResult.Ok(())
            }
            McpResult.Err(McpError(McpErrorKind.Protocol, "mcp.tasks.not_found", "MCP task was not found"))
        } finally { taskLock.unlock() }
    }

    public func cancelTask(taskId: String): McpResult<Unit> {
        taskLock.lock(); try {
            for (record in taskRecords where record.task.taskId == taskId) {
                if (!record.task.terminal()) { record.task = baseTask(taskId, McpTaskStatus.Cancelled) }
                return McpResult.Ok(())
            }
            McpResult.Err(McpError(McpErrorKind.Protocol, "mcp.tasks.not_found", "MCP task was not found"))
        } finally { taskLock.unlock() }
    }

    public func complete(
        requestId: JsonRpcId, reference: JsonNode, argument: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpCompletionResult>> {
        let _ = requestId; let _ = reference; let _ = argument; let _ = continuation
        McpResult.Ok(McpOperationOutcome.Complete(McpCompletionResult(jsonObject([
            JsonObjectEntry("values", jsonArray([jsonString("test completion")])),
            JsonObjectEntry("total", jsonNumber("1")), JsonObjectEntry("hasMore", jsonBool(false))
        ]))))
    }

    public func listPrompts(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([
            McpPrompt("test_simple_prompt", description: "Simple conformance prompt").toValue(),
            McpPrompt("test_prompt_with_arguments", arguments: [
                McpPromptArgument("arg1", required: true), McpPromptArgument("arg2", required: true)
            ], description: "Prompt with two arguments").toValue(),
            McpPrompt("test_prompt_with_embedded_resource", arguments: [McpPromptArgument("resourceUri", required: true)], description: "Prompt with an embedded resource").toValue(),
            McpPrompt("test_prompt_with_image", description: "Prompt with an image").toValue(),
            McpPrompt("test_input_required_result_prompt", description: "Prompt requiring client input").toValue()
        ]))
    }

    public func getPrompt(
        requestId: JsonRpcId, name: String, arguments: JsonNode,
        continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpPromptResult>> {
        let _ = requestId
        if (name == "test_input_required_result_prompt" && continuation.inputResponses.fields.isEmpty()) {
            return McpResult.Ok(McpOperationOutcome.InputRequired(McpInputRequiredResult(
                inputRequests: jsonObject([JsonObjectEntry("user_context", inputRequest(
                    "elicitation/create", elicitationParams("What context should the prompt use?")
                ))]), requestState: "prompt-state"
            )))
        }
        let content = if (name == "test_prompt_with_image") { imageBlock() }
            else if (name == "test_prompt_with_embedded_resource") {
                resourceBlock(fieldText(arguments, "resourceUri"))
            } else if (name == "test_prompt_with_arguments") {
                textBlock("arg1=" + fieldText(arguments, "arg1") + "; arg2=" + fieldText(arguments, "arg2"))
            } else { textBlock("Conformance prompt: " + name) }
        McpResult.Ok(McpOperationOutcome.Complete(McpPromptResult([jsonObject([
            JsonObjectEntry("role", jsonString("user")), JsonObjectEntry("content", content)
        ])])))
    }

    public func listResources(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([
            McpResource("test://static-text", "static text", mimeType: "text/plain").toValue(),
            McpResource("test://static-binary", "static binary", mimeType: "application/octet-stream").toValue()
        ]))
    }

    public func listResourceTemplates(cursor: String): McpResult<McpPage> {
        let _ = cursor
        McpResult.Ok(McpPage([
            McpResourceTemplate("test://template/{id}/data", "template data", mimeType: "application/json").toValue()
        ]))
    }

    public func readResource(
        requestId: JsonRpcId, uri: String, continuation: McpToolCallContinuation
    ): McpResult<McpOperationOutcome<McpReadResourceResult>> {
        let _ = requestId; let _ = continuation
        if (uri == "test://static-text") {
            return readComplete(jsonObject([
                JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("mimeType", jsonString("text/plain")),
                JsonObjectEntry("text", jsonString("This is static text content for testing."))
            ]))
        }
        if (uri == "test://static-binary") {
            return readComplete(jsonObject([
                JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("mimeType", jsonString("application/octet-stream")),
                JsonObjectEntry("blob", jsonString("SGVsbG8sIE1DUCE="))
            ]))
        }
        if (uri == "test://template/123/data") {
            return readComplete(jsonObject([
                JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("mimeType", jsonString("application/json")),
                JsonObjectEntry("text", jsonString("{\"id\":\"123\",\"data\":\"Template-generated content\"}"))
            ]))
        }
        McpResult.Err(McpError(
            McpErrorKind.Protocol, "mcp.resource_not_found", "Resource not found",
            data: jsonObject([JsonObjectEntry("uri", jsonString(uri))])
        ))
    }

    public func open(
        requestId: JsonRpcId, filter: McpSubscriptionFilter
    ): McpResult<McpSubscriptionSource> {
        let _ = requestId
        McpResult.Ok(ConformanceSubscriptionSource(filter))
    }
    public func cancel(requestId: JsonRpcId, reason: String): McpResult<Unit> {
        let _ = requestId; let _ = reason; McpResult.Ok(())
    }
}

class ConformanceTaskRecord {
    var task: McpTask
    let kind: String
    let keepWorking: Bool
    var gets: Int64 = 0
    init(task: McpTask, kind: String, keepWorking!: Bool = false) {
        this.task = task; this.kind = kind; this.keepWorking = keepWorking
    }
}

func baseTask(
    id: String, status: McpTaskStatus,
    inputRequests!: JsonNode = jsonObject([]),
    result!: JsonNode = jsonNull(), error!: JsonNode = jsonNull()
): McpTask {
    McpTask(
        id, status, "2026-08-27T00:00:00Z", "2026-08-27T00:00:01Z", Some(60000),
        pollIntervalMillis: Some(10), inputRequests: inputRequests, result: result, error: error
    )
}

func taskToolResult(text: String): JsonNode {
    jsonObject([
        JsonObjectEntry("content", jsonArray([textBlock(text)])),
        JsonObjectEntry("isError", jsonBool(false))
    ])
}

class ConformanceSubscriptionSource <: McpSubscriptionSource {
    private let filter: McpSubscriptionFilter
    private var emitted = false
    init(filter: McpSubscriptionFilter) { this.filter = filter }
    public func acknowledged(): McpSubscriptionFilter { filter }
    public func next(): McpResult<?JsonRpcNotification> {
        if (emitted) { return McpResult.Ok(None) }
        emitted = true
        if (filter.toolsListChanged) {
            McpResult.Ok(Some(JsonRpcNotification(MCP_NOTIFICATION_TOOLS_LIST_CHANGED, params: jsonObject([]))))
        } else if (filter.promptsListChanged) {
            McpResult.Ok(Some(JsonRpcNotification(MCP_NOTIFICATION_PROMPTS_LIST_CHANGED, params: jsonObject([]))))
        } else if (filter.resourcesListChanged) {
            McpResult.Ok(Some(JsonRpcNotification(MCP_NOTIFICATION_RESOURCES_LIST_CHANGED, params: jsonObject([]))))
        } else { McpResult.Ok(None) }
    }
    public func close(): McpResult<Unit> { McpResult.Ok(()) }
}

func elicitationOutcome(name: String, continuation: McpToolCallContinuation): McpResult<McpCallToolOutcome> {
    if (name == "test_input_required_result_tampered_state" &&
        continuation.requestState != "" && continuation.requestState != "signed-state") {
        return McpResult.Err(McpError(
            McpErrorKind.Protocol, "mcp.request_state_invalid", "requestState integrity check failed"
        ))
    }
    inputOutcome("user_name", "elicitation/create", elicitationParams("What is your name?"), continuation, "signed-state")
}

func inputOutcome(
    key: String, method: String, params: JsonNode,
    continuation: McpToolCallContinuation, state: String
): McpResult<McpCallToolOutcome> {
    if (!continuation.inputResponses.fields.isEmpty()) { return completeText("input complete") }
    McpResult.Ok(McpCallToolOutcome.InputRequired(McpInputRequiredResult(
        inputRequests: jsonObject([JsonObjectEntry(key, inputRequest(method, params))]),
        requestState: state
    )))
}

func inputRequest(method: String, params: JsonNode): JsonNode {
    jsonObject([JsonObjectEntry("method", jsonString(method)), JsonObjectEntry("params", params)])
}

func elicitationParams(message: String): JsonNode {
    jsonObject([
        JsonObjectEntry("message", jsonString(message)),
        JsonObjectEntry("requestedSchema", jsonObject([
            JsonObjectEntry("type", jsonString("object")),
            JsonObjectEntry("properties", jsonObject([JsonObjectEntry("name", jsonObject([
                JsonObjectEntry("type", jsonString("string"))
            ]))])), JsonObjectEntry("required", jsonArray([jsonString("name")]))
        ]))
    ])
}

func samplingParams(): JsonNode {
    jsonObject([
        JsonObjectEntry("messages", jsonArray([jsonObject([
            JsonObjectEntry("role", jsonString("user")), JsonObjectEntry("content", textBlock("Sample this"))
        ])])), JsonObjectEntry("maxTokens", jsonNumber("100"))
    ])
}

func completeText(text: String): McpResult<McpCallToolOutcome> { complete([textBlock(text)]) }
func complete(content: Array<JsonNode>): McpResult<McpCallToolOutcome> {
    McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult(content)))
}
func readComplete(content: JsonNode): McpResult<McpOperationOutcome<McpReadResourceResult>> {
    McpResult.Ok(McpOperationOutcome.Complete(McpReadResourceResult([content])))
}
func textBlock(text: String): JsonNode {
    jsonObject([JsonObjectEntry("type", jsonString("text")), JsonObjectEntry("text", jsonString(text))])
}
func imageBlock(): JsonNode {
    jsonObject([
        JsonObjectEntry("type", jsonString("image")),
        JsonObjectEntry("data", jsonString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2GAAAAABJRU5ErkJggg==")),
        JsonObjectEntry("mimeType", jsonString("image/png"))
    ])
}
func audioBlock(): JsonNode {
    jsonObject([
        JsonObjectEntry("type", jsonString("audio")), JsonObjectEntry("data", jsonString("UklGRg==")),
        JsonObjectEntry("mimeType", jsonString("audio/wav"))
    ])
}
func resourceBlock(uri: String): JsonNode {
    jsonObject([
        JsonObjectEntry("type", jsonString("resource")), JsonObjectEntry("resource", jsonObject([
            JsonObjectEntry("uri", jsonString(uri)), JsonObjectEntry("mimeType", jsonString("application/json")),
            JsonObjectEntry("text", jsonString("{\"test\":\"data\",\"value\":123}"))
        ]))
    ])
}
func fieldText(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func fieldInt(value: JsonNode, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) {
            try { Int64.parse(item.number) } catch (_: Exception) { 0 }
        } else { 0 }
        case None => 0
    }
}
