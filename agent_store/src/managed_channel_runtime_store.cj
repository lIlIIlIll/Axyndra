package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// A separate ordinary-policy managed resource family. The reused paid codec
// and immutable-effect helpers are domain-neutral; no memory read, Native
// approval DTO, frozen-intent grant or new Core authority is introduced.


func requireManagedChannelOwnedCanonicalSource(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,admitted:Bool):Unit{
    journalStreamCheck(guard)
    if(!isManagedChannelOwnedParentPlan(parentPlan) || root.toolName()!=parentPlan.toolName || epoch<0){
        throw IllegalStateException("live family has no exact parent plan")}
    livePolicyRequireOne(tx,"SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id "+
        "JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id JOIN items call "+
        "ON call.id=? AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "+
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND call.kind='tool_call' AND r.state='running' "+
        "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active'",
        [SqlParameter.Text(root.itemId().value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Int64Value(epoch)],
        "live source does not own the same actual canonical run/turn/item")
    let host=parentPlan.canonicalArguments.field("host_plan").getOrThrow()
    let binding=host.field("binding").getOrThrow()
    if(httpIntentText(binding,"target_thread_id")!=thread.value || httpIntentText(binding,"run_id")!=run.value ||
        journalStreamInteger(binding.field("epoch").getOrThrow().asNumberText())!=epoch ||
        requirePluginDocumentLane(tx,thread,run,epoch).value!=httpIntentText(binding,"lane_id")){
        throw IllegalStateException("live parent changed its actual thread/lane/run/epoch")}
    // The ORIGINAL framing scans every argument byte through EOF. Comparing
    // the typed ToolCall is done under the same paid cell owner; no decoded
    // call/argument DOM is saved outside that callback.
    let cellSuffix=" FROM items WHERE id=? AND thread_id=? AND kind='tool_call'"
    let cellParams=[SqlParameter.Text(root.itemId().value),SqlParameter.Text(thread.value)]
    withLivePolicyStoredValue(tx,"payload",cellSuffix,cellParams,allocate,guard,{value=>
        match(decodeStoredThreadContent(value)){
            case ThreadItemContent.ToolCall(id,name,arguments)=>
                let expected=match(root){case OperationRootSource.Committed(source)=>
                    ToolCall(source.block.callId,source.block.name,source.block.arguments)
                    case OperationRootSource.Direct(source)=>source.call}
                if(id.value!=expected.callId || name!=expected.name ||
                    canonicalAgentValue(arguments)!=canonicalAgentValue(expected.arguments) ||
                    canonicalAgentValue(contextReadBusinessInput(parentPlan.canonicalArguments.field("input").getOrThrow()))!=
                        canonicalAgentValue(expected.arguments)){
                    throw IllegalStateException("live parent canonical call differs from its sealed source")}
            case _=>throw IllegalStateException("live parent item is not a canonical ToolCall")}})
    match(root){
        case OperationRootSource.Committed(source)=>
            if(parent.value!="operation-"+source.decisionId.value+"-"+source.scopedToolCallId.value){
                throw IllegalStateException("live model source changed its original canonical operation identity")}
            let decisionSuffix=" FROM model_decisions d JOIN model_attempts attempt ON attempt.id=d.attempt_id "+
                "JOIN model_decision_blocks b ON b.decision_id=d.id JOIN canonical_decision_items c "+
                "ON c.decision_id=d.id AND c.decision_block_id=b.id "+
                "WHERE d.id=? AND b.scoped_tool_call_id=? AND c.item_id=? AND attempt.run_id=? "+
                "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL"
            let decisionParams=[SqlParameter.Text(source.decisionId.value),SqlParameter.Text(source.scopedToolCallId.value),
                SqlParameter.Text(source.canonicalItemId.value),SqlParameter.Text(run.value)]
            livePolicyRequireOne(tx,"SELECT 1"+decisionSuffix,decisionParams,
                "live committed parent lost its exact canonical decision/block/item")
            withLivePolicyStoredValue(tx,"provenance",cellSuffix,cellParams,allocate,guard,{value=>
                let provenance=decodeStoredProvenance(value)
                if(provenance.source=="direct_tool" || provenance.runId.isNone() ||
                    provenance.runId.getOrThrow().value!=run.value || provenance.operationId.isSome() ||
                    !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance),DirectCallOrigin.UserDirect)){
                    throw IllegalStateException("live model source changed its original canonical provenance")}})
            // Reuse the ORIGINAL encoder and the private attested block. Its
            // wrappers and complete retained strings are paid before encoding;
            // actual SQL block bytes are independently paid before copying.
            withLivePolicyModelBlockEncoding(source.block,allocate,guard,{expected=>
                withLivePolicyStoredValue(tx,"b.payload",decisionSuffix,decisionParams,allocate,guard,{actual=>
                    if(actual!=expected){throw IllegalStateException("live committed source changed its complete original model block")}})})
            if(admitted){
                livePolicyRequireOne(tx,"SELECT 1 FROM decision_operations WHERE operation_id=? AND decision_id=? AND scoped_tool_call_id=?",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(source.decisionId.value),SqlParameter.Text(source.scopedToolCallId.value)],
                    "live model source changed its admitted decision relation")
            }else{
                livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM decision_operations WHERE operation_id=? OR "+
                    "(decision_id=? AND scoped_tool_call_id=?))",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(source.decisionId.value),SqlParameter.Text(source.scopedToolCallId.value)],
                    "live model source was already associated before its first admission")
            }
        case OperationRootSource.Direct(source)=>
            if(source.operationId.value!=parent.value || source.runId.value!=run.value || source.threadId.value!=thread.value ||
                source.epoch!=epoch || !sameDirectCallOrigin(source.origin,DirectCallOrigin.UserDirect)){
                throw IllegalStateException("live Tool read parent is not its original UserDirect source")}
            livePolicyRequireOne(tx,"SELECT 1 FROM runs r WHERE r.id=? AND r.turn_id=? "+
                "AND NOT EXISTS(SELECT 1 FROM decision_operations d WHERE d.operation_id=?) "+
                "AND NOT EXISTS(SELECT 1 FROM canonical_decision_items c WHERE c.item_id=?)",
                [SqlParameter.Text(run.value),SqlParameter.Text(source.turnId.value),SqlParameter.Text(parent.value),SqlParameter.Text(root.itemId().value)],
                "live UserDirect parent was relabelled as a model decision")
            withLivePolicyStoredValue(tx,"provenance",cellSuffix,cellParams,allocate,guard,{value=>
                let provenance=decodeStoredProvenance(value)
                if(provenance.source!="direct_tool" || provenance.runId.isNone() || provenance.operationId.isNone() ||
                    provenance.runId.getOrThrow().value!=run.value || provenance.operationId.getOrThrow().value!=parent.value ||
                    !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance),source.origin)){
                    throw IllegalStateException("live UserDirect parent lost its exact persisted origin")}})
            // This family consumes the old exact Tool read contract, whose
            // Direct origin is only UserDirect. Checking those exact fields
            // first prevents taking the ManagedJob/External/ContextRead
            // transitive branches with an unpaid or widened origin.
            let initialSuffix=" FROM runs r JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
                "JOIN items initial ON initial.id=turn.user_item_id AND initial.thread_id=r.thread_id AND initial.turn_id=r.turn_id WHERE r.id=?"
            let initialParams=[SqlParameter.Text(run.value)]
            withLivePolicyStoredValue(tx,"initial.provenance",initialSuffix,initialParams,allocate,guard,{value=>
                let initial=decodeStoredProvenance(value)
                if(initial.source=="host_service" || initial.source=="external" || initial.directOrigin.isSome()){
                    throw IllegalStateException("live UserDirect parent cannot downgrade a host/external initiator")}})
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                "AND kind IN ('operation_managed_job_origin_bound','operation_host_origin_bound'))",
                [SqlParameter.Text(parent.value)],"live UserDirect parent cannot downgrade an existing origin audit")
    }
    // The old Host-origin validator permits a normal model or UserDirect
    // call only when its initiator was not a host/external origin. Read this
    // original provenance under a real extent reservation for BOTH roots.
    let initialSuffix=" FROM runs r JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id "+
        "JOIN items initial ON initial.id=turn.user_item_id AND initial.thread_id=r.thread_id AND initial.turn_id=r.turn_id WHERE r.id=?"
    withLivePolicyStoredValue(tx,"initial.provenance",initialSuffix,[SqlParameter.Text(run.value)],allocate,guard,{value=>
        let initial=decodeStoredProvenance(value)
        if(initial.source=="host_service" || initial.source=="external" || initial.directOrigin.isSome()){
            throw IllegalStateException("live parent cannot downgrade a host/external initiator")}})
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
        "AND kind IN ('operation_managed_job_origin_bound','operation_host_origin_bound'))",
        [SqlParameter.Text(parent.value)],"live parent cannot downgrade an existing origin audit")
    requireManagedChannelPreparationReads(tx,parent,run,root.itemId(),parentPlan.toolName,parentPlan.contextReadFacts,allocate,guard)
    journalStreamCheck(guard)
}

enum ManagedChannelParentPhase { Prepared | WaitingApproval | RejectedWithoutHandoff | ExecutingWithoutHandoff | Executing }
func managedChannelParentState(phase:ManagedChannelParentPhase):String{
    match(phase){case ManagedChannelParentPhase.Prepared=>"prepared";case ManagedChannelParentPhase.WaitingApproval=>"waiting_approval"
        case ManagedChannelParentPhase.RejectedWithoutHandoff=>"rejected"
        case ManagedChannelParentPhase.ExecutingWithoutHandoff | ManagedChannelParentPhase.Executing=>"executing"}
}


func withManagedChannelParentHandoff(parent:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,epoch:Int64,
    plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    withLivePolicyPlanEncoding(plan,allocate,guard,{encoded=>
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
            let source=match(root){case OperationRootSource.Committed(value)=>objectValue([
                ValueField("kind",textValue("committed")),ValueField("decision_id",textValue(value.decisionId.value)),
                ValueField("scoped_tool_call_id",textValue(value.scopedToolCallId.value))])
                case OperationRootSource.Direct(_)=>objectValue([ValueField("kind",textValue("user_direct"))])}
            let value=objectValue([ValueField("schema",textValue("axyndra.managed-channel-owned-parent-handoff/v1")),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
                ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                ValueField("root_item_id",textValue(root.itemId().value)),ValueField("root_call_id",textValue(root.callId())),
                ValueField("parent_plan_sha256",textValue(modelPolicySha256Text(encoded))),
                ValueField("parent_binding_digest",textValue(plan.bindingDigest)),ValueField("source",source)])
            let extent=livePolicyStoredExtent(value)
            owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*4))
            let payload=encodeStoredValue(value)
            if(payload.size!=extent.bytes){throw IllegalStateException("live parent handoff measurement drift")}
            consume(payload);journalStreamCheck(guard)
        }finally{owner.close()}
    })
}

func requireManagedChannelOwnedParentSource(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,phase!:ManagedChannelParentPhase=ManagedChannelParentPhase.Executing):Unit{
    journalStreamCheck(guard)
    let state=managedChannelParentState(phase)
    livePolicyRequireOne(tx,"SELECT 1 FROM operations p JOIN runs r ON r.id=p.run_id WHERE p.id=? AND p.run_id=? "+
        "AND p.tool_call_item_id=? AND p.state=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events a WHERE a.operation_id=p.id AND a.kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(state)],
        "live parent does not own its original untouched prepared/executing operation")
    withLivePolicyPlanEncoding(parentPlan,allocate,guard,{encoded=>
        requireLivePolicyImmutableEffect(tx,parent,run,root.itemId(),parentPlan,encoded)})
    requireManagedChannelOwnedCanonicalSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,true)
    requireManagedChannelPreparedParentMarker(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard)
    match(phase){
        case ManagedChannelParentPhase.Executing=>
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'"
            let auditParams=[SqlParameter.Text(parent.value)]
            livePolicyRequireOne(tx,"SELECT 1"+auditSuffix+" AND run_id=? AND thread_id=?",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                "live parent handoff has no same original run/thread owner")
            withManagedChannelParentHandoff(parent,root,run,thread,epoch,parentPlan,allocate,guard,{expected=>
                withLivePolicyStoredValue(tx,"payload",auditSuffix,auditParams,allocate,guard,{actual=>
                    if(actual!=expected){throw IllegalStateException("live parent handoff changed its full Source/epoch/projection/plan witness")}})})
        case _=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                [SqlParameter.Text(parent.value)],"live prepared parent already has an execution handoff")
    }
    journalStreamCheck(guard)
}

func withManagedChannelPreparedParentMarker(parent:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,
    epoch:Int64,plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    // The exact handoff descriptor is domain-neutral Source/plan metadata.
    // Reuse its owned encoding, with an independent prepared marker schema.
    withManagedChannelParentHandoff(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        let owner=allocate(65536)
        try{
            let meter=StoredValuePaymentMeter(payload,owner);let nodes=meter.complete()
            owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(payload.size,nodes),payload.size*4))
            let value=decodeStoredValue(payload)
            value.put("schema",textValue("axyndra.managed-channel-owned-parent-prepared/v1"))
            let expected=encodeStoredValue(value);consume(expected);journalStreamCheck(guard)
        }finally{owner.close()}
    })
}

func requireManagedChannelPreparedParentMarker(tx:SqliteTransaction,parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let suffix=" FROM audit_events WHERE operation_id=? AND kind='managed_channel_parent_prepared_v1'"
    livePolicyRequireOne(tx,"SELECT 1"+suffix+" AND run_id=? AND thread_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
        "live parent lost its unique same-run prepared marker")
    withManagedChannelPreparedParentMarker(parent,root,run,thread,epoch,plan,allocate,guard,{expected=>
        withLivePolicyStoredValue(tx,"payload",suffix,[SqlParameter.Text(parent.value)],allocate,guard,{actual=>
            if(actual!=expected){throw IllegalStateException("live prepared parent Source/fullplan/epoch/projection marker changed")}})})
}

func prepareManagedChannelOwnedParentInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,approval:?ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelActiveResource(tx,plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow(),allocate,guard)
    if(!isManagedChannelOwnedParentPlan(plan) || root.toolName()!=plan.toolName){
        throw IllegalStateException("live parent preparation has no exact independently reviewed plan")}
    match(approval){case None=>();case Some(value)=>
        if(value.operationId.value!=parent.value || value.callId!=root.callId() || value.toolName!=root.toolName() ||
            value.sessionId!=thread.value || value.argumentHash=="" ||
            canonicalAgentValue(value.preview)!=canonicalAgentValue(plan.canonicalArguments)){
            throw IllegalStateException("live parent approval is not its original exact prepared request")}}
    let existing=tx.query("SELECT 1 FROM operations WHERE id=?",[SqlParameter.Text(parent.value)])
    if(!existing.isEmpty()){
        let phase=match(approval){case None=>ManagedChannelParentPhase.Prepared;case Some(_)=>ManagedChannelParentPhase.WaitingApproval}
        requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
        requireManagedChannelPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
        match(approval){case None=>();case Some(value)=>requireManagedChannelExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,value,allocate,guard)}
        return
    }
    requireManagedChannelOwnedCanonicalSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,false)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM operations WHERE tool_call_item_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_effect_records WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_state_registers WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts WHERE operation_id=?)",
        [SqlParameter.Text(root.itemId().value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),
         SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value)],
        "live first parent preparation cannot adopt another existing identity or effect evidence")
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
    withManagedChannelPreparedParentMarker(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'managed_channel_parent_prepared_v1',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),
             SqlParameter.Int64Value(agentUtcMillis())])})
    match(approval){case None=>();case Some(value)=>
        withManagedChannelExpectedParentApproval(root,parent,run,thread,epoch,plan,value,allocate,guard,{payload=>
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES (?,?,?,'managed_channel_parent_approval_expected_v1',?,?)",
                [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),
                 SqlParameter.Int64Value(agentUtcMillis())])})
        tx.execute("UPDATE operations SET state='waiting_approval',revision=revision+1 WHERE id=? AND state='prepared'",[SqlParameter.Text(parent.value)])
        requireStoreChanged(tx,"live initial parent approval lost its owner");mirrorOperationState(tx,parent,"waiting_approval")}
    let phase=match(approval){case None=>ManagedChannelParentPhase.Prepared;case Some(_)=>ManagedChannelParentPhase.WaitingApproval}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
    requireManagedChannelPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
    journalStreamCheck(guard)
}

func markManagedChannelOwnedParentExecutingInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live execution timestamp")}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:ManagedChannelParentPhase.Prepared)
    requireManagedChannelPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
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
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:ManagedChannelParentPhase.ExecutingWithoutHandoff)
    journalStreamCheck(guard)
}

func markManagedChannelOwnedParentHandoffInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,nowMillis:Int64,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelActiveResource(tx,plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow(),allocate,guard)
    if(nowMillis<0){throw IllegalStateException("negative live handoff timestamp")}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:ManagedChannelParentPhase.ExecutingWithoutHandoff)
    requireManagedChannelPreparedParentMarker(tx,parent,root,run,thread,epoch,plan,allocate,guard)
    withManagedChannelParentHandoff(parent,root,run,thread,epoch,plan,allocate,guard,{payload=>
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'operation_execution_handoff',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(payload),SqlParameter.Int64Value(nowMillis)])})
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard)
    journalStreamCheck(guard)
}

func withManagedChannelExpectedParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
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
        let value=objectValue([ValueField("schema",textValue("axyndra.managed-channel-parent-approval/v1")),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
            ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
            ValueField("plan_digest",textValue(plan.bindingDigest)),ValueField("call_id",textValue(approval.callId)),
            ValueField("tool",textValue(approval.toolName)),ValueField("argument_hash",textValue(approval.argumentHash)),
            ValueField("capability",textValue(storeCapabilityName(approval.capability.kind))),ValueField("resource",textValue(approval.capability.resource))])
        let encoded=encodeStoredValue(value);consume(encoded);journalStreamCheck(guard)
    }finally{owner.close()}
}

func requireManagedChannelExpectedParentApproval(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,run:RunId,
    thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,approval:ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit{
    withManagedChannelExpectedParentApproval(root,parent,run,thread,epoch,plan,approval,allocate,guard,{expected=>
        withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
            "AND kind='managed_channel_parent_approval_expected_v1'",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                if(actual!=expected){throw IllegalStateException("live parent lost its sole actual prepared approval tuple")}})
    })
}

func recordManagedChannelOwnedParentApprovalInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,
    ceiling:CapabilitySet,approved:Bool,source:String,expires:?Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    // Only the restored same running Run can reach this full Source proof.
    // A replay can only verify the exact decision already written by this
    // same method. It cannot revive rejection or prepare a second operation.
    let waiting=tx.query("SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='waiting_approval'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    let phase=if(!waiting.isEmpty()){ManagedChannelParentPhase.WaitingApproval}
        else if(approved){ManagedChannelParentPhase.Prepared}else{ManagedChannelParentPhase.RejectedWithoutHandoff}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
    requireManagedChannelExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,expected,allocate,guard)
    recordLivePolicyApprovalInTransaction(tx,parent,run,plan,approvalId,ceiling,approved,source,expires,allocate,guard)
    let finalPhase=if(approved){ManagedChannelParentPhase.Prepared}else{ManagedChannelParentPhase.RejectedWithoutHandoff}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:finalPhase)
    // No handoff/effect/Receipt is manufactured by approval. The executing
    // transition and denied-result finalization each have a separate proof.
    journalStreamCheck(guard)
}

enum ManagedChannelChildPhase{Prepared | WaitingApproval | RejectedWithoutHandoff | ExecutingWithoutHandoff | Executing}
func managedChannelChildState(phase:ManagedChannelChildPhase):String{
    match(phase){case ManagedChannelChildPhase.Prepared=>"prepared";case ManagedChannelChildPhase.WaitingApproval=>"waiting_approval"
        case ManagedChannelChildPhase.RejectedWithoutHandoff=>"rejected"
        case ManagedChannelChildPhase.ExecutingWithoutHandoff | ManagedChannelChildPhase.Executing=>"executing"}
}


func managedChannelPreparedEvidence(parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    approval:?ApprovalRequest):AgentValue{
    let pending=match(approval){case None=>nullValue();case Some(value)=>objectValue([
        ValueField("operation_id",textValue(value.operationId.value)),ValueField("call_id",textValue(value.callId)),
        ValueField("tool_name",textValue(value.toolName)),ValueField("session_id",textValue(value.sessionId)),
        ValueField("argument_hash",textValue(value.argumentHash)),ValueField("capability",textValue(storeCapabilityName(value.capability.kind))),
        ValueField("resource",textValue(value.capability.resource))])}
    objectValue([ValueField("schema",textValue("axyndra.managed-channel-owned-prepared/v1")),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("operation_id",textValue(child.value)),
        ValueField("run_id",textValue(run.value)),ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
        ValueField("parent_binding_digest",textValue(parentPlan.bindingDigest)),ValueField("child_binding_digest",textValue(childPlan.bindingDigest)),
        ValueField("request_key",textValue(requestKey)),ValueField("call_id",textValue(callId)),ValueField("approval",pending)])
}

func managedChannelPreparedTupleBytes(parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    approval:?ApprovalRequest):Int64{
    // Actual already-held String extents, not a Native declared size. The
    // fixed overhead covers original length-frame labels/digits and nodes.
    var bytes:Int64=65536
    for(value in [parent.value,child.value,run.value,thread.value,parentPlan.bindingDigest,childPlan.bindingDigest,requestKey,callId]){
        bytes=journalStreamAdd(bytes,value.size)}
    match(approval){case None=>();case Some(value)=>
        for(text in [value.operationId.value,value.callId,value.toolName,value.sessionId,value.argumentHash,value.capability.resource]){
            bytes=journalStreamAdd(bytes,text.size)}}
    bytes
}

func managedChannelApprovalMatches(approval:ApprovalRequest,child:OperationId,thread:ThreadId,callId:String,
    childPlan:NormalizedOperationPlan):Bool{
    approval.operationId.value==child.value && approval.callId==callId && approval.toolName==childPlan.toolName &&
        approval.sessionId==thread.value && approval.argumentHash!="" && !childPlan.requiredCapabilities.isEmpty() &&
        approval.capability.kind==childPlan.requiredCapabilities[0].kind && approval.capability.resource==childPlan.requiredCapabilities[0].resource &&
        canonicalAgentValue(approval.preview)==canonicalAgentValue(childPlan.canonicalArguments)
}

func requireManagedChannelChildPreparedTuple(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,phase:ManagedChannelChildPhase,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    if(child.value==parent.value || !managedChannelOwnedChildAllowed(parentPlan,childPlan) ||
        requestKey!=managedChannelOwnedRequestKey(root.callId(),childPlan) ||
        callId!=root.callId()+":managed:"+childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText()){
        throw IllegalStateException("live child lost its actual precise parent/plan/request/call")}
    match(expected){case Some(value)=>if(!managedChannelApprovalMatches(value,child,thread,callId,childPlan)){
        throw IllegalStateException("live child changed its originally reviewed exact approval")};case None=>()}
    if(match(phase){case ManagedChannelChildPhase.WaitingApproval=>expected.isNone();case _=>false}){
        throw IllegalStateException("waiting child has no actual retained reviewed approval")}
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    let state=managedChannelChildState(phase)
    withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
        requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),childPlan,encoded)
        livePolicyRequireOne(tx,"SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
            "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND o.state=? "+
            "AND a.parent_operation_id=? AND a.root_operation_id=? AND a.depth=1 "+
            "AND typeof(a.call_sequence)='integer' AND a.call_sequence=? "+
            "AND a.request_key=? AND a.request_digest=? AND a.child_call_id=? "+
            "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
            "AND n.call_sequence=a.call_sequence)=1 "+
            "AND NOT EXISTS(SELECT 1 FROM operation_receipts r WHERE r.operation_id=o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions nested WHERE nested.parent_operation_id=o.id)",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(state),
             SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence),
             SqlParameter.Text(requestKey),SqlParameter.Text(childPlan.bindingDigest),SqlParameter.Text(callId)],
            "live child does not own its same unique actual immutable operation/admission")
    })
    let tupleOwner=allocate(65536)
    try{
        tupleOwner.ensureRetainedPeak(contextReadMetadataRawPeak(managedChannelPreparedTupleBytes(parent,child,run,thread,
            parentPlan,childPlan,requestKey,callId,expected)))
        let evidence=managedChannelPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected)
        let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='managed_channel_child_prepared_v1'"
        withLivePolicyStoredValue(tx,"payload",suffix,
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                if(canonicalAgentValue(decodeStoredValue(actual))!=canonicalAgentValue(evidence)){
                    throw IllegalStateException("live child changed its complete original prepared Source/approval evidence")}})
        match(phase){case ManagedChannelChildPhase.WaitingApproval=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
                [SqlParameter.Text(child.value)],"live waiting child already has an unrelated durable approval")
            case _=>()}
        match(phase){case ManagedChannelChildPhase.Executing=>
            withManagedChannelChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{expectedPayload=>
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                    "AND kind='operation_execution_handoff'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                        if(actual!=expectedPayload){throw IllegalStateException("live child handoff changed its actual full Source/plan")}})})
            case _=>livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                "AND kind='operation_execution_handoff')",[SqlParameter.Text(child.value)],
                "live child already has an execution handoff before its actual phase")}
        journalStreamCheck(guard)
    }finally{tupleOwner.close()}
}

func withManagedChannelChildHandoff(parent:OperationId,child:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,
    epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    if(!managedChannelOwnedChildAllowed(parentPlan,childPlan)){
        throw IllegalStateException("actual child handoff has no exact original paid parent/read")}
    withLivePolicyPlanEncoding(parentPlan,allocate,guard,{parentEncoded=>
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{childEncoded=>
            let owner=allocate(65536)
            try{
                // Prepay complete actual scalar extents before wrappers,
                // digest encoders or SQL parameter copies are allocated.
                var bytes:Int64=65536
                for(value in [parent.value,child.value,run.value,thread.value,root.itemId().value,root.callId(),callId,
                    requestKey,parentPlan.bindingDigest,childPlan.bindingDigest]){
                    bytes=journalStreamAdd(bytes,value.size)}
                match(root){case OperationRootSource.Committed(value)=>
                    bytes=journalStreamAdd(bytes,journalStreamAdd(value.decisionId.value.size,value.scopedToolCallId.value.size));case _=>()}
                let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
                bytes=journalStreamAdd(bytes,httpIntentText(binding,"lane_id").size)
                owner.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
                let source=match(root){case OperationRootSource.Committed(value)=>objectValue([
                    ValueField("kind",textValue("committed")),ValueField("decision_id",textValue(value.decisionId.value)),
                    ValueField("scoped_tool_call_id",textValue(value.scopedToolCallId.value))])
                    case OperationRootSource.Direct(_)=>objectValue([ValueField("kind",textValue("user_direct"))])}
                let value=objectValue([ValueField("schema",textValue("axyndra.managed-channel-owned-child-handoff/v1")),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("operation_id",textValue(child.value)),
                    ValueField("run_id",textValue(run.value)),ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
                    ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                    ValueField("root_item_id",textValue(root.itemId().value)),ValueField("root_call_id",textValue(root.callId())),
                    ValueField("child_call_id",textValue(callId)),ValueField("request_key",textValue(requestKey)),
                    ValueField("sequence",childPlan.canonicalArguments.field("sequence").getOrThrow()),
                    ValueField("parent_plan_sha256",textValue(modelPolicySha256Text(parentEncoded))),
                    ValueField("child_plan_sha256",textValue(modelPolicySha256Text(childEncoded))),
                    ValueField("parent_binding_digest",textValue(parentPlan.bindingDigest)),
                    ValueField("child_binding_digest",textValue(childPlan.bindingDigest)),ValueField("source",source)])
                let extent=livePolicyStoredExtent(value)
                owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*4))
                let encoded=encodeStoredValue(value)
                if(encoded.size!=extent.bytes){throw IllegalStateException("actual child handoff encoding measurement drift")}
                consume(encoded);journalStreamCheck(guard)
            }finally{owner.close()}
        })
    })
}

func managedChannelApprovalPhase(value:?ApprovalRequest):ManagedChannelChildPhase{
    match(value){case Some(_)=>ManagedChannelChildPhase.WaitingApproval;case None=>ManagedChannelChildPhase.Prepared}
}
func requireManagedChannelActiveResource(tx:SqliteTransaction,binding:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(httpIntentText(binding,"resource_state")!="active"){return}
    let startup=OperationId(httpIntentText(binding,"startup_operation_id"))
    livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id "+
        "JOIN operation_effect_records e ON e.operation_id=o.id WHERE o.id=? AND r.thread_id=? AND o.state='committed' "+
        "AND p.id=e.reserved_receipt_id AND p.outcome='completed' AND e.tool_id=? "+
        "AND (SELECT COUNT(*) FROM operation_receipts all_receipts WHERE all_receipts.operation_id=o.id)=1 "+
        "AND EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id AND a.depth=1 AND a.root_operation_id=a.parent_operation_id) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events c WHERE c.kind='managed_channel_resource_closed_v1' AND "+
        "CAST(c.payload AS BLOB)=CAST(? AS BLOB))",
        [SqlParameter.Text(startup.value),SqlParameter.Text(httpIntentText(binding,"target_thread_id")),
         SqlParameter.Text(HOST_MANAGED_CHANNEL_SPAWN_TOOL),SqlParameter.Text(httpIntentText(binding,"lease_id"))],
        "active managed resource has no actual completed startup or was physically closed")
    withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND kind='managed_channel_resource_bound_v1'",
        [SqlParameter.Text(startup.value)],allocate,guard,{stored=>
            let actual=decodeStoredValue(stored)
            if(!httpIntentExactFields(actual,["schema","lease_id","launch_digest","resource_binding","process_id"]) ||
                httpIntentText(actual,"schema")!="axyndra.managed-channel-spawn-result/v1" ||
                httpIntentText(actual,"lease_id")!=httpIntentText(binding,"lease_id") ||
                httpIntentText(actual,"launch_digest")!=httpIntentText(binding,"launch_digest")){
                throw IllegalStateException("active resource differs from its actual Host startup receipt")}
            withLivePolicyStoredValue(tx,"detail"," FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(startup.value)],allocate,guard,{detail=>
                if(detail!=stored){throw IllegalStateException("active startup audit differs from its actual complete receipt")}})
            withLivePolicyStoredValue(tx,"normalized_plan"," FROM operations WHERE id=?",[SqlParameter.Text(startup.value)],allocate,guard,{encoded=>
                let plan=decodeOperationPlan(encoded)
                if(!isManagedChannelOwnedChildPlan(plan) || plan.toolName!=HOST_MANAGED_CHANNEL_SPAWN_TOOL){
                    throw IllegalStateException("active startup has no actual complete strict managed spawn plan")}
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND kind='managed_channel_child_prepared_v1'",
                    [SqlParameter.Text(startup.value)],allocate,guard,{prepared=>
                        let value=decodeStoredValue(prepared)
                        if(httpIntentText(value,"operation_id")!=startup.value || httpIntentText(value,"child_binding_digest")!=plan.bindingDigest){
                            throw IllegalStateException("historical startup changed its original complete prepared plan")}})
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
                    [SqlParameter.Text(startup.value)],allocate,guard,{handoff=>
                        let value=decodeStoredValue(handoff)
                        if(httpIntentText(value,"schema")!="axyndra.managed-channel-owned-child-handoff/v1" ||
                            httpIntentText(value,"operation_id")!=startup.value || httpIntentText(value,"child_binding_digest")!=plan.bindingDigest ||
                            httpIntentText(value,"child_plan_sha256")!=modelPolicySha256Text(encoded)){
                            throw IllegalStateException("historical startup changed its original full Source handoff")}})
            })
            let frozen=actual.field("resource_binding").getOrThrow()
            // Run/epoch/lane may advance with a new actual ordinary root; all
            // physical resource/catalog/configuration identities remain exact.
            for(key in ["plugin","package_digest","configuration_digest","instance_identity","endpoint_identity",
                "directory_revision","directory_digest","implementation_version","implementation_fingerprint","schema_digest",
                "target_thread_id","permission_domain","workspace_root","workspace_mode","network","launch_digest",
                "resource_state","lease_id","startup_operation_id"]){
                if(canonicalAgentValue(frozen.field(key).getOrThrow())!=canonicalAgentValue(binding.field(key).getOrThrow())){
                    throw IllegalStateException("active resource startup full binding changed")}}})
}

class ManagedChannelPrefixCursor{
    var ordinal:Int64=0
    var rowid:Int64=0
    init(){}
}
// Inspect every own prior child one row at a time. This is actual persisted
// receipt evidence, not a caller supplied tip/hash or replay permission.
func requireManagedChannelKnownPrefix(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,pending:?OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let cursor=ManagedChannelPrefixCursor()
    while(true){
        journalStreamCheck(guard)
        let rows=tx.query("SELECT a.rowid,a.operation_id FROM derived_operation_admissions a WHERE a.parent_operation_id=? "+
            "AND a.rowid>? AND (? IS NULL OR a.operation_id<>?) ORDER BY a.rowid LIMIT 1",
            [SqlParameter.Text(parent.value),SqlParameter.Int64Value(cursor.rowid),
             match(pending){case Some(value)=>SqlParameter.Text(value.value);case None=>SqlParameter.Null},
             match(pending){case Some(value)=>SqlParameter.Text(value.value);case None=>SqlParameter.Null}])
        if(rows.isEmpty()){break}
        if(rows.size!=1 || cursor.ordinal>=through){throw IllegalStateException("managed resource has another unsettled or duplicate child")}
        cursor.rowid=journalStreamInteger(rows[0].required(0));cursor.ordinal=journalStreamAdd(cursor.ordinal,1)
        let child=OperationId(rows[0].required(1))
        withLivePolicyStoredValue(tx,"o.normalized_plan"," FROM operations o WHERE o.id=? AND o.run_id=?",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value)],allocate,guard,{encoded=>
                let plan=decodeOperationPlan(encoded)
                if(!managedChannelOwnedChildAllowed(parentPlan,plan) ||
                    journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())!=cursor.ordinal){
                    throw IllegalStateException("managed child prefix changed its complete actual plan or order")}
                requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),plan,encoded)
                livePolicyRequireOne(tx,"SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                    "JOIN operation_receipts p ON p.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id "+
                    "WHERE a.operation_id=? AND a.parent_operation_id=? AND a.root_operation_id=? AND a.depth=1 "+
                    "AND a.call_sequence=? AND a.request_key=? AND a.request_digest=? AND a.child_call_id=? "+
                    "AND p.id=e.reserved_receipt_id AND p.outcome IN ('completed','rejected','cancelled','timed_out','failed') "+
                    "AND o.state=CASE p.outcome WHEN 'completed' THEN 'committed' ELSE p.outcome END "+
                    "AND (SELECT COUNT(*) FROM operation_receipts all_receipts WHERE all_receipts.operation_id=o.id)=1 "+
                    "AND (SELECT COUNT(*) FROM derived_operation_admissions same_sequence WHERE same_sequence.parent_operation_id=a.parent_operation_id "+
                    "AND same_sequence.call_sequence=a.call_sequence)=1 "+
                    "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions n WHERE n.parent_operation_id=o.id)",
                    [SqlParameter.Text(child.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(cursor.ordinal),
                     SqlParameter.Text(managedChannelOwnedRequestKey(root.callId(),plan)),SqlParameter.Text(plan.bindingDigest),
                     SqlParameter.Text(root.callId()+":managed:"+cursor.ordinal.toString())],
                    "managed child lacks its same actual known receipt; Unknown never authorizes another request")
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='managed_channel_child_prepared_v1'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{stored=>
                        let evidence=decodeStoredValue(stored)
                        if(!httpIntentExactFields(evidence,["schema","parent_operation_id","operation_id","run_id","thread_id","epoch",
                            "parent_binding_digest","child_binding_digest","request_key","call_id","approval"]) ||
                            httpIntentText(evidence,"schema")!="axyndra.managed-channel-owned-prepared/v1" ||
                            httpIntentText(evidence,"parent_operation_id")!=parent.value || httpIntentText(evidence,"operation_id")!=child.value ||
                            httpIntentText(evidence,"run_id")!=run.value || httpIntentText(evidence,"thread_id")!=thread.value ||
                            evidence.field("epoch").getOrThrow().asNumberText()!=epoch.toString() ||
                            httpIntentText(evidence,"parent_binding_digest")!=parentPlan.bindingDigest || httpIntentText(evidence,"child_binding_digest")!=plan.bindingDigest ||
                            httpIntentText(evidence,"request_key")!=managedChannelOwnedRequestKey(root.callId(),plan) ||
                            httpIntentText(evidence,"call_id")!=root.callId()+":managed:"+cursor.ordinal.toString()){
                            throw IllegalStateException("known child lost its complete original prepared tuple")}
                        let approval=evidence.field("approval").getOrThrow()
                        if(approval.unifiedKind==ValueKind.Null){
                            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
                                [SqlParameter.Text(child.value)],"Ready known child adopted another approval")
                        }else{
                            if(!httpIntentExactFields(approval,["operation_id","call_id","tool_name","session_id","argument_hash","capability","resource"]) ||
                                httpIntentText(approval,"operation_id")!=child.value || httpIntentText(approval,"call_id")!=root.callId()+":managed:"+cursor.ordinal.toString() ||
                                httpIntentText(approval,"tool_name")!=plan.toolName || httpIntentText(approval,"session_id")!=thread.value ||
                                httpIntentText(approval,"argument_hash")=="" || plan.requiredCapabilities.isEmpty() ||
                                httpIntentText(approval,"capability")!=storeCapabilityName(plan.requiredCapabilities[0].kind) ||
                                httpIntentText(approval,"resource")!=plan.requiredCapabilities[0].resource){throw IllegalStateException("known child changed its reviewed approval")}
                            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? "+
                                "AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB)",
                                [SqlParameter.Text(child.value),SqlParameter.Text(plan.bindingDigest),SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities))],
                                "known child lost its original exact durable approval")
                        }
                    })
                let rejected=tx.query("SELECT 1 FROM operation_receipts WHERE operation_id=? AND outcome='rejected'",[SqlParameter.Text(child.value)])
                if(rejected.isEmpty()){
                    withManagedChannelChildHandoff(parent,child,root,run,thread,epoch,parentPlan,plan,managedChannelOwnedRequestKey(root.callId(),plan),
                        root.callId()+":managed:"+cursor.ordinal.toString(),allocate,guard,{expected=>
                            withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff'",
                                [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                                    if(actual!=expected){throw IllegalStateException("known child changed its full actual Source handoff")}})})
                }else{
                    livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND decision='rejected' AND source=? "+
                        "AND NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                        [SqlParameter.Text(child.value),SqlParameter.Text(approvalDecisionSourceName(ApprovalDecisionSource.User)),SqlParameter.Text(child.value)],
                        "known rejection did not remain the actual unexecuted User decision")
                }
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                    "AND kind='managed_channel_child_terminal_v1'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{witness=>
                        withLivePolicyStoredValue(tx,"detail"," FROM operation_receipts WHERE operation_id=?",
                            [SqlParameter.Text(child.value)],allocate,guard,{detail=>
                                if(witness!=detail){throw IllegalStateException("managed known receipt lost its exact complete terminal output")}})})
            })
    }
    if(cursor.ordinal!=through){throw IllegalStateException("managed child prefix omitted a prior receipt")}
    journalStreamCheck(guard)
}

func prepareManagedChannelOwnedInvocationInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,call:ToolCall,approval:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(child.value==parent.value || !managedChannelOwnedChildAllowed(parentPlan,childPlan) ||
        requestKey!=managedChannelOwnedRequestKey(root.callId(),childPlan) || requestKey!=httpIntentText(childPlan.canonicalArguments,"request_key") ||
        call.name!=childPlan.toolName || call.callId!=root.callId()+":managed:"+childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText() ||
        canonicalAgentValue(call.arguments)!=canonicalAgentValue(childPlan.canonicalArguments)){
        throw IllegalStateException("managed child is not its complete ordinary-policy prepared proposal")}
    match(approval){case Some(value)=>if(!managedChannelApprovalMatches(value,child,thread,call.callId,childPlan)){
        throw IllegalStateException("managed child approval changed its original reviewed tuple")};case None=>()}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    let existing=tx.query("SELECT 1 FROM derived_operation_admissions WHERE parent_operation_id=? AND request_key=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(requestKey)])
    if(!existing.isEmpty()){
        match(approval){case Some(value)=>requireManagedChannelOwnedPendingInTransaction(tx,root,parent,child,run,thread,epoch,
            parentPlan,childPlan,requestKey,call.callId,value,allocate,guard)
            case None=>throw IllegalStateException("Known or ready managed children never replay")}
        return
    }
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,sequence-1,None,allocate,guard)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='managed_channel_no_effect_stop_v1')",
        [SqlParameter.Text(parent.value)],"a policy-stopped parent cannot prepare another request")
    requireManagedChannelActiveResource(tx,childPlan.canonicalArguments.field("binding").getOrThrow(),allocate,guard)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM operations WHERE id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?)",
        [SqlParameter.Text(child.value),SqlParameter.Text(child.value),SqlParameter.Text(child.value)],"managed child identity is already in use")
    withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
        tx.execute("INSERT INTO operations(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,resource_scope,effect_class,"+
            "retry_disposition,idempotency_key,state,revision) VALUES (?,?,?,?,?,?,?,?,NULL,'prepared',1)",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(encoded),
             SqlParameter.Text(encodeCapabilities(childPlan.requiredCapabilities)),SqlParameter.Text(encodeResourceScope(childPlan)),
             SqlParameter.Text(storeEffectName(childPlan.effectClass)),SqlParameter.Text(storeRetryName(childPlan.retryDisposition))])
        insertOperationEffectRecord(tx,child,run,root.itemId(),childPlan,encoded)
        tx.execute("INSERT INTO derived_operation_admissions(operation_id,parent_operation_id,call_sequence,request_key,request_digest,"+
            "child_call_id,root_operation_id,depth) VALUES (?,?,?,?,?,?,?,1)",
            [SqlParameter.Text(child.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence),SqlParameter.Text(requestKey),
             SqlParameter.Text(childPlan.bindingDigest),SqlParameter.Text(call.callId),SqlParameter.Text(parent.value)])
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(contextReadMetadataRawPeak(managedChannelPreparedTupleBytes(parent,child,run,thread,parentPlan,childPlan,requestKey,call.callId,approval)))
            let evidence=managedChannelPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call.callId,approval)
            let payload=encodeStoredValue(evidence)
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES (?,?,?,'managed_channel_child_prepared_v1',?,?)",
                [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(payload),SqlParameter.Int64Value(agentUtcMillis())])
        }finally{owner.close()}
        match(approval){case Some(_)=>
            tx.execute("UPDATE operations SET state='waiting_approval',revision=revision+1 WHERE id=? AND state='prepared'",[SqlParameter.Text(child.value)])
            requireStoreChanged(tx,"managed waiting child lost its owner");mirrorOperationState(tx,child,"waiting_approval")
            case None=>()}
    })
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call.callId,approval,
        managedChannelApprovalPhase(approval),allocate,guard)
    journalStreamCheck(guard)
}
func requireManagedChannelOwnedPendingInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,approval:ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,Some(approval),
        ManagedChannelChildPhase.WaitingApproval,allocate,guard)
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,
        journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())-1,Some(child),allocate,guard)
    requireManagedChannelActiveResource(tx,childPlan.canonicalArguments.field("binding").getOrThrow(),allocate,guard)
}


func requireManagedChannelChildExecutionApproval(tx:SqliteTransaction,child:OperationId,childPlan:NormalizedOperationPlan,
    expected:?ApprovalRequest,nowMillis:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live child execution timestamp")}
    match(expected){
        case None=>livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
            [SqlParameter.Text(child.value)],"original Ready child cannot adopt another durable approval")
        case Some(_)=>withLivePolicyPlanEncoding(childPlan,allocate,guard,{_=>
            // No historical invocation timestamp can resurrect an expired
            // reviewed decision between approval, admission and handoff.
            let observedNow=agentUtcMillis()
            let currentNow=if(observedNow>nowMillis){observedNow}else{nowMillis}
            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? "+
                "AND decision='approved' AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) "+
                "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>?))",
                [SqlParameter.Text(child.value),SqlParameter.Text(childPlan.bindingDigest),
                    SqlParameter.Text(encodeCapabilities(childPlan.requiredCapabilities)),SqlParameter.Int64Value(currentNow)],
                "live child lost its exact actual unexpired reviewed capability set")
            journalStreamCheck(guard)
        })
    }
}

func markManagedChannelOwnedChildExecutingInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(approvalRequired!=expected.isSome()){
        throw IllegalStateException("live child cannot downgrade its retained actual approval requirement")}
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,ManagedChannelChildPhase.Prepared,allocate,guard)
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    requireManagedChannelChildExecutionApproval(tx,child,childPlan,expected,nowMillis,allocate,guard)
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,
        journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())-1,Some(child),allocate,guard)
    requireManagedChannelActiveResource(tx,childPlan.canonicalArguments.field("binding").getOrThrow(),allocate,guard)
    journalStreamCheck(guard)
    tx.execute("UPDATE operations SET state='executing',revision=revision+1 WHERE id=? AND run_id=? AND state='prepared'",
        [SqlParameter.Text(child.value),SqlParameter.Text(run.value)])
    requireStoreChanged(tx,"live child execution lost its original prepared owner")
    mirrorOperationState(tx,child,"executing")
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,ManagedChannelChildPhase.ExecutingWithoutHandoff,allocate,guard)
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    journalStreamCheck(guard)
}

func markManagedChannelOwnedChildHandoffInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,nowMillis:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(nowMillis<0){throw IllegalStateException("negative live child handoff timestamp")}
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,ManagedChannelChildPhase.ExecutingWithoutHandoff,allocate,guard)
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    requireManagedChannelChildExecutionApproval(tx,child,childPlan,expected,nowMillis,allocate,guard)
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,
        journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())-1,Some(child),allocate,guard)
    requireManagedChannelActiveResource(tx,childPlan.canonicalArguments.field("binding").getOrThrow(),allocate,guard)
    withManagedChannelChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{payload=>
        journalStreamCheck(guard)
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'operation_execution_handoff',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                SqlParameter.Text(payload),SqlParameter.Int64Value(nowMillis)])
        requireStoreChanged(tx,"live child handoff lost its precise actual Source")
    })
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,ManagedChannelChildPhase.Executing,allocate,guard)
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    journalStreamCheck(guard)
}

func recordManagedChannelOwnedChildApprovalInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    childPlan:NormalizedOperationPlan,requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,
    ceiling:CapabilitySet,approved:Bool,source:String,expires:?Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,rejectionError!:?AgentError=None):Unit{
    if(approved && rejectionError.isSome()){throw IllegalStateException("approved child cannot carry a rejection Error")}
    requireManagedChannelOwnedPendingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,allocate,guard)
    recordLivePolicyApprovalInTransaction(tx,child,run,childPlan,approvalId,ceiling,approved,source,expires,allocate,guard)
    let phase=if(approved){ManagedChannelChildPhase.Prepared}else{ManagedChannelChildPhase.RejectedWithoutHandoff}
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,Some(expected),phase,allocate,guard)
    if(!approved){
        if(source!=approvalDecisionSourceName(ApprovalDecisionSource.User)){throw IllegalStateException("managed no-effect rejection needs actual User decision")}
        let owner=allocate(65536)
        try{
            let detail=match(rejectionError){
                case None=>objectValue([ValueField("code",textValue("managed_channel.user_rejected"))])
                case Some(error)=>livePolicyRejectedErrorDetailOwned(error,owner,65536,guard)
            }
            let receipt=VNextOperationReceipt("receipt-"+child.value,child,OperationOutcome.Rejected,
                detail,nullValue(),agentUtcMillis())
            // This paid typed Error owner remains live while the separate
            // original-pool receipt encoder/writer allocates its own extent.
            writeManagedChannelReceipt(tx,child,run,thread,receipt,allocate,guard)
        }finally{owner.close()}
    }
    journalStreamCheck(guard)
}

func writeManagedChannelReceipt(tx:SqliteTransaction,child:OperationId,run:RunId,thread:ThreadId,receipt:VNextOperationReceipt,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(receipt.operationId.value!=child.value || receipt.receiptId!="receipt-"+child.value){throw IllegalStateException("managed receipt changed its real reserved identity")}
    let owner=allocate(65536)
    try{
        let left=livePolicyStoredExtent(receipt.detail);let right=livePolicyStoredExtent(receipt.verification)
        let bytes=journalStreamAdd(left.bytes,right.bytes);let nodes=journalStreamAdd(left.nodes,right.nodes)
        if(left.bytes>8388608 || right.bytes>8388608){throw IllegalStateException("managed receipt exceeds original durable codec")}
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(bytes,nodes),journalStreamAdd(bytes*12,1048576)))
        let detail=encodeStoredValue(receipt.detail);let verification=encodeStoredValue(receipt.verification)
        if(detail.size!=left.bytes || verification.size!=right.bytes){throw IllegalStateException("managed receipt measurement drift")}
        journalStreamCheck(guard)
        tx.execute("INSERT INTO operation_receipts(id,operation_id,outcome,detail,verification,created_at_millis) VALUES (?,?,?,?,?,?)",
            [SqlParameter.Text(receipt.receiptId),SqlParameter.Text(child.value),SqlParameter.Text(operationOutcomeName(receipt.outcome)),
             SqlParameter.Text(detail),SqlParameter.Text(verification),SqlParameter.Int64Value(receipt.observedAtMillis)])
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'managed_channel_child_terminal_v1',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(detail),SqlParameter.Int64Value(receipt.observedAtMillis)])
        let state=match(receipt.outcome){case OperationOutcome.Completed=>"committed";case OperationOutcome.Rejected=>"rejected"
            case OperationOutcome.Cancelled=>"cancelled";case OperationOutcome.TimedOut=>"timed_out";case OperationOutcome.Failed=>"failed"
            case OperationOutcome.Unknown=>"recovery_required"}
        tx.execute("UPDATE operations SET state=?,revision=revision+1 WHERE id=? AND run_id=? AND state IN ('executing','rejected')",
            [SqlParameter.Text(state),SqlParameter.Text(child.value),SqlParameter.Text(run.value)])
        requireStoreChanged(tx,"managed receipt lost its actual executing/rejected child");mirrorOperationState(tx,child,state)
        journalStreamCheck(guard)
    }finally{owner.close()}
}

func settleManagedChannelOwnedChildInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,receipt:VNextOperationReceipt,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,
        ManagedChannelChildPhase.Executing,allocate,guard)
    if(receipt.outcome==OperationOutcome.Rejected){throw IllegalStateException("handed-off work cannot become unexecuted rejection")}
    let operation=childPlan.canonicalArguments.field("operation").getOrThrow()
    if(receipt.outcome==OperationOutcome.Completed && httpIntentText(operation,"kind")=="spawn"){
        let output=receipt.detail
        if(!httpIntentExactFields(output,["schema","lease_id","launch_digest","resource_binding","process_id"]) ||
            httpIntentText(output,"schema")!="axyndra.managed-channel-spawn-result/v1"){
            throw IllegalStateException("actual adapter spawn must return complete physical resource binding")}
        let process=output.field("process_id").getOrThrow()
        let pid=journalStreamInteger(process.asNumberText())
        if(process.unifiedKind!=ValueKind.Number || pid<1 || pid.toString()!=process.asNumberText()){
            throw IllegalStateException("actual spawn has no canonical positive physical process ID")}
        let binding=output.field("resource_binding").getOrThrow()
        if(validateManagedChannelRuntimeBinding(binding).isError() || httpIntentText(binding,"resource_state")!="active" ||
            httpIntentText(binding,"startup_operation_id")!=child.value || httpIntentText(binding,"lease_id")!=httpIntentText(output,"lease_id") ||
            httpIntentText(binding,"launch_digest")!=httpIntentText(output,"launch_digest")){
            throw IllegalStateException("adapter spawn substituted its actual resource/operation identity")}
        let proposed=childPlan.canonicalArguments.field("binding").getOrThrow()
        for(key in ["plugin","package_digest","configuration_digest","instance_identity","endpoint_identity","directory_revision","directory_digest",
            "implementation_version","implementation_fingerprint","schema_digest","target_thread_id","permission_domain","workspace_root",
            "workspace_mode","network","launch_digest","lane_id","run_id","epoch"]){
            if(canonicalAgentValue(proposed.field(key).getOrThrow())!=canonicalAgentValue(binding.field(key).getOrThrow())){
                throw IllegalStateException("actual adapter resource differs from the full approved startup proposal")}}
    }
    if(receipt.outcome==OperationOutcome.Completed && httpIntentText(operation,"kind")=="write"){
        if(!httpIntentExactFields(receipt.detail,["schema","lease_id","intent_id","written_bytes"]) ||
            httpIntentText(receipt.detail,"schema")!="axyndra.managed-channel-write-result/v1" ||
            httpIntentText(receipt.detail,"lease_id")!=httpIntentText(operation,"lease_id") ||
            httpIntentText(receipt.detail,"intent_id")!=httpIntentText(operation,"id")){
            throw IllegalStateException("actual completed write changed its full precise physical effect")}
        let count=receipt.detail.field("written_bytes").getOrThrow()
        let bytes=journalStreamInteger(count.asNumberText())
        if(count.unifiedKind!=ValueKind.Number || bytes!=httpIntentText(operation,"bytes_hex").size/2 || bytes.toString()!=count.asNumberText()){
            throw IllegalStateException("partial or uncertain write cannot become completed")}
    }
    writeManagedChannelReceipt(tx,child,run,thread,receipt,allocate,guard)
    if(receipt.outcome==OperationOutcome.Completed && httpIntentText(operation,"kind")=="spawn"){
        withLivePolicyStoredValue(tx,"detail"," FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(child.value)],allocate,guard,{detail=>
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES (?,?,?,'managed_channel_resource_bound_v1',?,?)",
                [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),SqlParameter.Text(detail),SqlParameter.Int64Value(receipt.observedAtMillis)])})
    }
    if(receipt.outcome==OperationOutcome.Completed && httpIntentText(operation,"kind")=="close"){
        if(!httpIntentExactFields(receipt.detail,["schema","lease_id","resources_released"]) ||
            httpIntentText(receipt.detail,"schema")!="axyndra.managed-channel-close-result/v1" ||
            httpIntentText(receipt.detail,"lease_id")!=httpIntentText(operation,"lease_id") ||
            receipt.detail.field("resources_released").getOrThrow().unifiedKind!=ValueKind.Boolean ||
            !receipt.detail.field("resources_released").getOrThrow().asBool()){
            throw IllegalStateException("actual completed close has no physical resource release ACK")}
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'managed_channel_resource_closed_v1',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
             SqlParameter.Text(httpIntentText(operation,"lease_id")),SqlParameter.Int64Value(receipt.observedAtMillis)])
    }
    journalStreamCheck(guard)
}

func verifyManagedChannelOwnedChildTerminalInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,result:ToolResult,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(result.callId!=callId || result.receiptId!=child.value || result.payloadLease.isNone() ||
        requestKey!=managedChannelOwnedRequestKey(root.callId(),childPlan)){
        throw IllegalStateException("managed terminal result has no original paid child identity")}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,sequence,None,allocate,guard)
    livePolicyRequireOne(tx,"SELECT 1 FROM operation_receipts WHERE operation_id=? AND "+
        "CASE WHEN outcome='completed' THEN 0 ELSE 1 END=?",
        [SqlParameter.Text(child.value),SqlParameter.Int64Value(if(result.isError){1}else{0})],
        "child ToolResult error flag differs from its actual known outcome")
    let owner=allocate(65536)
    try{
        let extent=livePolicyStoredExtent(result.output)
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*12))
        let expected=encodeStoredValue(result.output)
        withLivePolicyStoredValue(tx,"detail"," FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(child.value)],allocate,guard,{actual=>
            if(actual!=expected){throw IllegalStateException("managed terminal result differs from its complete actual receipt")}})
    }finally{owner.close()}
}

func verifyManagedChannelOwnedParentTerminalInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,terminalKind!:String=""):Unit{
    if(result.callId!=root.callId() || result.receiptId!=parent.value || result.payloadLease.isNone()){
        throw IllegalStateException("managed parent terminal lost its actual owned output")}
    let rejected=tx.query("SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='rejected'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    let phase=if(rejected.isEmpty()){ManagedChannelParentPhase.Executing}else{ManagedChannelParentPhase.RejectedWithoutHandoff}
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,phase:phase)
    let rows=tx.query("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id=?",[SqlParameter.Text(parent.value)])
    if(rows.size!=1){throw IllegalStateException("managed parent has ambiguous child inventory")}
    let count=journalStreamInteger(rows[0].required(0))
    if(!rejected.isEmpty() && count!=0){throw IllegalStateException("unexecuted rejected parent already owns effect children")}
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,plan,count,None,allocate,guard)
    if(result.isError && rejected.isEmpty() && terminalKind!="protocol"){
        let stopped=tx.query("SELECT 1 FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='managed_channel_no_effect_stop_v1'",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)])
        let denied=tx.query("SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_receipts p ON p.operation_id=o.id JOIN approvals approval ON approval.operation_id=o.id "+
            "WHERE a.parent_operation_id=? AND a.call_sequence=? AND p.outcome='rejected' AND o.state='rejected' "+
            "AND approval.decision='rejected' AND approval.source=? "+
            "AND NOT EXISTS(SELECT 1 FROM audit_events h WHERE h.operation_id=o.id AND h.kind='operation_execution_handoff')",
            [SqlParameter.Text(parent.value),SqlParameter.Int64Value(count),SqlParameter.Text(approvalDecisionSourceName(ApprovalDecisionSource.User))])
        let failed=tx.query("SELECT 1 FROM derived_operation_admissions a JOIN operation_receipts p ON p.operation_id=a.operation_id "+
            "WHERE a.parent_operation_id=? AND a.call_sequence=? AND p.outcome IN ('failed','cancelled','timed_out')",
            [SqlParameter.Text(parent.value),SqlParameter.Int64Value(count)])
        if(stopped.size!=1 && denied.size!=1 && failed.size!=1){throw IllegalStateException("parent error has no actual policy stop, User rejection or known failed child")}
        if(stopped.size==1){
            withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='managed_channel_no_effect_stop_v1'",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{raw=>
                    let value=decodeStoredValue(raw)
                    if(!httpIntentExactFields(value,["schema","parent_operation_id","run_id","thread_id","epoch","call_id","tool","request_key","reason","arguments"]) ||
                        httpIntentText(value,"schema")!="axyndra.managed-channel-no-effect-stop/v1" ||
                        httpIntentText(value,"parent_operation_id")!=parent.value || httpIntentText(value,"run_id")!=run.value ||
                        httpIntentText(value,"thread_id")!=thread.value || value.field("epoch").getOrThrow().asNumberText()!=epoch.toString() ||
                        httpIntentText(value,"reason")!="ordinary_policy_preparation_stopped" ||
                        !managedChannelRuntimeChildValueValid(value.field("arguments").getOrThrow()) ||
                        value.field("arguments").getOrThrow().field("sequence").getOrThrow().asNumberText()!=journalStreamAdd(count,1).toString() ||
                        httpIntentText(value,"call_id")!=root.callId()+":managed:"+journalStreamAdd(count,1).toString() ||
                        httpIntentText(value,"request_key")!="managed-channel:"+root.callId()+":"+journalStreamAdd(count,1).toString()){
                        throw IllegalStateException("managed parent stop witness differs from its actual exact next request")}})
        }
    }else if(!result.isError){
        livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='managed_channel_no_effect_stop_v1')",
            [SqlParameter.Text(parent.value)],"ordinary stopped request cannot become a successful parent")
    }
    // Core remains the sole parent Receipt/ThreadResult owner. This proves its
    // current Source and every child before the actual output reaches Core.
    journalStreamCheck(guard)
}
func recordManagedChannelOwnedStopInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,call:ToolCall,requestKey:String,reason:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard)
    if(!managedChannelRuntimeChildValueValid(call.arguments) || reason!="ordinary_policy_preparation_stopped"){
        throw IllegalStateException("managed stop is not the actual complete normal preparation outcome")}
    let sequence=journalStreamInteger(call.arguments.field("sequence").getOrThrow().asNumberText())
    if(requestKey!="managed-channel:"+root.callId()+":"+sequence.toString() ||
        requestKey!=httpIntentText(call.arguments,"request_key") || call.callId!=root.callId()+":managed:"+sequence.toString()){
        throw IllegalStateException("managed stop changed its actual request identity")}
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,plan,sequence-1,None,allocate,guard)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='managed_channel_no_effect_stop_v1') "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions WHERE parent_operation_id=? AND request_key=?)",
        [SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(requestKey)],"managed stop already owns another obligation")
    let owner=allocate(65536)
    try{
        let extent=livePolicyStoredExtent(call.arguments)
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),journalStreamAdd(extent.bytes*12,65536)))
        let witness=objectValue([ValueField("schema",textValue("axyndra.managed-channel-no-effect-stop/v1")),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
            ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
            ValueField("call_id",textValue(call.callId)),ValueField("tool",textValue(call.name)),ValueField("request_key",textValue(requestKey)),
            ValueField("reason",textValue(reason)),ValueField("arguments",call.arguments)])
        let all=livePolicyStoredExtent(witness)
        if(all.bytes>8388608){throw IllegalStateException("managed stop exceeds original durable codec")}
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(all.bytes,all.nodes),all.bytes*12))
        let encoded=encodeStoredValue(witness)
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
            "VALUES (?,?,?,'managed_channel_no_effect_stop_v1',?,?)",
            [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])
        journalStreamCheck(guard)
    }finally{owner.close()}
}
func verifyManagedChannelOwnedEffectExecutingInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    requireManagedChannelChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected,
        ManagedChannelChildPhase.Executing,allocate,guard)
    requireManagedChannelChildExecutionApproval(tx,child,childPlan,expected,agentUtcMillis(),allocate,guard)
    requireManagedChannelKnownPrefix(tx,root,parent,run,thread,epoch,parentPlan,
        journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())-1,Some(child),allocate,guard)
    requireManagedChannelActiveResource(tx,childPlan.canonicalArguments.field("binding").getOrThrow(),allocate,guard)
}
func verifyManagedChannelOwnedResourceInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,binding:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    requireManagedChannelOwnedParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard)
    if(validateManagedChannelRuntimeBinding(binding).isError() || httpIntentText(binding,"resource_state")!="active"){
        throw IllegalStateException("managed read/activation has no exact active resource binding")}
    let frozen=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    for(key in ["plugin","package_digest","configuration_digest","instance_identity","endpoint_identity","directory_revision","directory_digest",
        "implementation_version","implementation_fingerprint","schema_digest","target_thread_id","permission_domain","workspace_root",
        "workspace_mode","network","launch_digest","lane_id","run_id","epoch"]){
        if(canonicalAgentValue(frozen.field(key).getOrThrow())!=canonicalAgentValue(binding.field(key).getOrThrow())){
            throw IllegalStateException("managed resource is outside the actual current root endpoint")}}
    requireManagedChannelActiveResource(tx,binding,allocate,guard)
}


func requireManagedChannelPreparationReads(transaction: SqliteTransaction, operation: OperationId,
    run: RunId, parentItem: ItemId, toolName: String, links: Array<ContextReadFactLink>, allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>): Unit {
    if (links.isEmpty()) { return }
    let source=" FROM items item JOIN runs r ON item.thread_id=r.thread_id AND item.turn_id=r.turn_id WHERE r.id=? AND item.id=?"
    let parameters=[SqlParameter.Text(run.value),SqlParameter.Text(parentItem.value)]
    let cells=ArrayList<ContextReadMetadataCell>()
    for(column in ["item.payload","item.provenance","r.skill_snapshot"]){cells.add(contextReadMetadataMeasure(transaction,column,source,parameters,allocate,guard))}
    withContextReadMetadataStage(cells.toArray(),allocate,guard,{=>
    let parents = transaction.query("SELECT item.payload,item.provenance,item.ordinal,r.thread_id,r.turn_id,r.epoch,r.skill_snapshot " +
        "FROM items item JOIN runs r ON item.thread_id=r.thread_id AND item.turn_id=r.turn_id " +
        "JOIN threads thread ON thread.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "WHERE r.id=? AND item.id=? AND item.kind='tool_call' AND r.state IN ('running','waiting_external') " +
        "AND r.finished_at_millis IS NULL AND thread.active_turn_id=turn.id AND turn.active_run_id=r.id AND turn.state='active' " +
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions child WHERE child.operation_id=?)",
        [SqlParameter.Text(run.value), SqlParameter.Text(parentItem.value), SqlParameter.Text(operation.value)])
    if (parents.size != 1) { throw IllegalStateException("context read consumption requires its active canonical root") }
    let parent = parents[0]
    let callId = match (decodeStoredThreadContent(parent.required(0))) {
        case ThreadItemContent.ToolCall(id, name, _) =>
            if (name != toolName) { throw IllegalStateException("context read cannot be transferred to another tool") }
            id.value
        case _ => throw IllegalStateException("context read parent is not a canonical call")
    }
    eachContextReadToolResultPaid(transaction,parent.required(3),parent.required(4),allocate,guard,{content=>
        match(content){case ThreadItemContent.ToolResult(id,_,_,_,_)=>if(id.value==callId){throw IllegalStateException("context read parent is already settled")};case _=>()}})
    let projection = contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(parent.required(6))))
    for (link in links) {
        let factSource=" FROM operations o JOIN runs r ON r.id=o.run_id JOIN items call ON call.id=o.tool_call_item_id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts receipt ON receipt.id=e.reserved_receipt_id "+
            "AND receipt.operation_id=o.id JOIN items result ON result.id=e.reserved_result_item_id WHERE o.id=? AND o.run_id=?"
        let factParams=[SqlParameter.Text(link.operationId.value),SqlParameter.Text(run.value)]
        let factCells=ArrayList<ContextReadMetadataCell>()
        for(column in ["call.payload","call.provenance","o.normalized_plan","receipt.detail","result.payload"]){
            factCells.add(contextReadMetadataMeasure(transaction,column,factSource,factParams,allocate,guard))}
        factCells.add(contextReadMetadataMeasure(transaction,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND kind='context_read_admitted'",factParams,allocate,guard))
        withContextReadMetadataStage(factCells.toArray(),allocate,guard,{=>
        let fact = requireContextReadFact(transaction, link.operationId, run)
        if (link.runId.value != run.value || canonicalAgentValue(link.toValue()) != canonicalAgentValue(fact.reference()) ||
            fact.origin.parentCallItemId != parentItem.value || fact.origin.projectionDigest != projection) {
            throw IllegalStateException("context read fact no longer matches this Run, projection and exact parent")
        }
        let order = transaction.query("SELECT call.ordinal,result.ordinal FROM items call JOIN items result ON result.id=? " +
            "AND result.thread_id=call.thread_id AND result.turn_id=call.turn_id WHERE call.id=? AND call.thread_id=? AND call.turn_id=?",
            [SqlParameter.Text(fact.resultItemId.value), SqlParameter.Text(fact.sourceItemId.value),
                SqlParameter.Text(parent.required(3)), SqlParameter.Text(parent.required(4))])
        if (order.size != 1 || parseStoreInt(order[0].required(0), "read order") <= parseStoreInt(parent.required(2), "parent order") ||
            parseStoreInt(order[0].required(1), "read result order") <= parseStoreInt(order[0].required(0), "read order")) {
            throw IllegalStateException("context read facts do not follow their canonical parent")
        }
        let origin = fact.origin
        if (origin.parentKind == "direct") {
            let provenance = decodeStoredProvenance(parent.required(1))
            if (origin.parentOperationId != operation.value || provenance.source != "direct_tool" ||
                provenance.runId.isNone() || provenance.runId.getOrThrow().value != run.value ||
                provenance.operationId.isNone() || provenance.operationId.getOrThrow().value != operation.value ||
                !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance), DirectCallOrigin.UserDirect) ||
                !transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
                    [SqlParameter.Text(parentItem.value)]).isEmpty()) {
                throw IllegalStateException("context read Direct parent binding changed")
            }
        } else if (origin.parentKind == "committed") {
            let expectedOperation = "operation-" + origin.parentDecisionId + "-" + origin.parentScopedCallId
            let canonical = transaction.query("SELECT c.item_id FROM canonical_decision_items c " +
                "JOIN model_decisions d ON d.id=c.decision_id JOIN model_attempts a ON a.id=d.attempt_id " +
                "JOIN model_decision_blocks b ON b.id=c.decision_block_id AND b.decision_id=d.id " +
                "WHERE c.item_id=? AND d.id=? AND b.scoped_tool_call_id=? AND a.run_id=? " +
                "AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL",
                [SqlParameter.Text(parentItem.value), SqlParameter.Text(origin.parentDecisionId),
                    SqlParameter.Text(origin.parentScopedCallId), SqlParameter.Text(run.value)])
            if (operation.value != expectedOperation || canonical.size != 1) {
                throw IllegalStateException("context read committed parent binding changed")
            }
        } else { throw IllegalStateException("safe-cut context data cannot be repurposed as a pending tool read") }
        })
    }
    })
}

func verifyManagedChannelActualTerminalInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
    descriptor:AgentValue,owner:LogicalJsonOwnerReservation,retainedPeak:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyFixedFD:()->Result<Unit>,guard:()->Result<Unit>):Unit{
    let kind=httpIntentText(descriptor,"terminal_kind")
    let fields=if(kind=="protocol"){
        ["schema","terminal_kind","parent_binding_digest","output","is_error","protocol_record"]
    }else{["schema","terminal_kind","parent_binding_digest","output","is_error"]}
    if(!httpIntentExactFields(descriptor,fields) ||
        httpIntentText(descriptor,"schema")!="axyndra.managed-channel-owned-terminal/v1" ||
        !["protocol","policy_stop","user_rejected","child_failure","complete"].contains(kind) ||
        httpIntentText(descriptor,"parent_binding_digest")!=plan.bindingDigest ||
        descriptor.field("is_error").getOrThrow().unifiedKind!=ValueKind.Boolean ||
        descriptor.field("is_error").getOrThrow().asBool()!=result.isError){
        throw IllegalStateException("actual managed terminal changed its complete bound Host descriptor")}
    let value=descriptor.field("output").getOrThrow()
    let left=livePolicyStoredExtent(value);let right=livePolicyStoredExtent(result.output)
    let bytes=journalStreamAdd(left.bytes,right.bytes);let nodes=journalStreamAdd(left.nodes,right.nodes)
    // Both complete exact comparator Strings are prepaid on the original
    // retained output owner before either original encoder allocates them.
    owner.ensureRetainedPeak(journalStreamAdd(retainedPeak,journalStreamAdd(contextReadMetadataPeak(bytes,nodes),bytes*12)))
    if(encodeStoredValue(value)!=encodeStoredValue(result.output)){
        throw IllegalStateException("actual terminal output differs from this exact retained ToolResult")}
    journalStreamCheck(verifyFixedFD)
    if(kind=="complete" && result.isError){throw IllegalStateException("ordinary complete terminal cannot claim a business failure")}
    if(["policy_stop","user_rejected","child_failure"].contains(kind) && !result.isError){
        throw IllegalStateException("actual stopped/rejected/failed terminal cannot become a successful parent")}
    if(kind=="protocol"){
        let record=descriptor.field("protocol_record").getOrThrow()
        if(!httpIntentExactFields(record,["operation_id","request_key","response"]) ||
            record.field("response").isNone()){
            throw IllegalStateException("actual parsed protocol terminal has no complete bound physical response")}
        // The response is generic data held by the same fixed-FD owner. It
        // does not authorize effects, replace exact equality, or supply a
        // snapshot/corpus digest. Store independently proves its exact write.
        livePolicyRequireOne(tx,"SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_receipts r ON r.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "WHERE a.operation_id=? AND a.parent_operation_id=? AND a.root_operation_id=? AND a.depth=1 AND a.request_key=? "+
            "AND o.run_id=? AND o.state='committed' AND r.outcome='completed' AND r.id=e.reserved_receipt_id AND e.tool_id=?",
            [SqlParameter.Text(httpIntentText(record,"operation_id")),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),
             SqlParameter.Text(httpIntentText(record,"request_key")),SqlParameter.Text(run.value),SqlParameter.Text(HOST_MANAGED_CHANNEL_WRITE_TOOL)],
            "actual protocol response has no own completed precise channel write")
    }
    let rejected=tx.query("SELECT 1 FROM operations WHERE id=? AND run_id=? AND state='rejected'",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    if(!rejected.isEmpty()){
        let approval=match(expected){case Some(value)=>value;case None=>throw IllegalStateException("rejected actual terminal lost its original reviewed parent")}
        requireManagedChannelExpectedParentApproval(tx,root,parent,run,thread,epoch,plan,approval,allocate,guard)
        if(kind!="user_rejected" || !result.isError){throw IllegalStateException("unexecuted parent rejection cannot become protocol completion")}
    }
    verifyManagedChannelOwnedParentTerminalInTransaction(tx,root,parent,run,thread,epoch,plan,result,allocate,guard,terminalKind:kind)
    recordManagedChannelActualTerminalWitness(tx,root,parent,run,thread,epoch,plan,result,descriptor,owner,retainedPeak,allocate,guard)
    journalStreamCheck(verifyFixedFD);journalStreamCheck(guard)
}
