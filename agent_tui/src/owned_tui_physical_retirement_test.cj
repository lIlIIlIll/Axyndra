package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedTuiPhysicalRetirementTests {
    @TestCase
    func ClosedActualMailboxRejectsOwnedTransferAndNeverFakesCopiedDataACK(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true); original.close()
        let mailbox = TuiMailbox(); mailbox.beginClosing(); let paid = pool.usage()[1]
        @Expect(mailbox.pushOwned(display).isOk(), false); @Expect(mailbox.size(), 0)
        mailbox.clearAfterProducerRetirement()
        @Expect(pool.usage()[1], paid); @Expect(display.isAcknowledged(), false)
        @Expect(display.withCopiedEvent({event =>
            match (event) { case TuiAgentEvent.ToolStarted(_, text) => @Expect(text, "kept"); case _ => @Fail("exact copied display") }
            Result.Ok(()) }).isOk(), true)
    }
    @TestCase
    func ActualSourceHistoryAndVirtualCachesClearTheirReferencesWithoutClaimingTargetACK(): Unit {
        let pool = LogicalJsonOwnerBudget(); let original = pool.acquire(1)
        let display = OwnedTuiToolDisplay(original.acquireCopiedDisplayAllocation(65536).value().getOrThrow(), 65536)
        @Expect(display.installCopiedEvent(TuiAgentEvent.ToolStarted("bash", "kept")).isOk(), true); original.close()
        let ui = UiSnapshot(); let card = UiCard("card", UiCardKind.Tool, "title", "kept")
        ui.cards.add(card)
        let source = AgentTranscriptSource(ui, {_, _, _ => Document([DocumentLine(DocumentLineKind.Paragraph, "kept")],
            retainedPayment: Some(OwnedTuiDocumentPayment(display)))})
        let view = VirtualTranscriptView(source, backgroundBatch: 0)
        let target = Buffer(Rect(0, 0, 10, 4)); view.render(target.area, target)
        let paid = pool.usage()[1]
        source.retireOwnedReferences(); view.retireRetainedReferences()
        @Expect(source.size(), 0); @Expect(view.metrics().cacheEntries, 0)
        // Actual target and the caller's card remain external references;
        // no Screen receipt or renderer payment refund is invented here.
        @Expect(card.body, "kept"); @Expect(pool.usage()[1], paid)
        @Expect(display.isAcknowledged(), false)
    }
}
