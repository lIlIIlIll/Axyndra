package agent_store

import std.collection.*
import std.sync.*
import agent_domain.*
import agent_runtime.*

class SqliteThreadRuntimeEntry {
    let threadId: ThreadId
    let runtime: AgentThreadRuntime

    init(threadId: ThreadId, runtime: AgentThreadRuntime) {
        this.threadId = threadId
        this.runtime = runtime
    }
}

// Process-local owner registry backed by one SQLite WAL database. Reopening an
// inactive Thread rebuilds its immutable state from SQLite; an active durable
// Run must go through explicit recovery instead of being guessed here.
public class SqliteThreadRuntimeRegistry <: ThreadRuntimeRegistry {
    private let lock = Mutex()
    private let database: SqliteDatabase
    private let projector: ContextProjector
    private let nowMillis: () -> Int64
    private let entries = ArrayList<SqliteThreadRuntimeEntry>()

    public init(
        database: SqliteDatabase,
        projector: ContextProjector,
        nowMillis: () -> Int64
    ) {
        this.database = database
        this.projector = projector
        this.nowMillis = nowMillis
    }

    public func acquire(
        threadId: ThreadId,
        workspaceId: String
    ): Result<AgentThreadRuntime> {
        lock.lock()
        try {
            for (entry in entries where entry.threadId.value == threadId.value) {
                return Result.Ok(entry.runtime)
            }
            let sink = SqliteThreadCommitSink(database)
            let snapshot = if (database.scalarInt(
                "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(threadId.value)
            ) == 0) {
                sink.createThread(threadId, workspaceId)
            } else {
                sink.loadThread(threadId)
            }
            if (snapshot.thread.activeTurnId.isSome()) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "thread.registry_recovery_required",
                    "Thread has an active durable Run and requires reconciliation",
                    fields: [ErrorField("thread_id", threadId.value)]
                ))
            }
            let runtime = AgentThreadRuntime(
                ThreadCoordinator(snapshot, sink), projector, nowMillis,
                checkpointRepository: Some(SqliteContextCheckpointStore(database))
            )
            entries.add(SqliteThreadRuntimeEntry(threadId, runtime))
            Result.Ok(runtime)
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "thread.registry_acquire_failed",
                error.message,
                fields: [ErrorField("thread_id", threadId.value)]
            ))
        } finally {
            lock.unlock()
        }
    }

    public func recover(
        threadId: ThreadId,
        workspaceId: String
    ): Result<AgentThreadRuntime> {
        let _ = workspaceId
        lock.lock()
        try {
            for (entry in entries where entry.threadId.value == threadId.value) {
                return Result.Ok(entry.runtime)
            }
            let runtime = match (SqliteThreadRuntimeRecovery(database).resume(
                threadId,
                projector,
                nowMillis
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            entries.add(SqliteThreadRuntimeEntry(threadId, runtime))
            Result.Ok(runtime)
        } finally {
            lock.unlock()
        }
    }

    public func discardInactive(threadId: ThreadId): Result<Bool> {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < entries.size) {
                if (entries[index].threadId.value == threadId.value) {
                    if (entries[index].runtime.activeRun().isSome()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "thread.registry_discard_active",
                            "cannot discard a Thread with an active Run",
                            fields: [ErrorField("thread_id", threadId.value)]
                        ))
                    }
                    entries.remove(at: index)
                    break
                }
                index += 1
            }
            let existed = database.scalarInt(
                "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(threadId.value)
            ) > 0
            if (existed) {
                database.transaction { transaction =>
                    transaction.execute(
                        "DELETE FROM audit_events WHERE thread_id=" + sqliteText(threadId.value)
                    )
                    transaction.execute(
                        "DELETE FROM threads WHERE id=" + sqliteText(threadId.value)
                    )
                }
            }
            Result.Ok(existed)
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "thread.registry_discard_failed",
                error.message,
                fields: [ErrorField("thread_id", threadId.value)]
            ))
        } finally {
            lock.unlock()
        }
    }

    public func releaseInactive(threadId: ThreadId): Result<Bool> {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < entries.size) {
                if (entries[index].threadId.value == threadId.value) {
                    if (entries[index].runtime.activeRun().isSome()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "thread.registry_release_active",
                            "cannot release a Thread with an active Run",
                            fields: [ErrorField("thread_id", threadId.value)]
                        ))
                    }
                    entries.remove(at: index)
                    return Result.Ok(true)
                }
                index += 1
            }
            Result.Ok(false)
        } finally {
            lock.unlock()
        }
    }
}
