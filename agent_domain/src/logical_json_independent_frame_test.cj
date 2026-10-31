package agent_domain

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonIndependentDataFrameTests {
    @TestCase
    func completedConfirmationFramesRefundWithoutClosingTheirInstalledSource(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let source = pool.acquire(1)
        try {
            for (_ in 0..3) {
                let frame = source.acquireIndependentDataFrame(1)
                let child = frame.deriveRetainedLease()
                try {
                    @Expect(frame.paysSamePrivateBankData180(source))
                    @Expect(pool.usage()[0], 2)
                    @Expect(pool.usage()[1], 33554432)
                    frame.ensureRetainedPeak(50331648)
                    child.ensureRetainedPeak(16777216)
                    let peak = pool.usage()[1]
                    @Expect(peak, 16777216 + 50331648 + 16777216 + 2048)
                    frame.close()
                    @Expect(pool.usage()[1], peak)
                    child.close()
                    @Expect(pool.usage()[0], 1)
                    @Expect(pool.usage()[1], 16777216)
                    frame.close(); child.close()
                    @Expect(pool.usage()[1], 16777216)
                } finally { child.close(); frame.close() }
            }
        } finally { source.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }

    @TestCase
    func independentFramesKeepTheOriginalFloorAggregateAndSaturationRefusal(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let source = pool.acquire(1)
        let frames = ArrayList<LogicalJsonOwnerReservation>()
        try {
            for (_ in 0..7) { frames.add(source.acquireIndependentDataFrame(1)) }
            @Expect(pool.usage()[0], 8); @Expect(pool.usage()[1], 134217728)
            var refused = false
            try { let unexpected = source.acquireIndependentDataFrame(1); unexpected.close() }
            catch (_: LogicalJsonPayloadError) { refused = true }
            @Expect(refused)
            @Expect(pool.usage()[0], 8); @Expect(pool.usage()[1], 134217728)
            frames.remove(at: 0).close()
            let replacement = source.acquireIndependentDataFrame(1)
            try { @Expect(pool.usage()[1], 134217728) } finally { replacement.close() }
        } finally { for (frame in frames) { frame.close() }; source.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }

    @TestCase
    func closedSourceAndOversizedFramesCannotCreateAnotherAllocation(): Unit {
        let pool = LogicalJsonOwnerBudget(maximumCharged: 134217728, maximumMessage: 1048576)
        let source = pool.acquire(1)
        let frame = source.acquireIndependentDataFrame(1)
        try {
            var oversized = false
            try { let unexpected = source.acquireIndependentDataFrame(1048577); unexpected.close() }
            catch (_: LogicalJsonPayloadError) { oversized = true }
            @Expect(oversized)
            source.close()
            @Expect(pool.usage()[0], 1); @Expect(pool.usage()[1], 16777216)
            var closed = false
            try { let unexpected = source.acquireIndependentDataFrame(1); unexpected.close() }
            catch (_: LogicalJsonPayloadError) { closed = true }
            @Expect(closed)
            @Expect(pool.usage()[0], 1); @Expect(pool.usage()[1], 16777216)
        } finally { frame.close(); source.close() }
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
