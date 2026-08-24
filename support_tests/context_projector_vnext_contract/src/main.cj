package context_projector_vnext_contract

import agent_domain.*
import agent_runtime.*
import std.time.*

main(): Int64 {
    budgetAndCheckpointContract()
    toolBoundaryContract()
    compactionBenchmark()
    println("vNext context projector contract passed")
    0
}

func compactionBenchmark(): Unit {
    let coordinator = ThreadCoordinator(
        ThreadId("benchmark-thread"), "workspace", InMemoryThreadCommitSink()
    )
    let started = coordinator.startTurn(
        SemanticTurnId("benchmark-turn"), RunId("benchmark-run"),
        ItemId("benchmark-item-0"),
        ThreadItemContent.UserMessage(textMessageParts("start"))
    ).value().getOrThrow()
    for (sequence in 1..10000) {
        expect(isCommitted(coordinator.commit(ResultEnvelope(
            ThreadId("benchmark-thread"), SemanticTurnId("benchmark-turn"),
            RunId("benchmark-run"), started.activeEpoch, sequence,
            ThreadItemDraft(
                ItemId("benchmark-item-" + sequence.toString()),
                ThreadItemContent.AssistantMessage(textMessageParts("x")),
                ItemProvenance("model", runId: Some(RunId("benchmark-run")))
            )
        ))), "compaction benchmark Item commits")
    }
    let snapshot = coordinator.snapshot()
    let benchmarkStarted = MonoTime.now()
    let checkpoint = ContextCheckpoint(
        "benchmark-checkpoint", ThreadId("benchmark-thread"), 9900,
        objectValue([ValueField("summary", textValue("structured"))]),
        contextSourceDigest(snapshot, 9900), "projector-v1", "responses"
    )
    let projected = ContextProjector("projector-v1", FixedEstimator(1)).project(
        snapshot, testLane(1000, 100, 50), checkpoint: Some(checkpoint)
    ).value().getOrThrow()
    let elapsedMillis = (MonoTime.now() - benchmarkStarted).toMilliseconds()
    expect(projected.checkpoint.isSome() && projected.recentItems.size == 100,
        "checkpoint projection retains only the requested canonical tail")
    println("vNext compaction benchmark items=10000 compacted=9900 recent=100 elapsed_ms=" +
        elapsedMillis.toString())
}

func budgetAndCheckpointContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread"), "workspace", InMemoryThreadCommitSink())
    var snapshot = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"),
        ThreadItemContent.UserMessage(textMessageParts("hello"))
    ).value().getOrThrow()
    snapshot = commitAssistant(coordinator, snapshot, "assistant", "answer")
    let lane = testLane(100, 20, 10)
    let projector = ContextProjector("projector-v1", FixedEstimator(15))
    let full = projector.project(snapshot, lane).value().getOrThrow()
    expect(full.recentItems.size == 2 && !full.overBudget,
        "canonical history projects without becoming truth itself")
    expect(full.estimatedInputTokens + lane.outputReserve + lane.providerSafetyMargin <=
        lane.contextWindow, "one token budget invariant covers input, output, and margin")

    let checkpoint = ContextCheckpoint(
        "checkpoint", ThreadId("thread"), 1, objectValue([]),
        contextSourceDigest(snapshot, 1), "projector-v1", "responses"
    )
    let compacted = projector.project(snapshot, lane, checkpoint: Some(checkpoint))
        .value().getOrThrow()
    expect(compacted.recentItems.size == 1 && snapshot.items.size == 2,
        "checkpoint changes projection but never canonical history")
    let stale = ContextCheckpoint(
        "stale", ThreadId("thread"), 1, objectValue([]),
        "stale-digest", "projector-v1", "responses"
    )
    let rebuilt = projector.project(snapshot, lane, checkpoint: Some(stale))
        .value().getOrThrow()
    expect(rebuilt.checkpoint.isNone() && rebuilt.recentItems.size == 2,
        "stale checkpoint digest rebuilds from canonical history")
    let constrained = projector.project(snapshot, testLane(50, 20, 10))
        .value().getOrThrow()
    expect(constrained.overBudget, "projection reports an unsatisfied unified budget")
}

func toolBoundaryContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("tools"), "workspace", InMemoryThreadCommitSink())
    let started = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"),
        ThreadItemContent.UserMessage(textMessageParts("tool"))
    ).value().getOrThrow()
    let call = coordinator.commit(ResultEnvelope(
        ThreadId("tools"), SemanticTurnId("turn"), RunId("run"), started.activeEpoch, 1,
        ThreadItemDraft(
            ItemId("call"),
            ThreadItemContent.ToolCall(
                CanonicalToolCallId("call"), "read", objectValue([])
            ),
            ItemProvenance("model", runId: Some(RunId("run")))
        )
    ))
    expect(isCommitted(call), "canonical tool call commits")
    let afterCall = coordinator.snapshot()
    let projector = ContextProjector("projector-v1", FixedEstimator(1))
    expect(projector.project(afterCall, testLane(100, 20, 10)).isError(),
        "provider context cannot end with an incomplete canonical tool round")
    let split = ContextCheckpoint(
        "split", ThreadId("tools"), 2, objectValue([]),
        "digest", "projector-v1", "responses"
    )
    let operation = OperationId("operation")
    let result = coordinator.commitOperationResult(ResultEnvelope(
        ThreadId("tools"), SemanticTurnId("turn"), RunId("run"), started.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("result"),
            ThreadItemContent.ToolResult(
                CanonicalToolCallId("call"), operation, "receipt", objectValue([]), false
            ),
            ItemProvenance(
                "operation", runId: Some(RunId("run")), operationId: Some(operation)
            )
        )
    ), VNextOperationReceipt(
        "receipt", operation, OperationOutcome.Completed,
        objectValue([]), objectValue([]), 1
    ), "running")
    expect(isCommitted(result), "paired canonical tool result commits")
    let complete = coordinator.snapshot()
    expect(projector.project(complete, testLane(100, 20, 10)).isOk(),
        "complete tool round is projectable")
    let validSplit = ContextCheckpoint(
        "split-valid", ThreadId("tools"), 2, objectValue([]),
        contextSourceDigest(complete, 2), "projector-v1", "responses"
    )
    expect(projector.project(
        complete, testLane(100, 20, 10), checkpoint: Some(validSplit)
    ).isError(),
        "checkpoint cannot split ToolCall from ToolResult")
}

class FixedEstimator <: ThreadTokenEstimator {
    let perItem: Int64
    init(perItem: Int64) { this.perItem = perItem }
    public func estimateSystemInstructions(_: String): Int64 { 5 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 5 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 5 }
    public func estimateItem(_: ThreadItem): Int64 { perItem }
    public func estimateDynamicState(_: AgentValue): Int64 { 5 }
}

func testLane(window: Int64, output: Int64, margin: Int64): ModelLane {
    ModelLane(
        ModelLaneRole.Main, "provider", "model", "responses",
        ModelLaneCapabilitiesSnapshot(), window, output, margin,
        "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1"
    )
}

func commitAssistant(
    coordinator: ThreadCoordinator,
    snapshot: AgentThreadSnapshot,
    id: String,
    text: String
): AgentThreadSnapshot {
    let decision = coordinator.commit(ResultEnvelope(
        snapshot.thread.id, snapshot.thread.activeTurnId.getOrThrow(),
        snapshot.activeRunId.getOrThrow(), snapshot.activeEpoch, snapshot.nextResultSequence,
        ThreadItemDraft(
            ItemId(id), ThreadItemContent.AssistantMessage(textMessageParts(text)),
            ItemProvenance("model", runId: snapshot.activeRunId)
        )
    ))
    expect(isCommitted(decision), "assistant item commits")
    coordinator.snapshot()
}

func isCommitted(decision: SemanticCommitDecision): Bool {
    match (decision) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
