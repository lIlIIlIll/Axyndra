package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual Runtime-attested canonical Source, completed ContextRead, SQLite
// ReservedReceipt and original Host artifact fixture. These are new-family
// admission/decision contracts, not Native policy or filesystem-effect mocks.
private func liveChildEntryDecision(f:LivePolicyCanonicalFixture,parent:NormalizedOperationPlan,
    child:(ToolCall,NormalizedOperationPlan,ApprovalRequest),approved:Bool,
    expected!:?ApprovalRequest=None,source!:String="user",expires!:?Int64=None):Result<Unit>{
    f.store.recordPluginLivePolicyChildApproval(f.parent,f.parentId(),child[2].operationId,f.active.runId,
        f.active.threadId,f.active.epoch,parent,child[1],pluginLivePolicyStreamingRequestKey(f.parent.callId(),child[1]),
        child[0].callId,expected ?? child[2],"approval-"+child[2].operationId.value,
        CapabilitySet(values:child[1].requiredCapabilities),approved,source,expires,{=>f.current()})
}
private func liveChildEntryExecuting(f:LivePolicyCanonicalFixture,parent:NormalizedOperationPlan,
    child:(ToolCall,NormalizedOperationPlan,ApprovalRequest),expected:?ApprovalRequest,required:Bool):Result<Unit>{
    f.store.markPluginLivePolicyChildExecuting(f.parent,f.parentId(),child[2].operationId,f.active.runId,
        f.active.threadId,f.active.epoch,parent,child[1],pluginLivePolicyStreamingRequestKey(f.parent.callId(),child[1]),
        child[0].callId,expected,agentUtcMillis(),required,{=>f.current()})
}
private func liveChildEntryHandoff(f:LivePolicyCanonicalFixture,parent:NormalizedOperationPlan,
    child:(ToolCall,NormalizedOperationPlan,ApprovalRequest),expected:?ApprovalRequest):Result<Unit>{
    f.store.markPluginLivePolicyChildHandoff(f.parent,f.parentId(),child[2].operationId,f.active.runId,
        f.active.threadId,f.active.epoch,parent,child[1],pluginLivePolicyStreamingRequestKey(f.parent.callId(),child[1]),
        child[0].callId,expected,agentUtcMillis(),{=>f.current()})
}

@Test
class PluginLivePolicyChildEntryTests{
    @TestCase
    func ActualCommittedChildApprovalAdmissionAndHandoffRemainDistinct():Unit{
        let f=LivePolicyCanonicalFixture(committed:true)
        try{f.seed("one","opaque");let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent)
            let child=f.child(parent);@Expect(f.prepareChild(parent,child).isOk(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,Some(child[2]),true).isError(),true)
            @Expect(liveChildEntryDecision(f,parent,child,true).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='prepared'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),0)
            @Expect(liveChildEntryExecuting(f,parent,child,Some(child[2]),true).isOk(),true)
            @Expect(liveChildEntryHandoff(f,parent,child,Some(child[2])).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id='live-child'"),0)
        }finally{f.close()}
    }
    @TestCase
    func OriginalReadyChildNeedsNoApprovalAndCannotAdoptAnotherReview():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent);let child=f.child(parent)
            @Expect(f.store.preparePluginLivePolicyInvocation(f.parent,f.parentId(),child[2].operationId,f.active.runId,
                f.active.threadId,f.active.epoch,parent,child[1],pluginLivePolicyStreamingRequestKey(f.parent.callId(),child[1]),
                child[0],None,{=>f.current()}).isOk(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,Some(child[2]),true).isError(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,None,false).isOk(),true)
            @Expect(liveChildEntryHandoff(f,parent,child,None).isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
        }finally{f.close()}
    }
    @TestCase
    func ApprovedChildCannotDowngradeItsRetainedReviewToReady():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent);let child=f.child(parent)
            @Expect(f.prepareChild(parent,child).isOk(),true);@Expect(liveChildEntryDecision(f,parent,child,true).isOk(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,None,false).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='prepared'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),0)
        }finally{f.close()}
    }
    @TestCase
    func ChangedHeldReviewOrActualCommittedSourceCannotRecordDecision():Unit{
        let f=LivePolicyCanonicalFixture(committed:true)
        try{let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent);let child=f.child(parent)
            @Expect(f.prepareChild(parent,child).isOk(),true)
            let approval=child[2]
            let other=ApprovalRequest(approval.operationId,approval.callId,approval.toolName,approval.capability,
                preview:approval.preview,sessionId:approval.sessionId,argumentHash:"changed-child-review")
            @Expect(liveChildEntryDecision(f,parent,child,true,expected:Some(other)).isError(),true)
            f.database.execute("UPDATE model_decisions SET canonical_committed_at_millis=NULL WHERE id='live-decision-model'")
            @Expect(liveChildEntryDecision(f,parent,child,true).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
        }finally{f.close()}
    }
    @TestCase
    func UserRejectsUntouchedChildWithActualReservedReceiptAndSameFence():Unit{
        let f=LivePolicyCanonicalFixture()
        try{f.seed("one","opaque");let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent)
            let child=f.child(parent);@Expect(f.prepareChild(parent,child).isOk(),true)
            let actualUserRejection113=liveChildEntryDecision(f,parent,child,false)
            match(actualUserRejection113){case Result.Ok(_)=>();case Result.Err(error)=>
                println("observed-live-child-user-rejection113 code="+error.code+" message="+error.message)}
            @Expect(actualUserRejection113.isOk(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='rejected'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child' AND id='receipt-live-child' AND outcome='rejected'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='plugin_live_no_effect_settled_v1'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='plugin_live_journal_causal_v1'"),1)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='operation_execution_handoff'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM memory_events"),1)
            @Expect(liveChildEntryDecision(f,parent,child,false).isError(),true)
            @Expect(liveChildEntryDecision(f,parent,child,true).isError(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,Some(child[2]),true).isError(),true)
        }finally{f.close()}
    }
    @TestCase
    func ExpiryAndCurrentCancellationPreventChildExecution():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent);let child=f.child(parent)
            @Expect(f.prepareChild(parent,child).isOk(),true)
            @Expect(liveChildEntryDecision(f,parent,child,true,expires:Some(1)).isOk(),true)
            @Expect(liveChildEntryExecuting(f,parent,child,Some(child[2]),true).isError(),true)
            f.cancellation.cancel()
            @Expect(liveChildEntryHandoff(f,parent,child,Some(child[2])).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='prepared'"),1)
        }finally{f.close()}
    }
    @TestCase
    func NonUserRejectionCannotManufactureKnownNoEffect():Unit{
        let f=LivePolicyCanonicalFixture()
        try{let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent);let child=f.child(parent)
            @Expect(f.prepareChild(parent,child).isOk(),true)
            @Expect(liveChildEntryDecision(f,parent,child,false,source:"ai").isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
        }finally{f.close()}
    }
    @TestCase
    func TriggeredForeignJournalChangeRollsBackWholeKnownRejection():Unit{
        let f=LivePolicyCanonicalFixture()
        try{f.seed("one","opaque");let parent=f.parentPlan(f.latest());f.prepareParent(parent);f.executeParent(parent)
            let child=f.child(parent);@Expect(f.prepareChild(parent,child).isOk(),true)
            f.database.execute("CREATE TRIGGER live_reject_foreign_change AFTER INSERT ON audit_events "+
                "WHEN NEW.kind='plugin_live_journal_causal_v1' BEGIN "+
                "INSERT INTO memory_events(memory_id,revision,operation,payload,created_at_millis) "+
                "SELECT 'foreign',1,'retain',payload,11 FROM memory_events WHERE memory_id='one'; END")
            @Expect(liveChildEntryDecision(f,parent,child,false).isError(),true)
            @Expect(f.count("SELECT COUNT(*) FROM memory_events"),1)
            @Expect(f.count("SELECT COUNT(*) FROM approvals WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='live-child'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM audit_events WHERE operation_id='live-child' AND kind='plugin_live_journal_causal_v1'"),0)
            @Expect(f.count("SELECT COUNT(*) FROM operations WHERE id='live-child' AND state='waiting_approval'"),1)
        }finally{f.close()}
    }
}
