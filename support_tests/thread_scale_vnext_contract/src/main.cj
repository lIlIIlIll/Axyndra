package thread_scale_vnext_contract

import std.time.*
import std.fs.*
import std.collection.*
import agent_domain.*
import agent_runtime.*
import agent_store.*

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
    laneScaleContract()
    0
}

func laneScaleContract(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/lane-scale.db")
    try {
        database.transaction { transaction =>
            transaction.execute(
                "INSERT INTO threads(id,revision,workspace_id,status,next_item_ordinal," +
                    "active_turn_id) VALUES ('lane-scale',1,'workspace','open',2,NULL)"
            )
            transaction.execute(
                "INSERT INTO turns(id,thread_id,ordinal,state,user_item_id,active_run_id) " +
                    "VALUES ('lane-scale-turn','lane-scale',1,'completed','lane-root',NULL)"
            )
            transaction.execute(
                "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance," +
                    "created_at_millis) VALUES ('lane-root','lane-scale','lane-scale-turn'," +
                    "1,'user_message',?,?,0)",
                [
                    SqlParameter.Text(encodeStoredThreadContent(
                        ThreadItemContent.UserMessage(textMessageParts("root"))
                    )),
                    SqlParameter.Text(encodeStoredProvenance(ItemProvenance("user")))
                ]
            )
        }
        let lanes = SqliteLaneTreeStore(database)
        let begin = MonoTime.now()
        for (ordinal in 0..256) {
            let laneId = LaneId("worker-" + paddedLaneOrdinal(ordinal))
            lanes.createLane(LaneRecord(
                laneId, ThreadId("lane-scale"), LaneKind.SharedHistoryChild,
                objectValue([ValueField("worker", integerValue(ordinal))]),
                parentLaneId: Some(LaneId("main")),
                forkItemId: Some(ItemId("lane-root")), createdAtMillis: ordinal
            )).value().getOrThrow()
            if (ordinal < 64) {
                SqliteInboxStepStore(database).enqueue(DurableInboxEntry(
                    InboxEntryId("lane-ready-" + paddedLaneOrdinal(ordinal)),
                    ThreadId("lane-scale"), laneId, InboxEntryKind.UserPrompt,
                    objectValue([ValueField("ordinal", integerValue(ordinal))]),
                    createdAtMillis: ordinal
                )).value().getOrThrow()
            }
        }
        let persistMillis = (MonoTime.now() - begin).toMilliseconds()
        let ready = lanes.readyLaneIds(ThreadId("lane-scale"), limit: 64)
            .value().getOrThrow()
        if (database.scalarInt(
            "SELECT COUNT(*) FROM lanes WHERE thread_id='lane-scale'"
        ) != 257 || ready.size != 64) {
            throw IllegalStateException("256-Lane persistence or ready set is incomplete")
        }
        var cursor = ""
        let observed = ArrayList<String>()
        for (_ in 0..64) {
            let next = lanes.readyLaneIds(
                ThreadId("lane-scale"), afterLaneId: cursor, limit: 1
            ).value().getOrThrow()
            if (next.size != 1 || observed.contains(next[0].value)) {
                throw IllegalStateException("ready Lane round-robin repeated before all peers")
            }
            cursor = next[0].value
            observed.add(cursor)
        }
        println(
            "vNext Lane scale contract passed lanes=256 ready=64 persist_ms=" +
                persistMillis.toString()
        )
    } finally {
        database.close()
        let _ = removeIfExists(root, recursive: true)
    }
}

func paddedLaneOrdinal(value: Int64): String {
    if (value < 10) { "00" + value.toString() }
    else if (value < 100) { "0" + value.toString() }
    else { value.toString() }
}
