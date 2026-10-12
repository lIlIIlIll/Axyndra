package agent_store

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Same existing transaction only; returns no Source, grant, admission or
// private journal fence. The actual caller retains full Parent/child/current
// authority checks and never presents this relationship as an approval.
func requirePluginLivePolicyCausalReadInputs(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit {
    livePolicyRequireCausalReadInputs(tx,parent,run,parentItem,parentTool,binding,links,
        through,expectedPrefix,None,allocate,guard)
}

func requirePluginLivePolicyCausalReadInputsBeforePending(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentItem:ItemId,parentTool:String,binding:AgentValue,links:Array<ContextReadFactLink>,
    through:Int64,expectedPrefix:AgentValue,actualPending:OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit {
    livePolicyRequireCausalReadInputs(tx,parent,run,parentItem,parentTool,binding,links,
        through,expectedPrefix,Some(actualPending),allocate,guard)
}

func livePolicyRequireCausalReadInputs(tx:SqliteTransaction,parent:OperationId,run:RunId,
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
    let payment=ContextReadCompletedMetadataPayment(tx,link,allocate,guard)
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
        let _=payment.withObservation({=>
            livePolicyRequireCausalObservation(tx,parent,run,link,read,data,backend,through,
                expectedPrefix,pending,allocate,current)
        })
        journalStreamCheck(current)
    }finally{payment.close()}
}

func livePolicyRequireCausalObservation(tx:SqliteTransaction,parent:OperationId,run:RunId,link:ContextReadFactLink,
    plan:NormalizedOperationPlan,data:AgentValue,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    through:Int64,expectedPrefix:AgentValue,pending:?OperationId,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):PluginDocumentLatestJournalStreamReference{
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
    livePolicyRequireCausalJournalPrefix(tx,parent,run,binding,link,httpIntentText(request,"key"),
        httpIntentText(value,"private_event_fence"),
        livePolicyCausalPositiveRevision(document.field("revision").getOrThrow()),through,expectedPrefix,pending,
        backend,allocate,guard)
    reference
}

// Constant holder references follow the existing paid Store callback pattern.
// Only fixed bounded fields survive their original charged callback stage.
class LivePolicyCausalEffectState { var appendsJournal=false }
class LivePolicyCausalReceiptState { var afterFence="";var afterRevision:Int64=0 }

// No child is hidden by the ordinary path. BeforePending is used only after
// the caller's actual immutable child tuple check; this independent relation
// check still requires its unique own next child and no terminal Receipt.
func livePolicyRequireCausalExcludedChild(tx:SqliteTransaction,parent:OperationId,run:RunId,
    parentCall:String,binding:AgentValue,through:Int64,expected:AgentValue,pending:OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit {
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
    withLivePolicyStoredValue(tx,"o.normalized_plan",suffix,args,allocate,guard,{encoded=>
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

func livePolicyCausalPositiveRevision(value:AgentValue):Int64 {
    let text=value.asNumberText();let number=journalStreamInteger(text)
    if(number<1 || text!=number.toString()){throw IllegalStateException("causal revision is not canonical positive Int64")}
    number
}

func livePolicyRequireCausalJournalPrefix(tx:SqliteTransaction,parent:OperationId,run:RunId,
    binding:AgentValue,link:ContextReadFactLink,key:String,initialFence:String,initialRevision:Int64,
    through:Int64,expected:AgentValue,pending:?OperationId,backend:SqliteOpaqueRowJournalLatestStreamBackend,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit {
    if(through<0 || !httpIntentDigest(initialFence) || initialRevision<1 ||
        !pluginLivePolicyLedgerReferenceValid(expected,parent.value,through)){
        throw IllegalStateException("causal input has no exact original observation and own prefix")}
    let parentCall=httpIntentText(binding,"parent_call_id")
    match(pending){case Some(actual)=>livePolicyRequireCausalExcludedChild(tx,parent,run,parentCall,binding,
        through,expected,actual,allocate,guard);case None=>()}
    let owner=allocate(65536)
    try {
        owner.ensureRetainedPeak(1048576)
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
            let actualTip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,parentCall,binding,next,previous,allocate,guard)
            let operation=httpIntentText(actualTip,"operation_id")
            let childSuffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=? AND o.id=?"
            let childArgs=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(operation)]
            let effectState=LivePolicyCausalEffectState()
            withLivePolicyStoredValue(tx,"o.normalized_plan",childSuffix,childArgs,allocate,guard,{encoded=>
                let plan=decodeOperationPlan(encoded);let effect=plan.canonicalArguments.field("effect").getOrThrow()
                effectState.appendsJournal=httpIntentText(effect,"kind")=="row_journal.append"
                if(modelPolicySha256Text(encoded)!=httpIntentText(actualTip,"plan_sha256") ||
                    (effectState.appendsJournal && httpIntentText(effect,"key")!=key)){
                    throw IllegalStateException("causal input effect changed its paid plan or read journal key")}
            })
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_journal_causal_v1'"
            let auditArgs=[SqlParameter.Text(operation),SqlParameter.Text(run.value),SqlParameter.Text(httpIntentText(binding,"thread_id"))]
            let beforeFence=fence;let beforeRevision=revision
            let receiptState=LivePolicyCausalReceiptState()
            withLivePolicyStoredValue(tx,"payload",auditSuffix,auditArgs,allocate,guard,{encoded=>
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
        let current=backend.full(tx,guard)
        if(current.digest!=fence || journalStreamAdd(current.events,1)!=revision){
            throw IllegalStateException("causal input current full private event fence changed outside its own known chain")}
        journalStreamCheck(guard)
    }finally{owner.close()}
}
