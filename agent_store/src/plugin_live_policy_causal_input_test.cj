package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class CausalInputAllocationCounter { var value:Int64=0 }

// Descriptive absent metadata only: no Source, read, Receipt or approval is
// inserted. Actual own-successor positives belong to installed Kernel tests.
func causalAbsentPrefix(f:LivePolicyInputAbsentFactsFixture,count:Int64):AgentValue {
    let tip=if(count==0){nullValue()}else{objectValue([
        ValueField("sequence",integerValue(count)),ValueField("operation_id",textValue("absent-causal-child")),
        ValueField("receipt_id",textValue("absent-causal-receipt")),ValueField("plan_sha256",textValue(f.digest)),
        ValueField("outcome",textValue("completed"))])}
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
        ValueField("parent_operation_id",textValue(f.parent.value)),ValueField("through_sequence",integerValue(count)),ValueField("tip",tip)])
}
func causalAbsentRejected(f:LivePolicyInputAbsentFactsFixture,through:Int64,expected:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,pending!:?OperationId=None):Bool {
    try{
        f.database.readTransaction<Unit>({tx=>
            match(pending){
                case None=>requirePluginLivePolicyCausalReadInputs(tx,f.parent,f.run,f.parentItem,f.tool,
                    f.binding(),[f.link()],through,expected,allocate,guard)
                case Some(actual)=>requirePluginLivePolicyCausalReadInputsBeforePending(tx,f.parent,f.run,f.parentItem,f.tool,
                    f.binding(),[f.link()],through,expected,actual,allocate,guard)
            }
        });false
    }catch(_:Exception){true}
}

@Test
class PluginLivePolicyCausalInputAbsentTests {
    @TestCase
    func negativeCountAndOtherParentPrefixFailBeforeAnyAllocation():Unit {
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let allocations=CausalInputAllocationCounter()
        let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
        try{
            @Expect(causalAbsentRejected(f,-1,causalAbsentPrefix(f,0),allocate,{=>Result<Unit>.Ok(())}),true)
            let other=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue("another-parent")),ValueField("through_sequence",integerValue(0)),ValueField("tip",nullValue())])
            @Expect(causalAbsentRejected(f,0,other,allocate,{=>Result<Unit>.Ok(())}),true)
            @Expect(allocations.value,0);@Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0);f.unchanged()
        }finally{f.close()}
    }
    @TestCase
    func ArbitraryCountsAndPendingReferenceCannotCreateMissingCanonicalRead():Unit {
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let allocate={bytes=>budget.acquire(bytes)}
        try{
            for(count in [0,1,1000000]){
                @Expect(causalAbsentRejected(f,count,causalAbsentPrefix(f,count),allocate,{=>Result<Unit>.Ok(())}),true)
                @Expect(causalAbsentRejected(f,count,causalAbsentPrefix(f,count),allocate,{=>Result<Unit>.Ok(())},
                    pending:Some(OperationId("absent-pending-child"))),true)
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            }
            f.unchanged()
        }finally{held.close();f.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func cancellationAndMissingFactsKeepOriginalPaidOwnerAndDatabaseUnchanged():Unit {
        let f=LivePolicyInputAbsentFactsFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let allocations=CausalInputAllocationCounter();let allocate={bytes=>allocations.value++;budget.acquire(bytes)}
        try{
            @Expect(causalAbsentRejected(f,0,causalAbsentPrefix(f,0),allocate,{=>Result<Unit>.Err(
                AgentError(AgentErrorKind.Cancelled,"causal.cancelled","actual owner cancelled"))}),true)
            @Expect(allocations.value,0)
            for(_ in 0..16){
                @Expect(causalAbsentRejected(f,0,causalAbsentPrefix(f,0),allocate,{=>Result<Unit>.Ok(())}),true)
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)
            }
            f.unchanged()
        }finally{held.close();f.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
