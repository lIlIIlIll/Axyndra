package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private func identitySnapshotProducer159(owner: OwnedToolSetSnapshot159): Unit {
    owner.installSnapshot159(ToolSetSnapshot("catalog-identity-canary", []))
}
private func identityFixture159(root: LogicalJsonOwnerReservation): OwnedToolSnapshotIdentity159 {
    let source = root.deriveRetainedLease(); source.ensureRetainedPeak(131072)
    let producer = OwnedToolSetSnapshot159(source)
    identitySnapshotProducer159(producer); producer.returnedSnapshotProducer159()
    let shared = producer.transferSharedSnapshot159()
    try { shared.copyIdentity159() } finally { shared.close159() }
}
private func identityCopiedComparison159(owner: OwnedToolSnapshotIdentity159): Bool {
    owner.withText159<Bool>({ text => text == "catalog-identity-canary" })
}

// DATA copies only: these fixtures cannot admit an operation or mint Source.
@Test
class OwnedToolSnapshotIdentity159Tests {
    @TestCase
    func independentTextOutlivesSourceAndReturnsOnlyAfterWholeConsumer(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let copied = identityFixture159(root); root.close()
        @Expect(bank.usage()[1] > 0, true)
        @Expect(identityCopiedComparison159(copied), true)
        copied.returnCopiedFrame159()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        var rejected = false
        try { let _ = identityCopiedComparison159(copied) } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected, true)
    }
    @TestCase
    func activeBorrowCannotReturnItsCarrierEarly(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let copied = identityFixture159(root); root.close()
        let rejected = copied.withText159<Bool>({ _ =>
            try { copied.returnCopiedFrame159(); false } catch (_: IllegalStateException) { true } })
        @Expect(rejected, true); @Expect(bank.usage()[1] > 0, true)
        copied.returnCopiedFrame159()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func historicalAndExceptionalConsumersKeepOnlyTheirActualCopyPaid(): Unit {
        for (exceptional in [false, true]) {
            let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
            let copied = identityFixture159(root); root.close()
            if (exceptional) {
                try { let _ = copied.withText159<Bool>({ _ => throw IllegalStateException("opaque identity consumer") }) }
                catch (_: IllegalStateException) { () }
            } else { copied.retainHistorical159() }
            copied.returnCopiedFrame159()
            @Expect(bank.usage()[1] > 0, true)
            @Expect(identityCopiedComparison159(copied), true)
        }
    }
}
