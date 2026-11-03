package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonSharedCustodyTests {
    @TestCase
    func concurrentChildPeaksUseTheOriginalAggregateSumAndOnePhysicalSlot():Unit {
        // Pins the aggregate this case was written against: the shared-custody
        // sum invariant is about the CONFIGURED capacity, not the pool default.
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let parent=pool.acquire(1)
        let first=parent.deriveRetainedLease()
        let second=parent.deriveRetainedLease()
        try {
            first.ensureRetainedPeak(83886080)
            second.ensureRetainedPeak(33554432)
            @Expect(pool.usage()[0],1)
            @Expect(pool.usage()[1],117440520+3072)
            var rejected=false
            try { second.ensureRetainedPeak(50331648) }
            catch(_:LogicalJsonPayloadError) { rejected=true }
            @Expect(rejected,true)
            @Expect(pool.usage()[1],117440520+3072)
        } finally { second.close();first.close();parent.close() }
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func parentCloseCannotRetireAChildBeforeItsActualUserCloses():Unit {
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let parent=pool.acquire(1)
        let child=parent.deriveRetainedLease()
        try {
            parent.close()
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1],16777216)
            child.ensureRetainedPeak(67108864)
            @Expect(pool.usage()[1],67108864+1024)
            var rejected=false
            try { let unexpected=parent.deriveRetainedLease();unexpected.close() }
            catch(_:LogicalJsonPayloadError) { rejected=true }
            @Expect(rejected,true)
        } finally { child.close();parent.close() }
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func independentOwnersAndFixedBuffersStillPressureTheSameOriginalPool():Unit {
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728)
        let parent=pool.acquire(1)
        let child=parent.deriveRetainedLease()
        let independent=pool.acquire(1)
        let fixed=pool.acquireFixedBuffer(65536)
        try {
            child.ensureRetainedPeak(100663296)
            @Expect(pool.usage()[0],3)
            var rejected=false
            try { child.ensureRetainedPeak(117440512) }
            catch(_:LogicalJsonPayloadError) { rejected=true }
            @Expect(rejected,true)
            parent.close();child.close()
            @Expect(pool.usage()[0],2);@Expect(pool.usage()[1],16777216+65536)
        } finally { fixed.close();independent.close();child.close();parent.close() }
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
