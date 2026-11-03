package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonRetainedPeakTests {
    @TestCase
    func peakGrowthSharesAggregateAndFailedGrowthRetainsOriginalCharge(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 33554432)
        let first = pool.acquire(1)
        let second = pool.acquire(1)
        try {
            var rejected = false
            try { first.ensureRetainedPeak(25165824) }
            catch (_: LogicalJsonPayloadError) { rejected = true }
            @Expect(rejected, true)
            @Expect(logicalPayloadUsageEqual(pool.usage(), (2, 33554432)), true)
            second.close()
            first.ensureRetainedPeak(25165824)
            first.ensureRetainedPeak(16777216)
            first.ensureDecoded(1, 1)
            @Expect(logicalPayloadUsageEqual(pool.usage(), (1, 25165824)), true)
        } finally { second.close(); first.close() }
        @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)), true)
    }

    @TestCase
    func invalidOrClosedPeakCannotAcquireCapacity(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let reservation = pool.acquire(1)
        try {
            var negativeRejected = false
            try { reservation.ensureRetainedPeak(-1) }
            catch (_: LogicalJsonPayloadError) { negativeRejected = true }
            @Expect(negativeRejected, true)
            var oversizedRejected = false
            try { reservation.ensureRetainedPeak(1073741825) }
            catch (_: LogicalJsonPayloadError) { oversizedRejected = true }
            @Expect(oversizedRejected, true)
            @Expect(logicalPayloadUsageEqual(pool.usage(), (1, 16777216)), true)
        } finally { reservation.close() }
        var closedRejected = false
        try { reservation.ensureRetainedPeak(25165824) }
        catch (_: LogicalJsonPayloadError) { closedRejected = true }
        @Expect(closedRejected, true)
        @Expect(logicalPayloadUsageEqual(pool.usage(), (0, 0)), true)
    }
}
