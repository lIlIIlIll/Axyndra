package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// A canonical ToolResult's ignored body still receives the entire original
// StoredValue/UTF8/frame/duplicate/depth/EOF scan. This flag is used only by
// the neutral-commit proof. The old paid reader remains the default branch.
func eachContextReadToolResultKnownCommitOwned(tx:SqliteTransaction,thread:String,turn:String,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>,
    consume:(ThreadItemContent)->Unit):Unit{
    var after:?Int64=None
    while(true){
        journalStreamCheck(guard)
        let found=match(after){case None=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? "+
            "AND kind='tool_result' ORDER BY rowid LIMIT 1",[SqlParameter.Text(thread),SqlParameter.Text(turn)])
            case Some(last)=>tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? "+
                "AND kind='tool_result' AND rowid>? ORDER BY rowid LIMIT 1",
                [SqlParameter.Text(thread),SqlParameter.Text(turn),SqlParameter.Int64Value(last)])}
        if(found.isEmpty()){break}
        let rowid=journalStreamInteger(found[0].required(0))
        let scanner=LiveKnownStoredStream(tx,"payload"," FROM items WHERE rowid=? AND thread_id=? AND turn_id=? AND kind='tool_result'",
            [SqlParameter.Int64Value(rowid),SqlParameter.Text(thread),SqlParameter.Text(turn)],owner,retained,guard)
        let _=scanner.complete();let header=scanner.header()
        if(httpIntentText(header,"kind")!="tool_result"){
            throw IllegalStateException("declared canonical result is not a Stored ToolResult")}
        // Same neutral header as the original consumptionHeader: result is
        // syntax-checked but not retained; a Text receipt stays Text.
        let receipt=header.field("receipt_id").getOrThrow()
        let value=objectValue([ValueField("kind",header.field("kind").getOrThrow()),
            ValueField("call_id",header.field("call_id").getOrThrow()),
            ValueField("operation_id",header.field("operation_id").getOrThrow()),
            ValueField("receipt_id",if(receipt.unifiedKind==ValueKind.Text){textValue("")}else{receipt}),
            ValueField("result",nullValue()),ValueField("is_error",header.field("is_error").getOrThrow())])
        consume(decodeStoredThreadContent(encodeStoredValue(value)));after=Some(rowid)
    }
    journalStreamCheck(guard)
}

// Same actual Source reader, private neutral-commit data verification only.
// The caller owns its held Parent plan; payment adds that retained invoice.
// No Root/Source object is made and a borrower never closes/refunds owner.
func livePolicyRequireCausalReadInputsForKnownParentOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,pending:?OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,retained:Int64):Unit{
    journalStreamCheck(guard)
    if(through<0 || !pluginLivePolicyLedgerReferenceValid(expectedPrefix,parent.value,through)){
        throw IllegalStateException("causal input has no exact own parent/count/tip")}
    // The opted-in latest stream carries precisely one original Tool read.
    // Empty input and parentless provider reads need a separate contract.
    if(links.size!=1 || !validatePluginDocumentBinding(binding).isOk() ||
        httpIntentText(binding,"run_id")!=run.value || httpIntentText(binding,"contribution")!=parentTool ||
        links[0].runId.value!=run.value){
        throw IllegalStateException("live policy requires its sole complete original Tool read input")}
    let link=links[0]
    let payment=try{ContextReadCompletedMetadataPayment(tx,link,allocate,guard,phaseOwner:Some(owner),extraRetained:journalStreamAdd(retained,1048576),knownCommitStreamingResults:true)}
        catch(error:Exception){throw error}
    try{
        let candidate=payment.plan()
        if(!pluginDocumentLatestJournalStreamReadAuthority(candidate) ||
            pluginDocumentContextLatestJournalStreamReadAuthority(candidate)){
            throw IllegalStateException("live policy input cannot reinterpret a parentless or older read dialect")}
        let fact=payment.fact()
        if(fact.runId.value!=run.value || fact.origin.parentCallItemId!=parentItem.value ||
            documentPayloadParentOperation(fact).value!=parent.value){
            throw IllegalStateException("live policy input belongs to another actual canonical parent")}
        payment.withParent(parent,run,parentItem,{paid=>
            match(decodeStoredThreadContent(paid.row.required(0))){
                case ThreadItemContent.ToolCall(id,name,_)=>
                    if(id.value!=httpIntentText(binding,"parent_call_id") || name!=parentTool){
                        throw IllegalStateException("live policy input changed its actual parent call or tool")}
                case _=>throw IllegalStateException("live policy input parent is not its canonical call")
            }
        })
        // Reuse full original fact/link, Source, origin, current projection,
        // order and UserDirect/Committed parent checks. Original result bodies
        // still reach framing EOF one at a time, without an aggregate turn DOM.
        let data=fact.output()
        let read=latestJournalInputRequireFact(tx,link,binding,data,payment)
        let key=httpIntentText(read.canonicalArguments,"key")
        let backend=match(tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)){
            case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){
                case Some(actual)=>actual
                case None=>throw IllegalStateException("live policy input requires its actual opted-in latest backend")}
            case None=>throw IllegalStateException("live policy input lost its actual latest backend")
        }
        // This captured witness checks only fixed immutable operator files.
        // It does not acquire Host/Runtime locks while the SQL owner is held.
        let configurationCurrent=backend.capture(read)
        let current={=>
            journalStreamCheck(guard);journalStreamCheck(configurationCurrent)
            payment.current(binding)
        }
        journalStreamCheck(current)
        let _=payment.withBorrowedObservation({phaseOwner,retained=>
            livePolicyRequireCausalObservationOwned(tx,parent,run,link,read,data,backend,through,
                expectedPrefix,pending,allocate,current,phaseOwner,retained)
        })
        journalStreamCheck(current)
    }finally{payment.close()}
}


// Independent opt-in Known canonical commit proof; old Source APIs remain whole.

func liveKnownParentPlanDigestOwned(plan:NormalizedOperationPlan,
    owner:LogicalJsonOwnerReservation,guard:()->Result<Unit>,externalRetained:Int64):String{
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
    let retained=journalStreamAdd(externalRetained,1048576+wrappers*2048)
    owner.ensureRetainedPeak(retained);journalStreamCheck(guard)
    let value=livePolicyPlanValue(plan)
    livePolicyInputStoredDigestStreamedOwned(value,owner,guard,extraRetained:retained)
}

func withLiveKnownParentMarkerOwned(parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,prepared:Bool,
    owner:LogicalJsonOwnerReservation,externalRetained:Int64,guard:()->Result<Unit>,
    consume:(String,LogicalJsonOwnerReservation,Int64)->Unit):Unit{
    try{
        let digest=liveKnownParentPlanDigestOwned(plan,owner,guard,externalRetained)
        // The plan wrapper is now out of scope. Only its bounded SHA survives.
        // This one owner remains paid until SQL comparison and guard complete.
        owner.ensureRetainedPeak(journalStreamAdd(externalRetained,1048576))
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
        let retained=journalStreamAdd(externalRetained,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*4))
        owner.ensureRetainedPeak(retained)
        let expected=encodeStoredValue(value)
        if(expected.size!=extent.bytes){throw IllegalStateException("live parent handoff measurement drift")}
        consume(expected,owner,retained);journalStreamCheck(guard)
    }finally{}
}

func requireLiveKnownParentMarkerOwned(tx:SqliteTransaction,parent:OperationId,root:OperationRootSource,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,prepared:Bool,owner:LogicalJsonOwnerReservation,retained:Int64):Unit{
    if(plan.contextReadFacts.size!=1){throw IllegalStateException("live handoff requires its sole actual paid read")}
    let kind=if(prepared){"plugin_live_parent_prepared_v1"}else{"operation_execution_handoff"}
    let suffix=" FROM audit_events WHERE operation_id=? AND kind=?"
    let parameters=[SqlParameter.Text(parent.value),SqlParameter.Text(kind)]
    livePolicyRequireOne(tx,"SELECT 1"+suffix+" AND run_id=? AND thread_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(kind),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
        "live parent marker has no unique same original run/thread owner")
    let cell=contextReadMetadataMeasureOwned(tx,"payload",suffix,parameters,owner,retained,guard)
    withLiveKnownParentMarkerOwned(parent,root,run,thread,epoch,plan,prepared,owner,retained,guard,{expected,owner,retained=>
        requireLivePolicyTerminalStoredCell(tx,"payload",suffix,parameters,cell,expected,owner,retained,guard)})
    journalStreamCheck(guard)
}

func withLiveKnownPlanEncodingOwned(plan:NormalizedOperationPlan,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>,
    consume:(String,Int64)->Unit):Unit{
    var wrappers:Int64=256
    wrappers=journalStreamAdd(wrappers,plan.requiredCapabilities.size*4)
    wrappers=journalStreamAdd(wrappers,plan.resolvedPaths.size)
    wrappers=journalStreamAdd(wrappers,plan.resolvedHosts.size)
    wrappers=journalStreamAdd(wrappers,plan.relevantEnvironment.size)
    wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.flags.size)
    wrappers=journalStreamAdd(wrappers,plan.approvalMetadata.assessment.reasons.size)
    wrappers=journalStreamAdd(wrappers,plan.contextReadFacts.size*64)
    if(wrappers>(Int64.Max-1048576)/2048){throw IllegalStateException("known parent plan wrapper payment overflow")}
    let wrapperPeak=journalStreamAdd(retained,1048576+wrappers*2048)
    owner.ensureRetainedPeak(wrapperPeak);journalStreamCheck(guard)
    let value=livePolicyPlanValue(plan);let extent=livePolicyStoredExtent(value)
    if(extent.bytes>8388608 || extent.bytes>(Int64.Max-wrapperPeak)/12){
        throw IllegalStateException("known parent plan exceeds its original codec/payment")}
    let peak=journalStreamAdd(wrapperPeak,extent.bytes*12)
    owner.ensureRetainedPeak(peak)
    let encoded=encodeOperationPlan(plan)
    if(encoded.size!=extent.bytes){throw IllegalStateException("known parent original plan framing drift")}
    let meter=StoredValuePaymentMeter(encoded,owner,extraRetained:wrapperPeak);let _=meter.complete()
    consume(encoded,peak);journalStreamCheck(guard)
}


func withLiveKnownModelBlockEncodingOwned(value:ModelBlock,owner:LogicalJsonOwnerReservation,externalRetained:Int64,
    guard:()->Result<Unit>,consume:(String,LogicalJsonOwnerReservation,Int64)->Unit):Unit{
    try{
        owner.ensureRetainedPeak(journalStreamAdd(externalRetained,1048576))
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
        let retained=journalStreamAdd(externalRetained,journalStreamAdd(contextReadMetadataRawPeak(extent.bytes),1048576))
        owner.ensureRetainedPeak(retained)
        journalStreamCheck(guard);let encoded=encodeStoredModelBlock(value)
        if(encoded.size!=extent.bytes){throw IllegalStateException("original model block framing measurement drift")}
        consume(encoded,owner,retained);journalStreamCheck(guard)
    }finally{}
}

func requireLiveKnownCanonicalSourceOwned(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,admitted:Bool,owner:LogicalJsonOwnerReservation,retained:Int64,progress!:?LivePolicyReadProgress=None):Unit{
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
    withLivePolicyStoredValueOwned(tx,"payload",cellSuffix,cellParams,allocate,guard,owner,retained,{value=>
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
            withLivePolicyStoredValueOwned(tx,"provenance",cellSuffix,cellParams,allocate,guard,owner,retained,{value=>
                let provenance=decodeStoredProvenance(value)
                if(provenance.source=="direct_tool" || provenance.runId.isNone() ||
                    provenance.runId.getOrThrow().value!=run.value || provenance.operationId.isSome() ||
                    !sameDirectCallOrigin(effectiveDirectCallOrigin(provenance),DirectCallOrigin.UserDirect)){
                    throw IllegalStateException("live model source changed its original canonical provenance")}})
            // Reuse the ORIGINAL encoder and the private attested block. Its
            // wrappers and complete retained strings are paid before encoding;
            // actual SQL block bytes are independently paid before copying.
            withLiveKnownModelBlockEncodingOwned(source.block,owner,retained,guard,{expected,phaseOwner,retained=>
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
            withLivePolicyStoredValueOwned(tx,"provenance",cellSuffix,cellParams,allocate,guard,owner,retained,{value=>
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
            withLivePolicyStoredValueOwned(tx,"initial.provenance",initialSuffix,initialParams,allocate,guard,owner,retained,{value=>
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
    withLivePolicyStoredValueOwned(tx,"initial.provenance",initialSuffix,[SqlParameter.Text(run.value)],allocate,guard,owner,retained,{value=>
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
        case None=>throw IllegalStateException("known canonical commit requires its complete terminal own prefix")
        case Some(value)=>match(value.pending){
            case None=>livePolicyRequireCausalReadInputsForKnownParentOwned(tx,parent,run,root.itemId(),root.toolName(),binding,
                parentPlan.contextReadFacts,value.through,value.reference,None<OperationId>,allocate,guard,owner,retained)
            case Some(actual)=>throw IllegalStateException("known canonical commit cannot omit an unsettled own child")}}
    journalStreamCheck(guard)
}

func requirePluginLivePolicyParentSourceForKnownCommitOwned(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,retained:Int64,
    phase!:LivePolicyParentPhase=LivePolicyParentPhase.Executing,progress!:?LivePolicyReadProgress=None):Unit{
    journalStreamCheck(guard)
    let state=livePolicyParentState(phase)
    livePolicyRequireOne(tx,"SELECT 1 FROM operations p JOIN runs r ON r.id=p.run_id WHERE p.id=? AND p.run_id=? "+
        "AND p.tool_call_item_id=? AND p.state=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts receipt WHERE receipt.operation_id=p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items result WHERE result.id='result-'||p.id) "+
        "AND NOT EXISTS(SELECT 1 FROM audit_events a WHERE a.operation_id=p.id AND a.kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value),SqlParameter.Text(state)],
        "live parent does not own its original untouched prepared/executing operation")
    withLiveKnownPlanEncodingOwned(parentPlan,owner,retained,guard,{encoded,_=>
        requireLivePolicyImmutableEffect(tx,parent,run,root.itemId(),parentPlan,encoded)})
    requireLiveKnownCanonicalSourceOwned(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,true,owner,retained,progress:progress)
    requireLiveKnownParentMarkerOwned(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard,true,owner,retained)
    match(phase){
        case LivePolicyParentPhase.Executing=>
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'"
            let auditParams=[SqlParameter.Text(parent.value)]
            livePolicyRequireOne(tx,"SELECT 1"+auditSuffix+" AND run_id=? AND thread_id=?",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                "live parent handoff has no same original run/thread owner")
            requireLiveKnownParentMarkerOwned(tx,parent,root,run,thread,epoch,parentPlan,allocate,guard,false,owner,retained)
        case _=>
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                [SqlParameter.Text(parent.value)],"live prepared parent already has an execution handoff")
    }
    journalStreamCheck(guard)
}
