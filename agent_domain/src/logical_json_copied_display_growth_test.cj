package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonCopiedDisplayGrowthTests {
    @TestCase
    func SharedHighWaterGrowsBeforeAllocationAndFailurePreservesEveryOldTicket(): Unit {
        let pool = LogicalJsonOwnerBudget(); let row = pool.acquire(1)
        row.ensureRetainedPeak(67108864)
        let copy = row.acquireCopiedDisplayAllocation(131072).value().getOrThrow()
        let cache = copy.retainCopiedDisplayAllocation().value().getOrThrow()
        @Expect(pool.usage()[1], 67108864 + 140032 + 1024)
        @Expect(cache.ensureCopiedDisplayRetainedPeak(196608).isOk(), true)
        @Expect(pool.usage()[1], 67108864 + 206592 + 1024)
        @Expect(copy.ensureCopiedDisplayRetainedPeak(1024).isOk(), true)
        @Expect(pool.usage()[1], 67108864 + 206592 + 1024)
        let pressure = pool.acquire(1); let before = pool.usage()
        @Expect(copy.ensureCopiedDisplayRetainedPeak(67108864).isOk(), false)
        @Expect(pool.usage()[0], before[0]); @Expect(pool.usage()[1], before[1])
        @Expect(copy.withCopiedDisplayBorrow({ =>
            @Expect(cache.closeAfterCopiedDisplayRetirement().isOk(), false)
            @Expect(cache.ensureCopiedDisplayRetainedPeak(196608).isOk(), true)
            Result.Ok(()) }).isOk(), true)
        row.close(); pressure.close()
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(copy.ensureCopiedDisplayRetainedPeak(262144).isOk(), false)
        @Expect(pool.usage()[1], 206592 + 1024)
        @Expect(cache.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
