package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

func addStablePresentationCard(snapshot: UiSnapshot, index: Int64): Unit {
    UiReducer.reduce(
        snapshot,
        UiEvent.UpsertCard(
            "history-${index}",
            UiCardKind.Assistant,
            "Assistant ${index}",
            "history body ${index}",
            "completed",
            false,
            ""
        )
    )
}

func presentationBatchKind(batch: HistoryBatch): String {
    match (batch.kind) {
        case HistoryBatchKind.Append => "append"
        case HistoryBatchKind.Replay => "replay"
    }
}

@Test
class TuiPresentationTests {
    @TestCase
    func retirementIsPendingUntilExplicitAcknowledgement(): Unit {
        let snapshot = UiSnapshot()
        for (index in 0..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })

        let first = match (source.prepareHistoryBatch(11, 80)) {
            case Some(value) => value
            case None => @Fail("stable prefix should produce a history batch")
        }
        @Expect(presentationBatchKind(first), "append")
        @Expect(source.retiredCount(), 0)
        @Expect(source.size(), 6)

        let retry = match (source.prepareHistoryBatch(11, 80)) {
            case Some(value) => value
            case None => @Fail("unacknowledged history must remain retryable")
        }
        @Expect(retry.id, first.id)
        @Expect(retry.lineCount(), first.lineCount())

        source.acknowledgeHistory(first.id)
        @Expect(source.retiredCount(), 2)
        @Expect(source.size(), 6)
    }

    @TestCase
    func resizeRequestsReplayWithoutDuplicatingBatchIds(): Unit {
        let snapshot = UiSnapshot()
        for (index in 0..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let adapter = AgentPresentationAdapter(source)

        let first = match (adapter.prepare(Rect(0, 0, 80, 24))) {
            case Some(value) => value
            case None => @Fail("initial stable prefix should be prepared")
        }
        @Expect(presentationBatchKind(first), "append")
        adapter.acknowledge(first.id)

        let replay = match (adapter.prepare(Rect(0, 0, 100, 24))) {
            case Some(value) => value
            case None => @Fail("resize must prepare a replay batch")
        }
        @Expect(presentationBatchKind(replay), "replay")
        @Expect(replay.id > first.id, true)
        let sameReplay = match (adapter.prepare(Rect(0, 0, 100, 24))) {
            case Some(value) => value
            case None => @Fail("replay must remain pending until acknowledged")
        }
        @Expect(sameReplay.id, replay.id)
        adapter.acknowledge(replay.id)
    }

    @TestCase
    func adapterRendersOnlyThePreparedBatch(): Unit {
        let snapshot = UiSnapshot()
        for (index in 0..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let adapter = AgentPresentationAdapter(source)
        let batch = match (adapter.prepare(Rect(0, 0, 80, 24))) {
            case Some(value) => value
            case None => @Fail("history batch is required for render probe")
        }
        let backend = TestBackend(area: Rect(0, 0, 80, 24))
        let terminal = Terminal(backend)
        terminal.draw { frame =>
            adapter.renderHistory(batch.id, 0, frame)
        }
        let output = backend.output()
        @Expect(output.contains("history body 0"), true)
        @Expect(output.contains("history body 1"), true)
        @Expect(output.contains("history body 8"), false)
        adapter.acknowledge(batch.id)
    }
}
