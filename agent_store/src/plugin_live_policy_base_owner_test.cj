package agent_store
import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

private class Base276Allocations{var count:Int64=0;init(){}}
@Test
class LivePolicyBaseMetadataPhaseTests{
    @TestCase
    func borrowedActualOwnerPaysTheCallerSumAndNeverRefundsIt(){
        let budget=LogicalJsonOwnerBudget();let caller=budget.acquire(1);let calls=Base276Allocations()
        let phase=LivePolicyBaseMetadataPhase276(true,Some(caller),1048576,{bytes=>calls.count+=1;budget.acquire(bytes)})
        try{
            @Expect(calls.count,0);@Expect(budget.usage()[0],1)
            @Expect(phase.extraRetained,2097152);phase.owner.getOrThrow().ensureRetainedPeak(phase.extraRetained)
            phase.close();@Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            caller.ensureRetainedPeak(2097152)
        }finally{phase.close();caller.close()}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func explicitOwnedFallbackAcquiresAndClosesExactlyOneOriginalFloor(){
        let budget=LogicalJsonOwnerBudget();let calls=Base276Allocations()
        let phase=LivePolicyBaseMetadataPhase276(true,None<LogicalJsonOwnerReservation>,0,{bytes=>calls.count+=1;budget.acquire(bytes)})
        try{@Expect(calls.count,1);@Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)}finally{phase.close()}
        @Expect(budget.usage()[0],0)
    }
    @TestCase
    func originalDefaultAndInvalidBorrowCannotAcquireOrCloseAnotherOwnersFloor(){
        let budget=LogicalJsonOwnerBudget();let caller=budget.acquire(1);let calls=Base276Allocations()
        try{
            let old=LivePolicyBaseMetadataPhase276(false,None<LogicalJsonOwnerReservation>,0,{bytes=>calls.count+=1;budget.acquire(bytes)})
            @Expect(old.owner.isNone(),true);old.close();@Expect(calls.count,0);@Expect(budget.usage()[0],1)
            for(streamed in [false,true]){
                var refused=false
                try{let phase=LivePolicyBaseMetadataPhase276(streamed,Some(caller),0,{bytes=>calls.count+=1;budget.acquire(bytes)});phase.close()}
                catch(_:Exception){refused=true}
                @Expect(refused,true);@Expect(calls.count,0);@Expect(budget.usage()[0],1)}
            caller.ensureRetainedPeak(1048576)
        }finally{caller.close()}
        @Expect(budget.usage()[0],0)
    }
}
