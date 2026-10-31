package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private class OwnedCanonicalCustodyCounter { var calls: Int64 = 0 }

private func ownedCustodyCase(pool: LogicalJsonOwnerBudget): OwnedCanonicalThreadItemCustody {
    let owner = pool.acquire(1)
    try {
        // Real original-pool invoice BEFORE the byte array/String/typed Item.
        owner.ensureRetainedPeak(16777216)
        let text = String.fromUtf8(Array<Byte>(1048576, repeat: b'x')) + "\u{0}雪"
        OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("owned-custody-item"), ThreadId("owned-custody-thread"),
            SemanticTurnId("owned-custody-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), owner)
    } catch (error: Exception) { owner.close(); throw error }
}

@Test
class OwnedCanonicalThreadCustodyTests {
    @TestCase
    func FullItemFanoutAfterVisitKeepsSameOriginalHighwaterUntilLastRealAliasRetires(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let root = ownedCustodyCase(pool)
        let first = root.retainAliasCustody().value().getOrThrow()
        @Expect(root.closeAfterConsumption().isOk(), true)
        let second = first.retainAliasCustody().value().getOrThrow()
        @Expect(first.closeAfterAliasRetirement().isOk(), true)
        @Expect(pool.usage()[0] > 0 && pool.usage()[1] >= 16777216, true)
        @Expect(second.withItem({ item =>
            match (item.content) { case ThreadItemContent.SystemNote(text) =>
                @Expect(text.size > 1048576 && text.endsWith("\u{0}雪"), true)
                case _ => @Expect(false, true) }
            Result.Ok(()) }).isOk(), true)
        @Expect(second.closeAfterAliasRetirement().isOk(), true)
        @Expect(second.isAcknowledged(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func SerializationPrepaymentUsesReal128MiBPoolAndFailsBeforeConsumerAllocation(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let pressure = [pool.acquire(1), pool.acquire(1), pool.acquire(1), pool.acquire(1)]
        let root = ownedCustodyCase(pool)
        let held = root.retainAliasCustody().value().getOrThrow()
        let counter = OwnedCanonicalCustodyCounter()
        @Expect(held.withPaidItem(50331648, { _ => counter.calls++; Result.Ok(()) }).isOk(), false)
        @Expect(counter.calls, 0)
        @Expect(root.closeAfterConsumption().isOk(), true)
        @Expect(pool.usage()[1] > 67108864, true)
        @Expect(held.withPaidItem(1024, { _ => counter.calls++; Result.Ok(()) }).isOk(), true)
        @Expect(counter.calls, 1)
        @Expect(held.closeAfterAliasRetirement().isOk(), true)
        for (owner in pressure) { owner.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func BorrowAndExtractedFrameMustEndBeforeEitherActualCustodyAcknowledges(): Unit {
        let pool = LogicalJsonOwnerBudget(); let root = ownedCustodyCase(pool)
        let alias = root.retainAliasCustody().value().getOrThrow()
        @Expect(root.withItem({ _ =>
            @Expect(root.closeAfterConsumption().isOk(), false)
            @Expect(alias.closeAfterAliasRetirement().isOk(), false)
            @Expect(alias.isAcknowledged(), false)
            Result.Ok(()) }).isOk(), true)
        @Expect(root.closeAfterConsumption().isOk(), true)
        @Expect(pool.usage()[1] > 0, true)
        @Expect(alias.closeAfterAliasRetirement().isOk(), true)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ClosedAliasesCannotFanoutBorrowOrPrepayAndCleanupRemainsIdempotent(): Unit {
        let pool = LogicalJsonOwnerBudget(); let root = ownedCustodyCase(pool)
        let held = root.retainAliasCustody().value().getOrThrow()
        @Expect(root.closeAfterConsumption().isOk(), true)
        @Expect(held.closeAfterAliasRetirement().isOk(), true)
        @Expect(held.retainAliasCustody().isOk(), false)
        @Expect(held.ensureAdditionalRetainedPeak(1).isOk(), false)
        @Expect(held.withItem({ _ => Result.Ok(()) }).isOk(), false)
        @Expect(held.closeAfterAliasRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
