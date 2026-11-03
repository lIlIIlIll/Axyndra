package agent_tui

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import core.*
import std.unittest.*
import std.unittest.testmacro.*

private func tuiFailureDisplayFixture113(pool: LogicalJsonOwnerBudget): OwnedTuiFailureDisplay113 {
    let source = pool.acquire(1)
    try {
        let paid = source.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        let result = OwnedTuiFailureDisplay113(paid, 65536)
        result.installCopiedFailure113("code雪\u{0}", "message🙂\u{0}", "{\"complete\":\"雪\\u0000🙂\"}").value().getOrThrow()
        result
    } finally { source.close() }
}

@Test
class ActualOwnedTuiFailureDisplay113Tests {
    @TestCase
    func actualMailboxCapacityIsNonblockingAndKeepsCopiedFailureUntilRealDrain113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let display = tuiFailureDisplayFixture113(pool)
        let mailbox = TuiMailbox(capacity: 8)
        for (_ in 0..8) { mailbox.push(TuiAgentEvent.Error("ordinary")) }
        let pending = mailbox.pushOwnedFailure113(display).error().getOrThrow()
        @Expect(refEq(pending, TUI_FAILURE_MAILBOX_PENDING113), true)
        @Expect(mailbox.size(), 8); @Expect(display.isAcknowledged(), false)
        @Expect(mailbox.drain().size, 8)
        @Expect(mailbox.pushOwnedFailure113(display).isOk(), true)
        let snapshot = UiSnapshot()
        for (event in mailbox.drain()) {
            match (event) {
                case TuiAgentEvent.OwnedFailureDisplay113(actual) =>
                    @Expect(refEq(actual, display), true)
                    actual.withCopiedFailure113({ code, message, complete =>
                        actual.ensureCopiedDisplayRetainedPeak(1048576).value().getOrThrow()
                        UiReducer.reduce(snapshot, UiEvent.UpsertCard("failure", UiCardKind.Error,
                            code, message + "\n\n" + complete, "failed", false, ""))
                        @Expect(actual.closeUnpublishedCopiedFailure113().isError(), true)
                        Result<Unit>.Ok(()) }).value().getOrThrow()
                    actual.noteUiAdoption()
                case _ => @Fail("actual copied mailbox entry required") }
        }
        @Expect(snapshot.cards[0].title, "code雪\u{0}")
        @Expect(snapshot.cards[0].body, "message🙂\u{0}\n\n{\"complete\":\"雪\\u0000🙂\"}")
        @Expect(display.closeUnpublishedCopiedFailure113().isError(), true)
        @Expect(pool.usage()[1] > 0, true)
        // An actual reducer/callback/history copy is not a native Screen ACK.
    }
    @TestCase
    func actualScreenProjectionAndRendererPaymentsKeepTheFullCopiedBodyWithoutRetirementReceipt113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let display = tuiFailureDisplayFixture113(pool)
        let backend = ActualInheritedScreenOrdinaryBackend()
        let screen = AgentScreen(backend, "title", "")
        backend.observer.getOrThrow()(TuiAgentEvent.OwnedFailureDisplay113(display))
        let _ = screen.update(Event.Message("agent-external-ready"))
        @Expect(display.isProjected(), true)
        let ui = screen.uiSnapshot()
        @Expect(ui.cards[0].title, "Error: code雪\u{0}")
        @Expect(ui.cards[0].body, "message🙂\u{0}\n\n{\"complete\":\"雪\\u0000🙂\"}")
        @Expect(display.matchesUiCard(ui.cards[0].id), true)
        let payment = OwnedTuiDocumentPayment(display)
        @Expect(payment.prepareLayoutCopies(65536), true)
        @Expect(payment.prepareHistoryCopies(65536), true)
        @Expect(payment.prepareRasterCopies(65536), true)
        @Expect(RetiredOwnedTuiScreenReferences.retire(screen).isNone(), true)
        @Expect(display.isAcknowledged(), false)
        @Expect(display.closeUnpublishedCopiedFailure113().isError(), true)
        @Expect(pool.usage()[1] > 0, true)
    }
    @TestCase
    func unpublishedActualCopyCanRetireOnlyAfterItsRealBorrowFrameReturns113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let display = tuiFailureDisplayFixture113(pool)
        @Expect(display.withCopiedFailure113({ code, _, complete =>
            @Expect(code, "code雪\u{0}"); @Expect(complete.contains("\\u0000"), true)
            @Expect(display.closeUnpublishedCopiedFailure113().isError(), true)
            Result<Unit>.Ok(()) }).isOk(), true)
        @Expect(display.isAcknowledged(), false)
        @Expect(display.closeUnpublishedCopiedFailure113().isOk(), true)
        @Expect(display.isAcknowledged(), true); @Expect(pool.usage()[1], 0)
    }
}
