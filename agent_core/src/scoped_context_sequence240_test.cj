package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private func scopedSequenceProducer240(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("scoped-sequence-tools", []))
}
private class ScopedSequenceFixture240 {
    let bank = LogicalJsonOwnerBudget()
    let root: LogicalJsonOwnerReservation
    let shared: SharedToolSetSnapshot159
    let context: ToolInvocationContext
    init() {
        root = bank.acquire(131072)
        let data = root.deriveRetainedLease(); data.ensureRetainedPeak(131072)
        let producer = OwnedToolSetSnapshot159(data)
        scopedSequenceProducer240(producer); producer.returnedSnapshotProducer159()
        shared = producer.transferSharedSnapshot159()
        context = ToolInvocationContext(RunId("scoped-sequence-run"), SessionId("scoped-sequence-thread"),
            CapabilitySet(), epoch: 1, ownedToolSetSnapshot159: Some(shared.fork159()))
    }
    func close(): Unit { context.returnOwnedToolSetFrame159(); shared.close159(); root.close() }
}
private func contextIsClosed240(value: ToolInvocationContext): Bool {
    try { value.requireLiveInvocationView159(); false }
    catch (_: IllegalStateException) { true }
}

// Public APIs and real paid Context/snapshot views only. These DATA callbacks
// produce no Source, Tool invocation, Operation, approval, task-return witness
// or provider result. The original parent/retained/historical debts stay distinct.
@Test
class ScopedContextSequence240Tests {
    @TestCase
    func LegacySequenceStillReceivesItsOriginalOpenContext(): Unit {
        let fixture = ScopedSequenceFixture240(); let saved = [None<ToolInvocationContext>]
        try {
            let sequence = ContextReadSequence(1, { context, _ =>
                saved[0] = Some(context); Result.Ok(ContextReadNext.Ready(InvocationContextProjection())) })
            @Expect(sequence.advance(fixture.context, []).isOk())
            @Expect(contextIsClosed240(saved[0].getOrThrow()), false)
            @Expect(saved[0].getOrThrow().runId.value, "scoped-sequence-run")
        } finally { fixture.close() }
    }
    @TestCase
    func ScopedSequenceRevokesOnlyItsLoanAndPreservesAnActualRetainedConsumer(): Unit {
        let fixture = ScopedSequenceFixture240(); let saved = [None<ToolInvocationContext>]
        let retained = [None<ToolInvocationContext>]
        let sequence = ContextReadSequence.scoped240(1, { context, _ =>
            saved[0] = Some(context); retained[0] = Some(context.retainInvocationContext159())
            Result.Ok(ContextReadNext.Ready(InvocationContextProjection())) })
        try {
            @Expect(sequence.advance(fixture.context, []).isOk())
            @Expect(contextIsClosed240(saved[0].getOrThrow()))
            @Expect(contextIsClosed240(fixture.context), false)
            fixture.close()
            @Expect(retained[0].getOrThrow().runId.value, "scoped-sequence-run")
            @Expect(retained[0].getOrThrow().epoch, 1)
            @Expect(fixture.bank.usage()[1] > 0)
        } finally { retained[0].getOrThrow().returnOwnedToolSetFrame159(); fixture.close() }
        @Expect(fixture.bank.usage()[0], 0); @Expect(fixture.bank.usage()[1], 0)
    }
    @TestCase
    func AHistoricalGraphExportStaysPaidAfterTheScopedCallbackReturns(): Unit {
        let fixture = ScopedSequenceFixture240(); let raw = [None<ToolSetSnapshot>]
        let sequence = ContextReadSequence.scoped240(1, { context, _ =>
            raw[0] = context.toolSetSnapshot
            Result.Ok(ContextReadNext.Ready(InvocationContextProjection())) })
        try { @Expect(sequence.advance(fixture.context, []).isOk()) }
        finally { fixture.close() }
        @Expect(raw[0].getOrThrow().id, "scoped-sequence-tools")
        @Expect(fixture.bank.usage()[1] > 0)
    }
    @TestCase
    func AThrowStillEndsOnlyTheActualScopedLoan(): Unit {
        let fixture = ScopedSequenceFixture240(); let saved = [None<ToolInvocationContext>]
        let sequence = ContextReadSequence.scoped240(1, { context, _ =>
            saved[0] = Some(context); throw IllegalStateException("scoped-sequence-fixture") })
        try {
            var caught = false
            try { let _ = sequence.advance(fixture.context, []) }
            catch (error: IllegalStateException) { caught = error.message == "scoped-sequence-fixture" }
            @Expect(caught); @Expect(contextIsClosed240(saved[0].getOrThrow()))
            @Expect(contextIsClosed240(fixture.context), false)
        } finally { fixture.close() }
        @Expect(fixture.bank.usage()[1], 0)
    }
}
