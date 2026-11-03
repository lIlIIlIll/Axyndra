package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

class WindowBorrowRetirementProbe <: RetainedDocumentPayment {
    let cache: DocumentWindowCache
    var sawBorrowReject = false
    init(cache: DocumentWindowCache) { this.cache = cache }
    public func prepareRasterCopies(_: Int64): Bool {
        sawBorrowReject = RetiredDocumentWindowReferences.retire(cache).isNone(); true }
    public func prepareLayoutCopies(_: Int64): Bool { true }
    public func prepareHistoryCopies(_: Int64): Bool { true }
}

@Test
class RetiredDocumentWindowReferenceTests {
    @TestCase
    func ActualRasterRenderBorrowBlocksRetirementAndActualClearLeavesBlitTargetsUnacknowledged(): Unit {
        let cache = DocumentWindowCache(); let payment = WindowBorrowRetirementProbe(cache)
        let document = Document([DocumentLine(DocumentLineKind.Paragraph, "kept")], retainedPayment: Some(payment))
        let target = Buffer(Rect(0, 0, 8, 2))
        cache.render(document, "window", 0, target.area, target)
        @Expect(payment.sawBorrowReject, true)
        let witness = RetiredDocumentWindowReferences.retire(cache).getOrThrow()
        @Expect(witness.internalReferencesRetired(), true)
        @Expect(witness.targetBufferReferencesAcknowledged(), false)
        @Expect(cache.entries(), 0); @Expect(cache.bufferCapacityCells(), 0)
        @Expect(target.getCell(0, 0).symbol, "k")
    }
    @TestCase
    func ActualInternalWindowWitnessDoesNotRefundRealCopiedRendererOrTargetData(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true)
        original.close()
        let document = Document([DocumentLine(DocumentLineKind.Paragraph, "kept")], retainedPayment: Some(OwnedTuiDocumentPayment(display)))
        let cache = DocumentWindowCache(); let target = Buffer(Rect(0, 0, 8, 2))
        cache.render(document, "copied", 0, target.area, target)
        let paid = pool.usage()[1]
        @Expect(RetiredDocumentWindowReferences.retire(cache).getOrThrow().targetBufferReferencesAcknowledged(), false)
        @Expect(display.isAcknowledged(), false); @Expect(pool.usage()[1], paid)
        @Expect(target.getCell(0, 0).symbol, "k")
    }
}
