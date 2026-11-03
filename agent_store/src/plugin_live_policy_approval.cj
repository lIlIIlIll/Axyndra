package agent_store

import agent_domain.*
import agent_runtime.OperationRootSource
import yjson.*
import yjson_support.*

func withLivePolicyExpectedParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
    epoch:Int64,plan:NormalizedOperationPlan,approval:ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    if(approval.operationId.value!=parent.value || approval.callId!=root.callId() || approval.toolName!=root.toolName() ||
        approval.sessionId!=thread.value || approval.argumentHash=="" || plan.requiredCapabilities.isEmpty() ||
        approval.capability.kind!=plan.requiredCapabilities[0].kind || approval.capability.resource!=plan.requiredCapabilities[0].resource){
        throw IllegalStateException("live parent approval changed its original prepared tuple")}
    let bytes=journalStreamAdd(parent.value.size,run.value.size)
    let all=journalStreamAdd(journalStreamAdd(bytes,thread.value.size),journalStreamAdd(approval.callId.size,approval.toolName.size))
    let extent=journalStreamAdd(journalStreamAdd(all,plan.bindingDigest.size),journalStreamAdd(approval.argumentHash.size,approval.capability.resource.size))
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(contextReadMetadataRawPeak(journalStreamAdd(extent,4096)))
        journalStreamCheck(guard)
        let value=objectValue([ValueField("schema",textValue("axyndra.plugin-live-parent-approval/v1")),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
            ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
            ValueField("plan_digest",textValue(plan.bindingDigest)),ValueField("call_id",textValue(approval.callId)),
            ValueField("tool",textValue(approval.toolName)),ValueField("argument_hash",textValue(approval.argumentHash)),
            ValueField("capability",textValue(storeCapabilityName(approval.capability.kind))),ValueField("resource",textValue(approval.capability.resource))])
        let encoded=encodeStoredValue(value);consume(encoded);journalStreamCheck(guard)
    }finally{owner.close()}
}

func requireLivePolicyExpectedParentApproval(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,run:RunId,
    thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,approval:ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit{
    withLivePolicyExpectedParentApproval(root,parent,run,thread,epoch,plan,approval,allocate,guard,{expected=>
        withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
            "AND kind='plugin_live_parent_approval_expected_v1'",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                if(actual!=expected){throw IllegalStateException("live parent lost its sole actual prepared approval tuple")}})
    })
}

// The caller has independently verified the actual parent/child Source,
// phase, immutable effect, prepared approval tuple and current configuration.
// This performs only the original canonical approval bookkeeping; it never
// reinterprets a native decision or makes ParentIntent approval from a ceiling.
func livePolicySameApprovalCapabilities(ceiling:CapabilitySet,plan:NormalizedOperationPlan):Bool{
    if(ceiling.values.size!=plan.requiredCapabilities.size){return false}
    for(index in 0..ceiling.values.size){
        if(ceiling.values[index].kind!=plan.requiredCapabilities[index].kind ||
            ceiling.values[index].resource!=plan.requiredCapabilities[index].resource){return false}}
    true
}
func recordLivePolicyApprovalInTransaction(tx:SqliteTransaction,operation:OperationId,run:RunId,
    plan:NormalizedOperationPlan,approvalId:String,ceiling:CapabilitySet,approved:Bool,source:String,
    expires:?Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(approvalId.size==0 || source.size==0 ||
        match(expires){case Some(value)=>value<0;case None=>false}){
        throw IllegalStateException("live approval identity/source/expiry is invalid")}
    if(!livePolicySameApprovalCapabilities(ceiling,plan)){
        throw IllegalStateException("live approval changed the exact reviewed capability set")}
    let identityOwner=allocate(65536)
    try{
    identityOwner.ensureRetainedPeak(contextReadMetadataRawPeak(journalStreamAdd(8192,
        journalStreamAdd(approvalId.size,source.size))))
    journalStreamCheck(guard)
    let retainedId=approvalId.trimAscii();let retainedSource=source.trimAscii()
    if(retainedId=="" || retainedSource==""){
        throw IllegalStateException("live approval identity/source is empty after original ASCII trimming")}
    withLivePolicyPlanEncoding(plan,allocate,guard,{_=>
        // The new path always retains the exact reviewed capability array.
        // A broader caller-supplied array cannot add a later child grant.
        let encoded=encodeCapabilities(plan.requiredCapabilities)
        let decision=if(approved){"approved"}else{"rejected"}
        let existing=tx.query("SELECT 1 FROM approvals WHERE operation_id=?",[SqlParameter.Text(operation.value)])
        if(!existing.isEmpty()){
            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND id=? AND operation_digest=? "+
                "AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) AND decision=? AND source=? "+
                "AND ((expires_at_millis IS NULL AND ? IS NULL) OR (typeof(expires_at_millis)='integer' AND expires_at_millis=?))",
                [SqlParameter.Text(operation.value),SqlParameter.Text(retainedId),SqlParameter.Text(plan.bindingDigest),
                 SqlParameter.Text(encoded),SqlParameter.Text(decision),SqlParameter.Text(retainedSource),
                 match(expires){case Some(value)=>SqlParameter.Int64Value(value);case None=>SqlParameter.Null},
                 match(expires){case Some(value)=>SqlParameter.Int64Value(value);case None=>SqlParameter.Null}],
                "live approval replay differs from its original exact durable evidence")
            return
        }
        livePolicyRequireOne(tx,"SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='waiting_approval' "+
            "AND NOT EXISTS(SELECT 1 FROM operation_receipts WHERE operation_id=?) "+
            "AND NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
            [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(operation.value),SqlParameter.Text(operation.value)],
            "live approval no longer owns its same untouched waiting operation")
        tx.execute("INSERT INTO approvals(id,operation_id,operation_digest,capability_ceiling,decision,source,expires_at_millis) VALUES (?,?,?,?,?,?,?)",
            [SqlParameter.Text(retainedId),SqlParameter.Text(operation.value),SqlParameter.Text(plan.bindingDigest),SqlParameter.Text(encoded),
             SqlParameter.Text(decision),SqlParameter.Text(retainedSource),match(expires){case Some(value)=>SqlParameter.Int64Value(value);case None=>SqlParameter.Null}])
        let state=if(approved){"prepared"}else{"rejected"}
        tx.execute("UPDATE operations SET state=?,revision=revision+1 WHERE id=? AND run_id=? AND state='waiting_approval'",
            [SqlParameter.Text(state),SqlParameter.Text(operation.value),SqlParameter.Text(run.value)])
        requireStoreChanged(tx,"live approval lost its original operation owner");mirrorOperationState(tx,operation,state)
        journalStreamCheck(guard)
    })
    }finally{identityOwner.close()}
}

func recordPluginLivePolicyParentApprovalInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,
    ceiling:CapabilitySet,approved:Bool,source:String,expires:?Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    // Only the restored same running Run can reach this full Source proof.
    // A replay can only verify the exact decision already written by this
    // same method. It cannot revive rejection or prepare a second operation.
    let waiting=tx.query("SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='waiting_approval'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    let phase=if(!waiting.isEmpty()){LivePolicyParentPhase.WaitingApproval}
        else if(approved){LivePolicyParentPhase.Prepared}else{LivePolicyParentPhase.RejectedWithoutHandoff}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
    requireLivePolicyExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
    recordLivePolicyApprovalInTransaction(tx,parent,run,plan,approvalId,ceiling,approved,source,expires,allocate,guard)
    let finalPhase=if(approved){LivePolicyParentPhase.Prepared}else{LivePolicyParentPhase.RejectedWithoutHandoff}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:finalPhase)
    // No handoff/effect/Receipt is manufactured by approval. The executing
    // transition and denied-result finalization each have a separate proof.
    journalStreamCheck(guard)
}
