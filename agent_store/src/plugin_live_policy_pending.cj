package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Independent live-family validation. None of these checks enters the old
// frozen-document ParentIntent, derived admission or retry branches.
// Every SQL result below either consists of fixed numeric predicates or has
// its actual byte extent paid before copying. No Source comes from a DTO.
func livePolicyRequireOne(tx:SqliteTransaction,sql:String,parameters:Array<SqlParameter>,message:String):Unit{
    let rows=tx.query(sql,parameters)
    if(rows.size!=1 || rows[0].size!=1 || rows[0].required(0)!="1"){
        throw IllegalStateException(message)}
}

// The trusted pipeline retains the complete reviewed plan. This fixed
// reservation pays the original durable maximum before serializing a new
// plan; its reference/metadata wrapper copies are prepaid separately. The
// raw encoding cannot escape this callback or outlive this reservation.
// Compute the original byte-length framing WITHOUT copying strings or
// allocating a second argument DOM. This is size/payment metadata only.
class LivePolicyStoredExtent {
    var bytes:Int64=0
    var nodes:Int64=0
    init(){}
}
func livePolicyFrameBytes(bytes:Int64):Int64{
    if(bytes<0){throw IllegalStateException("negative actual stored frame")}
    journalStreamAdd(bytes,bytes.toString().size+1)
}
func livePolicyStoredMeasure(value:AgentValue,state:LivePolicyStoredExtent,depth:Int64):Unit{
    if(depth>64){throw IllegalStateException("stored value exceeds its original depth")}
    state.bytes=journalStreamAdd(state.bytes,1);state.nodes=journalStreamAdd(state.nodes,1)
    match(value.unifiedKind){
        case ValueKind.Null | ValueKind.Boolean=>()
        case ValueKind.Number=>state.bytes=journalStreamAdd(state.bytes,livePolicyFrameBytes(value.asNumberText().size))
        case ValueKind.Text=>state.bytes=journalStreamAdd(state.bytes,livePolicyFrameBytes(value.text.size))
        case ValueKind.List=>
            let array=value.asArray()
            state.bytes=journalStreamAdd(state.bytes,livePolicyFrameBytes(array.size().toString().size))
            for(index in 0..array.size()){livePolicyStoredMeasure(array.get(index).getOrThrow(),state,depth+1)}
        case ValueKind.Object=>
            let object=value.asObject()
            state.bytes=journalStreamAdd(state.bytes,livePolicyFrameBytes(object.size().toString().size))
            for(index in 0..object.size()){
                state.bytes=journalStreamAdd(state.bytes,livePolicyFrameBytes(object.nameAt(index).size))
                livePolicyStoredMeasure(object.valueAt(index),state,depth+1)}
    }
}
func livePolicyStoredExtent(value:AgentValue):LivePolicyStoredExtent{
    // A single mutable reference holder; no per-node objects/second DOM.
    // Original strings stay referenced and every subtree is visited.
    let extent=LivePolicyStoredExtent();livePolicyStoredMeasure(value,extent,0);extent
}
func livePolicyPlanValue(plan:NormalizedOperationPlan):AgentValue{
    // Exact generic durable plan wrapper. All scalar builders are the original
    // Store builders; canonicalArguments is referenced, never cloned here.
    let value=objectValue([
        ValueField("tool",textValue(plan.toolName)),ValueField("arguments",plan.canonicalArguments),
        ValueField("capabilities",capabilityValues(plan.requiredCapabilities)),ValueField("paths",stringValues(plan.resolvedPaths)),
        ValueField("hosts",stringValues(plan.resolvedHosts)),ValueField("network",networkPolicyCanonicalValue(plan.networkPolicy)),
        ValueField("cwd",textValue(plan.cwd)),ValueField("environment",objectValue(plan.relevantEnvironment)),
        ValueField("approval",storedApprovalMetadata(plan.approvalMetadata)),ValueField("effect",textValue(storeEffectName(plan.effectClass))),
        ValueField("retry",textValue(storeRetryName(plan.retryDisposition))),ValueField("replay",replayDispositionValue(plan.replayDisposition)),
        ValueField("idempotency_key",textValue(plan.idempotencyKey)),ValueField("digest",textValue(plan.bindingDigest)),
        ValueField("tool_version",textValue(plan.implementation.toolVersion)),
        ValueField("implementation_fingerprint",textValue(plan.implementation.implementationFingerprint)),
        ValueField("schema_digest",textValue(plan.implementation.schemaDigest)),
        ValueField("effective_arguments_digest",textValue(plan.implementation.effectiveArgumentsDigest)),
        ValueField("replay_contract_version",integerValue(Int64(plan.implementation.replayContractVersion)))])
    if(!plan.contextReadFacts.isEmpty()){value.put("context_reads",contextReadFactLinksValue(plan.contextReadFacts))}
    value
}
func withLivePolicyPlanEncoding(plan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    let owner=allocate(65536)
    try{
        var wrappers:Int64=256
        wrappers=journalStreamAdd(wrappers,plan.requiredCapabilities.size*4)
        wrappers=journalStreamAdd(wrappers,plan.resolvedPaths.size)
        wrappers=journalStreamAdd(wrappers,plan.resolvedHosts.size)
        wrappers=journalStreamAdd(wrappers,plan.relevantEnvironment.size)
        wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.flags.size)
        wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.reasons.size)
        wrappers=journalStreamAdd(wrappers,plan.contextReadFacts.size*64)
        if(wrappers>Int64.Max/2048){throw IllegalStateException("live plan wrapper payment overflow")}
        // Prepay wrapper construction before constructing any new Cj nodes.
        // Existing strings and arguments stay in their original paid owner.
        owner.ensureRetainedPeak(journalStreamAdd(1048576,wrappers*2048))
        journalStreamCheck(guard)
        let value=livePolicyPlanValue(plan);let extent=livePolicyStoredExtent(value)
        if(extent.bytes>8388608){throw IllegalStateException("live plan exceeds the original durable codec")}
        if(extent.bytes>(Int64.Max-1048576-wrappers*2048)/12){throw IllegalStateException("live plan encoding payment overflow")}
        // Includes original raw encoder ArrayList/toArray/String, fixed SQL
        // binding copies, and simultaneous capabilities/resource/replay bytes.
        owner.ensureRetainedPeak(1048576+extent.bytes*12+wrappers*2048)
        let encoded=encodeOperationPlan(plan)
        if(encoded.size!=extent.bytes){throw IllegalStateException("generic plan framing measurement drift")}
        let meter=StoredValuePaymentMeter(encoded,owner);let _=meter.complete()
        consume(encoded);journalStreamCheck(guard)
    }finally{owner.close()}
}
func withLivePolicyModelBlockEncoding(value:ModelBlock,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(1048576)
        let measured=objectValue([
            ValueField("kind",textValue(modelBlockKindName(value.kind))),ValueField("text",textValue(value.text)),
            ValueField("call_id",textValue(value.callId)),ValueField("name",textValue(value.name)),ValueField("arguments",value.arguments),
            ValueField("is_error",boolValue(value.isError)),ValueField("receipt_id",textValue(value.receiptId)),
            ValueField("opaque_state",match(value.opaqueState){case None=>nullValue();case Some(state)=>objectValue([
                ValueField("provider_id",textValue(state.providerId)),ValueField("protocol",textValue(state.protocol)),
                ValueField("item_id",textValue(state.itemId)),ValueField("payload",textValue(state.payload)),ValueField("replay_required",boolValue(state.replayRequired))])}),
            ValueField("image",match(value.image){case None=>nullValue();case Some(image)=>objectValue([
                ValueField("source_kind",textValue(match(image.sourceKind){case ModelImageSourceKind.Url=>"url";case ModelImageSourceKind.Base64=>"base64"})),
                ValueField("data",textValue(image.data)),ValueField("media_type",textValue(image.mediaType)),
                ValueField("detail",textValue(match(image.detail){case ModelImageDetail.Auto=>"auto";case ModelImageDetail.Low=>"low";case ModelImageDetail.High=>"high"}))])})])
        let extent=livePolicyStoredExtent(measured)
        if(extent.bytes>8388608){throw IllegalStateException("model block exceeds its original durable codec")}
        owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(extent.bytes),1048576))
        journalStreamCheck(guard);let encoded=encodeStoredModelBlock(value)
        if(encoded.size!=extent.bytes){throw IllegalStateException("original model block framing measurement drift")}
        consume(encoded);journalStreamCheck(guard)
    }finally{owner.close()}
}

// This method remains in the actual SQL transaction. The pipeline checks
// Direct live-source cancellation before entering SQL; guard here is only
// atomic cancellation/deadline or a fixed-file configuration witness, never
// registry/Host locks. Exact package/configuration facts are checked by the
// independent paid input helper, not by trusting the public binding.
func requirePluginLivePolicyCanonicalSource(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,admitted:Bool,progress!:?LivePolicyReadProgress=None):Unit{
    journalStreamCheck(guard)
    if(!isPluginLivePolicyParentPlan(parentPlan) || root.toolName()!=parentPlan.toolName || epoch<0){
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
    if(httpIntentText(binding,"thread_id")!=thread.value || httpIntentText(binding,"run_id")!=run.value ||
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
    // Payment and validation of actual Skill projection, original read
    // sources/receipts/audits, all turn results and private blind fence are
    // delegated to the independent same-TX helper (no DOM escapes).
    match(progress){
        case None=>requirePluginLivePolicyReadInputs(tx,parent,run,root.itemId(),root.toolName(),binding,parentPlan.contextReadFacts,allocate,guard)
        case Some(value)=>match(value.pending){
            case None=>requirePluginLivePolicyCausalReadInputs(tx,parent,run,root.itemId(),root.toolName(),binding,
                parentPlan.contextReadFacts,value.through,value.reference,allocate,guard)
            case Some(actual)=>requirePluginLivePolicyCausalReadInputsBeforePending(tx,parent,run,root.itemId(),root.toolName(),binding,
                parentPlan.contextReadFacts,value.through,value.reference,actual,allocate,guard)}}
    journalStreamCheck(guard)
}


enum LivePolicyParentPhase { Prepared | WaitingApproval | RejectedWithoutHandoff | ExecutingWithoutHandoff | Executing }
func livePolicyParentState(phase:LivePolicyParentPhase):String{
    match(phase){case LivePolicyParentPhase.Prepared=>"prepared";case LivePolicyParentPhase.WaitingApproval=>"waiting_approval"
        case LivePolicyParentPhase.RejectedWithoutHandoff=>"rejected"
        case LivePolicyParentPhase.ExecutingWithoutHandoff | LivePolicyParentPhase.Executing=>"executing"}
}
func requireLivePolicyImmutableEffect(tx:SqliteTransaction,operation:OperationId,run:RunId,item:ItemId,
    plan:NormalizedOperationPlan,encoded:String):Unit{
    // All parameters are derived from the actual retained normalized plan.
    // Its caller owns the complete encoder/capability/resource/replay payment.
    livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "+
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
        "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "AND CAST(o.normalized_plan AS BLOB)=CAST(? AS BLOB) AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
        "AND e.tool_id=? AND e.tool_version=? AND e.implementation_fingerprint=? AND e.schema_digest=? "+
        "AND e.effective_arguments_digest=? AND e.replay_contract_version=? AND CAST(e.replay_disposition AS BLOB)=CAST(? AS BLOB) "+
        "AND e.reserved_receipt_id=? AND e.reserved_result_item_id=? "+
        "AND CAST(o.capability_requirement AS BLOB)=CAST(? AS BLOB) AND CAST(o.resource_scope AS BLOB)=CAST(? AS BLOB) "+
        "AND o.effect_class=? AND o.retry_disposition=? AND COALESCE(o.idempotency_key,'')=?",
        [SqlParameter.Text(operation.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value),SqlParameter.Text(encoded),
         SqlParameter.Text(plan.implementation.toolId),SqlParameter.Text(plan.implementation.toolVersion),
         SqlParameter.Text(plan.implementation.implementationFingerprint),SqlParameter.Text(plan.implementation.schemaDigest),
         SqlParameter.Text(plan.implementation.effectiveArgumentsDigest),SqlParameter.Int64Value(Int64(plan.implementation.replayContractVersion)),
         SqlParameter.Text(encodeStoredValue(replayDispositionValue(plan.replayDisposition))),
         SqlParameter.Text("receipt-"+operation.value),SqlParameter.Text("result-"+operation.value),
         SqlParameter.Text(encodeCapabilities(plan.requiredCapabilities)),SqlParameter.Text(encodeResourceScope(plan)),
         SqlParameter.Text(storeEffectName(plan.effectClass)),SqlParameter.Text(storeRetryName(plan.retryDisposition)),SqlParameter.Text(plan.idempotencyKey)],
        "live operation changed its complete immutable effect or reserved canonical slots")
}
func withLivePolicyParentHandoff(parent:OperationId,root:OperationRootSource,run:RunId,thread:ThreadId,epoch:Int64,
    plan:NormalizedOperationPlan,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    if(plan.contextReadFacts.size!=1){throw IllegalStateException("live handoff requires its sole actual paid read") }
    withLivePolicyPlanEncoding(plan,allocate,guard,{encoded=>
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576)
            let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
            let source=match(root){case OperationRootSource.Committed(value)=>objectValue([
                ValueField("kind",textValue("committed")),ValueField("decision_id",textValue(value.decisionId.value)),
                ValueField("scoped_tool_call_id",textValue(value.scopedToolCallId.value))])
                case OperationRootSource.Direct(_)=>objectValue([ValueField("kind",textValue("user_direct"))])}
            let value=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-parent-handoff/v1")),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
                ValueField("lane_id",binding.field("lane_id").getOrThrow()),ValueField("projection_digest",textValue(plan.contextReadFacts[0].origin.projectionDigest)),
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
func requirePluginLivePolicyParentSource(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,phase!:LivePolicyParentPhase=LivePolicyParentPhase.Executing,
    progress!:?LivePolicyReadProgress=None):Unit{
    journalStreamCheck(guard)
    let state=livePolicyParentState(phase)
    livePolicyRequireOne(tx,"SELECT 1 FROM operations p JOIN runs r ON r.id=p.run_id WHERE p.id=? AND p.run_id=? "+
        "AND p.tool_call_item_id=? AND p.state=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events a WHERE a.operation_id=p.id AND a.kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(state)],
        "live parent does not own its original untouched prepared/executing operation")
    withLivePolicyPlanEncoding(parentPlan,allocate,guard,{encoded=>
        requireLivePolicyImmutableEffect(tx,parent,run,root.itemId(),parentPlan,encoded)})
    requirePluginLivePolicyCanonicalSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,true,progress:progress)
    requireLivePolicyPreparedParentMarker(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard)
    match(phase){
        case LivePolicyParentPhase.Executing=>
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'"
            let auditParams=[SqlParameter.Text(parent.value)]
            livePolicyRequireOne(tx,"SELECT 1"+auditSuffix+" AND run_id=? AND thread_id=?",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                "live parent handoff has no same original run/thread owner")
            withLivePolicyParentHandoff(parent,root,run,thread,epoch,parentPlan,allocate,guard,{expected=>
                withLivePolicyStoredValue(tx,"payload",auditSuffix,auditParams,allocate,guard,{actual=>
                    if(actual!=expected){throw IllegalStateException("live parent handoff changed its full Source/epoch/projection/plan witness")}})})
        case _=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                [SqlParameter.Text(parent.value)],"live prepared parent already has an execution handoff")
    }
    journalStreamCheck(guard)
}

// Full original StoredValue codec, paid using real same-TX byte/node counts.
// It returns Unit: actual callers compare fields only and retain no DOM.
func withLivePolicyStoredValue(tx:SqliteTransaction,column:String,suffix:String,parameters:Array<SqlParameter>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    let cell=contextReadMetadataMeasure(tx,column,suffix,parameters,allocate,guard)
    withContextReadMetadataStage([cell],allocate,guard,{=>
        let rows=tx.query("SELECT "+column+suffix,parameters)
        if(rows.size!=1 || rows[0].required(0).size!=cell.bytes){throw IllegalStateException("live source metadata extent changed")}
        consume(rows[0].required(0))})
}

func livePolicyPreparedEvidence(parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    approval:?ApprovalRequest):AgentValue{
    let pending=match(approval){case None=>nullValue();case Some(value)=>objectValue([
        ValueField("operation_id",textValue(value.operationId.value)),ValueField("call_id",textValue(value.callId)),
        ValueField("tool_name",textValue(value.toolName)),ValueField("session_id",textValue(value.sessionId)),
        ValueField("argument_hash",textValue(value.argumentHash)),ValueField("capability",textValue(storeCapabilityName(value.capability.kind))),
        ValueField("resource",textValue(value.capability.resource))])}
    objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-prepared/v1")),
        ValueField("parent_operation_id",textValue(parent.value)),ValueField("operation_id",textValue(child.value)),
        ValueField("run_id",textValue(run.value)),ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
        ValueField("parent_binding_digest",textValue(parentPlan.bindingDigest)),ValueField("child_binding_digest",textValue(childPlan.bindingDigest)),
        ValueField("request_key",textValue(requestKey)),ValueField("call_id",textValue(callId)),ValueField("approval",pending)])
}

func livePolicyPreparedTupleBytes(parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,
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

func livePolicyApprovalMatches(approval:ApprovalRequest,child:OperationId,thread:ThreadId,callId:String,
    childPlan:NormalizedOperationPlan):Bool{
    approval.operationId.value==child.value && approval.callId==callId && approval.toolName==childPlan.toolName &&
        approval.sessionId==thread.value && approval.argumentHash!="" && childPlan.requiredCapabilities.size==1 &&
        approval.capability.kind==childPlan.requiredCapabilities[0].kind && approval.capability.resource==childPlan.requiredCapabilities[0].resource &&
        canonicalAgentValue(approval.preview)==canonicalAgentValue(childPlan.canonicalArguments)
}

// New admission primitive, distinct from prepareDerivedIdentity. The
// pipeline first runs the ordinary complete policy/approval preparation with
// parentIntentPlan=None. This records only its exact prepared child; no
// parent capability, prefix reference or Native result becomes permission.
func preparePluginLivePolicyInvocationInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,call:ToolCall,approval:?ApprovalRequest,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(child.value==parent.value || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
        requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan) ||
        call.name!=HOST_PLUGIN_LIVE_EFFECT_TOOL || call.name!=childPlan.toolName ||
        call.callId!=root.callId()+":live:"+childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText() ||
        canonicalAgentValue(call.arguments)!=canonicalAgentValue(childPlan.canonicalArguments)){
        throw IllegalStateException("live child is not the precise independently prepared bounded proposal")}
    match(approval){case Some(value)=>if(!livePolicyApprovalMatches(value,child,thread,call.callId,childPlan)){
        throw IllegalStateException("live child approval tuple differs from its reviewed plan")}
        case None=>()}
    let existing=tx.query("SELECT 1 FROM derived_operation_admissions WHERE parent_operation_id=? AND request_key=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(requestKey)])
    if(!existing.isEmpty()){
        // Replay preserves the same pending operation. It cannot create a
        // new ID, reset approval, revive a terminal operation or rerun IO.
        match(approval){case Some(value)=>
            requirePluginLivePolicyPendingInTransaction(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,call.callId,value,allocate,guard)
            case None=>throw IllegalStateException("ready live-child replay requires the distinct execution ledger path")}
        return
    }
    // Only a new child uses the no-pending Source proof. The replay verifier
    // above admits Some(child) only after its full immutable tuple, prepared
    // audit and entire Known prefix have been checked against the same Root.
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,progress:Some(livePolicyReadProgressForChild(childPlan,None)))
    let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    let tupleOwner=allocate(65536)
    try{
    tupleOwner.ensureRetainedPeak(contextReadMetadataRawPeak(livePolicyPreparedTupleBytes(parent,child,run,thread,
        parentPlan,childPlan,requestKey,call.callId,approval)))
    let evidence=livePolicyPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,call.callId,approval)
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM operations WHERE id=?) "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions WHERE operation_id=? OR parent_operation_id=?)",
        [SqlParameter.Text(child.value),SqlParameter.Text(child.value),SqlParameter.Text(child.value)],
        "live child operation identity is already in use")
    let prefix=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,sequence-1,
        childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
    try{
        let _=prefix.reference()
        // Own public read links must equal the actual parent inputs. A child
        // cannot pick another Namespace/thread/lane or an earlier read alias.
        if(canonicalAgentValue(childPlan.canonicalArguments.field("read_facts").getOrThrow())!=
            canonicalAgentValue(contextReadFactLinksValue(parentPlan.contextReadFacts))){
            throw IllegalStateException("live child substituted an initial actual read input")}
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
            tx.execute("INSERT INTO operations(id,run_id,tool_call_item_id,normalized_plan,capability_requirement,"+
                "resource_scope,effect_class,retry_disposition,idempotency_key,state,revision) "+
                "VALUES (?,?,?,?,?,?,?,? ,NULL,'prepared',1)",
                [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),
                    SqlParameter.Text(encoded),SqlParameter.Text(encodeCapabilities(childPlan.requiredCapabilities)),
                    SqlParameter.Text(encodeResourceScope(childPlan)),SqlParameter.Text(storeEffectName(childPlan.effectClass)),
                    SqlParameter.Text(storeRetryName(childPlan.retryDisposition))])
            // Existing generic immutable effect/ReservedReceipt bookkeeping;
            // the new child carries no plan.contextReadFacts and is not an old
            // exact-service child or frozen payload ParentIntent.
            insertOperationEffectRecord(tx,child,run,root.itemId(),childPlan,encoded)
            tx.execute("INSERT INTO derived_operation_admissions(operation_id,parent_operation_id,call_sequence,"+
                "request_key,request_digest,child_call_id,root_operation_id,depth) VALUES (?,?,?,?,?,?,?,1)",
                [SqlParameter.Text(child.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence),
                    SqlParameter.Text(requestKey),SqlParameter.Text(childPlan.bindingDigest),SqlParameter.Text(call.callId),SqlParameter.Text(parent.value)])
            let auditOwner=allocate(65536)
            try{
                auditOwner.ensureRetainedPeak(1048576)
                let payload=encodeStoredValue(evidence)
                if(payload.size>65536){throw IllegalStateException("live exact prepared tuple exceeds its bounded metadata envelope")}
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_child_prepared_v1',?,?)",
                    [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                        SqlParameter.Text(payload),SqlParameter.Int64Value(agentUtcMillis())])
            }finally{auditOwner.close()}
            match(approval){case Some(_)=>
                tx.execute("UPDATE operations SET state='waiting_approval',revision=revision+1 WHERE id=? AND state='prepared'",
                    [SqlParameter.Text(child.value)])
                requireStoreChanged(tx,"live waiting preparation lost its operation owner")
                mirrorOperationState(tx,child,"waiting_approval")
                case None=>()}
        })
        // Any guard/Source/config/input-fence failure rolls back ALL of the
        // preparation records. No effect handoff or Receipt was emitted.
        let currentPhase=match(approval){case Some(_)=>LivePolicyChildPhase.WaitingApproval;case None=>LivePolicyChildPhase.Prepared}
        requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,
            call.callId,approval,currentPhase,allocate,guard)
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
        journalStreamCheck(guard)
    }finally{prefix.close()}
    }finally{tupleOwner.close()}
}

func requirePluginLivePolicyPendingInTransaction(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,approval:ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    if(!pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
        requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan) ||
        callId!=root.callId()+":live:"+childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText() ||
        !livePolicyApprovalMatches(approval,child,thread,callId,childPlan)){
        throw IllegalStateException("live pending child changed its exact reviewed tuple")}
    if(canonicalAgentValue(childPlan.canonicalArguments.field("read_facts").getOrThrow())!=
        canonicalAgentValue(contextReadFactLinksValue(parentPlan.contextReadFacts))){
        throw IllegalStateException("live pending child changed its actual original read links")}
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
        requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),childPlan,encoded)
        livePolicyRequireOne(tx,"SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
            "AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
            "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
            "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND o.state='waiting_approval' "+
            "AND a.parent_operation_id=? AND a.root_operation_id=? AND a.depth=1 AND a.call_sequence=? "+
            "AND a.request_key=? AND a.request_digest=? AND a.child_call_id=? AND CAST(o.normalized_plan AS BLOB)=CAST(? AS BLOB) "+
            "AND NOT EXISTS(SELECT 1 FROM approvals approved WHERE approved.operation_id=o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=o.id) "+
            "AND NOT EXISTS(SELECT 1 FROM audit_events handoff WHERE handoff.operation_id=o.id AND handoff.kind='operation_execution_handoff') "+
            "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions nested WHERE nested.parent_operation_id=o.id)",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),
                SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence),
                SqlParameter.Text(requestKey),SqlParameter.Text(childPlan.bindingDigest),SqlParameter.Text(callId),SqlParameter.Text(encoded)],
            "live pending child is not its same untouched waiting operation")})
    let tupleOwner=allocate(65536)
    try{
    tupleOwner.ensureRetainedPeak(contextReadMetadataRawPeak(livePolicyPreparedTupleBytes(parent,child,run,thread,
        parentPlan,childPlan,requestKey,callId,Some(approval))))
    let evidence=livePolicyPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,Some(approval))
    let auditSuffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_child_prepared_v1'"
    let auditParams=[SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)]
    withLivePolicyStoredValue(tx,"payload",auditSuffix,auditParams,allocate,guard,{actual=>
        if(canonicalAgentValue(decodeStoredValue(actual))!=canonicalAgentValue(evidence)){throw IllegalStateException("live pending approval evidence changed")}})
    let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
    let ledger=readPluginLivePolicyReceiptPrefixBeforePending(tx,parent,child,run,root.callId(),binding,sequence-1,
        childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
    try{let _=ledger.reference();journalStreamCheck(guard)}finally{ledger.close()}
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    }finally{tupleOwner.close()}
}

// The pending child has already been verified above. Exclude only that
// exact operation, and inspect EVERY other own child; a second pending or
// missing/Unknown/non-contiguous row cannot be hidden by this selector.
func readPluginLivePolicyReceiptPrefixBeforePending(tx:SqliteTransaction,parent:OperationId,pending:OperationId,
    run:RunId,parentCallId:String,binding:AgentValue,through:Int64,expected:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):SqliteLivePolicyReceiptPrefix{
    if(!pluginLivePolicyLedgerReferenceValid(expected,parent.value,through)){
        throw IllegalStateException("live pending prefix has no exact own count/tip")}
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(1048576)
        var cursor:?Int64=None;var ordinal:Int64=0;var tip:AgentValue=nullValue()
        while(true){
            journalStreamCheck(guard)
            let rows=match(cursor){
                case None=>tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=? AND operation_id<>? ORDER BY rowid LIMIT 1",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(pending.value)])
                case Some(last)=>tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=? AND operation_id<>? AND rowid>? ORDER BY rowid LIMIT 1",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(pending.value),SqlParameter.Int64Value(last)])}
            if(rows.isEmpty()){break}
            if(ordinal>=through){throw IllegalStateException("live pending prefix has an extra unsettled child")}
            let previous=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),ValueField("tip",tip)])
            let rowid=journalStreamInteger(rows[0].required(0));let next=ordinal+1
            tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,parentCallId,binding,next,previous,allocate,guard)
            ordinal=next;cursor=Some(rowid)
        }
        let actual=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),ValueField("tip",tip)])
        if(ordinal!=through || canonicalAgentValue(actual)!=canonicalAgentValue(expected)){
            throw IllegalStateException("live pending prefix substituted or omitted an own receipt")}
        journalStreamCheck(guard);SqliteLivePolicyReceiptPrefix(actual,owner)
    }catch(error:Exception){owner.close();throw error}
}
