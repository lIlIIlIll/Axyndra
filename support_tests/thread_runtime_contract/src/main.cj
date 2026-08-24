package thread_runtime_contract

import std.collection.*
import agent_domain.*
import agent_runtime.*

main(): Int64 {
    canonicalCommitContract()
    oneActiveTurnContract()
    concurrentOwnerContract()
    staleModelResultContract()
    lateToolReceiptContract()
    toolResultProvenanceContract()
    toolBoundaryOwnershipContract()
    durableCommitRollbackContract()
    correlationAndSequenceContract()
    rejectedCommitContract()
    replayContract()
    println("thread runtime contract passed")
    0
}

func toolBoundaryOwnershipContract(): Unit {
    let coordinator = ThreadCoordinator(
        ThreadId("thread-tool-boundary"), "workspace", InMemoryThreadCommitSink()
    )
    let active = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("tool")
    ).value().getOrThrow()
    let operation = OperationId("boundary-operation")
    let orphan = coordinator.commitOperationResult(
        ResultEnvelope(
            ThreadId("thread-tool-boundary"), SemanticTurnId("turn"), RunId("run"),
            active.activeEpoch, 1,
            ThreadItemDraft(
                ItemId("orphan-result"),
                ThreadItemContent.ToolResult(
                    CanonicalToolCallId("call"), operation, "orphan-receipt", objectValue([]), false
                ),
                ItemProvenance(
                    "operation", runId: Some(RunId("run")), operationId: Some(operation)
                )
            )
        ),
        VNextOperationReceipt(
            "orphan-receipt", operation, OperationOutcome.Completed,
            objectValue([]), objectValue([]), 1
        ),
        "running"
    )
    expect(rejectedCode(orphan) == "thread.tool_result_without_call",
        "ToolResult cannot appear without its canonical ToolCall")
    expect(isCommitted(coordinator.commit(ResultEnvelope(
        ThreadId("thread-tool-boundary"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 1,
        ThreadItemDraft(
            ItemId("call"),
            ThreadItemContent.ToolCall(CanonicalToolCallId("call"), "tool", objectValue([])),
            ItemProvenance("model", runId: Some(RunId("run")))
        )
    ))), "canonical ToolCall commits")
    let interleaved = coordinator.commit(ResultEnvelope(
        ThreadId("thread-tool-boundary"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("interleaved"), assistantContent("not yet"),
            ItemProvenance("model", runId: Some(RunId("run")))
        )
    ))
    expect(rejectedCode(interleaved) == "thread.incomplete_tool_round" &&
        coordinator.cancelRun(RunId("run")).isError(),
        "pending ToolCall blocks unrelated Items and terminal Run settlement")
    let resolved = coordinator.commitOperationResult(
        ResultEnvelope(
            ThreadId("thread-tool-boundary"), SemanticTurnId("turn"), RunId("run"),
            active.activeEpoch, 2,
            ThreadItemDraft(
                ItemId("result"),
                ThreadItemContent.ToolResult(
                    CanonicalToolCallId("call"), operation, "receipt", objectValue([]), false
                ),
                ItemProvenance(
                    "operation", runId: Some(RunId("run")), operationId: Some(operation)
                )
            )
        ),
        VNextOperationReceipt(
            "receipt", operation, OperationOutcome.Completed,
            objectValue([]), objectValue([]), 2
        ),
        "running"
    )
    expect(isCommitted(resolved) && coordinator.cancelRun(RunId("run")).isOk(),
        "matching receipted ToolResult closes the tool round before settlement")
}

func toolResultProvenanceContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-tool-provenance"), "workspace", InMemoryThreadCommitSink())
    let active = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("run tool")
    ).value().getOrThrow()
    let operationId = OperationId("operation-tool-result")
    let call = coordinator.commit(ResultEnvelope(
        ThreadId("thread-tool-provenance"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 1,
        ThreadItemDraft(
            ItemId("tool-call"),
            ThreadItemContent.ToolCall(
                CanonicalToolCallId("call-tool-result"), "tool", objectValue([])
            ),
            ItemProvenance("model", runId: Some(RunId("run")))
        )
    ))
    expect(isCommitted(call), "ToolCall establishes the canonical operation boundary")
    let content = ThreadItemContent.ToolResult(
        CanonicalToolCallId("call-tool-result"), operationId,
        "receipt-tool-result", textValue("ok"), false
    )
    let missing = coordinator.commit(ResultEnvelope(
        ThreadId("thread-tool-provenance"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("missing-operation"), content,
            ItemProvenance("operation", runId: Some(RunId("run")))
        )
    ))
    expect(rejectedCode(missing) == "thread.provenance_operation_missing",
        "tool result cannot commit without operation provenance")
    let mismatch = coordinator.commit(ResultEnvelope(
        ThreadId("thread-tool-provenance"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("mismatched-operation"), content,
            ItemProvenance(
                "operation", runId: Some(RunId("run")),
                operationId: Some(OperationId("other-operation"))
            )
        )
    ))
    expect(rejectedCode(mismatch) == "thread.provenance_operation_mismatch",
        "tool result cannot commit under another operation receipt")
    let envelope = ResultEnvelope(
        ThreadId("thread-tool-provenance"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch, 2,
        ThreadItemDraft(
            ItemId("tool-result"), content,
            ItemProvenance(
                "operation", runId: Some(RunId("run")),
                operationId: Some(operationId)
            )
        )
    )
    expect(rejectedCode(coordinator.commit(envelope)) == "thread.tool_result_requires_receipt",
        "generic semantic commit cannot publish an unreceipted ToolResult")
    let committed = coordinator.commitOperationResult(
        envelope,
        VNextOperationReceipt(
            "receipt-tool-result", operationId, OperationOutcome.Completed,
            textValue("ok"), objectValue([]), 1
        ),
        "running"
    )
    expect(isCommitted(committed),
        "tool result commits only with matching run and operation provenance")
}

func durableCommitRollbackContract(): Unit {
    let sink = RejectingThreadCommitSink()
    let coordinator = ThreadCoordinator(ThreadId("thread-durable"), "workspace", sink)
    let rejectedStart = coordinator.startTurn(
        SemanticTurnId("turn-rejected"), RunId("run-rejected"),
        ItemId("user-rejected"), userContent("rejected")
    )
    expect(rejectedStart.isError() && coordinator.snapshot().thread.revision == 0 &&
        coordinator.snapshot().items.isEmpty(),
        "a failed durable start never leaks into in-memory canonical truth")

    sink.allow()
    let active = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("accepted")
    ).value().getOrThrow()
    sink.reject()
    let rejectedItem = coordinator.commit(envelope(
        active, "thread-durable", "turn", "run", 1,
        "assistant", ItemKind.AssistantMessage, "late durable failure"
    ))
    expect(rejectedCode(rejectedItem) == "store.rejected" &&
        coordinator.snapshot().thread.revision == 1 && coordinator.snapshot().items.size == 1,
        "a failed durable item commit rolls the coordinator back to its prior revision")
}

class RejectingThreadCommitSink <: ThreadCommitSink {
    private var accepted: Bool = false

    public init() {}

    public func allow(): Unit { accepted = true }
    public func reject(): Unit { accepted = false }

    public func commit(transition: ThreadTransition): Result<Unit> {
        let _ = transition.kind
        if (accepted) {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "store.rejected",
                "fault-injected durable rejection"
            ))
        }
    }

    public func recordOperationReceipt(runId: RunId, receipt: VNextOperationReceipt): Result<Unit> {
        let _ = runId.value
        let _ = receipt.receiptId
        if (accepted) {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "store.rejected",
                "fault-injected durable rejection"
            ))
        }
    }
    public func recordRunTransition(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        transition: RunTransition,
        observedAtMillis: Int64
    ): Result<Unit> {
        let _ = threadId.value
        let _ = turnId.value
        let _ = runId.value
        let _ = epoch
        let _ = transition.sequence
        let _ = observedAtMillis
        if (accepted) {
            Result.Ok(())
        } else {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "store.rejected",
                "fault-injected durable rejection"
            ))
        }
    }
    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> {
        let _ = sample.requestSequence
        Result.Ok(())
    }
}

func concurrentOwnerContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-concurrent"), "workspace", InMemoryThreadCommitSink())
    let startA = spawn {
        coordinator.startTurn(
            SemanticTurnId("turn-a"), RunId("run-a"), ItemId("user-a"), userContent("a")
        )
    }
    let startB = spawn {
        coordinator.startTurn(
            SemanticTurnId("turn-b"), RunId("run-b"), ItemId("user-b"), userContent("b")
        )
    }
    let resultA = startA.get()
    let resultB = startB.get()
    let acceptedStarts = (if (resultA.isOk()) { 1 } else { 0 }) +
        (if (resultB.isOk()) { 1 } else { 0 })
    expect(acceptedStarts == 1, "concurrent turn starts have exactly one owner")

    let active = coordinator.snapshot()
    let turnId = active.thread.activeTurnId.getOrThrow()
    let runId = active.activeRunId.getOrThrow()
    let commitA = spawn {
        coordinator.commit(envelope(
            active,
            "thread-concurrent",
            turnId.value,
            runId.value,
            1,
            "assistant-a",
            ItemKind.AssistantMessage,
            "a"
        ))
    }
    let commitB = spawn {
        coordinator.commit(envelope(
            active,
            "thread-concurrent",
            turnId.value,
            runId.value,
            1,
            "assistant-b",
            ItemKind.AssistantMessage,
            "b"
        ))
    }
    let decisionA = commitA.get()
    let decisionB = commitB.get()
    let committed = (if (isCommitted(decisionA)) { 1 } else { 0 }) +
        (if (isCommitted(decisionB)) { 1 } else { 0 })
    expect(committed == 1, "duplicate concurrent result sequence commits exactly once")
    expect(coordinator.snapshot().items.size == 2,
        "atomic commit guard prevents duplicate canonical Items")
}

func canonicalCommitContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-basic"), "workspace", InMemoryThreadCommitSink())
    let started = coordinator.startTurn(
        SemanticTurnId("turn-basic"),
        RunId("run-basic"),
        ItemId("item-user"),
        userContent("hello")
    ).value().getOrThrow()
    expect(started.thread.revision == 1, "starting a turn is one semantic revision")
    expect(started.items.size == 1 && started.items[0].kind == ItemKind.UserMessage,
        "the user item is canonical")
    let decision = coordinator.commit(envelope(
        started,
        "thread-basic",
        "turn-basic",
        "run-basic",
        1,
        "item-assistant",
        ItemKind.AssistantMessage,
        "done"
    ))
    expect(match (decision) {
        case SemanticCommitDecision.Committed(item, revision) =>
            item.ordinal == 2 && revision == 2
        case _ => false
    }, "the active run commits through the coordinator")
    let completed = coordinator.completeTurn(
        SemanticTurnId("turn-basic"), RunId("run-basic"), started.activeEpoch
    ).value().getOrThrow()
    expect(completed.thread.revision == 3 && completed.thread.activeTurnId.isNone(),
        "turn completion closes the active owner")
    expect(completed.turns[0].state == TurnState.Completed,
        "completed turn state is durable in the snapshot")
}

func oneActiveTurnContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-single"), "workspace", InMemoryThreadCommitSink())
    let first = coordinator.startTurn(
        SemanticTurnId("turn-a"), RunId("run-a"), ItemId("user-a"), userContent("a")
    )
    expect(first.isOk(), "first turn starts")
    let second = coordinator.startTurn(
        SemanticTurnId("turn-b"), RunId("run-b"), ItemId("user-b"), userContent("b")
    )
    expect(second.isError() && second.error().getOrThrow().code == "thread.turn_already_active",
        "a thread rejects a second simultaneous semantic turn")
}

func staleModelResultContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-stale-model"), "workspace", InMemoryThreadCommitSink())
    let runA = coordinator.startTurn(
        SemanticTurnId("turn-a"), RunId("run-a"), ItemId("user-a"), userContent("a")
    ).value().getOrThrow()
    coordinator.cancelRun(RunId("run-a")).value().getOrThrow()
    let runB = coordinator.startTurn(
        SemanticTurnId("turn-b"), RunId("run-b"), ItemId("user-b"), userContent("b")
    ).value().getOrThrow()
    let stale = coordinator.commit(envelope(
        runA,
        "thread-stale-model",
        "turn-a",
        "run-a",
        1,
        "assistant-a",
        ItemKind.AssistantMessage,
        "late-a"
    ))
    expect(match (stale) {
        case SemanticCommitDecision.Stale(reason) =>
            reason.kind == StaleResultKind.WrongTurn ||
                reason.kind == StaleResultKind.WrongRun ||
                reason.kind == StaleResultKind.WrongEpoch
        case _ => false
    }, "cancelled run model output is stale")
    let committed = coordinator.commit(envelope(
        runB,
        "thread-stale-model",
        "turn-b",
        "run-b",
        1,
        "assistant-b",
        ItemKind.AssistantMessage,
        "current-b"
    ))
    expect(match (committed) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "current run output remains committable")
    let snapshot = coordinator.snapshot()
    expect(snapshot.items.size == 3, "late output does not change item cardinality")
    expect(itemText(snapshot.items[2]) == "current-b", "new run never sees late model output")
}

func lateToolReceiptContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-late-tool"), "workspace", InMemoryThreadCommitSink())
    let runA = coordinator.startTurn(
        SemanticTurnId("turn-a"), RunId("run-a"), ItemId("user-a"), userContent("a")
    ).value().getOrThrow()
    let receipts = ArrayList<String>()
    coordinator.cancelRun(RunId("run-a")).value().getOrThrow()
    coordinator.startTurn(
        SemanticTurnId("turn-b"), RunId("run-b"), ItemId("user-b"), userContent("b")
    ).value().getOrThrow()

    // Receipt persistence belongs to the Operation ledger and is deliberately
    // independent from the Thread semantic commit boundary.
    receipts.add("receipt-operation-a")
    let late = coordinator.commit(envelope(
        runA,
        "thread-late-tool",
        "turn-a",
        "run-a",
        1,
        "tool-result-a",
        ItemKind.ToolResult,
        "late-effect-result"
    ))
    expect(receipts.size == 1, "late external effect receipt remains durable")
    expect(match (late) {
        case SemanticCommitDecision.Stale(_) => true
        case _ => false
    }, "late ToolResult cannot become new Thread truth")
    expect(coordinator.snapshot().items.size == 2,
        "receipt persistence does not imply ToolResult commit")
}

func correlationAndSequenceContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-correlation"), "workspace", InMemoryThreadCommitSink())
    let active = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("user")
    ).value().getOrThrow()
    let wrongThread = coordinator.commit(envelope(
        active, "other", "turn", "run", 1, "wrong-thread",
        ItemKind.AssistantMessage, "wrong"
    ))
    expect(staleKind(wrongThread) == Some(StaleResultKind.WrongThread),
        "wrong thread is rejected")
    let wrongRun = coordinator.commit(envelope(
        active, "thread-correlation", "turn", "other-run", 1, "wrong-run",
        ItemKind.AssistantMessage, "wrong"
    ))
    expect(staleKind(wrongRun) == Some(StaleResultKind.WrongRun),
        "wrong run is rejected")
    let wrongEpoch = coordinator.commit(ResultEnvelope(
        ThreadId("thread-correlation"), SemanticTurnId("turn"), RunId("run"),
        active.activeEpoch + 1, 1,
        ThreadItemDraft(
            ItemId("wrong-epoch"), assistantContent("wrong"),
            ItemProvenance("model", runId: Some(RunId("run")))
        )
    ))
    expect(staleKind(wrongEpoch) == Some(StaleResultKind.WrongEpoch),
        "wrong epoch is rejected")
    let wrongSequence = coordinator.commit(envelope(
        active, "thread-correlation", "turn", "run", 2, "wrong-sequence",
        ItemKind.AssistantMessage, "wrong"
    ))
    expect(staleKind(wrongSequence) == Some(StaleResultKind.WrongSequence),
        "sequence gaps are rejected")
    expect(coordinator.snapshot().items.size == 1,
        "all rejected envelopes leave canonical state unchanged")
}

func replayContract(): Unit {
    let original = ThreadCoordinator(ThreadId("thread-replay"), "workspace", InMemoryThreadCommitSink())
    let active = original.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("user")
    ).value().getOrThrow()
    original.commit(envelope(
        active, "thread-replay", "turn", "run", 1, "assistant",
        ItemKind.AssistantMessage, "assistant"
    ))
    let before = original.snapshot()
    let restored = ThreadCoordinator(before, InMemoryThreadCommitSink())
    let after = restored.snapshot()
    expect(after.thread.revision == before.thread.revision &&
        after.thread.nextItemOrdinal == before.thread.nextItemOrdinal &&
        after.activeEpoch == before.activeEpoch &&
        after.nextResultSequence == before.nextResultSequence,
        "coordinator restores commit ownership counters")
    expect(after.items.size == 2 && after.turns.size == 1,
        "coordinator restores canonical Items and Turns")
}

func rejectedCommitContract(): Unit {
    let coordinator = ThreadCoordinator(ThreadId("thread-rejected"), "workspace", InMemoryThreadCommitSink())
    let active = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run"), ItemId("user"), userContent("user")
    ).value().getOrThrow()
    let missingProvenance = coordinator.commit(ResultEnvelope(
        ThreadId("thread-rejected"),
        SemanticTurnId("turn"),
        RunId("run"),
        active.activeEpoch,
        1,
        ThreadItemDraft(
            ItemId("assistant-missing-run"),
            assistantContent("assistant"),
            ItemProvenance("model")
        )
    ))
    expect(rejectedCode(missingProvenance) == "thread.provenance_run_missing",
        "worker provenance must identify its run")
    let userFromWorker = coordinator.commit(ResultEnvelope(
        ThreadId("thread-rejected"),
        SemanticTurnId("turn"),
        RunId("run"),
        active.activeEpoch,
        1,
        ThreadItemDraft(
            ItemId("forged-user"),
            userContent("forged"),
            ItemProvenance("worker", runId: Some(RunId("run")))
        )
    ))
    expect(rejectedCode(userFromWorker) == "thread.worker_user_item_forbidden",
        "worker cannot forge a user item")
    expect(coordinator.snapshot().items.size == 1,
        "rejected commits do not mutate canonical state")

    coordinator.cancelRun(RunId("run")).value().getOrThrow()
    let duplicateTurn = coordinator.startTurn(
        SemanticTurnId("turn"), RunId("run-2"), ItemId("user-2"), userContent("again")
    )
    expect(duplicateTurn.isError() &&
        duplicateTurn.error().getOrThrow().code == "thread.duplicate_turn",
        "turn identifiers are immutable and cannot be reused")
    let duplicateItem = coordinator.startTurn(
        SemanticTurnId("turn-2"), RunId("run-2"), ItemId("user"), userContent("again")
    )
    expect(duplicateItem.isError() &&
        duplicateItem.error().getOrThrow().code == "thread.duplicate_item",
        "item identifiers are immutable and cannot be reused")
}

func envelope(
    snapshot: AgentThreadSnapshot,
    threadId: String,
    turnId: String,
    runId: String,
    sequence: Int64,
    itemId: String,
    kind: ItemKind,
    text: String
): ResultEnvelope {
    ResultEnvelope(
        ThreadId(threadId),
        SemanticTurnId(turnId),
        RunId(runId),
        snapshot.activeEpoch,
        sequence,
        ThreadItemDraft(
            ItemId(itemId),
            testContent(kind, itemId, text),
            ItemProvenance("worker", runId: Some(RunId(runId)))
        )
    )
}

func userContent(text: String): ThreadItemContent {
    ThreadItemContent.UserMessage(textMessageParts(text))
}

func assistantContent(text: String): ThreadItemContent {
    ThreadItemContent.AssistantMessage(textMessageParts(text))
}

func testContent(kind: ItemKind, itemId: String, text: String): ThreadItemContent {
    match (kind) {
        case ItemKind.AssistantMessage => assistantContent(text)
        case ItemKind.ToolResult => ThreadItemContent.ToolResult(
            CanonicalToolCallId("call-" + itemId),
            OperationId("operation-" + itemId),
            "receipt-" + itemId,
            textValue(text),
            false
        )
        case _ => throw IllegalArgumentException("unsupported fixture Item kind")
    }
}

func itemText(item: ThreadItem): String {
    match (item.content) {
        case ThreadItemContent.AssistantMessage(parts) => match (parts[0]) {
            case ThreadMessagePart.Text(value) => value
            case _ => ""
        }
        case _ => ""
    }
}

func staleKind(decision: SemanticCommitDecision): ?StaleResultKind {
    match (decision) {
        case SemanticCommitDecision.Stale(reason) => Some(reason.kind)
        case _ => None
    }
}

func isCommitted(decision: SemanticCommitDecision): Bool {
    match (decision) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }
}

func rejectedCode(decision: SemanticCommitDecision): String {
    match (decision) {
        case SemanticCommitDecision.Rejected(error) => error.code
        case _ => ""
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
