package mcp4cj

import json4cj.*
import std.collection.*
import std.convert.*
import std.sync.*

public let MCP_TASKS_EXTENSION = "io.modelcontextprotocol/tasks"

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
    public let ttl: ?Int64
    public let pollInterval: ?Int64
    public let result: JsonValue
    public init(
        taskId: String,
        status: McpTaskStatus,
        statusMessage!: String = "",
        createdAt!: String = "",
        lastUpdatedAt!: String = "",
        ttl!: ?Int64 = None,
        pollInterval!: ?Int64 = None,
        result!: JsonValue = JsonValue.nullValue()
    ) {
        if (taskId.trimAscii() == "") { throw IllegalArgumentException("MCP task id must not be empty") }
        match (ttl) { case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP task ttl must not be negative") }; case None => () }
        match (pollInterval) { case Some(value) => if (value < 0) { throw IllegalArgumentException("MCP task poll interval must not be negative") }; case None => () }
        this.taskId = taskId; this.status = status; this.statusMessage = statusMessage
        this.createdAt = createdAt; this.lastUpdatedAt = lastUpdatedAt; this.ttl = ttl
        this.pollInterval = pollInterval; this.result = result
    }
    public func terminal(): Bool { status == McpTaskStatus.Completed || status == McpTaskStatus.Failed || status == McpTaskStatus.Cancelled }
}

public interface McpTaskStore {
    func create(task: McpTask): McpResult<Unit>
    func get(taskId: String): McpResult<?McpTask>
    func update(task: McpTask): McpResult<Unit>
    func list(cursor: String, limit: Int64): McpResult<Array<McpTask>>
    func remove(taskId: String): McpResult<Unit>
}

public class MemoryMcpTaskStore <: McpTaskStore {
    private let lock = Mutex()
    private let tasks = ArrayList<McpTask>()
    public init() {}
    public func create(task: McpTask): McpResult<Unit> {
        lock.lock(); try {
            for (existing in tasks where existing.taskId == task.taskId) { return invalidMcp<Unit>("mcp.tasks.duplicate", "MCP task already exists") }
            tasks.add(task); McpResult.Ok(())
        } finally { lock.unlock() }
    }
    public func get(taskId: String): McpResult<?McpTask> {
        lock.lock(); try { for (task in tasks where task.taskId == taskId) { return McpResult.Ok(Some(task)) }; McpResult.Ok(None) }
        finally { lock.unlock() }
    }
    public func update(task: McpTask): McpResult<Unit> {
        lock.lock(); try {
            for (index in 0..tasks.size where tasks[index].taskId == task.taskId) {
                if (tasks[index].terminal()) { return invalidMcp<Unit>("mcp.tasks.terminal", "terminal MCP tasks cannot be updated") }
                tasks[index] = task; return McpResult.Ok(())
            }
            invalidMcp<Unit>("mcp.tasks.not_found", "MCP task was not found")
        } finally { lock.unlock() }
    }
    public func list(cursor: String, limit: Int64): McpResult<Array<McpTask>> {
        if (limit <= 0) { return invalidMcp<Array<McpTask>>("mcp.tasks.limit_invalid", "MCP task list limit must be positive") }
        let offset: Int64 = if (cursor == "") { 0 } else { try { Int64.parse(cursor) } catch (_: Exception) { return invalidMcp<Array<McpTask>>("mcp.tasks.cursor_invalid", "invalid MCP task cursor") } }
        lock.lock(); try {
            if (offset < 0 || offset > tasks.size) { return invalidMcp<Array<McpTask>>("mcp.tasks.cursor_invalid", "invalid MCP task cursor") }
            let values = ArrayList<McpTask>(); let end = min(tasks.size, offset + limit)
            for (index in offset..end) { values.add(tasks[index]) }
            McpResult.Ok(values.toArray())
        } finally { lock.unlock() }
    }
    public func remove(taskId: String): McpResult<Unit> {
        lock.lock(); try {
            for (index in 0..tasks.size where tasks[index].taskId == taskId) { tasks.remove(at: index); return McpResult.Ok(()) }
            invalidMcp<Unit>("mcp.tasks.not_found", "MCP task was not found")
        } finally { lock.unlock() }
    }
}
