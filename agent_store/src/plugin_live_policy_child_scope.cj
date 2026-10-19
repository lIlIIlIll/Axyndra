package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Private relationship only; neither a decoded Native grant nor a fence
// token. Every caller selecting Some(pending) must first check its complete
// actual immutable tuple/prepared audit. The causal helper repeats its own
// independent unique-next-child SQL relationships and all actual input facts.
class LivePolicyReadProgress{
    let through:Int64
    let reference:AgentValue
    let pending:?OperationId
    init(through:Int64,reference:AgentValue,pending:?OperationId){
        this.through=through;this.reference=reference;this.pending=pending}
}
func livePolicyReadProgressForChild(plan:NormalizedOperationPlan,pending:?OperationId):LivePolicyReadProgress{
    if(!isPluginLivePolicyStreamingChildPlan(plan)){
        throw IllegalStateException("causal child progress requires its actual strict independently normalized plan")}
    let sequence=journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    if(sequence<1){throw IllegalStateException("causal child sequence is not positive")}
    LivePolicyReadProgress(sequence-1,plan.canonicalArguments.field("prior_receipts").getOrThrow(),pending)
}

enum LivePolicyChildPhase{Prepared | WaitingApproval | RejectedWithoutHandoff | ExecutingWithoutHandoff | Executing}
func livePolicyChildState(phase:LivePolicyChildPhase):String{
    match(phase){case LivePolicyChildPhase.Prepared=>"prepared"
        case LivePolicyChildPhase.WaitingApproval=>"waiting_approval"
        case LivePolicyChildPhase.RejectedWithoutHandoff=>"rejected"
        case LivePolicyChildPhase.ExecutingWithoutHandoff | LivePolicyChildPhase.Executing=>"executing"}
}

// This is the full actual CHILD identity, not the parent Source authorizer.
// No body/SQL/prefix is dropped: immutable plan/caps/effect/replay/reserved
// slots, unique own admission, exact original prepared approval and handoff
// are checked while their complete bytes are paid. No DOM escapes the Unit.
func requireLivePolicyChildPreparedTuple(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,phase:LivePolicyChildPhase,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    if(child.value==parent.value || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
        requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan) ||
        callId!=root.callId()+":live:"+childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText()){
        throw IllegalStateException("live child lost its actual precise parent/plan/request/call")}
    match(expected){case Some(value)=>if(!livePolicyApprovalMatches(value,child,thread,callId,childPlan)){
        throw IllegalStateException("live child changed its originally reviewed exact approval")};case None=>()}
    if(match(phase){case LivePolicyChildPhase.WaitingApproval=>expected.isNone();case _=>false}){
        throw IllegalStateException("waiting child has no actual retained reviewed approval")}
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    let state=livePolicyChildState(phase)
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
        tupleOwner.ensureRetainedPeak(contextReadMetadataRawPeak(livePolicyPreparedTupleBytes(parent,child,run,thread,
            parentPlan,childPlan,requestKey,callId,expected)))
        let evidence=livePolicyPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected)
        let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_child_prepared_v1'"
        withLivePolicyStoredValue(tx,"payload",suffix,
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                if(canonicalAgentValue(decodeStoredValue(actual))!=canonicalAgentValue(evidence)){
                    throw IllegalStateException("live child changed its complete original prepared Source/approval evidence")}})
        match(phase){case LivePolicyChildPhase.WaitingApproval=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
                [SqlParameter.Text(child.value)],"live waiting child already has an unrelated durable approval")
            case _=>()}
        match(phase){case LivePolicyChildPhase.Executing=>
            withLivePolicyChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{expectedPayload=>
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

func withLivePolicyChildHandoff(parent:OperationId,child:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,
    epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    if(parentPlan.contextReadFacts.size!=1 || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan)){
        throw IllegalStateException("actual child handoff has no exact original paid parent/read")}
    withLivePolicyPlanEncoding(parentPlan,allocate,guard,{parentEncoded=>
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{childEncoded=>
            let owner=allocate(65536)
            try{
                // Prepay complete actual scalar extents before wrappers,
                // digest encoders or SQL parameter copies are allocated.
                var bytes:Int64=65536
                for(value in [parent.value,child.value,run.value,thread.value,root.itemId().value,root.callId(),callId,
                    requestKey,parentPlan.bindingDigest,childPlan.bindingDigest,parentPlan.contextReadFacts[0].origin.projectionDigest]){
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
                let value=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-child-handoff/v1")),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("operation_id",textValue(child.value)),
                    ValueField("run_id",textValue(run.value)),ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
                    ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                    ValueField("projection_digest",textValue(parentPlan.contextReadFacts[0].origin.projectionDigest)),
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

// Private full event fence/actual key stays inside the same paid callback and
// actual transaction. It is never a Native-visible digest or cache-read grant.
func withLivePolicyCurrentJournalFence(tx:SqliteTransaction,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(JournalLatestStreamFence,String,ContextReadFactLink)->Unit):Unit{
    if(!isPluginLivePolicyParentPlan(parentPlan) || parentPlan.contextReadFacts.size!=1){
        throw IllegalStateException("live causal writer has no exact sole original paid read")}
    let link=parentPlan.contextReadFacts[0]
    let payment=ContextReadCompletedMetadataPayment(tx,link,allocate,guard)
    try{
        let read=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(read) || pluginDocumentContextLatestJournalStreamReadAuthority(read)){
            throw IllegalStateException("live causal writer cannot reinterpret another or parentless read dialect")}
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let key=httpIntentText(read.canonicalArguments,"key")
        let namespace=httpIntentText(binding,"namespace")
        let backend=match(tx.documentStorageBackend(namespace,key)){
            case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){case Some(actual)=>actual
                case None=>throw IllegalStateException("live causal writer has no exact opted-in latest backend")}
            case None=>throw IllegalStateException("live causal writer lost its actual fixed namespace/key mapping")}
        let configurationCurrent=backend.capture(read)
        let current={=>journalStreamCheck(guard);journalStreamCheck(configurationCurrent);payment.current(binding)}
        journalStreamCheck(current)
        let before=backend.full(tx,current)
        consume(before,key,link)
        // No observed state escapes; callers mutating events must separately
        // verify their authorized exact post-state and causal witness at EOF.
        journalStreamCheck(current)
    }finally{payment.close()}
}
