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

func addLongPresentationCard(snapshot: UiSnapshot, index: Int64): Unit {
    let body = StringBuilder()
    for (line in 0..180) {
        body.append("long history ")
        body.append(index.toString())
        body.append("-")
        body.append(line.toString())
        body.append("\n")
    }
    UiReducer.reduce(
        snapshot,
        UiEvent.UpsertCard(
            "long-history-${index}",
            UiCardKind.Assistant,
            "Long history ${index}",
            body.toString(),
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
    func boundedHistoryAcknowledgesOnlyEmittedCards(): Unit {
        let snapshot = UiSnapshot()
        addLongPresentationCard(snapshot, 0)
        addLongPresentationCard(snapshot, 1)
        for (index in 2..7) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })

        let batch = match (source.prepareHistoryBatch(21, 80)) {
            case Some(value) => value
            case None => @Fail("bounded history should emit the first large card")
        }
        source.acknowledgeHistory(batch.id)
        @Expect(source.retiredCount(), 1)
    }

    @TestCase
    func settledInteractionCardsCanRetire(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "resolved-ask",
                UiCardKind.Ask,
                "Resolved question",
                "answered",
                "completed",
                false,
                ""
            )
        )
        for (index in 1..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })

        let batch = match (source.prepareHistoryBatch(22, 80)) {
            case Some(value) => value
            case None => @Fail("settled interaction cards should be retireable")
        }
        source.acknowledgeHistory(batch.id)
        @Expect(source.retiredCount(), 2)
    }

    @TestCase
    func rawHistoryLinesStripTerminalControls(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "unsafe-transcript",
                UiCardKind.Assistant,
                "Unsafe transcript",
                "safe \u{1B}[31mred\u{1B}[0m \u{1B}]8;;https://example.test\u{07}done",
                "completed",
                false,
                ""
            )
        )
        for (index in 1..7) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let batch = match (source.prepareHistoryBatch(23, 80)) {
            case Some(value) => value
            case None => @Fail("unsafe transcript should produce a history batch")
        }
        var safe = true
        for (line in batch.lines()) {
            safe = safe && !line.contains("\u{1B}")
        }
        @Expect(safe, true)
        @Expect(batch.lines()[0].contains("safe"), true)
        @Expect(batch.lines()[0].contains("red"), true)
        @Expect(batch.lines()[0].contains("done"), true)
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
