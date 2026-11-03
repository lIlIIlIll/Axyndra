package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Only this new family's paid input proof replaces the old aggregate read
// consumption validator. Original ordinary/frozen-document paths are intact.
// These functions run inside the actual Store transaction, not a plugin DTO.
func insertLivePolicyImmutableEffect(tx:SqliteTransaction,operation:OperationId,run:RunId,item:ItemId,
    plan:NormalizedOperationPlan,encoded:String):Unit{
    tx.execute("INSERT INTO operation_effect_records(operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version,"+
        "implementation_fingerprint,schema_digest,effective_arguments_digest,replay_contract_version,replay_disposition,"+
        "reserved_receipt_id,reserved_result_item_id,created_at_millis) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)",
        [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value),SqlParameter.Text(encoded),
         SqlParameter.Text(plan.implementation.toolId),SqlParameter.Text(plan.implementation.toolVersion),
         SqlParameter.Text(plan.implementation.implementationFingerprint),SqlParameter.Text(plan.implementation.schemaDigest),
         SqlParameter.Text(plan.implementation.effectiveArgumentsDigest),SqlParameter.Int64Value(Int64(plan.implementation.replayContractVersion)),
         SqlParameter.Text(encodeStoredValue(replayDispositionValue(plan.replayDisposition))),
         SqlParameter.Text("receipt-"+operation.value),SqlParameter.Text("result-"+operation.value)])
    tx.execute("INSERT INTO operation_state_registers(operation_id,state,revision) VALUES (?,'prepared',1)",[SqlParameter.Text(operation.value)])
}
func withLivePolicyPreparedParentMarker(parent:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,
    epoch:Int64,plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    // The exact handoff descriptor is domain-neutral Source/plan metadata.
    // Reuse its owned encoding, with an independent prepared marker schema.
    withLivePolicyParentHandoff(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        let owner=allocate(65536)
        try{
            let meter=StoredValuePaymentMeter(payload,owner);let nodes=meter.complete()
            owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(payload.size,nodes),payload.size*4))
            let value=decodeStoredValue(payload)
            value.put("schema",textValue("axyndra.plugin-live-policy-parent-prepared/v1"))
            let expected=encodeStoredValue(value);consume(expected);journalStreamCheck(guard)
        }finally{owner.close()}
    })
}
func requireLivePolicyPreparedParentMarker(tx:SqliteTransaction,parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let suffix=" FROM audit_events WHERE operation_id=? AND kind='plugin_live_parent_prepared_v1'"
    livePolicyRequireOne(tx,"SELECT 1"+suffix+" AND run_id=? AND thread_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
        "live parent lost its unique same-run prepared marker")
    withLivePolicyPreparedParentMarker(parent,root,run,thread,epoch,plan,allocate,guard,{expected=>
        withLivePolicyStoredValue(tx,"payload",suffix,[SqlParameter.Text(parent.value)],allocate,guard,{actual=>
            if(actual!=expected){throw IllegalStateException("live prepared parent Source/fullplan/epoch/projection marker changed")}})})
}
func preparePluginLivePolicyParentInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,approval:?ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(!isPluginLivePolicyParentPlan(plan) || root.toolName()!=plan.toolName){
        throw IllegalStateException("live parent preparation has no exact independently reviewed plan")}
    match(approval){case None=>();case Some(value)=>
        if(value.operationId.value!=parent.value || value.callId!=root.callId() || value.toolName!=root.toolName() ||
            value.sessionId!=thread.value || value.argumentHash=="" ||
            canonicalAgentValue(value.preview)!=canonicalAgentValue(plan.canonicalArguments)){
            throw IllegalStateException("live parent approval is not its original exact prepared request")}}
    let existing=tx.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(parent.value)])
    if(!existing.isEmpty()){
        let phase=match(approval){case None=>LivePolicyParentPhase.Prepared;case Some(_)=>LivePolicyParentPhase.WaitingApproval}
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
        requireLivePolicyPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
        match(approval){case None=>();case Some(value)=>requireLivePolicyExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,value,allocate,guard)}
        return
    }
    requirePluginLivePolicyCanonicalSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,false)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM operations WHERE tool_call_item_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_effect_records WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_state_registers WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind<>?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts WHERE operation_id=?)",
        [SqlParameter.Text(root.itemId().value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),
         SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND),SqlParameter.Text(parent.value)],
        "live first parent preparation cannot adopt another existing identity or effect evidence")
    if(!tx.query("SELECT 1 FROM audit_events WHERE operation_id=? AND kind=? LIMIT 1",
        [SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_POLICY_INPUT_PIN_KIND)]).isEmpty()){
        // The allowed pre-operation audit is DATA only. Its unique whole pin
        // must match this actual parent/run/item, original ToolCall, binding,
        // completed read fact and complete fixed payload in this same TX.
        requirePluginLivePolicyInputPayload(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
    }
    withLivePolicyPlanEncoding(plan,allocate,guard,{encoded=>
        tx.execute("INSERT INTO operations(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,"+
            "effect_class,retry_disposition,idempotency_key,state,revision) VALUES (?,?,?,?,?,?,?,? ,?,'prepared',1)",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(encoded),
             SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),SqlParameter.Text(encodeResourceScope(plan)),
             SqlParameter.Text(storeEffectName(plan.effectClass)),SqlParameter.Text(storeRetryName(plan.retryDisposition)),
             if(plan.idempotencyKey==""){SqlParameter.Null}else{SqlParameter.Text(plan.idempotencyKey)}])
        insertLivePolicyImmutableEffect(tx,parent,run,root.itemId(),plan,encoded)
        match(root){case OperationRootSource.Direct(_)=>();case OperationRootSource.Committed(source)=>
            tx.execute("INSERT INTO decision_operations(decision_id,scoped_tool_call_id,operation_id) VALUES (?,?,?)",
                [SqlParameter.Text(source.decisionId.value),SqlParameter.Text(source.scopedToolCallId.value),SqlParameter.Text(parent.value)])}
    })
    withLivePolicyPreparedParentMarker(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'plugin_live_parent_prepared_v1',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),
             SqlParameter.Int64Value(agentUtcMillis())])})
    match(approval){case None=>();case Some(value)=>
        withLivePolicyExpectedParentApproval(root,parent,run,thread,epoch,plan,value,allocate,guard,{payload=>
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES (?,?,?,'plugin_live_parent_approval_expected_v1',?,?)",
                [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),
                 SqlParameter.Int64Value(agentUtcMillis())])})
        tx.execute("UPDATE operations SET state='waiting_approval',revision=revision+1 WHERE id=? AND state='prepared'",[SqlParameter.Text(parent.value)])
        requireStoreChanged(tx,"live initial parent approval lost its owner");mirrorOperationState(tx,parent,"waiting_approval")}
    let phase=match(approval){case None=>LivePolicyParentPhase.Prepared;case Some(_)=>LivePolicyParentPhase.WaitingApproval}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
    requireLivePolicyPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
    journalStreamCheck(guard)
}
func markPluginLivePolicyParentExecutingInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live execution timestamp")}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.Prepared)
    requireLivePolicyPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
    if(approvalRequired){
        withLivePolicyPlanEncoding(plan,allocate,guard,{_=>
            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND decision='approved' AND operation_digest=? "+
                "AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) "+
                "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>?))",
                [SqlParameter.Text(parent.value),SqlParameter.Text(plan.bindingDigest),SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),SqlParameter.Int64Value(nowMillis)],
                "live parent lacks its exact unexpired actual User approval")})
    }
    tx.execute("UPDATE operations SET state='executing',revision=revision+1 WHERE id=? AND run_id=? AND state='prepared'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    requireStoreChanged(tx,"live parent execution lost its original owner");mirrorOperationState(tx,parent,"executing")
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.ExecutingWithoutHandoff)
    journalStreamCheck(guard)
}
func markPluginLivePolicyParentHandoffInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,nowMillis:Int64,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live handoff timestamp")}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:LivePolicyParentPhase.ExecutingWithoutHandoff)
    requireLivePolicyPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
    withLivePolicyParentHandoff(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'operation_execution_handoff',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),SqlParameter.Int64Value(nowMillis)])})
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard)
    journalStreamCheck(guard)
}
