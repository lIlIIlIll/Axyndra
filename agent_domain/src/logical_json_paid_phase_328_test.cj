package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LogicalJsonActualPaidDataPhaseTests328 {
    @TestCase
    func DerivedDataPhasesSumEveryActualPeakInTheOriginalSingleBank():Unit{
        let bank=LogicalJsonOwnerBudget();let original=bank.acquire(65536)
        let first=original.derivePaidDataPhase328(65536);let second=original.derivePaidDataPhase328(65536)
        try{
            first.ensureRetainedPeak(67108864);second.ensureRetainedPeak(33554432)
            @Expect(bank.usage()[0],1)
            @Expect(bank.usage()[1],100663296+524288+3072)
            first.close();second.close()
            // Shared high water remains paid until actual original closes.
            @Expect(bank.usage()[0],1)
            @Expect(bank.usage()[1],100663296+524288+3072)
        }finally{second.close();first.close();original.close()}
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
    @TestCase
    func DerivedDataPhaseKeepsTheSamePrivateConfiguredMessageLimit():Unit{
        let bank=LogicalJsonOwnerBudget(maximumMessage:1024);let original=bank.acquire(1)
        try{
            var refused=false
            try{let invalid=original.derivePaidDataPhase328(1025);invalid.close()}
            catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused,true);@Expect(bank.usage()[0],1);@Expect(bank.usage()[1],16777216)
            let valid=original.derivePaidDataPhase328(1024);valid.close()
            @Expect(bank.usage()[0],1)
        }finally{original.close()}
        @Expect(bank.usage()[0],0);@Expect(bank.usage()[1],0)
    }
}
