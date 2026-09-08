package thread_runtime_integration_contract

import std.sync.*
import agent_domain.*
import agent_runtime.*
import agent_skills.*
import agent_store.*

func concurrentThreadSnapshotContract(path: String): Unit {
    let writer = SqliteDatabase(path)
    let reader = SqliteDatabase(path)
    let threadId = ThreadId("snapshot-race")
    let sink = SqliteThreadCommitSink(writer)
    let snapshots = SqliteThreadCommitSink(reader)
    let runtime = AgentThreadRuntime(
        ThreadCoordinator(sink.createThread(threadId, "workspace"), sink),
        ContextProjector("snapshot-projector", FixedEstimator()), { => 100 }
    )
    let ready = AtomicBool(false)
    let done = AtomicBool(false)
    let reading = spawn {
        var reads: Int64 = 0
        var failure = ""
        while (!done.load()) {
            try {
                let snapshot = snapshots.loadThread(threadId)
                expect(snapshot.thread.nextItemOrdinal == snapshot.items.size + 1,
                    "Thread header ordinal and Items must come from one revision")
                var activeTurns: Int64 = 0
                for (turn in snapshot.turns where turn.activeRunId.isSome()) {
                    activeTurns += 1
                    expect(snapshot.thread.activeTurnId.isSome() &&
                        snapshot.thread.activeTurnId.getOrThrow().value == turn.id.value &&
                        snapshot.activeRunId.isSome() &&
                        snapshot.activeRunId.getOrThrow().value == turn.activeRunId.getOrThrow().value &&
                        snapshot.activeEpoch > 0,
                        "active Thread, Turn and Run ownership must agree")
                }
                expect(activeTurns == if (snapshot.thread.activeTurnId.isSome()) { 1 } else { 0 },
                    "Thread active-turn pointer must agree with loaded Turns")
                if (activeTurns == 0) {
                    expect(snapshot.activeRunId.isNone(), "inactive Thread cannot expose an active Run")
                }
                reads += 1
                ready.store(true)
            } catch (error: Exception) {
                failure = "thread=" + threadId.value + " reads=" + reads.toString() +
                    " exception-message=[" + error.message + "]"
                ready.store(true)
                break
            }
        }
        (reads, failure)
    }
    try {
        while (!ready.load()) { sleep(Duration.millisecond) }
        for (index in 0..80) {
            let id = index.toString()
            runtime.startTurn(SemanticTurnId("snapshot-turn-" + id), RunId("snapshot-run-" + id),
                ItemId("snapshot-user-" + id), ThreadItemContent.UserMessage(textMessageParts("input")),
                lane("snapshot-model"), SkillStackSnapshot([], [])).value().getOrThrow()
            runtime.finish(RunState.Completed, 1000).value().getOrThrow()
        }
    } finally { done.store(true) }
    let (reads, failure) = reading.get()
    reader.close()
    writer.close()
    expect(failure == "", "concurrent Thread snapshot failed: " + failure)
    expect(reads > 1, "concurrent Thread snapshot reader observed multiple revisions")
    println("consistent concurrent Thread snapshots passed reads=" + reads.toString())
}
