package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Opt-in terminal revalidation only. All ORIGINAL Source predicates remain
// below, including actual Direct/Committed class, immutable effect, User
// origin, running/lane/epoch, full completed read and complete own prefix.
// Only marker construction/comparison shares one real lexical phase owner.
// The old Source APIs and their default ownership remain byte-for-byte.
// Full Source/read/prefix validation below shares only real paid lexical phases.

private func livePolicyTerminalParentPlanDigestOwned(plan:NormalizedOperationPlan,
    owner:LogicalJsonOwnerReservation,guard:()->Result<Unit>):String{
    // EXACT original wrapper invoice, before livePolicyPlanValue constructs
    // any wrapper. Original strings/arguments remain in their actual owner.
    var wrappers:Int64=256
    wrappers=journalStreamAdd(wrappers,plan.requiredCapabilities.size*4)
    wrappers=journalStreamAdd(wrappers,plan.resolvedPaths.size)
    wrappers=journalStreamAdd(wrappers,plan.resolvedHosts.size)
    wrappers=journalStreamAdd(wrappers,plan.relevantEnvironment.size)
    wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.flags.size)
    wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.reasons.size)
    wrappers=journalStreamAdd(wrappers,plan.contextReadFacts.size*64)
    if(wrappers>(Int64.Max-1048576)/2048){throw IllegalStateException("live plan wrapper payment overflow")}
    let retained=1048576+wrappers*2048
    owner.ensureRetainedPeak(retained);journalStreamCheck(guard)
    let value=livePolicyPlanValue(plan)
    livePolicyInputStoredDigestStreamedOwned(value,owner,guard,extraRetained:retained)
}
private func withLivePolicyTerminalParentMarker(parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,prepared:Bool,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(String,LogicalJsonOwnerReservation,Int64)->Unit):Unit{
    let owner=allocate(65536)
    try{
        let digest=livePolicyTerminalParentPlanDigestOwned(plan,owner,guard)
        // The plan wrapper is now out of scope. Only its bounded SHA survives.
        // This one owner remains paid until SQL comparison and guard complete.
        owner.ensureRetainedPeak(1048576)
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let source=match(root){case OperationRootSource.Committed(value)=>objectValue([
            ValueField("kind",textValue("committed")),ValueField("decision_id",textValue(value.decisionId.value)),
            ValueField("scoped_tool_call_id",textValue(value.scopedToolCallId.value))])
            case OperationRootSource.Direct(_)=>objectValue([ValueField("kind",textValue("user_direct"))])}
        let schema=if(prepared){"axyndra.plugin-live-policy-parent-prepared/v1"}else{"axyndra.plugin-live-policy-parent-handoff/v1"}
        let value=objectValue([ValueField("schema",textValue(schema)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
            ValueField("thread_id",textValue(thread.value)),ValueField("epoch",integerValue(epoch)),
            ValueField("lane_id",binding.field("lane_id").getOrThrow()),ValueField("projection_digest",textValue(plan.contextReadFacts[0].origin.projectionDigest)),
            ValueField("root_item_id",textValue(root.itemId().value)),ValueField("root_call_id",textValue(root.callId())),
            ValueField("parent_plan_sha256",textValue(digest)),
            ValueField("parent_binding_digest",textValue(plan.bindingDigest)),ValueField("source",source)])
        let extent=livePolicyStoredExtent(value)
        let retained=journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*4)
        owner.ensureRetainedPeak(retained)
        let expected=encodeStoredValue(value)
        if(expected.size!=extent.bytes){throw IllegalStateException("live parent handoff measurement drift")}
        consume(expected,owner,retained);journalStreamCheck(guard)
    }finally{owner.close()}
}

// Complete same-TX raw comparison with no extra phase owner. Numeric
// byte/node measurement already scanned the ORIGINAL full grammar and EOF
// under its own owner, which was closed before expected encoding began.
// The caller's real owner now prepays expected + actual raw/scanner/DOM peak
// before SELECT. Original meter dynamic asks cannot exceed this complete
// bytes*8 + nodes*512 invoice; no fake allocator/close/early refund is used.
func requireLivePolicyTerminalStoredCell(tx:SqliteTransaction,column:String,suffix:String,
    parameters:Array<SqlParameter>,cell:ContextReadMetadataCell,expected:String,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataPeak(cell.bytes,cell.nodes)))
    journalStreamCheck(guard)
    let rows=tx.query("SELECT "+column+suffix,parameters)
    if(rows.size!=1 || rows[0].required(0).size!=cell.bytes){throw IllegalStateException("live source metadata extent changed")}
    let raw=rows[0].required(0);let meter=StoredValuePaymentMeter(raw,owner);let actualNodes=meter.complete()
    if(actualNodes!=cell.nodes || raw!=expected){
        throw IllegalStateException("live parent marker changed its complete original Source/epoch/projection/plan witness")}
    journalStreamCheck(guard)
}
private func requireLivePolicyParentMarkerStreamed(tx:SqliteTransaction,parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,prepared:Bool):Unit{
    if(plan.contextReadFacts.size!=1){throw IllegalStateException("live handoff requires its sole actual paid read")}
    let kind=if(prepared){"plugin_live_parent_prepared_v1"}else{"operation_execution_handoff"}
    let suffix=" FROM audit_events WHERE operation_id=? AND kind=?"
    let parameters=[SqlParameter.Text(parent.value),SqlParameter.Text(kind)]
    livePolicyRequireOne(tx,"SELECT 1"+suffix+" AND run_id=? AND thread_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(kind),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
        "live parent marker has no unique same original run/thread owner")
    let cell=contextReadMetadataMeasure(tx,"payload",suffix,parameters,allocate,guard)
    withLivePolicyTerminalParentMarker(parent,root,run,thread,epoch,plan,prepared,allocate,guard,{expected,owner,retained=>
        requireLivePolicyTerminalStoredCell(tx,"payload",suffix,parameters,cell,expected,owner,retained,guard)})
    journalStreamCheck(guard)
}

func requirePluginLivePolicyParentSourceStreamed(tx:SqliteTransaction,root:OperationRootSource,
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
    requirePluginLivePolicyCanonicalSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,true,progress:progress)
    requireLivePolicyParentMarkerStreamed(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard,true)
    match(phase){
        case LivePolicyParentPhase.Executing=>
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'"
            let auditParams=[SqlParameter.Text(parent.value)]
            livePolicyRequireOne(tx,"SELECT 1"+auditSuffix+" AND run_id=? AND thread_id=?",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                "live parent handoff has no same original run/thread owner")
            requireLivePolicyParentMarkerStreamed(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard,false)
        case _=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                [SqlParameter.Text(parent.value)],"live prepared parent already has an execution handoff")
    }
    journalStreamCheck(guard)
}

private func withLivePolicyTerminalModelBlockEncodingOwned(value:ModelBlock,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(String,LogicalJsonOwnerReservation,Int64)->Unit):Unit{
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
        let retained=journalStreamAdd(contextReadMetadataRawPeak(extent.bytes),1048576)
        owner.ensureRetainedPeak(retained)
        journalStreamCheck(guard);let encoded=encodeStoredModelBlock(value)
        if(encoded.size!=extent.bytes){throw IllegalStateException("original model block framing measurement drift")}
        consume(encoded,owner,retained);journalStreamCheck(guard)
    }finally{owner.close()}
}

func requirePluginLivePolicyCanonicalSourceStreamed(tx:SqliteTransaction,root:OperationRootSource,
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
            withLivePolicyTerminalModelBlockEncodingOwned(source.block,allocate,guard,{expected,phaseOwner,retained=>
                withLivePolicyStoredValueOwned(tx,"b.payload",decisionSuffix,decisionParams,allocate,guard,phaseOwner,retained,{actual=>
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
        case None=>requirePluginLivePolicyReadInputsOwned(tx,parent,run,root.itemId(),root.toolName(),binding,parentPlan.contextReadFacts,allocate,guard)
        case Some(value)=>match(value.pending){
            case None=>requirePluginLivePolicyCausalReadInputsOwned(tx,parent,run,root.itemId(),root.toolName(),binding,
                parentPlan.contextReadFacts,value.through,value.reference,allocate,guard)
            case Some(actual)=>requirePluginLivePolicyCausalReadInputsBeforePendingOwned(tx,parent,run,root.itemId(),root.toolName(),binding,
                parentPlan.contextReadFacts,value.through,value.reference,actual,allocate,guard)}}
    journalStreamCheck(guard)
}
