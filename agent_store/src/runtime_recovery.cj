package agent_store

import agent_domain.*
import agent_runtime.*

public class SqliteThreadRuntimeRecovery {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func pendingActions(threadId: ThreadId): Array<RecoveryAction> {
        OperationRecoveryPlanner(database).inspect(threadId)
    }

    public func resume(
        threadId: ThreadId,
        projector: ContextProjector,
        nowMillis: () -> Int64
    ): Result<AgentThreadRuntime> {
        try {
            let sink = SqliteThreadCommitSink(database)
            let thread = sink.loadThread(threadId)
            if (thread.thread.activeTurnId.isNone() || thread.activeRunId.isNone()) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "thread.recovery_no_active_run",
                    "Thread has no active Run to recover"
                ))
            }
            let actions = pendingActions(threadId)
            if (!actions.isEmpty()) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "thread.recovery_actions_pending",
                    "durable Operations must be reconciled before model execution resumes",
                    fields: [ErrorField("action_count", actions.size.toString())]
                ))
            }
            let run = SqliteRunStore(database).load(thread.activeRunId.getOrThrow())
            if (!run.hasRecoverableLaunchSnapshot()) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "run.launch_snapshot_missing",
                    "active Run has no immutable ModelLane/Skill snapshot"
                ))
            }
            Result.Ok(AgentThreadRuntime(
                ThreadCoordinator(thread, sink), projector,
                RecoveredRunSpec(
                    run.turnId, run.id, run.epoch, run.state, run.transitionSequence,
                    run.lane.getOrThrow(), run.skills.getOrThrow()
                ),
                nowMillis,
                checkpointRepository: Some(SqliteContextCheckpointStore(database))
            ))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "thread.runtime_recovery_failed",
                error.message,
                fields: [ErrorField("thread_id", threadId.value)]
            ))
        }
    }
}
