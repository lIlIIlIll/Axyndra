package thread_runtime_integration_contract

import yjson_support.*

import yjson.*

import std.fs.*
import std.sync.*
import std.collection.*
import agent_domain.*
import agent_runtime.*
import agent_skills.*
import agent_store.*

main(): Int64 {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/state.db")
    try {
        registryOwnershipContract(database)
        externalInputCommitContract(database)
        modelResultBatchContract(database)
        schedulerPermutationContract(database)
        let sink = SqliteThreadCommitSink(database)
        let coordinator = ThreadCoordinator(
            sink.createThread(ThreadId("thread"), "workspace"), sink
        )
        let runtime = AgentThreadRuntime(
            coordinator, ContextProjector("projector", FixedEstimator()), { => 100 }
        )
        let skills = SkillStackSnapshot([], [])

        let first = runtime.startTurn(
            SemanticTurnId("turn-a"), RunId("run-a"), ItemId("user-a"),
            ThreadItemContent.UserMessage(textMessageParts("first")),
            lane("model-a"), skills
        ).value().getOrThrow()
        let projection = runtime.projectContext().value().getOrThrow()
        expect(projection.recentItems.size == 1 && !projection.overBudget &&
            runtime.activeRun().getOrThrow().lane.modelId == "model-a",
            "Run freezes ModelLane and projects canonical Thread state")
        let durableLane = decodeStoredValue(database.query(
            "SELECT lane_snapshot FROM runs WHERE id='run-a'"
        )[0].required(0))
        expect(durableLane.field("model_id").getOrThrow().text == "model-a" &&
            durableLane.field("tool_set_id").getOrThrow().text == "tools",
            "Run launch atomically persists its immutable ModelLane snapshot")
        expect(modelLaneFromSnapshotValue(durableLane).modelId == "model-a" &&
            skillStackFromSnapshotValue(decodeStoredValue(database.query(
                "SELECT skill_snapshot FROM runs WHERE id='run-a'"
            )[0].required(0))).active.isEmpty(),
            "Run launch snapshots round-trip independently of live configuration")
        let call = runtime.commitResult(ResultEnvelope(
            ThreadId("thread"), SemanticTurnId("turn-a"), RunId("run-a"), first.epoch, 1,
            ThreadItemDraft(
                ItemId("call-a"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("call-a"), "read", objectValue([])
                ),
                ItemProvenance("model", runId: Some(RunId("run-a")))
            )
        ))
        expect(isCommitted(call), "active Run commits its canonical ToolCall")
        database.execute(
            "INSERT INTO operations VALUES ('operation-a','run-a','call-a'," +
                "'plan','capability','resource','read_only','safe',NULL,'executing',1)"
        )
        let operationPlan = NormalizedOperationPlan(
            "read", objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "binding-a"
        )
        let operation = runtime.resolveOperation(
            ItemId("result-a"), OperationId("operation-a"), CanonicalToolCallId("call-a"),
            operationPlan,
            OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(
                "call-a", objectValue([ValueField("value", textValue("done"))])
            ))),
            "receipt-a", 2
        ).value().getOrThrow()
        expect(operation.semanticCommit.isSome() &&
            isCommitted(operation.semanticCommit.getOrThrow()) &&
            runtime.projectContext().value().getOrThrow().recentItems.size == 3,
            "resolved Tool outcome commits Receipt and paired ToolResult through Runtime")
        let usage = RunModelUsageSample(
            ThreadId("thread"), SemanticTurnId("turn-a"), RunId("run-a"), first.epoch, 1,
            ModelLaneRole.Main, 20,
            ModelUsage(
                inputTokens: 18, outputTokens: 4, cacheReadTokens: 3,
                costMicros: Some(7)
            ),
            90
        )
        runtime.recordModelUsage(usage).value().getOrThrow()
        runtime.recordModelUsage(usage).value().getOrThrow()
        expect(database.scalarInt(
            "SELECT COUNT(*) FROM run_model_usage WHERE run_id='run-a'"
        ) == 1, "model usage is idempotent per Run request sequence")
        runtime.ownTask("model", spawn { sleep(Duration.millisecond) }).value().getOrThrow()
        let completed = runtime.finish(RunState.Completed, 1000).value().getOrThrow()
        expect(completed.run.state == RunState.Completed &&
            completed.thread.turns[0].state == TurnState.Completed &&
            database.query("SELECT state FROM runs WHERE id='run-a'")[0].required(0) == "completed",
            "Run publishes completion only after owned work joins and durable Turn commit succeeds")
        expect(journalStates(database, "run-a") == [
            "created>running", "running>completed"
        ], "Run start and completion transitions have durable ordered evidence")
        let revisionBeforeLateUsage = runtime.threadSnapshot().thread.revision
        runtime.recordModelUsage(RunModelUsageSample(
            ThreadId("thread"), SemanticTurnId("turn-a"), RunId("run-a"), first.epoch, 2,
            ModelLaneRole.Main, 22, ModelUsage(inputTokens: 20, outputTokens: 2), 101
        )).value().getOrThrow()
        let durableRun = SqliteRunStore(database).load(RunId("run-a"))
        expect(durableRun.state == RunState.Completed &&
            durableRun.transitionSequence == 2 &&
            durableRun.lane.getOrThrow().modelId == "model-a" &&
            durableRun.skills.getOrThrow().active.isEmpty() &&
            durableRun.usage.field("input_tokens").getOrThrow().number == "38" &&
            durableRun.usage.field("cost_micros").getOrThrow().unifiedKind == ValueKind.Null &&
            runtime.threadSnapshot().thread.revision == revisionBeforeLateUsage,
            "RunStore reconstructs launch snapshots and late usage without semantic mutation")

        let cancelledRun = runtime.startTurn(
            SemanticTurnId("turn-b"), RunId("run-b"), ItemId("user-b"),
            ThreadItemContent.UserMessage(textMessageParts("cancel")),
            lane("model-b"), skills
        ).value().getOrThrow()
        let child = runtime.childCancellationToken().value().getOrThrow()
        runtime.ownTask("tool/process", spawn {
            while (!child.isCancelled()) { sleep(Duration.millisecond) }
        }).value().getOrThrow()
        let cancelled = runtime.cancel(1000).value().getOrThrow()
        let cancelledRow = database.query(
            "SELECT state,finished_at_millis,cancellation_reason FROM runs WHERE id='run-b'"
        )[0]
        expect(cancelled.run.state == RunState.Cancelled && child.isCancelled() &&
            cancelledRow.required(0) == "cancelled" &&
            cancelledRow.required(1) == "100" &&
            cancelledRow.required(2) == "cancel_requested",
            "structured cancellation reaches children before durable cancelled state")
        expect(journalStates(database, "run-b") == [
            "created>running", "running>cancelling", "cancelling>cancelled"
        ], "cancellation intent and terminal settlement are durably journaled")

        let current = runtime.startTurn(
            SemanticTurnId("turn-c"), RunId("run-c"), ItemId("user-c"),
            ThreadItemContent.UserMessage(textMessageParts("quarantine")),
            lane("model-c"), skills
        ).value().getOrThrow()
        let stale = runtime.commitResult(ResultEnvelope(
            ThreadId("thread"), SemanticTurnId("turn-b"), RunId("run-b"),
            cancelledRun.epoch, 1,
            ThreadItemDraft(
                ItemId("late-b"),
                ThreadItemContent.AssistantMessage(textMessageParts("late")),
                ItemProvenance("model", runId: Some(RunId("run-b")))
            )
        ))
        expect(match (stale) {
            case SemanticCommitDecision.Stale(_) => true
            case _ => false
        }, "a cancelled Run cannot commit into the next Turn")

        let release = AtomicBool(false)
        let stubborn = spawn {
            while (!release.load()) { sleep(Duration.millisecond) }
        }
        runtime.ownTask("mcp/ambiguous", stubborn).value().getOrThrow()
        let quarantined = runtime.finish(RunState.Completed, 1).value().getOrThrow()
        expect(quarantined.joined.quarantinedCount() == 1 &&
            quarantined.run.state == RunState.RecoveryRequired &&
            database.query("SELECT state FROM runs WHERE id='run-c'")[0].required(0) == "recovery_required" &&
            runtime.threadSnapshot().items.size == 5,
            "quarantined work forces RecoveryRequired and cannot publish late semantic Items")
        expect(journalStates(database, "run-c") == [
            "created>running", "running>recovery_required"
        ], "quarantine recovery state has durable ordered evidence")
        release.store(true)
        stubborn.get()

        let unknownRun = runtime.startTurn(
            SemanticTurnId("turn-d"), RunId("run-d"), ItemId("user-d"),
            ThreadItemContent.UserMessage(textMessageParts("unknown effect")),
            lane("model-d"), skills
        ).value().getOrThrow()
        expect(isCommitted(runtime.commitResult(ResultEnvelope(
            ThreadId("thread"), SemanticTurnId("turn-d"), RunId("run-d"),
            unknownRun.epoch, 1,
            ThreadItemDraft(
                ItemId("call-d"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("call-d"), "write", objectValue([])
                ),
                ItemProvenance("model", runId: Some(RunId("run-d")))
            )
        ))), "unknown-effect fixture commits its ToolCall")
        database.execute(
            "INSERT INTO operations VALUES ('operation-d','run-d','call-d'," +
                "'plan','capability','resource','workspace_mutation','never',NULL,'executing',1)"
        )
        let unknownPlan = NormalizedOperationPlan(
            "write", objectValue([]), [Capability(CapabilityKind.WorkspaceWrite)],
            OperationEffectClass.WorkspaceMutation, OperationRetryDisposition.Never,
            "binding-d"
        )
        let unknown = runtime.resolveOperation(
            ItemId("result-d"), OperationId("operation-d"), CanonicalToolCallId("call-d"),
            unknownPlan, OperationAttemptStage.Executing,
            Result<ToolInvocationResult>.Err(AgentError(
                AgentErrorKind.Timeout, "process.timeout", "connection lost"
            )),
            "receipt-d", 110
        ).value().getOrThrow()
        expect(unknown.semanticCommit.isSome() &&
            isCommitted(unknown.semanticCommit.getOrThrow()) &&
            match (unknown.resolution) {
                case OperationResolution.Terminal(value) =>
                    value.error.getOrThrow().kind == AgentErrorKind.RecoveryRequired &&
                        value.toolResult.getOrThrow().isError
                case _ => false
            } && database.query(
                "SELECT state FROM operations WHERE id='operation-d'"
            )[0].required(0) == "recovery_required",
            "Unknown side effect closes tool protocol with an explicit error Result and Receipt")
        runtime.finish(RunState.RecoveryRequired, 100).value().getOrThrow()

        let reopened = sink.loadThread(ThreadId("thread"))
        expect(reopened.thread.revision == 12 && reopened.turns.size == 4 &&
            reopened.turns[2].state == TurnState.Failed &&
            reopened.turns[3].state == TurnState.Failed && reopened.activeRunId.isNone() &&
            current.epoch > first.epoch,
            "durable replay preserves all terminal Turns and monotonically increasing epochs")
    } finally {
        database.close()
    }
    println("vNext integrated Thread Runtime contract passed")
    0
}

// T013: deterministic pseudo-random delivery orders exercise the semantic
// commit fence as a property, not only as one named interleaving. Current-Run
// results retain their sequence; three distinct late worker classes may arrive
// anywhere around them after Run A has been cancelled and Run B has started.
func schedulerPermutationContract(database: SqliteDatabase): Unit {
    var forbiddenCommits: Int64 = 0
    var staleResults: Int64 = 0
    for (seed in 1..129) {
        let suffix = seed.toString()
        let threadId = ThreadId("permutation-thread-" + suffix)
        let sink = SqliteThreadCommitSink(database)
        let runtime = AgentThreadRuntime(
            ThreadCoordinator(sink.createThread(threadId, "workspace"), sink),
            ContextProjector("permutation-projector", FixedEstimator()),
            { => seed }
        )
        let first = runtime.startTurn(
            SemanticTurnId("permutation-turn-a-" + suffix),
            RunId("permutation-run-a-" + suffix),
            ItemId("permutation-user-a-" + suffix),
            ThreadItemContent.UserMessage(textMessageParts("first")),
            lane("permutation-model-a"), SkillStackSnapshot([], [])
        ).value().getOrThrow()
        runtime.cancel(1000).value().getOrThrow()
        let second = runtime.startTurn(
            SemanticTurnId("permutation-turn-b-" + suffix),
            RunId("permutation-run-b-" + suffix),
            ItemId("permutation-user-b-" + suffix),
            ThreadItemContent.UserMessage(textMessageParts("second")),
            lane("permutation-model-b"), SkillStackSnapshot([], [])
        ).value().getOrThrow()

        let order = shuffledEventOrder(seed)
        var secondCommitted = false
        var deferredSecond = false
        for (event in order) {
            if (event < 3) {
                let decision = runtime.commitResult(latePermutationEnvelope(
                    event, suffix, threadId, first
                ))
                match (decision) {
                    case SemanticCommitDecision.Committed(_, _) => forbiddenCommits += 1
                    case SemanticCommitDecision.Stale(_) => staleResults += 1
                    case SemanticCommitDecision.Rejected(_) => ()
                }
            } else if (event == 3) {
                expect(isCommitted(runtime.commitResult(currentPermutationEnvelope(
                    1, suffix, threadId, second
                ))), "current Run sequence one commits in every scheduler permutation")
                secondCommitted = true
            } else if (secondCommitted) {
                expect(isCommitted(runtime.commitResult(currentPermutationEnvelope(
                    2, suffix, threadId, second
                ))), "current Run sequence two commits after sequence one")
            } else {
                deferredSecond = true
            }
        }
        if (deferredSecond) {
            expect(isCommitted(runtime.commitResult(currentPermutationEnvelope(
                2, suffix, threadId, second
            ))), "scheduler releases a causally deferred current result")
        }
        runtime.finish(RunState.Completed, 2000).value().getOrThrow()
        let replay = sink.loadThread(threadId)
        expect(replay.items.size == 4 &&
            !containsItem(replay.items, "permutation-late-model-" + suffix) &&
            !containsItem(replay.items, "permutation-late-tool-" + suffix) &&
            !containsItem(replay.items, "permutation-late-child-" + suffix),
            "canonical replay excludes all old-Run results in every permutation")
    }
    expect(forbiddenCommits == 0 && staleResults == 128 * 3,
        "128 deterministic scheduler permutations keep lateSemanticCommit at zero")
}

func shuffledEventOrder(seed: Int64): Array<Int64> {
    let values = [0, 1, 2, 3, 4]
    var state = seed
    var index: Int64 = values.size - 1
    while (index > 0) {
        state = (state * 1103515245 + 12345) % 2147483647
        let target = state % (index + 1)
        let previous = values[index]
        values[index] = values[target]
        values[target] = previous
        index -= 1
    }
    values
}

func latePermutationEnvelope(
    event: Int64,
    suffix: String,
    threadId: ThreadId,
    active: ActiveRunSnapshot
): ResultEnvelope {
    let draft = match (event) {
        case 0 => ThreadItemDraft(
            ItemId("permutation-late-model-" + suffix),
            ThreadItemContent.AssistantMessage(textMessageParts("late model")),
            ItemProvenance("model", runId: Some(active.runId))
        )
        case 1 => ThreadItemDraft(
            ItemId("permutation-late-tool-" + suffix),
            ThreadItemContent.ToolResult(
                CanonicalToolCallId("permutation-call-" + suffix),
                OperationId("permutation-operation-" + suffix),
                "permutation-receipt-" + suffix,
                objectValue([ValueField("late", boolValue(true))]), false
            ),
            ItemProvenance(
                "operation", runId: Some(active.runId),
                operationId: Some(OperationId("permutation-operation-" + suffix))
            )
        )
        case _ => ThreadItemDraft(
            ItemId("permutation-late-child-" + suffix),
            ThreadItemContent.AssistantMessage(textMessageParts("late child")),
            ItemProvenance("child_run", runId: Some(active.runId))
        )
    }
    ResultEnvelope(
        threadId, active.turnId, active.runId, active.epoch, 1, draft
    )
}

func currentPermutationEnvelope(
    sequence: Int64,
    suffix: String,
    threadId: ThreadId,
    active: ActiveRunSnapshot
): ResultEnvelope {
    ResultEnvelope(
        threadId, active.turnId, active.runId, active.epoch, sequence,
        ThreadItemDraft(
            ItemId("permutation-current-" + sequence.toString() + "-" + suffix),
            ThreadItemContent.AssistantMessage(textMessageParts(
                "current " + sequence.toString()
            )),
            ItemProvenance("model", runId: Some(active.runId))
        )
    )
}

func containsItem(items: Array<ThreadItem>, id: String): Bool {
    for (item in items where item.id.value == id) { return true }
    false
}

func externalInputCommitContract(database: SqliteDatabase): Unit {
    let registry = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("external-projector", FixedEstimator()),
        { => 77 }
    )
    let runtime = registry.acquire(ThreadId("external-thread"), "workspace")
        .value().getOrThrow()
    expect(runtime.appendExternalUserTextOnce(
        "receipt-a", "async completed", source: "async_result", createdAtMillis: 70
    ).value().getOrThrow(), "first idle external input commits")
    expect(!runtime.appendExternalUserTextOnce(
        "receipt-a", "async completed", source: "async_result", createdAtMillis: 71
    ).value().getOrThrow() && runtime.appendExternalUserTextOnce(
        "receipt-a", "different", source: "async_result", createdAtMillis: 72
    ).isError(), "external input replay is exact-once and rejects payload collision")
    expect(database.scalarInt(
        "SELECT COUNT(*) FROM turns WHERE thread_id='external-thread' AND state='completed'"
    ) == 1 && database.scalarInt(
        "SELECT COUNT(*) FROM runs WHERE thread_id='external-thread' AND state='completed'"
    ) == 1 && database.scalarInt(
        "SELECT COUNT(*) FROM items WHERE thread_id='external-thread'"
    ) == 1, "idle delivery atomically commits one completed Turn, Run, and Item")

    let active = runtime.startTurn(
        SemanticTurnId("external-live-turn"), RunId("external-live-run"),
        ItemId("external-live-user"),
        ThreadItemContent.UserMessage(textMessageParts("continue")),
        lane("external-model"), SkillStackSnapshot([], [])
    ).value().getOrThrow()
    expect(runtime.appendExternalUserTextOnce(
        "receipt-b", "live async completed", source: "async_result", createdAtMillis: 73
    ).value().getOrThrow(), "live external input joins the active Run owner")
    let snapshot = runtime.threadSnapshot()
    let delivered = snapshot.items[snapshot.items.size - 1]
    expect(snapshot.turns.size == 2 && delivered.turnId.value == active.turnId.value &&
        delivered.provenance.runId.getOrThrow().value == active.runId.value,
        "live delivery cannot create a parallel Turn or Run")
    runtime.finish(RunState.Completed, 1000).value().getOrThrow()
}

func modelResultBatchContract(database: SqliteDatabase): Unit {
    let sink = SqliteThreadCommitSink(database)
    let runtime = AgentThreadRuntime(
        ThreadCoordinator(
            sink.createThread(ThreadId("batch-thread"), "workspace"), sink
        ),
        ContextProjector("batch-projector", FixedEstimator()),
        { => 60 }
    )
    let active = runtime.startTurn(
        SemanticTurnId("batch-turn"), RunId("batch-run"), ItemId("batch-user"),
        ThreadItemContent.UserMessage(textMessageParts("batch")),
        lane("batch-model"), SkillStackSnapshot([], [])
    ).value().getOrThrow()
    let committed = runtime.commitBatch(ResultBatchEnvelope(
        ThreadId("batch-thread"), SemanticTurnId("batch-turn"), RunId("batch-run"),
        active.epoch, 1,
        [
            ThreadItemDraft(
                ItemId("batch-assistant"),
                ThreadItemContent.AssistantMessage(textMessageParts("working")),
                ItemProvenance("model", runId: Some(RunId("batch-run")))
            ),
            ThreadItemDraft(
                ItemId("batch-call-a"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("batch-call-a"), "read-a", objectValue([])
                ),
                ItemProvenance("model", runId: Some(RunId("batch-run")))
            ),
            ThreadItemDraft(
                ItemId("batch-call-b"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("batch-call-b"), "read-b", objectValue([])
                ),
                ItemProvenance("model", runId: Some(RunId("batch-run")))
            )
        ]
    ))
    expect(match (committed) {
        case SemanticBatchCommitDecision.Committed(items, revision) =>
            items.size == 3 && revision == 2
        case _ => false
    } && runtime.threadSnapshot().nextResultSequence == 4 &&
        database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='batch-thread'") == 4,
        "one model result batch atomically commits Assistant and parallel ToolCalls")
    let failed = AgentThreadRuntime(
        ThreadCoordinator(
            sink.createThread(ThreadId("batch-fail-thread"), "workspace"), sink
        ),
        ContextProjector("batch-projector", FixedEstimator()),
        { => 61 }
    )
    let failedActive = failed.startTurn(
        SemanticTurnId("batch-fail-turn"), RunId("batch-fail-run"),
        ItemId("batch-fail-user"),
        ThreadItemContent.UserMessage(textMessageParts("batch fail")),
        lane("batch-model"), SkillStackSnapshot([], [])
    ).value().getOrThrow()
    database.execute(
        "CREATE TRIGGER reject_batch_item BEFORE INSERT ON items " +
            "WHEN NEW.id='batch-fail-call' BEGIN SELECT RAISE(ABORT,'injected'); END"
    )
    let rejected = failed.commitBatch(ResultBatchEnvelope(
        ThreadId("batch-fail-thread"), SemanticTurnId("batch-fail-turn"),
        RunId("batch-fail-run"), failedActive.epoch, 1,
        [
            ThreadItemDraft(
                ItemId("batch-fail-assistant"),
                ThreadItemContent.AssistantMessage(textMessageParts("partial forbidden")),
                ItemProvenance("model", runId: Some(RunId("batch-fail-run")))
            ),
            ThreadItemDraft(
                ItemId("batch-fail-call"),
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId("batch-fail-call"), "read", objectValue([])
                ),
                ItemProvenance("model", runId: Some(RunId("batch-fail-run")))
            )
        ]
    ))
    database.execute("DROP TRIGGER reject_batch_item")
    expect(match (rejected) {
        case SemanticBatchCommitDecision.Rejected(_) => true
        case _ => false
    } && failed.threadSnapshot().thread.revision == 1 &&
        failed.threadSnapshot().nextResultSequence == 1 &&
        database.scalarInt(
            "SELECT COUNT(*) FROM items WHERE thread_id='batch-fail-thread'"
        ) == 1,
        "SQLite failure rolls back the complete model result batch")
    failed.cancel(1000).value().getOrThrow()
}

func registryOwnershipContract(database: SqliteDatabase): Unit {
    let registry = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("registry-projector", FixedEstimator()),
        { => 50 }
    )
    let first = registry.acquire(ThreadId("registry-thread"), "workspace")
        .value().getOrThrow()
    let active = first.startTurn(
        SemanticTurnId("registry-turn"), RunId("registry-run"),
        ItemId("registry-user"),
        ThreadItemContent.UserMessage(textMessageParts("owned")),
        lane("registry-model"), SkillStackSnapshot([], [])
    ).value().getOrThrow()
    let second = registry.acquire(ThreadId("registry-thread"), "workspace")
        .value().getOrThrow()
    expect(second.activeRun().getOrThrow().runId.value == active.runId.value &&
        second.startTurn(
            SemanticTurnId("parallel-turn"), RunId("parallel-run"),
            ItemId("parallel-user"),
            ThreadItemContent.UserMessage(textMessageParts("parallel")),
            lane("parallel-model"), SkillStackSnapshot([], [])
        ).isError(),
        "registry returns one mutable owner and rejects a parallel semantic Turn")
    expect(registry.discardInactive(ThreadId("registry-thread")).isError() &&
        database.scalarInt("SELECT COUNT(*) FROM threads WHERE id='registry-thread'") == 1,
        "registry cannot discard canonical truth underneath an active Run owner")
    let reopened = SqliteThreadRuntimeRegistry(
        database,
        ContextProjector("registry-projector", FixedEstimator()),
        { => 51 }
    )
    let recovery = reopened.acquire(ThreadId("registry-thread"), "workspace")
    expect(recovery.isError() && recovery.error().getOrThrow().kind ==
        AgentErrorKind.RecoveryRequired,
        "a second process-style registry cannot guess ownership of an active durable Run")
    let recovered = reopened.recover(ThreadId("registry-thread"), "workspace")
        .value().getOrThrow()
    expect(recovered.activeRun().getOrThrow().runId.value == active.runId.value,
        "explicit registry recovery reconstructs the durable active Run snapshot")
    recovered.finish(RunState.Completed, 1000).value().getOrThrow()

    let disposable = registry.acquire(ThreadId("registry-disposable"), "workspace")
        .value().getOrThrow()
    expect(disposable.activeRun().isNone() &&
        registry.discardInactive(ThreadId("registry-disposable")).value().getOrThrow() &&
        database.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id='registry-disposable'"
        ) == 0,
        "registry releases an inactive owner before atomically deleting its durable Thread")
}

func journalStates(database: SqliteDatabase, runId: String): Array<String> {
    let rows = database.query(
        "SELECT payload FROM run_journal WHERE run_id='" + runId + "' ORDER BY sequence"
    )
    let states = ArrayList<String>()
    for (row in rows) {
        let value = decodeStoredValue(row.required(0))
        states.add(value.field("from").getOrThrow().text + ">" +
            value.field("to").getOrThrow().text)
    }
    states.toArray()
}

func isCommitted(decision: SemanticCommitDecision): Bool {
    match (decision) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }
}

class FixedEstimator <: ThreadTokenEstimator {
    public init() {}
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}

func lane(modelId: String): ModelLane {
    ModelLane(
        ModelLaneRole.Main, "provider", modelId, "responses",
        ModelLaneCapabilitiesSnapshot(), 1000, 100, 20,
        "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1"
    )
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
