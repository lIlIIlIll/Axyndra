package thread_scale_vnext_contract

import std.time.*
import agent_domain.*
import agent_runtime.*

main(): Int64 {
    let coordinator = ThreadCoordinator(
        ThreadId("scale-thread"), "workspace", InMemoryThreadCommitSink()
    )
    let started = coordinator.startTurn(
        SemanticTurnId("scale-turn"), RunId("scale-run"), ItemId("item-0"),
        ThreadItemContent.UserMessage(textMessageParts("start"))
    ).value().getOrThrow()
    let begin = MonoTime.now()
    for (sequence in 1..100000) {
        let decision = coordinator.commit(ResultEnvelope(
            ThreadId("scale-thread"), SemanticTurnId("scale-turn"), RunId("scale-run"),
            started.activeEpoch, sequence,
            ThreadItemDraft(
                ItemId("item-" + sequence.toString()),
                ThreadItemContent.AssistantMessage(textMessageParts("x")),
                ItemProvenance("model", runId: Some(RunId("scale-run")))
            )
        ))
        match (decision) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case _ => throw IllegalStateException("scale append was not committed")
        }
    }
    let appendMillis = (MonoTime.now() - begin).toMilliseconds()
    let snapshotBegin = MonoTime.now()
    let snapshot = coordinator.snapshot()
    let snapshotMillis = (MonoTime.now() - snapshotBegin).toMilliseconds()
    if (snapshot.items.size != 100000 || snapshot.thread.revision != 100000 ||
        snapshot.nextResultSequence != 100000) {
        throw IllegalStateException("100k canonical Thread state is inconsistent")
    }
    let duplicate = coordinator.commit(ResultEnvelope(
        ThreadId("scale-thread"), SemanticTurnId("scale-turn"), RunId("scale-run"),
        started.activeEpoch, 100000,
        ThreadItemDraft(
            ItemId("item-1"),
            ThreadItemContent.AssistantMessage(textMessageParts("duplicate")),
            ItemProvenance("model", runId: Some(RunId("scale-run")))
        )
    ))
    if (!match (duplicate) {
        case SemanticCommitDecision.Rejected(error) => error.code == "thread.duplicate_item"
        case _ => false
    }) {
        throw IllegalStateException("100k Item identity index does not reject duplicates")
    }
    println(
        "vNext 100k Thread scale contract passed append_ms=" + appendMillis.toString() +
            " snapshot_ms=" + snapshotMillis.toString()
    )
    0
}
