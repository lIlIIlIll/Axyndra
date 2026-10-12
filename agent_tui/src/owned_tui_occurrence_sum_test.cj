package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiOccurrenceSumTests {
    @TestCase
    func RealSameOwnerVirtualHistoryAggregateAndModalDocumentsSumWithoutGrowingRenderMetadata(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true); original.close()
        let virtual = Document([DocumentLine(DocumentLineKind.Paragraph, "virtual é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 0)))
        let history = Document([DocumentLine(DocumentLineKind.Paragraph, "history é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 1)))
        let aggregate = Document([DocumentLine(DocumentLineKind.HorizontalRule, "aggregate")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 2)))
        let modal = Document([DocumentLine(DocumentLineKind.Paragraph, "modal é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        let virtualView = DocumentView(virtual, cacheLayout: true); let historyView = DocumentView(history, cacheLayout: true)
        let aggregateView = DocumentView(aggregate, cacheLayout: true); let modalView = DocumentView(modal, cacheLayout: true)
        let virtualRows = virtualView.renderedLineCount(20); let one = pool.usage()[1]
        let historyRows = historyView.renderedLineCount(20); let two = pool.usage()[1]
        let aggregateRows = aggregateView.renderedLineCount(20); let three = pool.usage()[1]
        let modalRows = modalView.renderedLineCount(20); let four = pool.usage()[1]
        @Expect(one < two && two < three && three < four, true)
        @Expect(virtualRows == 0 || historyRows == 0 || aggregateRows == 0 || modalRows == 0, false)
        for (_ in 0..100) { let _ = virtualView.renderedLineCount(20); let _ = historyView.renderedLineCount(20) }
        @Expect(pool.usage()[1], four)
        @Expect(display.prepareRenderCopies(1, 128 * 1048576, occurrence: 3).isOk(), false)
        @Expect(pool.usage()[1], four)
        @Expect(virtualView.renderedLineCount(20), virtualRows)
        @Expect(modalView.renderedLineCount(20), modalRows)
    }
    @TestCase
    func ActualOldWideRasterAndCompleteScalarBackingArePaidBeforeNarrowReplacement(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true); original.close()
        let cache = DocumentWindowCache(); let target = Buffer(Rect(0, 0, 40, 2))
        let old = Document([DocumentLine(DocumentLineKind.Paragraph, "é old exact")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        cache.render(old, "old", 0, Rect(0, 0, 40, 2), target)
        let exactCell = target.getCell(0, 0).symbol; let cells = cache.bufferCapacityCells()
        let oldInvoice = cache.retainedPreviousCopiesInvoice(); @Expect(oldInvoice > cells * 1024, true)
        let pressure = pool.acquire(1)
        let huge = Document([DocumentLine(DocumentLineKind.Paragraph, "new exact")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        var failed = false
        try { cache.render(huge, "new", 0, Rect(0, 0, 65536, 65536), target) } catch (_: Exception) { failed = true }
        @Expect(failed, true); @Expect(cache.bufferCapacityCells(), cells)
        @Expect(cache.retainedPreviousCopiesInvoice(), oldInvoice); @Expect(target.getCell(0, 0).symbol, exactCell)
        pressure.close()
        cache.render(huge, "new", 0, Rect(0, 0, 2, 2), target)
        @Expect(cache.bufferCapacityCells(), 256)
        @Expect(display.isAcknowledged(), false)
    }
}
