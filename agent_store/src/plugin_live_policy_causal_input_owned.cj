package agent_store

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Same existing transaction only; returns no Source, grant, admission or
// private journal fence. The actual caller retains full Parent/child/current
// authority checks and never presents this relationship as an approval.
func requirePluginLivePolicyCausalReadInputsOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit {
    livePolicyRequireCausalReadInputsOwned(tx,parent,run,parentItem,parentTool,binding,links,
        through,expectedPrefix,None,allocate,guard)
}

func requirePluginLivePolicyCausalReadInputsBeforePendingOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,actualPending:OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit {
    livePolicyRequireCausalReadInputsOwned(tx,parent,run,parentItem,parentTool,binding,links,
        through,expectedPrefix,Some(actualPending),allocate,guard)
}

func livePolicyRequireCausalReadInputsOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,pending:?OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
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
    let owner=allocate(65536)
    let payment=try{ContextReadCompletedMetadataPayment(tx,link,allocate,guard,phaseOwner:Some(owner),extraRetained:1048576)}
        catch(error:Exception){owner.close();throw error}
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
    }finally{payment.close();owner.close()}
}

func livePolicyRequireCausalObservationOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,link:ContextReadFactLink,
    plan:NormalizedOperationPlan,data:AgentValue,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    through:Int64,expectedPrefix:AgentValue,pending:?OperationId,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,retained:Int64):PluginDocumentLatestJournalStreamReference{
    let request=plan.canonicalArguments;let binding=request.field("binding").getOrThrow()
    let rows=tx.query("SELECT thread_id,payload FROM audit_events WHERE operation_id=? AND run_id=? "+
        "AND kind='plugin_document_latest_journal_observed' LIMIT 2",[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
    if(rows.size!=1 || rows[0].required(0)!=httpIntentText(binding,"thread_id")){
        throw IllegalStateException("journal input lost its sole actual observed stream")}
    let value=decodeStoredValue(rows[0].required(1));let document=data.field("documents").getOrThrow().items[0]
    if(!httpIntentExactFields(value,["schema","thread_id","lane_id","run_id","read_operation_id","read_item_id","plan_sha256",
        "binding","projection_digest","access_policy_digest","view_policy_digest","key","revision","epoch","private_event_fence","stream"]) ||
        httpIntentText(value,"schema")!="axyndra.journal-stream-observation/v3" ||
        httpIntentText(value,"thread_id")!=httpIntentText(binding,"thread_id") || httpIntentText(value,"lane_id")!=httpIntentText(binding,"lane_id") ||
        httpIntentText(value,"run_id")!=link.runId.value || httpIntentText(value,"read_operation_id")!=link.operationId.value ||
        httpIntentText(value,"read_item_id")!=link.sourceItemId.value ||
        httpIntentText(value,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(plan)) ||
        canonicalAgentValue(value.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        httpIntentText(value,"projection_digest")!=httpIntentText(request,"projection_digest") ||
        httpIntentText(value,"access_policy_digest")!=httpIntentText(request,"access_policy_digest") ||
        httpIntentText(value,"view_policy_digest")!=httpIntentText(request,"view_policy_digest") ||
        httpIntentText(value,"key")!=httpIntentText(request,"key") ||
        value.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
        value.field("revision").getOrThrow().asNumberText()!=document.field("revision").getOrThrow().asNumberText() ||
        canonicalAgentValue(value.field("stream").getOrThrow())!=canonicalAgentValue(document.field("stream").getOrThrow())){
        throw IllegalStateException("journal observation no longer matches all original canonical fields")}
    let reference=parsePluginDocumentLatestJournalStreamReference(document.field("stream").getOrThrow()).value().getOrThrow()
    let metadata=tx.query("SELECT length(CAST(metadata AS BLOB)),length(CAST(mime AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=? LIMIT 2",
        [SqlParameter.Text(reference.digest)])
    if(metadata.size!=1 || journalStreamInteger(metadata[0].required(0))<1 || journalStreamInteger(metadata[0].required(0))>4096 ||
        journalStreamInteger(metadata[0].required(1))>128 || journalStreamInteger(metadata[0].required(2))>256){
        throw IllegalStateException("journal input artifact metadata changed its fixed original extent")}
    requireLatestJournalStreamArtifactMetadata(tx,reference);journalStreamCheck(guard)
    // Original observation/artifact/body/source fields remain exact above.
    // The new family additionally proves every own known successor, then
    // compares the current full private fence to that actual terminal tip.
    livePolicyRequireCausalJournalPrefixOwned(tx,parent,run,binding,link,httpIntentText(request,"key"),
        httpIntentText(value,"private_event_fence"),
        livePolicyCausalPositiveRevision(document.field("revision").getOrThrow()),through,expectedPrefix,pending,
        backend,allocate,guard,owner,retained)
    reference
}

// Constant holder references follow the existing paid Store callback pattern.
// Only fixed bounded fields survive their original charged callback stage.
class LivePolicyCausalOwnedEffectState { var appendsJournal=false }
class LivePolicyCausalOwnedReceiptState { var afterFence="";var afterRevision:Int64=0 }

// No child is hidden by the ordinary path. BeforePending is used only after
// the caller's actual immutable child tuple check; this independent relation
// check still requires its unique own next child and no terminal Receipt.
func livePolicyRequireCausalExcludedChildOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentCall:String,binding:AgentValue,through:Int64,expected:AgentValue,pending:OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):Unit {
    let next=journalStreamAdd(through,1)
    let suffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=o.run_id AND parent.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
        "WHERE a.parent_operation_id=? AND o.id=? AND o.run_id=? AND a.root_operation_id=? "+
        "AND CAST(a.call_sequence AS BLOB)=CAST(? AS BLOB) AND CAST(a.depth AS BLOB)=CAST('1' AS BLOB) "+
        "AND a.request_key=? AND a.child_call_id=? AND o.state IN ('prepared','waiting_approval','executing') "+
        "AND NOT EXISTS(SELECT 1 FROM operation_receipts r WHERE r.operation_id=o.id) "+
        "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
        "AND CAST(n.call_sequence AS BLOB)=CAST(? AS BLOB))=1"
    let args=[SqlParameter.Text(parent.value),SqlParameter.Text(pending.value),SqlParameter.Text(run.value),
        SqlParameter.Text(parent.value),SqlParameter.Text(next.toString()),
        SqlParameter.Text("live-policy:"+parentCall+":"+next.toString()),
        SqlParameter.Text(parentCall+":live:"+next.toString()),SqlParameter.Text(next.toString())]
    journalStreamCheck(guard)
    withLivePolicyStoredValueOwned(tx,"o.normalized_plan",suffix,args,allocate,guard,owner,extraRetained,{encoded=>
        let plan=decodeOperationPlan(encoded)
        if(!isPluginLivePolicyStreamingChildPlan(plan) ||
            plan.canonicalArguments.field("sequence").getOrThrow().asNumberText()!=next.toString() ||
            canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            canonicalAgentValue(plan.canonicalArguments.field("prior_receipts").getOrThrow())!=canonicalAgentValue(expected)){
            throw IllegalStateException("causal input cannot exclude another or terminal child")}
        let digestArgs=ArrayList<SqlParameter>()
        for(value in args){digestArgs.add(value)}
        digestArgs.add(SqlParameter.Text(plan.bindingDigest))
        if(tx.query("SELECT 1"+suffix+" AND CAST(a.request_digest AS BLOB)=CAST(? AS BLOB)",digestArgs.toArray()).size!=1){
            throw IllegalStateException("causal excluded child lost its actual normalized request digest")}
    })
    journalStreamCheck(guard)
}

func livePolicyRequireCausalJournalPrefixOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    binding:AgentValue,link:ContextReadFactLink,key:String,initialFence:String,initialRevision:Int64,
    through:Int64,expected:AgentValue,pending:?OperationId,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):Unit {
    if(through<0 || !httpIntentDigest(initialFence) || initialRevision<1 ||
        !pluginLivePolicyLedgerReferenceValid(expected,parent.value,through)){
        throw IllegalStateException("causal input has no exact original observation and own prefix")}
    let parentCall=httpIntentText(binding,"parent_call_id")
    match(pending){case Some(actual)=>livePolicyRequireCausalExcludedChildOwned(tx,parent,run,parentCall,binding,
        through,expected,actual,allocate,guard,owner,extraRetained);case None=>()}
    // Cursor, current/previous bounded tip and scalar digests stay paid for
    // this complete Unit scope in the existing Source/observation owner.
    let prefixRetained=journalStreamAdd(extraRetained,1048576)
    try {
        owner.ensureRetainedPeak(prefixRetained)
        let bindingDigest=modelPolicySha256Text(canonicalAgentValue(binding))
        let readDigest=modelPolicySha256Text(canonicalAgentValue(link.toValue()))
        var cursor:?Int64=None;var ordinal:Int64=0;var tip:AgentValue=nullValue()
        var fence=initialFence;var revision=initialRevision
        while(true){
            journalStreamCheck(guard)
            let ignore=match(pending){case Some(actual)=>" AND operation_id<>?";case None=>""}
            let args=ArrayList<SqlParameter>();args.add(SqlParameter.Text(parent.value))
            match(pending){case Some(actual)=>args.add(SqlParameter.Text(actual.value));case None=>()}
            let after=match(cursor){case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND rowid>?";case None=>""}
            let rows=tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=?"+
                ignore+after+" ORDER BY rowid LIMIT 1",args.toArray())
            if(rows.isEmpty()){break}
            if(ordinal>=through){throw IllegalStateException("causal input has an extra or unsettled own child")}
            let rowid=journalStreamInteger(rows[0].required(0));let next=journalStreamAdd(ordinal,1)
            // The original paid receipt reader validates the plan sequence.
            // Independently bind the actual admission's canonical sequence,
            // including unique ownership, without loading another plan DOM.
            let sequenceRows=tx.query("SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=? "+
                "AND CAST(a.call_sequence AS BLOB)=CAST(? AS BLOB) "+
                "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
                "AND CAST(n.call_sequence AS BLOB)=CAST(? AS BLOB))=1",
                [SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),
                    SqlParameter.Text(next.toString()),SqlParameter.Text(next.toString())])
            if(sequenceRows.size!=1){throw IllegalStateException("causal input changed its unique actual own admission sequence")}
            let previous=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),
                ValueField("tip",tip)])
            // This original paid reader checks every full own plan/detail/EOF,
            // exact previous prefix, reserved Receipt and no-effect witness.
            let actualTip=readPluginLivePolicyReceiptRowOwned(tx,rowid,parent,run,parentCall,binding,next,previous,allocate,guard,owner,prefixRetained)
            let operation=httpIntentText(actualTip,"operation_id")
            let childSuffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=? AND o.id=?"
            let childArgs=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(operation)]
            let effectState=LivePolicyCausalOwnedEffectState()
            withLivePolicyStoredValueOwned(tx,"o.normalized_plan",childSuffix,childArgs,allocate,guard,owner,prefixRetained,{encoded=>
                let plan=decodeOperationPlan(encoded);let effect=plan.canonicalArguments.field("effect").getOrThrow()
                effectState.appendsJournal=httpIntentText(effect,"kind")=="row_journal.append"
                if(modelPolicySha256Text(encoded)!=httpIntentText(actualTip,"plan_sha256") ||
                    (effectState.appendsJournal && httpIntentText(effect,"key")!=key)){
                    throw IllegalStateException("causal input effect changed its paid plan or read journal key")}
            })
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_journal_causal_v1'"
            let auditArgs=[SqlParameter.Text(operation),SqlParameter.Text(run.value),SqlParameter.Text(httpIntentText(binding,"thread_id"))]
            let beforeFence=fence;let beforeRevision=revision
            let receiptState=LivePolicyCausalOwnedReceiptState()
            withLivePolicyStoredValueOwned(tx,"payload",auditSuffix,auditArgs,allocate,guard,owner,prefixRetained,{encoded=>
                let value=decodeStoredValue(encoded)
                if(!httpIntentExactFields(value,["schema","parent_operation_id","run_id","thread_id","lane_id","epoch",
                    "binding_digest","read_fact_digest","sequence","operation_id","receipt_id","plan_sha256","key",
                    "before_fence","after_fence","before_revision","after_revision"]) ||
                    httpIntentText(value,"schema")!="axyndra.plugin-live-journal-causal/v1" ||
                    httpIntentText(value,"parent_operation_id")!=parent.value || httpIntentText(value,"run_id")!=run.value ||
                    httpIntentText(value,"thread_id")!=httpIntentText(binding,"thread_id") ||
                    httpIntentText(value,"lane_id")!=httpIntentText(binding,"lane_id") ||
                    value.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
                    httpIntentText(value,"binding_digest")!=bindingDigest || httpIntentText(value,"read_fact_digest")!=readDigest ||
                    value.field("sequence").getOrThrow().asNumberText()!=next.toString() ||
                    httpIntentText(value,"operation_id")!=operation ||
                    httpIntentText(value,"receipt_id")!=httpIntentText(actualTip,"receipt_id") ||
                    httpIntentText(value,"plan_sha256")!=httpIntentText(actualTip,"plan_sha256") ||
                    httpIntentText(value,"key")!=key || httpIntentText(value,"before_fence")!=beforeFence ||
                    livePolicyCausalPositiveRevision(value.field("before_revision").getOrThrow())!=beforeRevision ||
                    !httpIntentDigest(httpIntentText(value,"after_fence"))){
                    throw IllegalStateException("causal input lost its unique complete own before/after witness")}
                let proposed=livePolicyCausalPositiveRevision(value.field("after_revision").getOrThrow())
                let completed=httpIntentText(actualTip,"outcome")=="completed"
                if(completed && effectState.appendsJournal){
                    if(proposed<=beforeRevision){throw IllegalStateException("own completed append did not advance its actual journal")}
                }else if(proposed!=beforeRevision || httpIntentText(value,"after_fence")!=beforeFence){
                    throw IllegalStateException("known no-effect or filesystem child cannot advance journal history")}
                // Copy only fixed validated64 bytes while this paid phase is
                // held; no large SQL/decoded witness remains with the cursor.
                receiptState.afterFence=String.fromUtf8(httpIntentText(value,"after_fence").toArray());receiptState.afterRevision=proposed
            })
            fence=receiptState.afterFence;revision=receiptState.afterRevision;tip=actualTip;ordinal=next;cursor=Some(rowid)
        }
        let actual=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),ValueField("tip",tip)])
        if(ordinal!=through || canonicalAgentValue(actual)!=canonicalAgentValue(expected)){
            throw IllegalStateException("causal input omitted or substituted an own receipt prefix")}
        journalStreamCheck(guard)
        let finalFence=fence;let finalRevision=revision
        tx.withBackendAllocationPhase({=>
            let current=backend.fullOwned(tx,guard,owner,prefixRetained)
            if(current.digest!=finalFence || journalStreamAdd(current.events,1)!=finalRevision){
                throw IllegalStateException("causal input current full private event fence changed outside its own known chain")}
            journalStreamCheck(guard)})
    }finally{}
}


// Original complete StoredValue extent/grammar/EOF under its own measured
// raw phase, released before the existing owner receives the actual raw/DOM
// phase. Returned Unit ensures no child plan/audit body escapes this scope.
func withLivePolicyStoredValueOwned(tx:SqliteTransaction,column:String,suffix:String,parameters:Array<SqlParameter>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,
    extraRetained:Int64,consume:(String)->Unit):Unit{
    let cell=contextReadMetadataMeasureOwned(tx,column,suffix,parameters,owner,extraRetained,guard)
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataPeak(cell.bytes,cell.nodes)))
    journalStreamCheck(guard)
    let rows=tx.query("SELECT "+column+suffix,parameters)
    if(rows.size!=1 || rows[0].required(0).size!=cell.bytes){throw IllegalStateException("live source metadata extent changed")}
    let raw=rows[0].required(0);let meter=StoredValuePaymentMeter(raw,owner,extraRetained:extraRetained)
    if(meter.complete()!=cell.nodes){throw IllegalStateException("live source metadata node extent changed")}
    consume(raw);journalStreamCheck(guard)
}

func readPluginLivePolicyReceiptRowOwned(tx:SqliteTransaction,rowid:Int64,parentOperation:OperationId,run:RunId,
    parentCallId:String,binding:AgentValue,sequence:Int64,previous:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):AgentValue{
    let parameters=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parentOperation.value),SqlParameter.Text(run.value)]
    let suffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=o.run_id AND parent.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state "+
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id "+
        "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=?"
    journalStreamCheck(guard)
    // Only numeric extents materialize before the raw owner. IDs/request keys
    // are measured too, including state/outcome/depth. SQLite is not assumed
    // to contain short legal TEXT or a legal depth scalar before validation.
    let lengths=tx.query("SELECT length(CAST(o.id AS BLOB)),length(CAST(a.request_key AS BLOB)),"+
        "length(CAST(a.request_digest AS BLOB)),length(CAST(a.child_call_id AS BLOB)),"+
        "length(CAST(a.root_operation_id AS BLOB)),length(CAST(receipt.id AS BLOB)),"+
        "length(CAST(o.state AS BLOB)),length(CAST(receipt.outcome AS BLOB)),length(CAST(a.depth AS BLOB))"+suffix,parameters)
    if(lengths.size!=1){throw IllegalStateException("live prefix has no unique reserved receipt/effect/state")}
    let smallBytes=livePolicyLedgerCopiedHeaderBytes(lengths[0])
    let small=owner
    try{
        small.ensureRetainedPeak(journalStreamAdd(extraRetained,contextReadMetadataRawPeak(smallBytes)))
        let headers=tx.query("SELECT o.id,a.request_key,a.request_digest,a.child_call_id,a.root_operation_id,"+
            "receipt.id,o.state,receipt.outcome,a.depth"+suffix,parameters)
        if(headers.size!=1){throw IllegalStateException("live prefix metadata changed")}
        let header=headers[0]
        for(index in 0..9){if(header.required(index).size!=journalStreamInteger(lengths[0].required(index))){
            throw IllegalStateException("live prefix identity extent changed")}}
        if(header.required(1)!="live-policy:"+parentCallId+":"+sequence.toString() ||
            header.required(3)!=parentCallId+":live:"+sequence.toString() ||
            header.required(4)!=parentOperation.value || header.required(8)!="1" ||
            !((header.required(6)=="committed" && header.required(7)=="completed") ||
                (header.required(6)=="rejected" && header.required(7)=="rejected"))){
            throw IllegalStateException("live prefix is not a contiguous completed/known-no-effect own child")}
        // Ignored user-facing result/detail bodies still receive the original
        // complete StoredValue grammar/UTF8/node/EOF scan and exact payment.
        // Each temporary raw value is released before the next phase.
        let _=contextReadMetadataMeasureOwned(tx,"receipt.detail",suffix,parameters,owner,journalStreamAdd(extraRetained,contextReadMetadataRawPeak(smallBytes)),guard)
        let _=contextReadMetadataMeasureOwned(tx,"receipt.verification",suffix,parameters,owner,journalStreamAdd(extraRetained,contextReadMetadataRawPeak(smallBytes)),guard)
        let planCell=contextReadMetadataMeasureOwned(tx,"o.normalized_plan",suffix,parameters,owner,journalStreamAdd(extraRetained,contextReadMetadataRawPeak(smallBytes)),guard)
        let planPhase=owner
        try{
            planPhase.ensureRetainedPeak(journalStreamAdd(extraRetained,journalStreamAdd(contextReadMetadataRawPeak(smallBytes),contextReadMetadataPeak(planCell.bytes,planCell.nodes))))
            let rows=tx.query("SELECT o.normalized_plan"+suffix,parameters)
            if(rows.size!=1 || rows[0].required(0).size!=planCell.bytes){throw IllegalStateException("live prefix plan extent changed")}
            let encoded=rows[0].required(0);let plan=decodeOperationPlan(encoded)
            if(!pluginLivePolicyStreamingChildValueValid(plan.canonicalArguments) ||
                !livePolicyLedgerPlanEnvelopeValid(plan) || plan.bindingDigest!=header.required(2) ||
                canonicalAgentValue(plan.canonicalArguments.field("prior_receipts").getOrThrow())!=canonicalAgentValue(previous) ||
                canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
                journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())!=sequence ||
                httpIntentText(plan.canonicalArguments.field("prior_receipts").getOrThrow(),"parent_operation_id")!=parentOperation.value){
                throw IllegalStateException("live prefix plan does not bind its actual sequence/parent/effect")}
            let digest=modelPolicySha256Text(encoded)
            // Rejected is sufficient ONLY when the actual Store's future
            // zero-effect/rollback-ACK settlement wrote this exact witness in
            // the same transaction. Arbitrary Err/rejected text is insufficient.
            if(header.required(7)=="rejected"){
                let witness=objectValue([ValueField("schema",textValue("axyndra.plugin-live-no-effect/v1")),
                    ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("run_id",textValue(run.value)),
                    ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(header.required(0))),
                    ValueField("receipt_id",textValue(header.required(5))),ValueField("plan_sha256",textValue(digest))])
                let audits=tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? "+
                    "AND kind='plugin_live_no_effect_settled_v1' AND CAST(payload AS BLOB)=CAST(? AS BLOB) LIMIT 2",
                    [SqlParameter.Text(header.required(0)),SqlParameter.Text(run.value),SqlParameter.Text(encodeStoredValue(witness))])
                if(audits.size!=1){throw IllegalStateException("live rejected child lacks its exclusive actual no-effect settlement witness")}}
            journalStreamCheck(guard)
            let tip=objectValue([ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(header.required(0))),
                ValueField("receipt_id",textValue(header.required(5))),ValueField("plan_sha256",textValue(digest)),
                ValueField("outcome",textValue(header.required(7)))])
            let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
            if(!pluginLivePolicyLedgerReferenceValid(reference,parentOperation.value,sequence)){
                throw IllegalStateException("live receipt cannot fit its original bounded identity descriptor")}
            // The checked identifier/digest/field bounds guarantee this small
            // descriptor fits the already retained referenceCharge. Full SQL
            // strings and decoded plan remain confined to the phases above.
            tip
        }finally{}
    }finally{}
}

func requirePluginLivePolicyReadInputsOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    // The opted-in latest stream carries precisely one original Tool read.
    // Empty input and parentless provider reads need a separate contract.
    if(links.size!=1 || !validatePluginDocumentBinding(binding).isOk() ||
        httpIntentText(binding,"run_id")!=run.value || httpIntentText(binding,"contribution")!=parentTool ||
        links[0].runId.value!=run.value){
        throw IllegalStateException("live policy requires its sole complete original Tool read input")}
    let link=links[0]
    let owner=allocate(65536)
    let payment=try{ContextReadCompletedMetadataPayment(tx,link,allocate,guard,phaseOwner:Some(owner),extraRetained:1048576)}
        catch(error:Exception){owner.close();throw error}
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
            latestJournalInputRequireObservationOwned(tx,link,read,data,backend,current,phaseOwner,retained)
        })
        journalStreamCheck(current)
    }finally{payment.close();owner.close()}
}

func latestJournalInputRequireObservationOwned(tx:SqliteTransaction,link:ContextReadFactLink,
    plan:NormalizedOperationPlan,data:AgentValue,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):PluginDocumentLatestJournalStreamReference{
    let request=plan.canonicalArguments;let binding=request.field("binding").getOrThrow()
    let rows=tx.query("SELECT thread_id,payload FROM audit_events WHERE operation_id=? AND run_id=? "+
        "AND kind='plugin_document_latest_journal_observed' LIMIT 2",[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
    if(rows.size!=1 || rows[0].required(0)!=httpIntentText(binding,"thread_id")){
        throw IllegalStateException("journal input lost its sole actual observed stream")}
    let value=decodeStoredValue(rows[0].required(1));let document=data.field("documents").getOrThrow().items[0]
    if(!httpIntentExactFields(value,["schema","thread_id","lane_id","run_id","read_operation_id","read_item_id","plan_sha256",
        "binding","projection_digest","access_policy_digest","view_policy_digest","key","revision","epoch","private_event_fence","stream"]) ||
        httpIntentText(value,"schema")!="axyndra.journal-stream-observation/v3" ||
        httpIntentText(value,"thread_id")!=httpIntentText(binding,"thread_id") || httpIntentText(value,"lane_id")!=httpIntentText(binding,"lane_id") ||
        httpIntentText(value,"run_id")!=link.runId.value || httpIntentText(value,"read_operation_id")!=link.operationId.value ||
        httpIntentText(value,"read_item_id")!=link.sourceItemId.value ||
        httpIntentText(value,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(plan)) ||
        canonicalAgentValue(value.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
        httpIntentText(value,"projection_digest")!=httpIntentText(request,"projection_digest") ||
        httpIntentText(value,"access_policy_digest")!=httpIntentText(request,"access_policy_digest") ||
        httpIntentText(value,"view_policy_digest")!=httpIntentText(request,"view_policy_digest") ||
        httpIntentText(value,"key")!=httpIntentText(request,"key") ||
        value.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
        value.field("revision").getOrThrow().asNumberText()!=document.field("revision").getOrThrow().asNumberText() ||
        canonicalAgentValue(value.field("stream").getOrThrow())!=canonicalAgentValue(document.field("stream").getOrThrow())){
        throw IllegalStateException("journal observation no longer matches all original canonical fields")}
    let reference=parsePluginDocumentLatestJournalStreamReference(document.field("stream").getOrThrow()).value().getOrThrow()
    let metadata=tx.query("SELECT length(CAST(metadata AS BLOB)),length(CAST(mime AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=? LIMIT 2",
        [SqlParameter.Text(reference.digest)])
    if(metadata.size!=1 || journalStreamInteger(metadata[0].required(0))<1 || journalStreamInteger(metadata[0].required(0))>4096 ||
        journalStreamInteger(metadata[0].required(1))>128 || journalStreamInteger(metadata[0].required(2))>256){
        throw IllegalStateException("journal input artifact metadata changed its fixed original extent")}
    requireLatestJournalStreamArtifactMetadata(tx,reference);journalStreamCheck(guard)
    tx.withBackendAllocationPhase({=>
        let actual=backend.fullOwned(tx,guard,owner,extraRetained)
        // The original full fence is consumed completely inside Unit.
        if(!httpIntentDigest(httpIntentText(value,"private_event_fence")) || actual.digest!=httpIntentText(value,"private_event_fence") ||
            journalStreamAdd(actual.events,1)!=journalStreamInteger(document.field("revision").getOrThrow().asNumberText())){
            throw IllegalStateException("journal input full private event fence changed")}
        journalStreamCheck(guard)})
    reference
}
