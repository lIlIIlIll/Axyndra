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

func addOversizedPresentationCard(snapshot: UiSnapshot, index: Int64): Unit {
    let body = StringBuilder()
    for (line in 0..400) {
        body.append("oversized history ")
        body.append(index.toString())
        body.append("-")
        body.append(line.toString())
        body.append("\n")
    }
    UiReducer.reduce(
        snapshot,
        UiEvent.UpsertCard(
            "oversized-history-${index}",
            UiCardKind.Assistant,
            "Oversized history ${index}",
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
    func resizePreservesNativeScrollbackWithoutRequestingReplay(): Unit {
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

        let afterResize = adapter.prepare(Rect(0, 0, 100, 24))
        match (afterResize) {
            case Some(_) => @Fail("resize must not request a scrollback replay")
            case None => ()
        }
        @Expect(source.historyReplayRequested(), false)
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
    func oversizedFirstCardIsCappedAndHistoryProgresses(): Unit {
        let snapshot = UiSnapshot()
        addOversizedPresentationCard(snapshot, 0)
        addStablePresentationCard(snapshot, 1)
        for (index in 2..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let first = match (source.prepareHistoryBatch(27, 80)) {
            case Some(value) => value
            case None => @Fail("oversized first card should produce a bounded history batch")
        }
        @Expect(first.lineCount() <= 256, true)
        var truncated = false
        for (line in first.lines()) {
            truncated = truncated || line.contains("history truncated")
        }
        @Expect(truncated, true)
        source.acknowledgeHistory(first.id)
        @Expect(source.retiredCount(), 0)
        let second = match (source.prepareHistoryBatch(28, 80)) {
            case Some(value) => value
            case None => @Fail("history should continue the oversized card after the cap")
        }
        var continued = false
        var nextCardVisible = false
        for (line in second.lines()) {
            continued = continued || line.contains("oversized history 0-255")
            nextCardVisible = nextCardVisible || line.contains("history body 1")
        }
        @Expect(continued, true)
        @Expect(nextCardVisible, true)
        source.acknowledgeHistory(second.id)
        @Expect(source.retiredCount(), 2)
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
    func rawHistoryTitlesAndFootersStripTerminalControls(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "unsafe-title-footer",
                UiCardKind.Tool,
                "Unsafe \u{1B}[31mtitle\u{1B}[0m\nnext",
                "safe body",
                "completed",
                false,
                "footer \u{1B}]8;;https://example.test\u{07}\nnext"
            )
        )
        for (index in 1..7) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let batch = match (source.prepareHistoryBatch(26, 80)) {
            case Some(value) => value
            case None => @Fail("unsafe title and footer should produce a history batch")
        }
        var safe = true
        for (line in batch.lines()) {
            safe = safe && !line.contains("\u{1B}") && !line.contains("\n") && !line.contains("\r")
        }
        @Expect(safe, true)
        @Expect(batch.lines()[0].contains("Unsafe"), true)
        @Expect(batch.lines()[0].contains("next"), true)
        @Expect(batch.lines()[batch.lineCount() - 1].contains("footer"), true)
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
    @TestCase
    func boundedHistoryRequestsFollowUpFrame(): Unit {
        let snapshot = UiSnapshot()
        addLongPresentationCard(snapshot, 0)
        addLongPresentationCard(snapshot, 1)
        for (index in 2..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let adapter = AgentPresentationAdapter(source)
        let first = match (adapter.prepare(Rect(0, 0, 80, 24))) {
            case Some(value) => value
            case None => @Fail("bounded history should prepare the first batch")
        }
        @Expect(adapter.hasHistoryFollowUp(), true)
        adapter.acknowledge(first.id)
        let second = match (adapter.prepare(Rect(0, 0, 80, 24))) {
            case Some(value) => value
            case None => @Fail("follow-up history should be prepared")
        }
        @Expect(second.id > first.id, true)
        @Expect(adapter.hasHistoryFollowUp(), false)
        adapter.acknowledge(second.id)
    }

    @TestCase
    func shortReplayEmitsResetBatch(): Unit {
        let snapshot = UiSnapshot()
        for (index in 0..5) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        source.requestHistoryReplay()

        let replay = match (source.prepareHistoryBatch(24, 80)) {
            case Some(value) => value
            case None => @Fail("short replay must emit an empty reset batch")
        }
        @Expect(presentationBatchKind(replay), "replay")
        @Expect(replay.lineCount(), 0)
        source.acknowledgeHistory(replay.id)
        @Expect(source.historyReplayRequested(), false)
    }

    @TestCase
    func blockedToolJobsStayVisible(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "blocked-job",
                UiCardKind.Tool,
                "Blocked job",
                "waiting for approval",
                "blocked",
                false,
                ""
            )
        )
        for (index in 1..8) {
            addStablePresentationCard(snapshot, index)
        }
        let source = AgentTranscriptSource(snapshot, { item, _, _ => Document.plain(item.body) })
        let batch = source.prepareHistoryBatch(25, 80)
        match (batch) {
            case Some(_) => @Fail("blocked tool jobs must remain in the live viewport")
            case None => ()
        }
    }
    @TestCase
    func agentHubWindowStartMatchesVisibleRows(): Unit {
        let area = Rect(0, 0, 40, 10)
        @Expect(agentHubWindowCapacity(area), 4)
        @Expect(agentHubSelectionRow(area, area.y), -1)
        @Expect(agentHubSelectionRow(area, area.y + 1), 0)
        @Expect(agentHubSelectionIndex(area, 6, 8, 0), 4)
        @Expect(agentHubSelectionIndex(area, 6, 8, 2), 6)
        @Expect(agentHubSelectionIndex(area, 6, 8, 4), -1)
        @Expect(agentHubSelectionIndex(area, 6, 3, 3), -1)
    }
}
