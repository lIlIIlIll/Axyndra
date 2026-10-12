package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OwnedOuterErrorFrame334Tests {
    @TestCase
    func actualPaidFrameIsOneShotAndMarksOnlyReturnedInvokeWithoutRefund():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        ancestor.ensureRetainedPeak(16777216)
        let before=bank.usage();let frame=PluginLivePolicyOuterErrorFrame334.retain(ancestor)
        @Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1]>before[1],true)
        @Expect(frame.hasReturned(),false);@Expect(frame.isInvoking(),false)
        let result=frame.invoke({actual=>
            @Expect(refEq(frame,actual),true);@Expect(actual.isInvoking(),true)
            @Expect(actual.hasReturned(),false);17})
        @Expect(result,17);@Expect(frame.isInvoking(),false);@Expect(frame.hasReturned(),true)
        let twice=try{let _=frame.invoke({_=>23});false}catch(_:Exception){true}
        @Expect(twice,true);let paid=bank.usage();ancestor.close()
        @Expect(bank.usage()[1],paid[1]);@Expect(frame.hasReturned(),true)
    }
    @TestCase
    func throwDoesNotPublishReturnedWitnessAndPressureRejectsBeforeFrameCreation():Unit{
        let bank=LogicalJsonOwnerBudget();let ancestor=bank.acquire(1)
        // Fill the already-paid floor declaration before applying pressure.
        // An unclaimed floor can correctly fund another child without growth.
        ancestor.ensureRetainedPeak(16777216)
        let frame=PluginLivePolicyOuterErrorFrame334.retain(ancestor)
        let thrown=try{frame.invoke<Unit>({_=>throw IllegalStateException("actual callback failed")});false}
            catch(_:Exception){true}
        @Expect(thrown,true);@Expect(frame.hasReturned(),false);@Expect(frame.isInvoking(),false)
        let pressure=bank.acquire(1)
        pressure.ensureRetainedPeak(134217728-bank.usage()[1]+16777216)
        let before=bank.usage()
        let refused=try{let _=PluginLivePolicyOuterErrorFrame334.retain(ancestor);false}catch(_:Exception){true}
        @Expect(refused,true);@Expect(bank.usage()[0],before[0]);@Expect(bank.usage()[1],before[1])
        pressure.close();ancestor.close();@Expect(bank.usage()[0],1)
    }
}
