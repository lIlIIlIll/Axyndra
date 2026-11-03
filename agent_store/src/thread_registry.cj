package agent_store

import std.collection.*
import std.sync.*
import agent_domain.*
import agent_runtime.*

class SqliteThreadRuntimeEntry {
    let threadId: ThreadId
    let runtime: AgentThreadRuntime
    var preparedPlanPins204: Int64 = 0

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
    private let continuationVerifier: ?ContinuationRunTransactionVerifier
    private let knownParentAllocation: ?(Int64)->LogicalJsonOwnerReservation
    private let entries = ArrayList<SqliteThreadRuntimeEntry>()

    public init(
        database: SqliteDatabase,
        projector: ContextProjector,
        nowMillis: () -> Int64,
        continuationVerifier!: ?ContinuationRunTransactionVerifier = None,
        knownParentAllocation!: ?(Int64)->LogicalJsonOwnerReservation = None
    ) {
        this.database = database
        this.projector = projector
        this.nowMillis = nowMillis
        this.continuationVerifier = continuationVerifier
        this.knownParentAllocation=knownParentAllocation
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
            let sink = SqliteThreadCommitSink(database, continuationVerifier: continuationVerifier, knownParentAllocation:knownParentAllocation)
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
                checkpointRepository: Some(SqliteContextCheckpointStore(database)),
                knownParentHistoryEnabled:knownParentAllocation.isSome()
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
                nowMillis,
                continuationVerifier: continuationVerifier
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

    // This entry point copies numeric DATA; it cannot acquire/recover a Run or
    // substitute an interface response for an original Source/transaction gate.
    public func resolveOperationOwnedUtf8204(
        runtime: AgentThreadRuntime, value: PreparedPlanUtf8Owner204,
        itemId: ItemId, operationId: OperationId, callId: CanonicalToolCallId,
        stage: OperationAttemptStage, attempt: Result<ToolInvocationResult>,
        receiptId: String, observedAtMillis: Int64,
        expectedRunId!: RunId, expectedEpoch!: Int64
    ): Result<Unit> {
        let phase = openPreparedPlanCopy204(value)
        try {
            let result = resolveCopiedPlanFrame204(phase, runtime, itemId, operationId,
                callId, stage, attempt, receiptId, observedAtMillis, expectedRunId, expectedEpoch)
            match (result) {
                case Result.Err(error) => phase.holdError204(error)
                case Result.Ok(_) => returnPreparedPlanCopy204(phase)
            }
            result
        } catch (error: Exception) {
            phase.holdException204(error); throw error
        }
    }

    private func resolveCopiedPlanFrame204(phase: PreparedPlanCopyPhase204,
        runtime: AgentThreadRuntime, itemId: ItemId, operationId: OperationId,
        callId: CanonicalToolCallId, stage: OperationAttemptStage,
        attempt: Result<ToolInvocationResult>, receiptId: String, observedAtMillis: Int64,
        expectedRunId: RunId, expectedEpoch: Int64): Result<Unit> {
        let entry = match (pinPreparedRuntime204(runtime)) {
            case Some(value) => value
            case None => return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
                "thread.registry_owned_runtime_missing", "prepared resolution requires this registry's existing Runtime"))
        }
        try {
            // The Registry mutex is not held while entering Runtime or SQL.
            // The original Runtime resolve gate repeats Run/epoch validation
            // atomically with resolution; this check cannot authorize a Run.
            if (!preparedRuntimeIdentity204(entry, expectedRunId, expectedEpoch)) {
                return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
                    "thread.registry_owned_run_stale", "prepared resolution belongs to another Run or epoch")) }
            phase.copyAndDecodeFrame204()
            phase.sourceCopyReturned204()
            phase.resolveFrame204(runtime, itemId, operationId, callId, stage, attempt,
                receiptId, observedAtMillis, expectedRunId, expectedEpoch)
        } finally {
            // All original Runtime/SQL/temporary resolution frames returned
            // before this scalar pin drops. The outer caller still owns phase.
            unpinPreparedRuntime204(entry)
        }
    }

    private func pinPreparedRuntime204(runtime: AgentThreadRuntime): ?SqliteThreadRuntimeEntry {
        lock.lock()
        try {
            for (entry in entries) {
                if (refEq(entry.runtime, runtime)) {
                    if (entry.preparedPlanPins204 == Int64.Max) {
                        throw IllegalStateException("prepared Runtime pin count is exhausted") }
                    entry.preparedPlanPins204++
                    return Some(entry)
                }
            }
            None<SqliteThreadRuntimeEntry>
        } finally { lock.unlock() }
    }

    private func preparedRuntimeIdentity204(entry: SqliteThreadRuntimeEntry,
        expectedRunId: RunId, expectedEpoch: Int64): Bool {
        match (entry.runtime.activeRunControl159()) {
            case None => false
            case Some(control) =>
                let (threadId, _, runId, epoch, _, _, _) = control
                threadId.value == entry.threadId.value && runId.value == expectedRunId.value &&
                    epoch == expectedEpoch
        }
    }

    private func unpinPreparedRuntime204(entry: SqliteThreadRuntimeEntry): Unit {
        lock.lock()
        try {
            if (entry.preparedPlanPins204 < 1) {
                throw IllegalStateException("prepared Runtime pin count underflow") }
            entry.preparedPlanPins204--
        } finally { lock.unlock() }
    }

    public func discardInactive(threadId: ThreadId): Result<Bool> {
        lock.lock()
        try {
            var index: Int64 = 0
            while (index < entries.size) {
                if (entries[index].threadId.value == threadId.value) {
                    if (entries[index].preparedPlanPins204 != 0) {
                        return Result<Bool>.Err(AgentError(AgentErrorKind.Conflict,
                            "thread.registry_discard_borrowed", "cannot discard a Runtime with an active prepared DATA receiver")) }
                    if (entries[index].runtime.hasActiveRun159()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "thread.registry_discard_active",
                            "cannot discard a Thread with an active Run",
                            fields: [ErrorField("thread_id", threadId.value)]
                        ))
                    }
                    break
                }
                index += 1
            }
            let result: Result<Bool> = database.transaction { transaction: SqliteTransaction =>
                let rows = transaction.query(
                    "SELECT active_turn_id FROM threads WHERE id=" + sqliteText(threadId.value)
                )
                if (rows.isEmpty()) { return Result.Ok(false) }
                if (rows[0][0].isSome() || transaction.query(
                    "SELECT COUNT(*) FROM turns WHERE thread_id=" + sqliteText(threadId.value) +
                        " AND active_run_id IS NOT NULL"
                )[0].required(0) != "0") {
                    return Result<Bool>.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "thread.registry_discard_active",
                        "cannot discard a Thread with an active Run",
                        fields: [ErrorField("thread_id", threadId.value)]
                    ))
                }
                transaction.execute(
                    "DELETE FROM audit_events WHERE thread_id=" + sqliteText(threadId.value)
                )
                transaction.execute("DELETE FROM threads WHERE id=" + sqliteText(threadId.value))
                Result.Ok(true)
            }
            if (result.isOk() && index < entries.size) { entries.remove(at: index) }
            result
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
                    if (entries[index].preparedPlanPins204 != 0) {
                        return Result<Bool>.Err(AgentError(AgentErrorKind.Conflict,
                            "thread.registry_release_borrowed", "cannot release a Runtime with an active prepared DATA receiver")) }
                    if (entries[index].runtime.hasActiveRun159()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "thread.registry_release_active",
                            "cannot release a Thread with an active Run",
                            fields: [ErrorField("thread_id", threadId.value)]
                        ))
                    }
                    if (entries[index].runtime.hasRetainedQueuedInputCache113()) {
                        return Result<Bool>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "thread.registry_queued_cache_retained", "actual cached input aliases still require their retained owner")) }
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
