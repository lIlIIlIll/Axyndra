package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Separate actual User-rejected Parent path. It never starts a worker or
// borrows an Executing handoff. Core still owns the canonical rejected
// Receipt and result Item. Only full bounded retention data is written here.
private func requireLivePolicyActualRejectedParentDecision(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireLivePolicyExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
    withLivePolicyPlanEncoding(plan,allocate,guard,{_=>
        livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? "+
            "AND decision='rejected' AND source='user' AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) "+
            "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>=0)) "+
            "AND (SELECT COUNT(*) FROM approvals other WHERE other.operation_id=approvals.operation_id)=1",
            [SqlParameter.Text(parent.value),SqlParameter.Text(plan.bindingDigest),SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities))],
            "rejected parent lost its sole actual user decision and exact reviewed capability set")
        livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM derived_operation_admissions WHERE parent_operation_id=?) "+
            "AND NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff') "+
            "AND NOT EXISTS(SELECT 1 FROM operation_receipts WHERE operation_id=?) "+
            "AND NOT EXISTS(SELECT 1 FROM items WHERE id='result-'||?)",
            [SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value)],
            "rejected parent acquired a child, handoff or premature canonical settlement")
        journalStreamCheck(guard)
    })
}

private func livePolicyRejectedParentTerminalDescriptorOwned(descriptor:AgentValue,parent:OperationId,
    plan:NormalizedOperationPlan,owner:LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(String,Int64,PluginDocumentPayloadReference)->Unit,extraRetained:Int64):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extraRetained))
    let extent=livePolicyStoredExtent(descriptor)
    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extraRetained))
    if(!pluginLivePolicyTerminalDataValid(descriptor,parent.value,plan.bindingDigest)){
        throw IllegalStateException("live parent terminal data changed its exact bounded shape")}
    let through=journalStreamInteger(descriptor.field("prior_receipts").getOrThrow().field("through_sequence").getOrThrow().asNumberText())
    let payload=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
    let encoded=encodeStoredValue(descriptor)
    if(encoded.size!=extent.bytes){throw IllegalStateException("live terminal descriptor extent changed")}
    journalStreamCheck(guard);consume(encoded,through,payload);journalStreamCheck(guard)
}

private func withLivePolicyRejectedParentTerminalDescriptor(descriptor:AgentValue,parent:OperationId,
    plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String,Int64,PluginDocumentPayloadReference)->Unit,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,
    retainedDescriptorPeak!:Int64=0):Unit{
    journalStreamCheck(guard)
    match(retainedDescriptorOwner){
        case Some(owner)=>
            if(retainedDescriptorPeak<=0){
                throw IllegalStateException("borrowed descriptor requires actual simultaneous metadata payment")}
            livePolicyRejectedParentTerminalDescriptorOwned(descriptor,parent,plan,owner,guard,consume,retainedDescriptorPeak)
        case None=>
            let owner=allocate(65536)
            try{livePolicyRejectedParentTerminalDescriptorOwned(descriptor,parent,plan,owner,guard,consume,0)}finally{owner.close()}
    }
}

private func withLivePolicyRejectedParentTerminalEvidence(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,descriptor:AgentValue,
    through:Int64,payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>,consume:()->Unit,streamedSource!:Bool=false):Unit{
    if(streamedSource){withLivePolicyRejectedParentTerminalEvidenceStreamed(tx,root,parent,run,thread,epoch,plan,expected,descriptor,through,payload,allocate,verifyContent,guard,consume);return}
    if(through!=0 || !descriptor.field("is_error").getOrThrow().asBool()){
        throw IllegalStateException("rejected parent cannot have a child prefix or successful output")}
    let reference=descriptor.field("prior_receipts").getOrThrow()
    let progress=Some(LivePolicyReadProgress(through,reference,None<OperationId>))
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.RejectedWithoutHandoff,progress:progress)
    requireLivePolicyActualRejectedParentDecision(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
    requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let prefix=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,reference,allocate,guard)
    try{
        requireLivePolicyParentTerminalBlob(tx,payload,allocate,verifyContent,guard)
    }finally{prefix.close()}
    journalStreamCheck(guard);consume();journalStreamCheck(guard)
    // Recheck the complete original Source and every causal relationship
        // after the trusted callback, while the same transaction is held.
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.RejectedWithoutHandoff,progress:progress)
    requireLivePolicyActualRejectedParentDecision(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        let after=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,reference,allocate,guard)
        try{requireLivePolicyParentTerminalBlob(tx,payload,allocate,verifyContent,guard)}finally{after.close()}
    journalStreamCheck(guard)
}


private func withLivePolicyRejectedParentTerminalEvidenceStreamed(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,descriptor:AgentValue,
    through:Int64,payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:()->Result<Unit>,guard:()->Result<Unit>,consume:()->Unit):Unit{
    if(through!=0 || !descriptor.field("is_error").getOrThrow().asBool()){
        throw IllegalStateException("rejected parent cannot have a child prefix or successful output")}
    let reference=descriptor.field("prior_receipts").getOrThrow()
    let progress=Some(LivePolicyReadProgress(through,reference,None<OperationId>))
    requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.RejectedWithoutHandoff,progress:progress)
    requireLivePolicyActualRejectedParentDecision(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
    requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
    let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,reference,allocate,guard,{owner,retained=>
        requireLivePolicyParentTerminalBlobOwned(tx,payload,owner,retained,verifyContent,guard)})
    journalStreamCheck(guard);consume();journalStreamCheck(guard)
    // Recheck the complete original Source and every causal relationship
        // after the trusted callback, while the same transaction is held.
        requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.RejectedWithoutHandoff,progress:progress)
    requireLivePolicyActualRejectedParentDecision(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,reference,allocate,guard,{owner,retained=>
            requireLivePolicyParentTerminalBlobOwned(tx,payload,owner,retained,verifyContent,guard)})
    journalStreamCheck(guard)
}

private func requireLivePolicyRejectedParentTerminalAudit(tx:SqliteTransaction,parent:OperationId,
    run:RunId,thread:ThreadId,encoded:String,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT count(*) FROM audit_events WHERE operation_id=? "+
        "AND kind='plugin_live_policy_parent_terminal_v1')=1",
        [SqlParameter.Text(parent.value)],"live parent terminal audit is missing or repeated")
    withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
        "AND kind='plugin_live_policy_parent_terminal_v1'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
            if(actual!=encoded){throw IllegalStateException("live terminal audit substituted its exact complete descriptor")}})
}

// Must be called inside the actual Host ArtifactStore transaction. Exceptions
// escape to its original rollback. This records only bounded retention data;
// Core alone creates the canonical Parent Receipt and ToolResult afterward.
public func retainPluginLivePolicyRejectedParentTerminal(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,retainedDescriptorPeak!:Int64=0,streamedSource!:Bool=false):Unit{
    withLivePolicyRejectedParentTerminalDescriptor(descriptor,parent,plan,allocate,guard,{encoded,through,payload=>
        withLivePolicyRejectedParentTerminalEvidence(tx,root,parent,run,thread,epoch,plan,expected,descriptor,through,payload,
            allocate,verifyContent,guard,{=>
                livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                    "AND kind='plugin_live_policy_parent_terminal_v1')",[SqlParameter.Text(parent.value)],
                    "live parent terminal retention cannot overwrite an existing terminal")
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_policy_parent_terminal_v1',?,?)",
                    [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),
                     SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
                requireLivePolicyRejectedParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
            },streamedSource:streamedSource)
        requireLivePolicyRejectedParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
    },retainedDescriptorOwner:retainedDescriptorOwner,retainedDescriptorPeak:retainedDescriptorPeak)
}

// Read-only verification for the real Port's owned Completed path. It keeps
// the Host's same physical Session and result lease alive; it neither closes
// that lease nor acknowledges a worker, file, cleanup or cancellation debt.
public func verifyPluginLivePolicyRejectedParentTerminalInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,descriptor:AgentValue,
    result:ToolResult,allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:()->Result<Unit>,guard:()->Result<Unit>,
    retainedDescriptorOwner!:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>,retainedDescriptorPeak!:Int64=0,streamedSource!:Bool=false):Unit{
    withLivePolicyRejectedParentTerminalDescriptor(descriptor,parent,plan,allocate,guard,{encoded,through,payload=>
        if(result.callId!=root.callId() || result.receiptId!=parent.value || result.payloadLease.isNone() ||
            result.isError!=descriptor.field("is_error").getOrThrow().asBool()){
            throw IllegalStateException("live parent result changed its actual call/operation/leased output")}
        withLivePolicyRejectedParentTerminalEvidence(tx,root,parent,run,thread,epoch,plan,expected,descriptor,through,payload,
            allocate,verifyContent,guard,{=>
                requireLivePolicyRejectedParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
                withPluginLivePolicyTerminalOutputIdentity(result.output,allocate,guard,{bytes,digest=>
                    if(bytes!=payload.bytes || digest!=payload.digest){
                        throw IllegalStateException("live parent result differs from every frozen output JSON byte")}})
                requireLivePolicyRejectedParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
            },streamedSource:streamedSource)
        requireLivePolicyRejectedParentTerminalAudit(tx,parent,run,thread,encoded,allocate,guard)
    },retainedDescriptorOwner:retainedDescriptorOwner,retainedDescriptorPeak:retainedDescriptorPeak)
}
