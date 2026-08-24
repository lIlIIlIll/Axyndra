package task_runtime

import agent_domain.*
import std.collection.*
import std.deriving.*
import std.sync.*

public class TaskId {
    public let value: String
    public init(value: String) {
        if (value.trimAscii() == "") {
            throw IllegalArgumentException("task id must not be empty")
        }
        this.value = value
    }
}

@Derive[Equatable]
public enum TaskStatus {
    Queued | Running | Blocked | Completed | Failed | Cancelled
}

public class TaskRecord {
    public let taskId: TaskId
    public let parentTaskId: ?TaskId
    public let runId: ?RunId
    public let title: String
    public let status: TaskStatus
    public let version: Int64

    public init(
        taskId: TaskId,
        title: String,
        status!: TaskStatus = TaskStatus.Queued,
        parentTaskId!: ?TaskId = None,
        runId!: ?RunId = None,
        version!: Int64 = 0
    ) {
        if (title.trimAscii() == "") {
            throw IllegalArgumentException("task title must not be empty")
        }
        this.taskId = taskId
        this.title = title
        this.status = status
        this.parentTaskId = parentTaskId
        this.runId = runId
        this.version = version
    }
}

public interface TaskRepository {
    func save(record: TaskRecord, expectedVersion: Int64): Result<Unit>
    func find(taskId: TaskId): Result<TaskRecord>
}

public class MemoryTaskRepository <: TaskRepository {
    private let lock = Mutex()
    private let values = ArrayList<TaskRecord>()

    public init() {}

    public func save(
        record: TaskRecord,
        expectedVersion: Int64
    ): Result<Unit> {
        lock.lock()
        try {
            for (index in 0..values.size) {
                if (values[index].taskId.value == record.taskId.value) {
                    // A version-zero record is a create request. Keep that
                    // distinct from the first legal transition, which uses
                    // expectedVersion=0 but writes version 1.
                    if (expectedVersion == 0 && record.version == 0) {
                        if (!terminalTaskStatus(values[index].status)) {
                            return taskConflict()
                        }
                        if (values[index].version == Int64.Max) {
                            return taskConflict()
                        }
                        // Keep the CAS token monotonic across generations so
                        // a delayed transition from an older version-zero
                        // generation cannot mutate the replacement task.
                        values[index] = TaskRecord(
                            record.taskId,
                            record.title,
                            status: record.status,
                            parentTaskId: record.parentTaskId,
                            runId: record.runId,
                            version: values[index].version + 1
                        )
                        return Result.Ok(())
                    }
                    if (values[index].version != expectedVersion) {
                        return taskConflict()
                    }
                    values[index] = record
                    return Result.Ok(())
                }
            }
            if (expectedVersion != 0) { return taskConflict() }
            values.add(record)
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func find(taskId: TaskId): Result<TaskRecord> {
        lock.lock()
        try {
            for (value in values where value.taskId.value == taskId.value) {
                return Result.Ok(value)
            }
            Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "task.not_found",
                "task was not found",
                fields: [ErrorField("task_id", taskId.value)]
            ))
        } finally {
            lock.unlock()
        }
    }
}

public class TaskService {
    private let repository: TaskRepository

    public init(repository: TaskRepository) {
        this.repository = repository
    }

    public func create(
        taskId: TaskId,
        title: String,
        parentTaskId!: ?TaskId = None
    ): Result<TaskRecord> {
        let record = TaskRecord(
            taskId,
            title,
            parentTaskId: parentTaskId
        )
        match (repository.save(record, 0)) {
            case Result.Ok(_) => repository.find(taskId)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func transition(
        taskId: TaskId,
        next: TaskStatus,
        runId!: ?RunId = None
    ): Result<TaskRecord> {
        let current = match (repository.find(taskId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!legalTransition(current.status, next)) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "task.invalid_transition",
                "task state transition is not legal"
            ))
        }
        let updated = TaskRecord(
            current.taskId,
            current.title,
            status: next,
            parentTaskId: current.parentTaskId,
            runId: match (runId) {
                case Some(value) => Some(value)
                case None => current.runId
            },
            version: current.version + 1
        )
        match (repository.save(updated, current.version)) {
            case Result.Ok(_) => Result.Ok(updated)
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func legalTransition(current: TaskStatus, next: TaskStatus): Bool {
    match ((current, next)) {
        case (TaskStatus.Queued, TaskStatus.Running) => true
        case (TaskStatus.Queued, TaskStatus.Cancelled) => true
        case (TaskStatus.Running, TaskStatus.Blocked) => true
        case (TaskStatus.Running, TaskStatus.Completed) => true
        case (TaskStatus.Running, TaskStatus.Failed) => true
        case (TaskStatus.Running, TaskStatus.Cancelled) => true
        case (TaskStatus.Blocked, TaskStatus.Running) => true
        case (TaskStatus.Blocked, TaskStatus.Cancelled) => true
        case _ => false
    }
}

func terminalTaskStatus(status: TaskStatus): Bool {
    match (status) {
        case TaskStatus.Completed => true
        case TaskStatus.Failed => true
        case TaskStatus.Cancelled => true
        case _ => false
    }
}

func taskConflict(): Result<Unit> {
    Result.Err(AgentError(
        AgentErrorKind.Conflict,
        "task.version_conflict",
        "task record version changed concurrently"
    ))
}
