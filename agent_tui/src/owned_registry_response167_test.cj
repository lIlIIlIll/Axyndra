package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiRegistryResponse167Tests {
    @TestCase
    func ActualMailboxDrainAndFieldClearKeepMaintenancePaymentWithoutNativeScreenReceipt(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let payment = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let backend = ActualInheritedScreenOrdinaryBackend()
        let display = OwnedTuiRegistryResponseDisplay167(backend, payment, 65536)
        original.close()
        let mailbox = TuiMailbox(capacity: 8)
        mailbox.complete(TuiTurnResult("", "ready", action: TuiTurnAction.OpenDocument("Plugins", "雪\ncomplete maintenance"),
            ownedRegistryDisplay167: Some(display)))
        let before = pool.usage()[1]
        let actual = mailbox.takeResult().getOrThrow()
        @Expect(refEq(actual.ownedRegistryDisplay167.getOrThrow(), display), true)
        match (actual.action) {
            case TuiTurnAction.OpenDocument(title, body) => @Expect(title, "Plugins"); @Expect(body, "雪\ncomplete maintenance")
            case _ => @Fail("actual maintenance document action") }
        mailbox.beginClosing(); mailbox.clearAfterProducerRetirement()
        let screen = AgentScreen(backend, "held title", "")
        @Expect(RetiredOwnedTuiScreenReferences.retire(screen).isNone(), true)
        // An actual observer call and drained mailbox do not manufacture
        // Future/Window/Terminal/direct-stdout native retirement evidence.
        @Expect(pool.usage()[1], before)
        @Expect(payment.isAcknowledged(), false)
    }
    @TestCase
    func ActualVirtualHistoryAggregateAndModalLayoutsHaveSeparateSimultaneousInvoices(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let payment = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let backend = ActualInheritedScreenOrdinaryBackend()
        let display = OwnedTuiRegistryResponseDisplay167(backend, payment, 65536)
        original.close()
        let virtual = Document([DocumentLine(DocumentLineKind.Paragraph, "virtual plugin é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 0)))
        let history = Document([DocumentLine(DocumentLineKind.Paragraph, "history plugin é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 1)))
        let aggregate = Document([DocumentLine(DocumentLineKind.Paragraph, "aggregate plugin é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 2)))
        let modal = Document([DocumentLine(DocumentLineKind.Paragraph, "modal plugin é")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        let virtualView = DocumentView(virtual, cacheLayout: true)
        let historyView = DocumentView(history, cacheLayout: true)
        let aggregateView = DocumentView(aggregate, cacheLayout: true)
        let modalView = DocumentView(modal, cacheLayout: true)
        let virtualRows = virtualView.renderedLineCount(20); let one = pool.usage()[1]
        let historyRows = historyView.renderedLineCount(20); let two = pool.usage()[1]
        let aggregateRows = aggregateView.renderedLineCount(20); let three = pool.usage()[1]
        let modalRows = modalView.renderedLineCount(20); let four = pool.usage()[1]
        @Expect(one < two && two < three && three < four, true)
        @Expect(virtualRows > 0 && historyRows > 0 && aggregateRows > 0 && modalRows > 0, true)
        for (_ in 0..16) { let _ = virtualView.renderedLineCount(20); let _ = historyView.renderedLineCount(20) }
        @Expect(pool.usage()[1], four)
        @Expect(payment.isAcknowledged(), false)
    }
    @TestCase
    func ActualBankPressureRefusesNewRasterWithoutClearingOldMaintenanceLayout(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let payment = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let backend = ActualInheritedScreenOrdinaryBackend()
        let display = OwnedTuiRegistryResponseDisplay167(backend, payment, 65536)
        original.close()
        let cache = DocumentWindowCache(); let target = Buffer(Rect(0, 0, 8, 2))
        let old = Document([DocumentLine(DocumentLineKind.Paragraph, "old 雪 plugin")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        cache.render(old, "old", 0, target.area, target)
        let oldCell = target.getCell(0, 0).symbol
        let oldCapacity = cache.bufferCapacityCells()
        let oldInvoice = cache.retainedPreviousCopiesInvoice()
        let pressure = pool.acquire(1)
        let next = Document([DocumentLine(DocumentLineKind.Paragraph, "new plugin")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display, occurrence: 3)))
        var refused = false
        try { cache.render(next, "new", 0, Rect(0, 0, 65536, 65536), target) }
        catch (_: Exception) { refused = true }
        @Expect(refused, true)
        @Expect(cache.bufferCapacityCells(), oldCapacity)
        @Expect(cache.retainedPreviousCopiesInvoice(), oldInvoice)
        @Expect(target.getCell(0, 0).symbol, oldCell)
        @Expect(payment.isAcknowledged(), false)
        pressure.close()
        cache.render(next, "new", 0, Rect(0, 0, 2, 2), target)
        @Expect(payment.isAcknowledged(), false)
    }
}
