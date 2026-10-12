package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonCopiedDisplayTests {
    @TestCase
    func IndependentFixedCopyRetiresSeparatelyFromOriginal64MiBLedger(): Unit {
        let pool = LogicalJsonOwnerBudget(); let row = pool.acquire(1)
        row.ensureRetainedPeak(67108864)
        let copy = row.acquireCopiedDisplayAllocation(196608).value().getOrThrow()
        let cache = copy.retainCopiedDisplayAllocation().value().getOrThrow()
        @Expect(pool.usage()[0], 6)
        @Expect(pool.usage()[1], 67108864 + 205824 + 1024)
        row.close()
        @Expect(pool.usage()[1], 205824 + 1024)
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[1], 205824 + 1024)
        @Expect(cache.withCopiedDisplayBorrow({ =>
            @Expect(cache.closeAfterCopiedDisplayRetirement().isOk(), false)
            Result.Ok(()) }).isOk(), true)
        @Expect(cache.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(cache.isAcknowledged(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func OriginalAggregatePressureRollsBackEveryPartiallyAcquiredFixedTicket(): Unit {
        let pool = LogicalJsonOwnerBudget(); let row = pool.acquire(1)
        row.ensureRetainedPeak(67108864)
        let pressure = pool.acquire(1)
        @Expect(row.acquireCopiedDisplayAllocation(50331648).isOk(), false)
        @Expect(pool.usage()[0], 2); @Expect(pool.usage()[1], 83886080)
        let copy = row.acquireCopiedDisplayAllocation(65536).value().getOrThrow()
        @Expect(pool.usage()[1] > 83886080, true)
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        pressure.close(); row.close()
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ClosedSourceInvalidInvoiceAndSharedBorrowCannotMintOrRetireHandles(): Unit {
        let pool = LogicalJsonOwnerBudget(); let row = pool.acquire(1)
        @Expect(row.acquireCopiedDisplayAllocation(0).isOk(), false)
        @Expect(row.acquireCopiedDisplayAllocation(Int64.Max).isOk(), false)
        let copy = row.acquireCopiedDisplayAllocation(1024).value().getOrThrow()
        let mailbox = copy.retainCopiedDisplayAllocation().value().getOrThrow()
        @Expect(copy.withCopiedDisplayBorrow({ =>
            @Expect(mailbox.closeAfterCopiedDisplayRetirement().isOk(), false)
            Result.Ok(()) }).isOk(), true)
        row.close()
        @Expect(row.acquireCopiedDisplayAllocation(1024).isOk(), false)
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(copy.retainCopiedDisplayAllocation().isOk(), false)
        @Expect(copy.withCopiedDisplayBorrow({ => Result.Ok(()) }).isOk(), false)
        @Expect(mailbox.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(mailbox.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
