package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiRenderPaymentTests {
    @TestCase
    func ActualPaidCopiedOwnerSumsDocumentLayoutHistoryRasterAndFramePeaksAndKeepsOldDataOnRefusal(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let copied = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let display = OwnedTuiToolDisplay(copied, 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStartedWithId("bash", "call", "copied")).isOk(), true)
        original.close()
        @Expect(display.prepareRenderCopies(0, 1048576).isOk(), true)
        @Expect(display.prepareRenderCopies(1, 1048576).isOk(), true)
        @Expect(display.prepareRenderCopies(2, 1048576).isOk(), true)
        @Expect(display.prepareRenderCopies(3, 1048576).isOk(), true)
        @Expect(display.prepareRenderCopies(4, 1048576).isOk(), true)
        let paid = pool.usage()[1]
        @Expect(paid > 5 * 1048576, true)
        @Expect(display.prepareRenderCopies(1, 128 * 1048576).isOk(), false)
        @Expect(pool.usage()[1], paid)
        @Expect(display.withCopiedEvent({event =>
            match (event) {
                case TuiAgentEvent.ToolStartedWithId(_, _, text) => @Expect(text, "copied")
                case _ => @Fail("complete copied event retained") }
            Result.Ok(()) }).isOk(), true)
        @Expect(display.isAcknowledged(), false)
        @Expect(display.closeAfterCopiedDisplayRetirement().isOk(), true)
        // The independently retained real renderer custody remains paid;
        // this control has no physical cache/frame retirement authority.
        @Expect(pool.usage()[1] > 5 * 1048576, true)
    }
    @TestCase
    func RealWindowRasterPaymentFailurePrecedesBufferReplacementAndPreservesDisplay(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true)
        original.close()
        let document = Document([DocumentLine(DocumentLineKind.Paragraph, "é"),
            DocumentLine(DocumentLineKind.HorizontalRule, "Output")], retainedPayment: Some(OwnedTuiDocumentPayment(display)))
        let cache = DocumentWindowCache(); let target = Buffer(Rect(0, 0, 2, 2))
        let oldCells = cache.bufferCapacityCells()
        let pressure = pool.acquire(1)
        var failed = false
        try { cache.render(document, "paid", 0, Rect(0, 0, 65536, 65536), target) }
        catch (_: Exception) { failed = true }
        @Expect(failed, true); @Expect(cache.bufferCapacityCells(), oldCells)
        @Expect(display.isAcknowledged(), false)
        pressure.close()
        cache.render(document, "paid", 0, Rect(0, 0, 2, 2), target)
        @Expect(cache.bufferCapacityCells(), 256)
        // The real cache/raster references remain live here; no history or
        // callback-based refund is inferred by this test.
        @Expect(display.isAcknowledged(), false)
    }
    @TestCase
    func FrameInvoiceChargesPhysicalArraysAndCompleteScalarBackingAndRejectsOverflow(): Unit {
        @Expect(ownedTuiFrameConstructionInvoice(80, 24, 65536) > 65536 + 80 * 24 * 4, true)
        var failed = false
        try { let _ = ownedTuiFrameConstructionInvoice(Int64.Max, 2, 0) } catch (_: Exception) { failed = true }
        @Expect(failed, true)
    }
}
