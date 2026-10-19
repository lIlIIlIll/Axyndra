package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual Runtime/SQLite/ContextRead/Host file fixture from the full canonical
// tests. This records an explicit reviewed decision; it does not simulate a
// frontend approval or execute a Native proposal/filesystem effect.
private func liveParentDecision(f:LivePolicyCanonicalFixture,plan:NormalizedOperationPlan,
    approved:Bool,expected!:?ApprovalRequest=None,ceiling!:?CapabilitySet=None):Result<Unit>{
    f.store.recordPluginLivePolicyParentApproval(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
        plan,expected ?? f.parentApproval(plan),"approval-"+f.parentId().value,
        ceiling ?? CapabilitySet(values:plan.requiredCapabilities),approved,"user",Option<Int64>.None,{=>f.current()})
}

@Test
class PluginLivePolicyParentApprovalTests{
    @TestCase
    func SameOriginalRunApprovalRecordsNoReceiptThenAdmitsOnlyItsOriginalParent():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            @Expect(f.runtime.pauseForApproval().isOk(),true)
            @Expect(liveParentDecision(f,plan,true).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),0)
            @Expect(f.runtime.resumeAfterApproval().isOk(),true)
            @Expect(liveParentDecision(f,plan,true).isOk(),true)
            @Expect(liveParentDecision(f,plan,true).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='prepared'",[SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]),0)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",[SqlParameter.Text(f.parentId().value)]),0)
            @Expect(f.store.markPluginLivePolicyParentExecuting(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,14,true,{=>f.current()}).isOk(),true)
            @Expect(f.store.markPluginLivePolicyParentHandoff(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,15,{=>f.current()}).isOk(),true)
            @Expect(f.prepareChild(plan,f.child(plan)).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
        }finally{f.close()}
    }
    @TestCase
    func KnownParentRejectionHasNoHandoffOrReceiptAndCannotBecomeApproval():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            @Expect(liveParentDecision(f,plan,false).isOk(),true)
            @Expect(liveParentDecision(f,plan,false).isOk(),true)
            @Expect(liveParentDecision(f,plan,true).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE decision='rejected'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='rejected'",[SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.store.markPluginLivePolicyParentExecuting(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,14,true,{=>f.current()}).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]),0)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",[SqlParameter.Text(f.parentId().value)]),0)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions"),0)
        }finally{f.close()}
    }
    @TestCase
    func ChangedExpectedApprovalHashCannotRecordAUserDecision():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            let expected=f.parentApproval(plan)
            let other=ApprovalRequest(expected.operationId,expected.callId,expected.toolName,expected.capability,
                preview:expected.preview,sessionId:expected.sessionId,argumentHash:"changed-approved-arguments")
            @Expect(liveParentDecision(f,plan,true,expected:Some(other)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='waiting_approval'",[SqlParameter.Text(f.parentId().value)]),1)
        }finally{f.close()}
    }
    @TestCase
    func BroaderReviewedCapabilityArrayCannotAuthorizeLaterEffects():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            let broader=CapabilitySet(values:[plan.requiredCapabilities[0],Capability(CapabilityKind.WorkspaceWrite,resource:f.root)])
            @Expect(liveParentDecision(f,plan,true,ceiling:Some(broader)).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),0)
        }finally{f.close()}
    }
    @TestCase
    func PersistedCapabilityCeilingSubstitutionFailsBeforeExecutionAdmission():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan)
            @Expect(liveParentDecision(f,plan,true).isOk(),true)
            f.database.execute("UPDATE approvals SET capability_ceiling='changed-stored-ceiling' WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)])
            @Expect(f.store.markPluginLivePolicyParentExecuting(f.parent,f.parentId(),f.active.runId,f.active.threadId,f.active.epoch,
                plan,14,true,{=>f.current()}).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='prepared'",[SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",[SqlParameter.Text(f.parentId().value)]),0)
        }finally{f.close()}
    }
    @TestCase
    func CancelledOriginalRunRetainsWaitingOperationWithoutApprovalOrReceipt():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let fact=f.latest();let plan=f.parentPlan(fact);f.prepareWaitingParent(plan);f.cancellation.cancel()
            @Expect(liveParentDecision(f,plan,true).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id=? AND state='waiting_approval'",[SqlParameter.Text(f.parentId().value)]),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(f.parentId().value)]),0)
        }finally{f.close()}
    }
}
