package sqlite_run_repository_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*

// The repository CAS test retains its original IDs/request/assertions, but its
// approved Tool now has real canonical ownership and settles through the same
// transaction as its Receipt. No SQL clears the foreground continuation.
class RepositoryApprovalSettlementFixture {
    let database: SqliteDatabase
    let runtime: AgentThreadRuntime
    let store: DurableOperationStore
    let plan: NormalizedOperationPlan
    let thread = ThreadId("migration-thread")
    let turn = SemanticTurnId("migration-turn")
    let run = RunId("migration-run")
    let operation = OperationId("migration-operation")
    init(database: SqliteDatabase) {
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(sink.createThread(ThreadId("migration-thread"), "workspace"), sink)
        let actual = AgentThreadRuntime(coordinator, ContextProjector("repository-fixture", RepositoryApprovalEstimator()), { => 20 })
        let lane = ModelLane(ModelLaneRole.Main, "provider", "fixture", "responses", ModelLaneCapabilitiesSnapshot(),
            100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1")
        // A non-main Lane requires an actual parent-history fork point.
        // Seed and complete it through Runtime rather than inserting Lane SQL.
        actual.startTurn(SemanticTurnId("migration-lane-seed-turn"), RunId("migration-lane-seed-run"),
            ItemId("migration-lane-seed-user"), ThreadItemContent.UserMessage(textMessageParts("seed the review Lane")),
            lane, InvocationContextProjection(), createdAtMillis: 1).value().getOrThrow()
        actual.finish(RunState.Completed, 1000).value().getOrThrow()
        match (SqliteLaneTreeStore(database).createLane(LaneRecord(LaneId("review"), ThreadId("migration-thread"),
            LaneKind.SharedHistoryChild, objectValue([]), parentLaneId: Some(LaneId("main")),
            forkItemId: Some(ItemId("migration-lane-seed-user")), createdAtMillis: 20))) {
            case Result.Err(error) => throw IllegalStateException(error.describe()); case Result.Ok(_) => () }
        let started = actual.startTurn(SemanticTurnId("migration-turn"), RunId("migration-run"), ItemId("migration-user"),
            ThreadItemContent.UserMessage(textMessageParts("resume current continuation")), lane, InvocationContextProjection(),
            createdAtMillis: 21, executionLaneId: LaneId("review"))
        match (started) { case Result.Err(error) => throw IllegalStateException(error.describe()); case Result.Ok(_) => () }
        let active = actual.activeRun().getOrThrow()
        let state = actual.threadSnapshot()
        let committed = actual.commitResult(ResultEnvelope(ThreadId("migration-thread"), SemanticTurnId("migration-turn"),
            RunId("migration-run"), active.epoch, state.nextResultSequence,
            ThreadItemDraft(ItemId("migration-call-item"), ThreadItemContent.ToolCall(CanonicalToolCallId("migration-call"), "write", objectValue([])),
                ItemProvenance("direct_tool", runId: Some(RunId("migration-run")), operationId: Some(OperationId("migration-operation"))))))
        expect(repositoryFixtureCommitted(committed), "CAS fixture commits the actual Direct ToolCall")
        let source = actual.attestDirectToolCall(ItemId("migration-call-item"), OperationId("migration-operation"),
            RunId("migration-run"), active.epoch).value().getOrThrow()
        let normalized = NormalizedOperationPlan("write", objectValue([]), [Capability(CapabilityKind.WorkspaceWrite)],
            OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never, "migration-operation-binding")
        let operations = DurableOperationStore(database)
        operations.prepareDirectOperation(source, normalized).value().getOrThrow()
        operations.waitForApproval(OperationId("migration-operation"), RunId("migration-run")).value().getOrThrow()
        actual.pauseForApproval().value().getOrThrow()
        this.database = database; this.runtime = actual; this.store = operations; this.plan = normalized
    }
    func settle(): Unit {
        store.recordApproval("approval-" + operation.value, operation, run, plan,
            CapabilitySet(values: plan.requiredCapabilities), true, "user").value().getOrThrow()
        runtime.resumeAfterApproval().value().getOrThrow()
        store.markExecuting(operation, run, plan, 23, true).value().getOrThrow()
        store.markExecutionHandoff(operation, run, thread, 24).value().getOrThrow()
        let result = runtime.resolveOperation(ItemId("migration-tool-result"), operation, CanonicalToolCallId("migration-call"),
            plan, OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult("migration-call", objectValue([])))),
            "migration-tool-receipt", 25).value().getOrThrow()
        expect(result.semanticCommit.isSome() && repositoryFixtureCommitted(result.semanticCommit.getOrThrow()),
            "actual Receipt and canonical ToolResult commit atomically")
        let current = SqliteSemanticStore(database).continuation(run).value().getOrThrow()
        expect(runExecutionPhaseName(current.phase) == "checkpoint" && current.pendingOperationId.isNone() &&
            current.pendingApprovalId.isNone() && current.workDebt.unsettledOperations.isEmpty() &&
            current.workDebt.pendingApprovals.isEmpty() && current.laneId.value == "review" &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE id='migration-tool-receipt' AND outcome='completed'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE run_id='migration-run' AND kind='approval_continuation_settled'") == 1,
            "only the real settlement clears approval debt while preserving its non-main Lane")
    }
}

func repositoryFixtureCommitted(value: SemanticCommitDecision): Bool {
    match (value) { case SemanticCommitDecision.Committed(_, _) => true; case _ => false }
}

class RepositoryApprovalEstimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
