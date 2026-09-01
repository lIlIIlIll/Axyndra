package mcp4cj

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*

public let MCP_TASKS_EXTENSION = "io.modelcontextprotocol/tasks"
public let MCP_METHOD_TASKS_GET = "tasks/get"
public let MCP_METHOD_TASKS_UPDATE = "tasks/update"
public let MCP_METHOD_TASKS_CANCEL = "tasks/cancel"
public let MCP_NOTIFICATION_TASKS = "notifications/tasks"
public let MCP_RESULT_TASK = "task"

public enum McpTaskStatus <: Equatable<McpTaskStatus> {
    Working | InputRequired | Completed | Failed | Cancelled
    public operator func ==(other: McpTaskStatus): Bool {
        match (this) {
            case Working => if (let Working <- other) { true } else { false }
            case InputRequired => if (let InputRequired <- other) { true } else { false }
            case Completed => if (let Completed <- other) { true } else { false }
            case Failed => if (let Failed <- other) { true } else { false }
            case Cancelled => if (let Cancelled <- other) { true } else { false }
        }
    }
    public operator func !=(other: McpTaskStatus): Bool { !(this == other) }
}

public class McpTask {
    public let taskId: String
    public let status: McpTaskStatus
    public let statusMessage: String
    public let createdAt: String
    public let lastUpdatedAt: String
    public let ttlMillis: ?Int64
    public let pollIntervalMillis: ?Int64
    public let inputRequests: JsonNode
    public let result: JsonNode
    public let error: JsonNode

    public init(
        taskId: String,
        status: McpTaskStatus,
        createdAt: String,
        lastUpdatedAt: String,
        ttlMillis: ?Int64,
        statusMessage!: String = "",
        pollIntervalMillis!: ?Int64 = None,
        inputRequests!: JsonNode = jsonObject([]),
        result!: JsonNode = jsonNull(),
        error!: JsonNode = jsonNull()
    ) {
        if (taskId.trimAscii() == "" || createdAt.trimAscii() == "" || lastUpdatedAt.trimAscii() == "") {
            throw IllegalArgumentException("MCP task requires id and timestamps")
        }
        match (ttlMillis) {
            case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP task ttl must not be negative") }
            case None => ()
        }
        match (pollIntervalMillis) {
            case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP task poll interval must not be negative") }
            case None => ()
        }
        requireObject(inputRequests, "MCP task inputRequests")
        for (field in inputRequests.fields) {
            match (decodeMcpInputRequest(field.value)) {
                case McpResult.Ok(_) => ()
                case McpResult.Err(error) => throw IllegalArgumentException(error.message)
            }
        }
        match (status) {
            case McpTaskStatus.InputRequired =>
                if (result.unifiedKind != UnifiedJsonKind.Null || error.unifiedKind != UnifiedJsonKind.Null) {
                    throw IllegalArgumentException("input_required MCP task must not include result or error")
                }
            case McpTaskStatus.Completed =>
                if (result.unifiedKind != UnifiedJsonKind.Object) { throw IllegalArgumentException("completed MCP task requires object result") }
                if (!inputRequests.fields.isEmpty() || error.unifiedKind != UnifiedJsonKind.Null) {
                    throw IllegalArgumentException("completed MCP task must not include inputRequests or error")
                }
            case McpTaskStatus.Failed =>
                if (error.unifiedKind != UnifiedJsonKind.Object) { throw IllegalArgumentException("failed MCP task requires object error") }
                if (!inputRequests.fields.isEmpty() || result.unifiedKind != UnifiedJsonKind.Null) {
                    throw IllegalArgumentException("failed MCP task must not include inputRequests or result")
                }
            case _ =>
                if (!inputRequests.fields.isEmpty() || result.unifiedKind != UnifiedJsonKind.Null || error.unifiedKind != UnifiedJsonKind.Null) {
                    throw IllegalArgumentException("working or cancelled MCP task must not include status payloads")
                }
        }
        this.taskId = taskId; this.status = status; this.statusMessage = statusMessage
        this.createdAt = createdAt; this.lastUpdatedAt = lastUpdatedAt; this.ttlMillis = ttlMillis
        this.pollIntervalMillis = pollIntervalMillis; this.inputRequests = inputRequests
        this.result = result; this.error = error
    }

    public func terminal(): Bool {
        status == McpTaskStatus.Completed || status == McpTaskStatus.Failed || status == McpTaskStatus.Cancelled
    }

    public func toValue(resultType!: String = MCP_RESULT_COMPLETE): JsonNode {
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("resultType", jsonString(resultType)))
        fields.add(JsonObjectEntry("taskId", jsonString(taskId)))
        fields.add(JsonObjectEntry("status", jsonString(mcpTaskStatusText(status))))
        if (statusMessage != "") { fields.add(JsonObjectEntry("statusMessage", jsonString(statusMessage))) }
        fields.add(JsonObjectEntry("createdAt", jsonString(createdAt)))
        fields.add(JsonObjectEntry("lastUpdatedAt", jsonString(lastUpdatedAt)))
        match (ttlMillis) {
            case Some(value) => fields.add(JsonObjectEntry("ttlMs", jsonNumber(value.toString())))
            case None => fields.add(JsonObjectEntry("ttlMs", jsonNull()))
        }
        match (pollIntervalMillis) {
            case Some(value) => fields.add(JsonObjectEntry("pollIntervalMs", jsonNumber(value.toString())))
            case None => ()
        }
        if (!inputRequests.fields.isEmpty()) { fields.add(JsonObjectEntry("inputRequests", inputRequests)) }
        if (result.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("result", result)) }
        if (error.unifiedKind != UnifiedJsonKind.Null) { fields.add(JsonObjectEntry("error", error)) }
        jsonObject(fields.toArray())
    }
}

public interface McpTaskStore {
    func create(task: McpTask): McpResult<Unit>
    func get(taskId: String): McpResult<?McpTask>
    func update(task: McpTask): McpResult<Unit>
}

public class MemoryMcpTaskStore <: McpTaskStore {
    private let lock = Mutex()
    private let tasks = ArrayList<McpTask>()
    public init() {}
    public func create(task: McpTask): McpResult<Unit> {
        lock.lock(); try {
            for (existing in tasks where existing.taskId == task.taskId) {
                return invalidMcp<Unit>("mcp.tasks.duplicate", "MCP task already exists")
            }
            tasks.add(task); McpResult.Ok(())
        } finally { lock.unlock() }
    }
    public func get(taskId: String): McpResult<?McpTask> {
        lock.lock(); try {
            for (task in tasks where task.taskId == taskId) { return McpResult.Ok(Some(task)) }
            McpResult.Ok(None)
        } finally { lock.unlock() }
    }
    public func update(task: McpTask): McpResult<Unit> {
        lock.lock(); try {
            for (index in 0..tasks.size where tasks[index].taskId == task.taskId) {
                if (tasks[index].terminal()) {
                    return invalidMcp<Unit>("mcp.tasks.terminal", "terminal MCP tasks cannot be updated")
                }
                tasks[index] = task; return McpResult.Ok(())
            }
            invalidMcp<Unit>("mcp.tasks.not_found", "MCP task was not found")
        } finally { lock.unlock() }
    }
}

public interface McpTaskProvider {
    func getTask(taskId: String): McpResult<McpTask>
    func updateTask(taskId: String, inputResponses: JsonNode): McpResult<Unit>
    func cancelTask(taskId: String): McpResult<Unit>
}

public func decodeMcpTask(value: JsonNode): McpResult<McpTask> {
    if (value.unifiedKind != UnifiedJsonKind.Object) {
        return invalidMcp<McpTask>("mcp.tasks.invalid", "MCP task must be an object")
    }
    let status = match (mcpText(value, "status")) {
        case "working" => McpTaskStatus.Working
        case "input_required" => McpTaskStatus.InputRequired
        case "completed" => McpTaskStatus.Completed
        case "failed" => McpTaskStatus.Failed
        case "cancelled" => McpTaskStatus.Cancelled
        case _ => return invalidMcp<McpTask>("mcp.tasks.status_invalid", "MCP task status is invalid")
    }
    let ttl: ?Int64 = match (value.field("ttlMs")) {
        case Some(item) => match (item.unifiedKind) {
            case UnifiedJsonKind.Null => None
            case UnifiedJsonKind.Number => try { Some(Int64.parse(item.number)) } catch (_: Exception) {
                return invalidMcp<McpTask>("mcp.tasks.ttl_invalid", "MCP task ttlMs must be an integer or null")
            }
            case _ => return invalidMcp<McpTask>("mcp.tasks.ttl_invalid", "MCP task ttlMs must be an integer or null")
        }
        case None => return invalidMcp<McpTask>("mcp.tasks.ttl_missing", "MCP task omitted ttlMs")
    }
    let poll: ?Int64 = match (value.field("pollIntervalMs")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) {
            try { Some(Int64.parse(item.number)) } catch (_: Exception) {
                return invalidMcp<McpTask>("mcp.tasks.poll_invalid", "MCP task pollIntervalMs must be an integer")
            }
        } else { return invalidMcp<McpTask>("mcp.tasks.poll_invalid", "MCP task pollIntervalMs must be an integer") }
        case None => None
    }
    let inputRequests = match (value.field("inputRequests")) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Object) { item } else {
            return invalidMcp<McpTask>("mcp.tasks.input_requests_invalid", "MCP task inputRequests must be an object")
        }
        case None => jsonObject([])
    }
    try {
        McpResult.Ok(McpTask(
            mcpText(value, "taskId"), status, mcpText(value, "createdAt"),
            mcpText(value, "lastUpdatedAt"), ttl,
            statusMessage: mcpText(value, "statusMessage"), pollIntervalMillis: poll,
            inputRequests: inputRequests,
            result: mcpField(value, "result", jsonNull()), error: mcpField(value, "error", jsonNull())
        ))
    } catch (exception: Exception) { invalidMcp<McpTask>("mcp.tasks.invalid", exception.message) }
}

func mcpTaskStatusText(status: McpTaskStatus): String {
    match (status) {
        case McpTaskStatus.Working => "working"
        case McpTaskStatus.InputRequired => "input_required"
        case McpTaskStatus.Completed => "completed"
        case McpTaskStatus.Failed => "failed"
        case McpTaskStatus.Cancelled => "cancelled"
    }
}

func withMcpTasksExtension(value: JsonNode): JsonNode {
    let fields = ArrayList<JsonObjectEntry>()
    for (field in value.fields where field.name != MCP_TASKS_EXTENSION) { fields.add(field) }
    fields.add(JsonObjectEntry(MCP_TASKS_EXTENSION, jsonObject([])))
    jsonObject(fields.toArray())
}
