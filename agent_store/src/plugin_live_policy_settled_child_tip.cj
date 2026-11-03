package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// These callbacks inspect the actual reserved Receipt BEFORE Core commits
// the Parent canonical ToolResult Item. They create no Source, admission,
// Receipt, effect or ACK and do not close a returned child's output lease.
// User rejection has no fabricated ToolResult or output lease. Its full
// original terminal verifier below requires the actual retained review and
// exact durable user rejection/no-handoff/no-effect/causal evidence instead.
private func requirePluginLivePolicyKnownUserRejectedChild(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    withLivePolicyChildTerminalPayment(allocate,guard,{=>
        if(child.value==parent.value || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
            requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan)){
            throw IllegalStateException("terminal child substituted its independently normalized parent/plan/request")}
        let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
        if(sequence<1 || callId!=root.callId()+":live:"+sequence.toString() ||
            expected.isNone()){
            throw IllegalStateException("user rejection has no exact child/call/retained actual review")}
        let rowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
        journalStreamCheck(guard)
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
            requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),childPlan,encoded)})
        requireLivePolicyChildTerminalPrepared(tx,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
            expected,allocate,guard)
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,root.callId(),binding,sequence,
            childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
        // tip lives in the enclosing 1 MiB owner after the ledger reader's
        // own full raw/plan payments close, through every remaining check.
        if(httpIntentText(tip,"operation_id")!=child.value ||
            httpIntentText(tip,"outcome")!="rejected"){
            throw IllegalStateException("terminal output differs from its actual reserved Receipt and full plan")}
        let outcome=httpIntentText(tip,"outcome")
        requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,outcome,allocate,guard)
        livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
            "AND kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only')) "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_no_effect_settled_v1')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_journal_causal_v1')=1",
            [SqlParameter.Text(child.value),SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome=="rejected"){1}else{0}),
                SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome=="completed"){1}else{0}),SqlParameter.Text(child.value)],
            "known terminal child has conflicting or duplicated handoff/no-effect settlement evidence")
        if(outcome=="completed"){
            withLivePolicyChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{expectedHandoff=>
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                    "AND kind='operation_execution_handoff'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                        if(actual!=expectedHandoff){throw IllegalStateException("terminal child changed its full original handoff Source/plan")}})})
        }else{
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                "AND kind='operation_execution_handoff')",[SqlParameter.Text(child.value)],
                "known no-effect rejection cannot contain an execution handoff")
        }
        let actualPrefix=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
        // Include the already terminal child. None excludes no own child;
        // the full Parent Source replays actual receipts and every 17-field
        // causal witness and current full fence, never the caller's DTO tip.
        if(streamedSource){
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(sequence,actualPrefix,None)))
        }else{
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
            phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(sequence,actualPrefix,None)))
        }
        requireLivePolicyChildNoCanonicalResult(tx,run,thread,child,callId,allocate,guard)
        journalStreamCheck(guard)
    })
}


private func withLivePolicyActualKnownChildTip(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,verify:()->Unit,
    consume:(AgentValue)->Unit):Unit{
    journalStreamCheck(guard);verify();journalStreamCheck(guard)
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(1048576)
        let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
        let rowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,
            requestKey,childPlan.bindingDigest,callId)
        let binding=childPlan.canonicalArguments.field("binding").getOrThrow()
        let previous=childPlan.canonicalArguments.field("prior_receipts").getOrThrow()
        let tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,root.callId(),binding,sequence,previous,allocate,guard)
        if(httpIntentText(tip,"operation_id")!=child.value){
            throw IllegalStateException("known child tip changed its actual admitted operation")}
        // The original reader strictly bounds all five fields before returning
        // this data-only descriptor. Pay its complete StoredValue encoding too.
        let extent=livePolicyStoredExtent(tip)
        owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
        let encoded=encodeStoredValue(tip)
        if(encoded.size!=extent.bytes){throw IllegalStateException("known child tip extent changed")}
        journalStreamCheck(guard);consume(tip);journalStreamCheck(guard)
        let afterRowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,
            requestKey,childPlan.bindingDigest,callId)
        if(afterRowid!=rowid){throw IllegalStateException("known child tip admission changed during consumption")}
        let after=readPluginLivePolicyReceiptRow(tx,afterRowid,parent,run,root.callId(),binding,sequence,previous,allocate,guard)
        let afterExtent=livePolicyStoredExtent(after)
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),
            contextReadMetadataPeak(afterExtent.bytes,afterExtent.nodes)))
        if(encodeStoredValue(after)!=encoded){throw IllegalStateException("known child tip Receipt or full normalized plan changed")}
        journalStreamCheck(guard)
    }finally{owner.close()}
    // Release the small tip phase before the full original Source/causal
    // verifier runs again. No descriptor is returned across that lifetime.
    verify();journalStreamCheck(guard)
}

public func withPluginLivePolicySettledChildTip(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    childPlan:NormalizedOperationPlan,requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(AgentValue)->Unit,streamedSource!:Bool=false):Unit{
    withLivePolicyActualKnownChildTip(tx,root,parent,child,run,childPlan,requestKey,callId,allocate,guard,{=>
        requirePluginLivePolicyChildTerminal(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
            requestKey,callId,expected,result,allocate,guard,streamedSource:streamedSource)},consume)
}

public func withPluginLivePolicyRejectedChildTip(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    childPlan:NormalizedOperationPlan,requestKey:String,callId:String,expected:ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(AgentValue)->Unit,streamedSource!:Bool=false):Unit{
    withLivePolicyActualKnownChildTip(tx,root,parent,child,run,childPlan,requestKey,callId,allocate,guard,{=>
        requirePluginLivePolicyKnownUserRejectedChild(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
            requestKey,callId,Some(expected),allocate,guard,streamedSource:streamedSource)},consume)
}
