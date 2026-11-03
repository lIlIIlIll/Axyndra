package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class LiveBaseRejectedCallbacks {var payments:Int64=0;var materializations:Int64=0}
private func liveBaseEmptyLedger(parent:String):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
        ValueField("parent_operation_id",textValue(parent)),ValueField("through_sequence",integerValue(0)),ValueField("tip",nullValue())])
}

// The existing canonical fixture commits and attests a real ordinary parent
// and prepares its real ReadRoot. These are refusal controls: that ReadRoot
// cannot be relabelled into this new retained live Parent or base-file proof.
// No test constructs a Normalized live plan, Source or successful Receipt.
@Test
class HostLivePolicyBaseInputBoundaryTests{
    @TestCase
    func ActualOrdinaryAttestedRootDoesNotCreateALiveBaseCursor():Unit{
        let fixture=WindowCanonicalFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let counter=LiveBaseRejectedCallbacks()
        try{
            let read=fixture.begin(objectValue([ValueField("kind",textValue("manifest"))]),[])
            let operations=fixture.database.scalarInt("SELECT COUNT(*) FROM operations")
            let audits=fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events")
            let receipts=fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
            let rejected=fixture.database.readTransaction<Result<Unit>>({tx=>
                consumePluginLivePolicyBaseJournalInput(tx,fixture.parent,OperationId("window-parent"),fixture.active.runId,
                    fixture.active.threadId,fixture.active.epoch,read.plan,0,liveBaseEmptyLedger("window-parent"),
                    {bytes=>counter.payments++;budget.acquire(bytes)},{=>fixture.current()},
                    {_=>counter.materializations++;Result<Unit>.Ok(())})})
            @Expect(rejected.isError(),true);@Expect(counter.materializations,0);@Expect(counter.payments,0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations"),operations)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events"),audits)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),receipts)
            @Expect(budget.usage()[0],1)
        }finally{held.close();fixture.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func ActualCancellationPrecedesSourcePaymentAndPhysicalMaterialization():Unit{
        let fixture=WindowCanonicalFixture();let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        let counter=LiveBaseRejectedCallbacks()
        try{
            let read=fixture.begin(objectValue([ValueField("kind",textValue("manifest"))]),[])
            fixture.cancellation.cancel()
            let rejected=fixture.database.readTransaction<Result<Unit>>({tx=>
                consumePluginLivePolicyBaseJournalInput(tx,fixture.parent,OperationId("window-parent"),fixture.active.runId,
                    fixture.active.threadId,fixture.active.epoch,read.plan,0,liveBaseEmptyLedger("window-parent"),
                    {bytes=>counter.payments++;budget.acquire(bytes)},{=>fixture.current()},
                    {_=>counter.materializations++;Result<Unit>.Ok(())})})
            @Expect(rejected.isError(),true)
            match(rejected){case Result.Err(error)=>@Expect(error.kind,AgentErrorKind.Cancelled);case Result.Ok(_)=>@Expect(false,true)}
            @Expect(counter.materializations,0);@Expect(counter.payments,0);@Expect(budget.usage()[0],1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='plugin_live_policy_step_data_v1'"),0)
        }finally{held.close();fixture.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
