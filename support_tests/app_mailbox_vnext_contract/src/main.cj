package app_mailbox_vnext_contract

import agent_app_protocol.*
import agent_domain.*
import std.time.*

main(): Int64 {
    coalescingContract()
    terminalBackpressureContract()
    mailboxBenchmark()
    println("vNext app mailbox contract passed")
    0
}

func mailboxBenchmark(): Unit {
    let mailbox = AppEventMailbox(capacity: 512)
    let started = MonoTime.now()
    for (sequence in 1..100001) {
        expect(mailbox.push(draftEvent(
            sequence, "benchmark-draft", "text " + sequence.toString()
        )) != AppMailboxPushResult.Backpressure,
            "coalesced mailbox benchmark must remain bounded")
    }
    let elapsedMillis = (MonoTime.now() - started).toMilliseconds()
    expect(mailbox.size() == 1,
        "100k mailbox draft updates retain one bounded projection")
    println("vNext mailbox benchmark updates=100000 elapsed_ms=" +
        elapsedMillis.toString() + " peak_entries=1 capacity=512")
}

func coalescingContract(): Unit {
    let mailbox = AppEventMailbox(capacity: 3)
    for (sequence in 1..101) {
        let result = mailbox.push(draftEvent(sequence, "draft", "text " + sequence.toString()))
        expect(result != AppMailboxPushResult.Backpressure, "draft updates are coalescible")
    }
    expect(mailbox.size() == 1, "one draft key retains only its latest projection")
    let _ = mailbox.push(operationEvent(101, AppOperationPhase.Executing))
    let _ = mailbox.push(operationEvent(102, AppOperationPhase.Completed))
    expect(mailbox.size() == 2, "terminal operation replaces disposable progress")
    let drained = mailbox.drain()
    expect(drained[0].meta.sequence == 100 && drained[1].meta.sequence == 102,
        "coalescing preserves increasing event order")
    expect(match (drained[1].payload) {
        case AppEventPayload.OperationUpdated(_, AppOperationPhase.Completed, _) => true
        case _ => false
    }, "terminal operation state is retained")

    let sealed = AppEventMailbox(capacity: 4)
    expect(sealed.push(operationEvent(1, AppOperationPhase.Completed)) ==
        AppMailboxPushResult.Enqueued &&
        sealed.push(operationEvent(2, AppOperationPhase.Executing)) ==
        AppMailboxPushResult.Stale,
        "queued terminal Operation rejects late progress regression")
    expect(sealed.push(committedEvent(3, "sealed-item")) ==
        AppMailboxPushResult.Enqueued &&
        sealed.push(draftEvent(4, "sealed-item", "late")) ==
        AppMailboxPushResult.Stale,
        "queued committed Item rejects its late mutable draft")
}

func terminalBackpressureContract(): Unit {
    let mailbox = AppEventMailbox(capacity: 2)
    expect(mailbox.push(committedEvent(1, "one")) == AppMailboxPushResult.Enqueued,
        "semantic commit is enqueued")
    expect(mailbox.push(approvalEvent(2)) == AppMailboxPushResult.Enqueued,
        "approval is enqueued")
    expect(mailbox.push(finishedEvent(3)) == AppMailboxPushResult.Backpressure,
        "full terminal-only mailbox signals backpressure instead of dropping truth")
    let drained = mailbox.drain()
    expect(drained.size == 2 && match (drained[0].payload) {
        case AppEventPayload.ItemCommitted(_) => true
        case _ => false
    }, "semantic commit survives mailbox pressure")
}

func meta(sequence: Int64): AppEventMeta {
    AppEventMeta(
        sequence, ThreadId("thread"), sequence,
        turnId: Some(SemanticTurnId("turn")), runId: Some(RunId("run")), epoch: 1
    )
}

func draftEvent(sequence: Int64, itemId: String, text: String): AppEvent {
    AppEvent(
        meta(sequence),
        AppEventPayload.ItemDraftChanged(
            ItemId(itemId), ThreadItemContent.AssistantMessage(textMessageParts(text))
        )
    )
}

func operationEvent(sequence: Int64, phase: AppOperationPhase): AppEvent {
    AppEvent(meta(sequence), AppEventPayload.OperationUpdated(OperationId("operation"), phase, ""))
}

func committedEvent(sequence: Int64, itemId: String): AppEvent {
    AppEvent(meta(sequence), AppEventPayload.ItemCommitted(ThreadItem(
        ItemId(itemId), ThreadId("thread"), SemanticTurnId("turn"), sequence,
        ThreadItemContent.AssistantMessage(textMessageParts(itemId)),
        ItemProvenance("model", runId: Some(RunId("run")))
    )))
}

func approvalEvent(sequence: Int64): AppEvent {
    AppEvent(meta(sequence), AppEventPayload.ApprovalRequested(
        OperationId("approval"), CanonicalToolCallId("call"), "write", "high"
    ))
}

func finishedEvent(sequence: Int64): AppEvent {
    AppEvent(meta(sequence), AppEventPayload.RunFinished(AppRunPhase.Completed, "done"))
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
