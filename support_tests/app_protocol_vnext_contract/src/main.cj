package app_protocol_vnext_contract

import agent_domain.*
import agent_app_protocol.*

main(): Int64 {
    commandContract()
    eventCorrelationContract()
    staleEventContract()
    threadSwitchContract()
    println("vNext app protocol contract passed")
    0
}

func commandContract(): Unit {
    let command = AppCommand(
        AppCommandMeta(
            AppCommandId("command-1"),
            1,
            expectedThreadRevision: Some(7)
        ),
        AppCommandPayload.StartTurn(ThreadId("thread"), textMessageParts("hello"))
    )
    expect(command.meta.expectedThreadRevision == Some(7),
        "commands carry optimistic Thread revision")
    expect(rejects({ => AppCommand(
        AppCommandMeta(AppCommandId("page"), 2),
        AppCommandPayload.LoadItemsPage(ThreadId("thread"), 0, 0)
    ) }), "items page bounds are validated")
}

func eventCorrelationContract(): Unit {
    expect(rejects({ => AppEventMeta(
        1,
        ThreadId("thread"),
        0,
        turnId: Some(SemanticTurnId("turn")),
        runId: None,
        epoch: 1
    ) }), "partial Turn/Run correlation is rejected")
    expect(rejects({ => AppEvent(
        runMeta(1, 0, "thread", "turn", "run", 1),
        AppEventPayload.ItemsPage(ThreadItemsPage(
            ThreadId("thread"), 0, 0, 0, false, []
        ))
    ) }), "thread-scoped payload cannot carry Run metadata")
}

func staleEventContract(): Unit {
    let gapCursor = AppEventCursor(ThreadId("gap-thread"))
    expect(gapCursor.accept(AppEvent(
        threadMeta(1, 0, "gap-thread"),
        AppEventPayload.ItemsPage(ThreadItemsPage(
            ThreadId("gap-thread"), 0, 0, 0, false, []
        ))
    )) == AppEventDisposition.Accepted && gapCursor.accept(AppEvent(
        threadMeta(3, 0, "gap-thread"),
        AppEventPayload.ItemsPage(ThreadItemsPage(
            ThreadId("gap-thread"), 0, 0, 0, false, []
        ))
    )) == AppEventDisposition.Gap && gapCursor.accept(AppEvent(
        threadMeta(2, 0, "gap-thread"),
        AppEventPayload.ItemsPage(ThreadItemsPage(
            ThreadId("gap-thread"), 0, 0, 0, false, []
        ))
    )) == AppEventDisposition.Accepted,
        "AppEvent cursor exposes a sequence gap and waits for the missing event")
    let cursor = AppEventCursor(ThreadId("thread"))
    let started = AppEvent(
        runMeta(1, 1, "thread", "turn-a", "run-a", 1),
        AppEventPayload.RunStarted(AppRunPhase.Running)
    )
    expect(cursor.accept(started) == AppEventDisposition.Accepted,
        "first active Run event is accepted")
    let draft = AppEvent(
        runMeta(2, 1, "thread", "turn-a", "run-a", 1),
        AppEventPayload.ItemDraftChanged(
            ItemId("draft-a"), ThreadItemContent.AssistantMessage(textMessageParts("stream"))
        )
    )
    expect(cursor.accept(draft) == AppEventDisposition.Accepted,
        "current Run draft is accepted")
    let finished = AppEvent(
        runMeta(3, 2, "thread", "turn-a", "run-a", 1),
        AppEventPayload.RunFinished(AppRunPhase.Cancelled, "cancelled")
    )
    expect(cursor.accept(finished) == AppEventDisposition.Accepted,
        "current Run terminal event is accepted")
    let startedB = AppEvent(
        runMeta(4, 3, "thread", "turn-b", "run-b", 3),
        AppEventPayload.RunStarted(AppRunPhase.Running)
    )
    expect(cursor.accept(startedB) == AppEventDisposition.Accepted,
        "new epoch becomes active")
    let lateA = AppEvent(
        runMeta(5, 3, "thread", "turn-a", "run-a", 1),
        AppEventPayload.ItemDraftChanged(
            ItemId("late-a"), ThreadItemContent.AssistantMessage(textMessageParts("late"))
        )
    )
    expect(cursor.accept(lateA) == AppEventDisposition.Stale,
        "old Run event is rejected even with a newer event sequence")
    let repeatedB = AppEvent(
        runMeta(4, 3, "thread", "turn-b", "run-b", 3),
        AppEventPayload.ItemDraftChanged(
            ItemId("duplicate-b"), ThreadItemContent.AssistantMessage(textMessageParts("duplicate"))
        )
    )
    expect(cursor.accept(repeatedB) == AppEventDisposition.Stale,
        "duplicate event sequence is rejected")

    let operationDone = AppEvent(
        runMeta(6, 3, "thread", "turn-b", "run-b", 3),
        AppEventPayload.OperationUpdated(
            OperationId("operation-b"), AppOperationPhase.Completed, "done"
        )
    )
    expect(cursor.accept(operationDone) == AppEventDisposition.Accepted &&
        cursor.accept(AppEvent(
            runMeta(7, 3, "thread", "turn-b", "run-b", 3),
            AppEventPayload.OperationUpdated(
                OperationId("operation-b"), AppOperationPhase.Executing, "late"
            )
        )) == AppEventDisposition.Stale,
        "terminal Operation phase is a monotonic client projection fence")
    let committed = AppEvent(
        runMeta(8, 4, "thread", "turn-b", "run-b", 3),
        AppEventPayload.ItemCommitted(ThreadItem(
            ItemId("item-b"), ThreadId("thread"), SemanticTurnId("turn-b"), 4,
            ThreadItemContent.AssistantMessage(textMessageParts("done")),
            ItemProvenance("model", runId: Some(RunId("run-b")))
        ))
    )
    expect(cursor.accept(committed) == AppEventDisposition.Accepted &&
        cursor.accept(AppEvent(
            runMeta(9, 4, "thread", "turn-b", "run-b", 3),
            AppEventPayload.ItemDraftChanged(
                ItemId("item-b"),
                ThreadItemContent.AssistantMessage(textMessageParts("late"))
            )
        )) == AppEventDisposition.Stale,
        "committed Item is a monotonic fence against late drafts")
}

func threadSwitchContract(): Unit {
    let cursor = AppEventCursor(ThreadId("thread-a"))
    let wrong = AppEvent(
        threadMeta(1, 0, "thread-b"),
        AppEventPayload.ItemsPage(ThreadItemsPage(
            ThreadId("thread-b"), 0, 0, 0, false, []
        ))
    )
    expect(cursor.accept(wrong) == AppEventDisposition.Stale,
        "events for an unselected Thread are stale")
    cursor.switchThread(ThreadId("thread-b"))
    expect(cursor.accept(wrong) == AppEventDisposition.Accepted,
        "switch resets the selected Thread cursor")
}

func runMeta(
    sequence: Int64,
    revision: Int64,
    threadId: String,
    turnId: String,
    runId: String,
    epoch: Int64
): AppEventMeta {
    AppEventMeta(
        sequence,
        ThreadId(threadId),
        revision,
        turnId: Some(SemanticTurnId(turnId)),
        runId: Some(RunId(runId)),
        epoch: epoch
    )
}

func threadMeta(sequence: Int64, revision: Int64, threadId: String): AppEventMeta {
    AppEventMeta(sequence, ThreadId(threadId), revision)
}

func rejects(operation: () -> Unit): Bool {
    try {
        operation()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
