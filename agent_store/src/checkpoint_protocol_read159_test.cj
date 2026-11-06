package agent_store

import agent_domain.*
import agent_runtime.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

private func checkpointStoreProtocolProducer159(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("checkpoint-store-tools", []))
}
private func checkpointStoreProtocolLane159(root: LogicalJsonOwnerReservation, protocol: String): ModelLane {
    let source = root.deriveRetainedLease(); source.ensureRetainedPeak(131072)
    let owner = OwnedToolSetSnapshot159(source)
    checkpointStoreProtocolProducer159(owner); owner.returnedSnapshotProducer159()
    let shared = owner.transferSharedSnapshot159()
    try { modelLaneWithSharedToolSet159(ModelLaneRole.Main, "fixture", "fixture", protocol,
        ModelLaneCapabilitiesSnapshot(), 8192, 1024, 0, "fixture", "fixture", "fixture", shared, "fixture") }
    finally { shared.close159() }
}
private func checkpointStoreProtocolReadFrame159(store: ContextCheckpointRepository, thread: AgentThreadSnapshot,
    lane: ModelLane): ?ContextCheckpoint {
    loadContextCheckpointForLane159(store, thread, "projector-protocol", lane)
}

@Test
class SqliteCheckpointProtocolRead159Tests {
    @TestCase
    func actualStoreSelectsOnlyTheExactProtocolAndKeepsSourceDigestValidation(): Unit {
        let directory = Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let database = SqliteDatabase(directory + "/checkpoint.sqlite")
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let lane = checkpointStoreProtocolLane159(root, "protocol-\u{0000}雪")
        let other = checkpointStoreProtocolLane159(root, "absent-protocol")
        try {
            let sink = SqliteThreadCommitSink(database)
            let threadId = ThreadId("checkpoint-protocol-thread")
            let coordinator = ThreadCoordinator(sink.createThread(threadId, "fixture"), sink)
            let thread = coordinator.startTurn(SemanticTurnId("checkpoint-protocol-turn"), RunId("checkpoint-protocol-run"),
                ItemId("checkpoint-protocol-user"), ThreadItemContent.UserMessage([ThreadMessagePart.Text("checkpoint data")]),
                createdAtMillis: 1).value().getOrThrow()
            let store = SqliteContextCheckpointStore(database)
            let digest = contextSourceDigest(thread, 1)
            let selected = ContextCheckpoint("selected", threadId, 1, objectValue([]), digest,
                "projector-protocol", "protocol-\u{0000}雪", activeGoal: "actual selected checkpoint")
            let wrong = ContextCheckpoint("z-wrong-protocol", threadId, 1, objectValue([]), digest,
                "projector-protocol", "other-protocol")
            @Expect(store.save(wrong, thread, 2).isOk(), true)
            @Expect(store.save(selected, thread, 3).isOk(), true)
            let actual = checkpointStoreProtocolReadFrame159(store, thread, lane).getOrThrow()
            @Expect(actual.id, "selected")
            @Expect(actual.activeGoal, "actual selected checkpoint")
            @Expect(actual.laneCompatibility, "protocol-\u{0000}雪")
            @Expect(checkpointStoreProtocolReadFrame159(store, thread, other).isNone(), true)
            // Corrupt only disposable checkpoint DATA; no Source or operation
            // is admitted. The original canonical-prefix guard must reject it.
            database.execute("UPDATE context_checkpoints SET source_digest='changed' WHERE id='selected'")
            @Expect(checkpointStoreProtocolReadFrame159(store, thread, lane).isNone(), true)
        } finally {
            lane.returnOwnedLaneFrame159(); other.returnOwnedLaneFrame159(); root.close()
            database.close(); remove(directory, recursive: true)
        }
        // Only these lane DATA payments are asserted; no SQLite whole-frame
        // retirement or execution/receipt acknowledgement is claimed.
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}
