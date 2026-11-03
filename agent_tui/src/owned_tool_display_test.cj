package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiToolDisplayTests {
    @TestCase
    func ActualMailboxDrainAndReducerKeepCopiedPaymentWithoutCallbackOrHistoryRefund(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let allocation = original.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let display = OwnedTuiToolDisplay(allocation, 65536)
        let invoice = ownedTuiCardFormattingInvoice(65536, 64).value().getOrThrow()
        @Expect(display.ensureCopiedDisplayRetainedPeak(invoice).isOk(), true)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStartedWithId("generic", "call", "{\"x\":\"copied\"}")).isOk(), true)
        let mailbox = TuiMailbox(); mailbox.push(TuiAgentEvent.OwnedToolDisplay(display))
        original.close(); let paid = pool.usage()[1]
        let snapshot = UiSnapshot()
        for (event in mailbox.drain()) {
            match (event) {
                case TuiAgentEvent.OwnedToolDisplay(actual) => @Expect(actual.withCopiedEvent({copied =>
                    match (copied) {
                        case TuiAgentEvent.ToolStartedWithId(name, id, arguments) =>
                            UiReducer.reduce(snapshot, UiEvent.UpsertCard("card", UiCardKind.Tool, name, arguments, "running", false, ""))
                            UiReducer.reduce(snapshot, UiEvent.SetToolMetadata("card", name, arguments, id, ""))
                        case _ => @Fail("copied start required") }
                    @Expect(actual.closeAfterCopiedDisplayRetirement().isOk(), false); Result.Ok(()) }).isOk(), true)
                case _ => @Fail("owned actual mailbox entry required") }
        }
        @Expect(snapshot.cards[0].toolArguments, "{\"x\":\"copied\"}")
        @Expect(display.isAcknowledged(), false); @Expect(pool.usage()[1], paid)
        // Only this test's actual card references retire here. Production
        // Screen retains them through history/cache/raster and does not close.
        snapshot.cards[0].body = ""; snapshot.cards[0].toolArguments = ""; snapshot.cards[0].toolName = ""
        snapshot.cards[0].toolCallId = ""; snapshot.cards[0].title = ""; snapshot.cards.clear()
        @Expect(display.closeAfterCopiedDisplayRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func FormattingInvoiceIncludesAllCopiesAndRejectsOverflowRatherThanShrinkingDisplayPolicy(): Unit {
        @Expect(ownedTuiCardFormattingInvoice(65536, 12288).value().getOrThrow(), 3473408)
        @Expect(ownedTuiCardFormattingInvoice(65536, Int64.Max).isOk(), false)
        @Expect(ownedTuiCardFormattingInvoice(Int64.Max, 1).isOk(), false)
    }
}
