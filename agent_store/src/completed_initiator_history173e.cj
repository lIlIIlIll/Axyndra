package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Fixed, private SQL projections of existing historical DATA. No method can
// start/replay a Run, create a Receipt, consume a claim or grant a Source.
let COMPLETED_INITIATOR_HEADER173E = "completed_initiator_history173e_v1"
let COMPLETED_INITIATOR_CELL173E = "completed_initiator_cell173e_v1:"

class CompletedInitiatorEvidenceState173e {
    var cells: Int64 = 0
    var digest = modelPolicySha256Text("axyndra.completed-initiator-evidence/v1")
    func add173e(label: String, value: String): Unit {
        digest=modelPolicySha256Text(digest+":"+modelPolicySha256Text(label)+":"+modelPolicySha256Text(value));cells++ }
}
class CompletedInitiatorPayment173e {
    let owner: LogicalJsonOwnerReservation
    let retained: Int64
    let current: () -> Result<Unit>
    var simultaneous: Int64 = 0
    init(owner: LogicalJsonOwnerReservation, retained: Int64, current: () -> Result<Unit>) {
        this.owner=owner;this.retained=journalStreamAdd(retained,65536);this.current=current
        // Actual original bank must fund all selectors/scalars/helper frames
        // BEFORE their first allocation. This is an invoice, never a floor.
        owner.ensureRetainedPeak(this.retained)
    }
    func fund173e(bytes: Int64): Unit {
        owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(simultaneous,bytes))) }
    func withPeak173e(peak: Int64, consume: () -> Unit): Unit {
        fund173e(peak)
        let before=simultaneous;simultaneous=journalStreamAdd(before,peak)
        try {consume()} finally {simultaneous=before}
    }
    func withDecoded173e(text: String, consume: () -> Unit): Unit {
        // Meter scratch/duplicate keys is itself paid before any complete
        // decoder DOM/typed aliases. The existing 8 MiB/64-depth Store grammar
        // remains exact; no Native count or new decoder contract is accepted.
        let meter=StoredValuePaymentMeter(text,owner,extraRetained:journalStreamAdd(retained,simultaneous))
        let nodes=meter.complete()
        let peak=journalStreamAdd(4194304,journalStreamAdd(ownedThreadReadbackMultiply(text.size,12),
            ownedThreadReadbackMultiply(nodes,1024)))
        // Hold the complete decoder/typed/encoder peak through the actual
        // nested consumer frame. A following raw read cannot replace its SUM.
        withPeak173e(peak,consume)
    }
    func raw173e(tx: SqliteTransaction, column: String, suffix: String, args: Array<SqlParameter>,
        consume: (String,String) -> Unit): Unit {
        journalStreamCheck(current)
        let lengths=tx.query("SELECT typeof("+column+"),length(CAST(COALESCE("+column+",'') AS BLOB))"+suffix,args)
        if(lengths.size!=1){throw IllegalStateException("completed initiator evidence cell is missing or duplicated")}
        let bytes=journalStreamInteger(lengths[0].required(1));let kind=lengths[0].required(0)
        let peak=journalStreamAdd(65536,ownedThreadReadbackMultiply(bytes,10));fund173e(peak)
        let rows=tx.query("SELECT COALESCE("+column+",'')"+suffix,args)
        if(rows.size!=1 || rows[0].required(0).size!=bytes){throw IllegalStateException("completed initiator evidence cell changed extent")}
        let old=simultaneous;simultaneous=journalStreamAdd(old,peak)
        try {consume(kind,rows[0].required(0));journalStreamCheck(current)} finally {simultaneous=old}
    }
}

// Every frozen cell is copied independently. A legal 8 MiB original plan or
// result is not escaped into a new, smaller aggregate JSON envelope. NULL and
// its actual storage type are retained in the label; no NULL/empty conflation.
func completedInitiatorInsertCell173e(tx: SqliteTransaction, item: ThreadItem, sequence: Int64,
    label: String, raw: String, payment: CompletedInitiatorPayment173e): Unit {
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(label.size,raw.size),6)))
    let kind=COMPLETED_INITIATOR_CELL173E+label
    let run=item.provenance.runId.getOrThrow().value
    let params=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(run),SqlParameter.Text(item.id.value),
        SqlParameter.Text(kind),SqlParameter.Text(raw),SqlParameter.Int64Value(item.createdAtMillis),SqlParameter.Int64Value(sequence)]
    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES(?,?,?,?,?,?,?)",params)
    let equal=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
        "AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND created_at_millis=? AND commit_sequence=?",params)
    let total=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND commit_sequence=? "+
        "AND substr(kind,1,?)=?",[SqlParameter.Text(item.threadId.value),SqlParameter.Text(run),SqlParameter.Text(item.id.value),
        SqlParameter.Int64Value(sequence),SqlParameter.Int64Value(COMPLETED_INITIATOR_CELL173E.size),SqlParameter.Text(COMPLETED_INITIATOR_CELL173E)])
    if(equal.size!=1 || total.size!=1 || journalStreamInteger(equal[0].required(0))!=1 || journalStreamInteger(total[0].required(0))!=1){
        throw IllegalStateException("completed initiator evidence changed during its actual INSERT")}
}

func completedInitiatorRequireOriginal173e(tx: SqliteTransaction, item: ThreadItem,
    payment: CompletedInitiatorPayment173e): Unit {
    if((!isOwnedDirectInitiator(item) && !isInternalModelMaintenanceInitiator(item)) || item.provenance.runId.isNone()){
        throw IllegalStateException("completed initiator has no original typed origin")}
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(item.id.value.size,
        journalStreamAdd(item.threadId.value.size,journalStreamAdd(item.turnId.value.size,item.provenance.runId.getOrThrow().value.size))),16)))
    let args=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value),SqlParameter.Text(item.id.value),
        SqlParameter.Text(item.provenance.runId.getOrThrow().value)]
    let complete=tx.query("SELECT COUNT(*) FROM turns t JOIN runs r ON r.thread_id=t.thread_id AND r.turn_id=t.id "+
        "JOIN items i ON i.thread_id=t.thread_id AND i.turn_id=t.id AND i.id=t.user_item_id "+
        "WHERE t.thread_id=? AND t.id=? AND i.id=? AND r.id=? AND t.state='completed' AND t.active_run_id IS NULL "+
        "AND r.state='completed' AND r.finished_at_millis IS NOT NULL AND r.epoch>0 AND i.kind='system_note'",args)
    if(complete.size!=1 || journalStreamInteger(complete[0].required(0))!=1){
        throw IllegalStateException("historical initiator lacks its actual completed original Turn/Run")}
    let invalid=tx.query("SELECT COUNT(*) FROM operations o LEFT JOIN operation_receipts p ON p.operation_id=o.id "+
        "LEFT JOIN operation_state_registers s ON s.operation_id=o.id LEFT JOIN operation_effect_records e ON e.operation_id=o.id "+
        "WHERE o.run_id=? AND (NOT((o.state='committed' AND p.outcome='completed') OR "+
        "(EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) AND "+
        "((o.state='rejected' AND p.outcome='rejected') OR (o.state='cancelled' AND p.outcome='cancelled') OR "+
        "(o.state='timed_out' AND p.outcome='timed_out') OR (o.state='failed' AND p.outcome='failed')))) "+
        "OR s.state IS NULL OR s.state!=o.state OR p.id IS NULL OR p.outcome='unknown' "+
        "OR e.operation_id IS NULL OR e.run_id!=o.run_id OR e.tool_call_item_id!=o.tool_call_item_id "+
        "OR CAST(e.normalized_plan AS BLOB)!=CAST(o.normalized_plan AS BLOB) OR p.id!=e.reserved_receipt_id)",
        [SqlParameter.Text(item.provenance.runId.getOrThrow().value)])
    if(invalid.size!=1 || journalStreamInteger(invalid[0].required(0))!=0){
        throw IllegalStateException("completed initiator has unsettled, Unknown or unbound canonical Operation/Receipt")}
    let attempts=tx.query("SELECT COUNT(*) FROM model_attempts WHERE run_id=? AND lifecycle IN ('created','streaming')",
        [SqlParameter.Text(item.provenance.runId.getOrThrow().value)])
    if(attempts.size!=1 || journalStreamInteger(attempts[0].required(0))!=0){
        throw IllegalStateException("completed initiator still owns an unsettled model Attempt")}
}

func completedInitiatorOriginalOrigin173e(tx: SqliteTransaction,item: ThreadItem,callRaw: String,
    suffix: String,args: Array<SqlParameter>,payment: CompletedInitiatorPayment173e): Unit {
    // Read the actual full canonical call origin under the same original
    // owner. The existing original audit binds it to the initial SystemNote;
    // neither a copied origin DTO nor SQL self-equality grants a new Source.
    payment.raw173e(tx,"call.provenance",suffix,args,{_,raw=>
        payment.withDecoded173e(raw,{=>
        let origin=item.provenance.directOrigin.getOrThrow()
        let actual=decodeStoredProvenance(raw)
        if(actual.source!="direct_tool" || actual.runId.isNone() || actual.operationId.isNone() ||
            actual.runId.getOrThrow().value!=item.provenance.runId.getOrThrow().value ||
            !sameDirectCallOrigin(origin,effectiveDirectCallOrigin(actual))){
            throw IllegalStateException("completed actual ToolCall changed its full original origin")}
        let kind=match(origin){case DirectCallOrigin.ManagedJob(_)=>"operation_managed_job_origin_bound"
            case DirectCallOrigin.HostService(_) | DirectCallOrigin.External(_)=>"operation_host_origin_bound"
            case _=>throw IllegalStateException("completed original origin has no historical binding")}
        let rows=tx.query("SELECT r.epoch"+suffix,args)
        if(rows.size!=1){throw IllegalStateException("completed original origin epoch disappeared")}
        payment.raw173e(tx,"call.id",suffix,args,{_,callId=>
            payment.raw173e(tx,"o.id",suffix,args,{_,operation=>
                if(actual.operationId.getOrThrow().value!=operation){throw IllegalStateException("completed origin changed its exact Operation")}
                payment.withPeak173e(journalStreamAdd(4194304,ownedThreadReadbackMultiply(raw.size,12)),{=>
                    let encoded=encodeStoredValue(objectValue([
                        ValueField("origin",directCallOriginValue(origin)),ValueField("thread_id",textValue(item.threadId.value)),
                        ValueField("turn_id",textValue(item.turnId.value)),ValueField("run_id",textValue(item.provenance.runId.getOrThrow().value)),
                        ValueField("epoch",textValue(rows[0].required(0))),ValueField("initiator_item_id",textValue(item.id.value)),
                        ValueField("tool_call_item_id",textValue(callId)),ValueField("operation_id",textValue(operation)),
                        ValueField("call_digest",textValue(modelPolicySha256Text(callRaw)))]))
                    let bound=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
                        "AND CAST(payload AS BLOB)=CAST(? AS BLOB)",[SqlParameter.Text(item.threadId.value),
                            SqlParameter.Text(item.provenance.runId.getOrThrow().value),SqlParameter.Text(operation),SqlParameter.Text(kind),SqlParameter.Text(encoded)])
                    let count=tx.query("SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind=?",[SqlParameter.Text(operation),SqlParameter.Text(kind)])
                    if(bound.size!=1 || count.size!=1 || journalStreamInteger(bound[0].required(0))!=1 || journalStreamInteger(count[0].required(0))!=1){
                        throw IllegalStateException("completed full origin differs from the actual immutable original audit")}
                })
            })
        })
    })})
}

// A derived Operation has a real settled Receipt but deliberately has no
// independent Thread ToolResult. Validate the original SQL admission graph;
// never reconstruct a live source, capability, launch or execution from it.
func completedInitiatorDerivedAncestry173f(tx: SqliteTransaction,rowid: Int64,run: String): Unit {
    let args=[SqlParameter.Int64Value(rowid),SqlParameter.Text(run)]
    let valid=tx.query("WITH RECURSIVE chain(node,hop) AS (SELECT o.rowid,0 FROM operations o WHERE o.rowid=? AND o.run_id=? "+
        "UNION ALL SELECT parent.rowid,chain.hop+1 FROM chain JOIN operations child ON child.rowid=chain.node "+
        "JOIN derived_operation_admissions a ON a.operation_id=child.id JOIN operations parent ON parent.id=a.parent_operation_id "+
        "AND parent.run_id=child.run_id AND parent.tool_call_item_id=child.tool_call_item_id WHERE chain.hop<64) "+
        "SELECT COUNT(*) FROM chain JOIN operations root ON root.rowid=chain.node "+
        "JOIN operations child ON child.rowid=? JOIN derived_operation_admissions a ON a.operation_id=child.id "+
        "LEFT JOIN derived_operation_admissions root_edge ON root_edge.operation_id=root.id "+
        "WHERE root_edge.operation_id IS NULL AND chain.hop>0 AND "+
        "((a.child_call_id<>'' AND a.root_operation_id=root.id AND a.depth=chain.hop AND a.depth<=64) OR "+
        "(a.child_call_id='' AND a.root_operation_id='' AND a.depth=0 AND chain.hop=1))",
        [args[0],args[1],args[0]])
    if(valid.size!=1 || journalStreamInteger(valid[0].required(0))!=1){
        throw IllegalStateException("completed derived Operation lost its real same-Run root or has cyclic/depth-invalid ancestry")}
    // All descendants still use the original root canonical Item, and every
    // edge's depth/root relationship is checked independently in this Tx.
    // Empty schema27 identity remains descriptive legacy DATA, never an
    // admission token for a deeper call or a Native-declared ordinal.
    let edge=tx.query("SELECT COUNT(*) FROM operations child JOIN derived_operation_admissions a ON a.operation_id=child.id "+
        "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=child.run_id "+
        "AND parent.tool_call_item_id=child.tool_call_item_id LEFT JOIN derived_operation_admissions p ON p.operation_id=parent.id "+
        "WHERE child.rowid=? AND child.run_id=? AND a.call_sequence>0 AND length(trim(a.request_key))>0 "+
        "AND a.operation_id<>a.parent_operation_id AND "+
        "((a.child_call_id<>'' AND a.root_operation_id<>'' AND a.depth>0 AND "+
        "((p.operation_id IS NULL AND a.depth=1 AND a.root_operation_id=parent.id) OR "+
        "(p.child_call_id<>'' AND p.root_operation_id=a.root_operation_id AND p.depth+1=a.depth))) OR "+
        "(a.child_call_id='' AND a.root_operation_id='' AND a.depth=0 AND p.operation_id IS NULL)) "+
        "AND NOT EXISTS(SELECT 1 FROM items result JOIN operation_effect_records e ON e.operation_id=child.id "+
        "WHERE result.id=e.reserved_result_item_id)",args)
    if(edge.size!=1 || journalStreamInteger(edge[0].required(0))!=1){
        throw IllegalStateException("completed derived admission changed its exact parent/call/depth or minted a forbidden Thread result")}
}

func completedInitiatorVisitDerived173f(tx: SqliteTransaction,item: ThreadItem,rowid: Int64,
    suffix: String,args: Array<SqlParameter>,payment: CompletedInitiatorPayment173e,
    consume: (String,String) -> Unit,index: Int64): Unit {
    completedInitiatorDerivedAncestry173f(tx,rowid,item.provenance.runId.getOrThrow().value)
    payment.raw173e(tx,"o.normalized_plan",suffix,args,{_,planRaw=>
        payment.withDecoded173e(planRaw,{=>
            let plan=decodeOperationPlan(planRaw)
            payment.raw173e(tx,"a.request_digest",suffix,args,{_,digest=>
                if(digest!=plan.bindingDigest){throw IllegalStateException("completed derived admission changed its full original plan binding")}})
            payment.raw173e(tx,"p.verification",suffix,args,{_,raw=>
                payment.withDecoded173e(raw,{=>
                    let value=decodeStoredValue(raw)
                    if(value.unifiedKind!=ValueKind.Object){throw IllegalStateException("completed derived Receipt verification lost its original object")}
                    // Actual child writers have distinct complete verification
                    // schemas. Preserve all fields unchanged; any existing
                    // request/parent/digest witness must match its SQL edge.
                    for(pair in ["request_key","parent_operation_id","request_digest"]){
                        match(value.field(pair)){case Some(actual)=>
                            if(actual.unifiedKind!=ValueKind.Text){throw IllegalStateException("completed derived Receipt identity changed kind")}
                            let column=if(pair=="parent_operation_id"){"a.parent_operation_id"}else{"a."+pair}
                            payment.raw173e(tx,column,suffix,args,{_,expected=>
                                if(actual.text!=expected){throw IllegalStateException("completed derived Receipt differs from its actual admitted identity")}})
                            case None=>()}
                    }
                })})
        })})
    for(column in ["operation_id","parent_operation_id","call_sequence","request_key","request_digest",
        "child_call_id","root_operation_id","depth"]){
        payment.raw173e(tx,"a."+column,suffix,args,{kind,raw=>
            consume("operation."+index.toString()+".admission."+column+":"+kind,raw)})}
}

func completedInitiatorVisitOriginal173e(tx: SqliteTransaction,item: ThreadItem,payment: CompletedInitiatorPayment173e,
    consume: (String,String) -> Unit): Unit {
    completedInitiatorRequireOriginal173e(tx,item,payment)
    let run=item.provenance.runId.getOrThrow().value
    let continuations=tx.query("SELECT COUNT(*) FROM run_continuations WHERE run_id=?",[SqlParameter.Text(run)])
    if(continuations.size!=1 || journalStreamInteger(continuations[0].required(0))>1){
        throw IllegalStateException("completed initiator has ambiguous durable continuation")}
    if(journalStreamInteger(continuations[0].required(0))==1){
        payment.raw173e(tx,"payload"," FROM run_continuations WHERE run_id=?",[SqlParameter.Text(run)],{kind,raw=>
            payment.withDecoded173e(raw,{=>
            let value=decodeDurableRunContinuation(raw)
            if(!value.isSealed() || !value.workDebt.isEmpty() || value.pendingOperationId.isSome() ||
                value.pendingApprovalId.isSome() || value.waitingExternal.isSome()){
                throw IllegalStateException("completed initiator still owns durable WorkDebt")}
            payment.raw173e(tx,"digest"," FROM run_continuations WHERE run_id=?",[SqlParameter.Text(run)],{digestKind,digest=>
                if(value.digest!=digest){throw IllegalStateException("completed continuation digest changed")}
                consume("continuation.digest:"+digestKind,digest)})
            consume("continuation.payload:"+kind,raw)})})
    }
    let initial=" FROM items WHERE thread_id=? AND turn_id=? AND id=?"
    let ia=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value),SqlParameter.Text(item.id.value)]
    for(column in ["payload","provenance","created_at_millis"]){
        payment.raw173e(tx,column,initial,ia,{kind,raw=>
            if(column=="payload" || column=="provenance"){
                // Original paid input is not payment for a new complete
                // encoder/output/SQL String. Invoice before either codec.
                payment.withDecoded173e(raw,{=>
                    if(column=="payload" && raw!=encodeStoredThreadContent(item.content)){
                        throw IllegalStateException("completed initiator original content changed")}
                    if(column=="provenance" && raw!=encodeStoredProvenance(item.provenance)){
                        throw IllegalStateException("completed initiator original origin changed")}
                    consume("initial."+column+":"+kind,raw)})
            }else{consume("initial."+column+":"+kind,raw)}})}
    let ra=[SqlParameter.Text(run),SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value)]
    // v20 retired runs.continuation; exact canonical payload/digest were visited above.
    for(column in ["id","thread_id","turn_id","epoch","state","lane_snapshot","skill_snapshot","budget","usage",
        "started_at_millis","finished_at_millis","cancellation_reason","app_snapshot"]){
        payment.raw173e(tx,column," FROM runs WHERE id=? AND thread_id=? AND turn_id=?",ra,
            {kind,raw=>consume("run."+column+":"+kind,raw)})}
    // Actual operation/effect/state/receipt and their exact canonical Items.
    // No table is admitted by a Native name, DTO bool or copied ordinal.
    let count=tx.query("SELECT COUNT(*) FROM operations WHERE run_id=?",[SqlParameter.Text(run)])
    let roots=tx.query("SELECT COUNT(*) FROM operations o LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id "+
        "WHERE o.run_id=? AND a.operation_id IS NULL",[SqlParameter.Text(run)])
    if(count.size!=1 || roots.size!=1){throw IllegalStateException("completed original Operation count is absent")}
    let operations=journalStreamInteger(count[0].required(0));let rootCount=journalStreamInteger(roots[0].required(0))
    let counts=tx.query("SELECT (SELECT COUNT(*) FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_call'),"+
        "(SELECT COUNT(*) FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result')",
        [SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value),SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value)])
    if(counts.size!=1 || journalStreamInteger(counts[0].required(0))!=rootCount || journalStreamInteger(counts[0].required(1))!=rootCount){
        throw IllegalStateException("completed initiator canonical calls/results are not root-operation-complete")}
    for(at in 0..operations){
        let selected=tx.query("SELECT o.rowid,(SELECT COUNT(*) FROM derived_operation_admissions a WHERE a.operation_id=o.id) "+
            "FROM operations o WHERE o.run_id=? ORDER BY o.rowid LIMIT 1 OFFSET ?",
            [SqlParameter.Text(run),SqlParameter.Int64Value(at)])
        if(selected.size!=1){throw IllegalStateException("completed original Operation enumeration changed")}
        let rowid=journalStreamInteger(selected[0].required(0));let derived=journalStreamInteger(selected[0].required(1))
        if(derived!=0 && derived!=1){throw IllegalStateException("completed Operation has ambiguous original admission")}
        let common=" FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
            "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state JOIN operation_receipts p ON p.operation_id=o.id "+
            "AND p.id=e.reserved_receipt_id JOIN items call ON call.id=o.tool_call_item_id AND call.kind='tool_call' "+
            "AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id "
        let suffix=if(derived==0){common+
            "JOIN items result ON result.id=e.reserved_result_item_id AND result.kind='tool_result' "+
            "AND result.thread_id=r.thread_id AND result.turn_id=r.turn_id "+
            "WHERE o.rowid=? AND o.run_id=? AND o.state='committed' AND p.outcome='completed'"}
        else{common+"JOIN derived_operation_admissions a ON a.operation_id=o.id "+
            "WHERE o.rowid=? AND o.run_id=? AND p.outcome!='unknown'"}
        let args=[SqlParameter.Int64Value(rowid),SqlParameter.Text(run)]
        if(derived==0){
        payment.raw173e(tx,"call.payload",suffix,args,{_,callRaw=>
            payment.withDecoded173e(callRaw,{=>
            completedInitiatorOriginalOrigin173e(tx,item,callRaw,suffix,args,payment)
            let call=match(decodeStoredThreadContent(callRaw)){case ThreadItemContent.ToolCall(id,name,arguments)=>ToolCall(id.value,name,arguments)
                case _=>throw IllegalStateException("completed original call kind changed")}
            payment.raw173e(tx,"o.normalized_plan",suffix,args,{_,planRaw=>
                payment.withDecoded173e(planRaw,{=>
                let plan=decodeOperationPlan(planRaw)
                if(plan.toolName!=call.name || !canonicalAgentValuesEqual(plan.canonicalArguments,call.arguments)){
                    throw IllegalStateException("completed original whole plan no longer binds its actual ToolCall")}})})
            payment.raw173e(tx,"result.payload",suffix,args,{_,resultRaw=>
                payment.withDecoded173e(resultRaw,{=>
                let result=decodeStoredThreadContent(resultRaw)
                match(result){case ThreadItemContent.ToolResult(id,operation,receipt,output,_)=>
                    payment.raw173e(tx,"o.id",suffix,args,{_,operationRaw=>
                        if(id.value!=call.callId || operation.value!=operationRaw){throw IllegalStateException("completed original result changed its call/Operation")}})
                    payment.raw173e(tx,"p.id",suffix,args,{_,receiptRaw=>
                        if(receipt!=receiptRaw){throw IllegalStateException("completed original result changed its actual Receipt")}})
                    payment.raw173e(tx,"p.detail",suffix,args,{_,detailRaw=>
                        payment.withDecoded173e(detailRaw,{=>
                        if(!canonicalAgentValuesEqual(decodeStoredValue(detailRaw),output)){
                            throw IllegalStateException("completed original Receipt detail differs from its actual complete output")}})})
                case _=>throw IllegalStateException("completed original result kind changed")}
            })})
        })})
        payment.raw173e(tx,"p.verification",suffix,args,{_,raw=>
            payment.withDecoded173e(raw,{=>
            let value=decodeStoredValue(raw);let known=value.field("known_completion");let stage=value.field("stage")
            if(known.isNone() || known.getOrThrow().unifiedKind!=ValueKind.Boolean || !known.getOrThrow().asBool() ||
                stage.isNone() || stage.getOrThrow().unifiedKind!=ValueKind.Text ||
                (stage.getOrThrow().text!="executing" && stage.getOrThrow().text!="prepared")){
                throw IllegalStateException("completed original Receipt is not a real known executing/prepared completion")}})})

            for(column in ["call.payload","call.provenance","result.payload","result.provenance"]){
                payment.raw173e(tx,column,suffix,args,{kind,raw=>consume("operation."+at.toString()+"."+column+":"+kind,raw)})}
        }else{completedInitiatorVisitDerived173f(tx,item,rowid,suffix,args,payment,consume,at)}
        for(column in ["o.id","o.run_id","o.tool_call_item_id","o.normalized_plan","o.capability_requirement","o.resource_scope",
            "o.effect_class","o.retry_disposition","o.idempotency_key","o.state","o.revision",
            "e.normalized_plan","e.tool_id","e.tool_version","e.implementation_fingerprint","e.schema_digest","e.effective_arguments_digest",
            "e.replay_contract_version","e.replay_disposition","e.reserved_receipt_id","e.reserved_result_item_id","e.created_at_millis",
            "s.state","s.revision","p.id","p.outcome","p.detail","p.verification","p.created_at_millis"]){

            payment.raw173e(tx,column,suffix,args,{kind,raw=>consume("operation."+at.toString()+"."+column+":"+kind,raw)})}

    }
    // Preserve the actual original approval/handoff/origin/claim history as
    // independently paid raw evidence. This copy issues no audit permission,
    // Operation, Receipt or continuation admission in the target Run.
    let audits=tx.query("SELECT COUNT(*) FROM audit_events WHERE run_id=?",[SqlParameter.Text(run)])
    if(audits.size!=1){throw IllegalStateException("completed original audit count is absent")}
    for(at in 0..journalStreamInteger(audits[0].required(0))){
        let rows=tx.query("SELECT id FROM audit_events WHERE run_id=? ORDER BY id LIMIT 1 OFFSET ?",[SqlParameter.Text(run),SqlParameter.Int64Value(at)])
        if(rows.size!=1){throw IllegalStateException("completed original audit enumeration changed")}
        let id=journalStreamInteger(rows[0].required(0))
        for(column in ["thread_id","run_id","operation_id","kind","payload","created_at_millis","commit_sequence"]){
            payment.raw173e(tx,column," FROM audit_events WHERE id=?",[SqlParameter.Int64Value(id)],
                {kind,raw=>consume("audit."+at.toString()+"."+column+":"+kind,raw)})}
    }
    // Model maintenance history remains DATA; freeze every original Attempt
    // and Decision independently without minting a new Attempt or replaying it.
    for(table in ["model_attempts","model_decisions"]){
        let root=if(table=="model_attempts"){" FROM model_attempts WHERE run_id=?"}
            else{" FROM model_decisions WHERE attempt_id IN(SELECT id FROM model_attempts WHERE run_id=?)"}
        let total=tx.query("SELECT COUNT(*)"+root,[SqlParameter.Text(run)])
        if(total.size!=1){throw IllegalStateException("completed model evidence count is absent")}
        let columns=if(table=="model_attempts"){
            ["id","semantic_request_id","run_id","parent_attempt_id","attempt_no","lifecycle","policy","policy_reason","started_at_millis",
                "last_activity_at_millis","completed_at_millis","provider_request_id","provider_response_id","failure_kind",
                "semantic_request_digest","wire_policy_digest","dispatch_state","replay_barrier","dispatch_started_at_millis","provider_terminal_at_millis"]
        }else{["id","attempt_id","semantic_request_id","validation_status","completion_disposition","decision_outcome","content_hash",
            "replay_hash","provider_id","provider_response_id","terminal_evidence","validator_version","created_at_millis","canonical_committed_at_millis"]}
        for(at in 0..journalStreamInteger(total[0].required(0))){
            let rows=tx.query("SELECT rowid"+root+" ORDER BY rowid LIMIT 1 OFFSET ?",[SqlParameter.Text(run),SqlParameter.Int64Value(at)])
            if(rows.size!=1){throw IllegalStateException("completed model evidence enumeration changed")}
            let rowid=journalStreamInteger(rows[0].required(0))
            for(column in columns){payment.raw173e(tx,column," FROM "+table+" WHERE rowid=?",[SqlParameter.Int64Value(rowid)],
                {kind,raw=>consume(table+"."+at.toString()+"."+column+":"+kind,raw)})}
        }
    }
    // Complete model usage/block/item/operation associations remain frozen
    // historical DATA too. They are copied one exact cell at a time; no new
    // ModelAttempt, Decision, canonical Item or billing record is inserted.
    for(table in ["model_decision_blocks","model_decision_usage","canonical_decision_items","decision_operations","run_model_usage"]){
        let root=if(table=="run_model_usage"){" FROM run_model_usage WHERE run_id=?"}
            else{" FROM "+table+" WHERE decision_id IN(SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id WHERE a.run_id=?)"}
        let total=tx.query("SELECT COUNT(*)"+root,[SqlParameter.Text(run)])
        if(total.size!=1){throw IllegalStateException("completed model association count is absent")}
        let columns=match(table){
            case "model_decision_blocks"=>["id","decision_id","ordinal","kind","payload","scoped_tool_call_id"]
            case "model_decision_usage"=>["decision_id","payload","finalized_at_millis"]
            case "canonical_decision_items"=>["decision_id","decision_block_id","item_id"]
            case "decision_operations"=>["decision_id","scoped_tool_call_id","operation_id"]
            case _=>["id","run_id","request_sequence","role","estimated_input_tokens","actual_input_tokens","output_tokens",
                "reasoning_tokens","cache_read_tokens","cache_write_tokens","cost_micros","created_at_millis"]}
        for(at in 0..journalStreamInteger(total[0].required(0))){
            let rows=tx.query("SELECT rowid"+root+" ORDER BY rowid LIMIT 1 OFFSET ?",[SqlParameter.Text(run),SqlParameter.Int64Value(at)])
            if(rows.size!=1){throw IllegalStateException("completed model association enumeration changed")}
            let rowid=journalStreamInteger(rows[0].required(0))
            for(column in columns){payment.raw173e(tx,column," FROM "+table+" WHERE rowid=?",[SqlParameter.Int64Value(rowid)],
                {kind,raw=>consume(table+"."+at.toString()+"."+column+":"+kind,raw)})}
        }
    }
    completedInitiatorRequireOriginal173e(tx,item,payment)
}

func completedInitiatorVisitHistory173e(tx: SqliteTransaction,item: ThreadItem,payment: CompletedInitiatorPayment173e,
    consume: (String,String) -> Unit): Unit {
    if(!isCompletedInitiatorHistory173e(item)){throw IllegalStateException("completed initiator historical DATA is missing")}
    let history=item.provenance.completedInitiatorHistory173e.getOrThrow();let run=item.provenance.runId.getOrThrow().value
    let args=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(run),SqlParameter.Text(item.id.value)]
    let suffix=" FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND substr(kind,1,"+
        COMPLETED_INITIATOR_CELL173E.size.toString()+")='"+COMPLETED_INITIATOR_CELL173E+"'"
    let count=tx.query("SELECT COUNT(*)"+suffix,args)
    if(count.size!=1 || journalStreamInteger(count[0].required(0))!=history.evidenceCells){
        throw IllegalStateException("completed initiator historical evidence set changed")}
    let timestamps=tx.query("SELECT COUNT(*)"+suffix+" AND created_at_millis!=?",[SqlParameter.Text(item.threadId.value),
        SqlParameter.Text(run),SqlParameter.Text(item.id.value),SqlParameter.Int64Value(item.createdAtMillis)])
    if(timestamps.size!=1 || journalStreamInteger(timestamps[0].required(0))!=0){throw IllegalStateException("completed evidence timestamps changed")}
    let state=CompletedInitiatorEvidenceState173e()
    for(at in 0..history.evidenceCells){
        let selected=tx.query("SELECT id,length(CAST(kind AS BLOB))"+suffix+" AND commit_sequence=?",
            [SqlParameter.Text(item.threadId.value),SqlParameter.Text(run),SqlParameter.Text(item.id.value),SqlParameter.Int64Value(at)])
        if(selected.size!=1){throw IllegalStateException("completed initiator historical evidence sequence changed")}
        let rowid=journalStreamInteger(selected[0].required(0))
        // Both complete label Strings and its substring coexist with payload
        // SQL/decoder frames. Include them in SUM until the real helper returns.
        let labelPeak=journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamInteger(selected[0].required(1)),12))
        payment.fund173e(labelPeak);let oldPeak=payment.simultaneous
        payment.simultaneous=journalStreamAdd(oldPeak,labelPeak)
        try {
            let labels=tx.query("SELECT kind FROM audit_events WHERE id=?",[SqlParameter.Int64Value(rowid)])
            if(labels.size!=1){throw IllegalStateException("completed initiator historical evidence label disappeared")}
            let label=labels[0].required(0)[COMPLETED_INITIATOR_CELL173E.size..]
            payment.raw173e(tx,"payload"," FROM audit_events WHERE id=?",[SqlParameter.Int64Value(rowid)],{_,raw=>
                state.add173e(label,raw);consume(label,raw)})
        } finally {payment.simultaneous=oldPeak}
    }
    if(state.cells!=history.evidenceCells || state.digest!=history.evidenceDigest){
        throw IllegalStateException("completed initiator historical full evidence changed")}
}

func completedInitiatorHeaderPrepay173e(tx: SqliteTransaction,item: ThreadItem,
    payment: CompletedInitiatorPayment173e): Int64 {
    let history=item.provenance.completedInitiatorHistory173e.getOrThrow()
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(item.threadId.value.size,
        journalStreamAdd(item.provenance.runId.getOrThrow().value.size,item.id.value.size)),16)))
    let args=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.provenance.runId.getOrThrow().value),SqlParameter.Text(item.id.value)]
    let rows=tx.query("SELECT length(CAST(payload AS BLOB)) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? "+
        "AND kind='completed_initiator_cell173e_v1:initial.provenance:text'",args)
    if(rows.size!=1){throw IllegalStateException("completed history original full origin evidence is absent")}
    var bytes=journalStreamInteger(rows[0].required(0))
    for(text in [history.threadId,history.turnId,history.runId,history.itemId,history.originalSource,history.originDigest,history.evidenceDigest]){
        bytes=journalStreamAdd(bytes,text.size)}
    // Full worst-case UTF8/JSON escape expansion, original codec writer/String,
    // raw source origin/typed/DOM and SQL parameters coexist under one bank.
    journalStreamAdd(4194304,ownedThreadReadbackMultiply(bytes,16))
}

func completedInitiatorRequireHistory173e(tx: SqliteTransaction,item: ThreadItem,
    owner: LogicalJsonOwnerReservation,retained: Int64,current: () -> Result<Unit>): Unit {
    let payment=CompletedInitiatorPayment173e(owner,retained,current)
    let history=item.provenance.completedInitiatorHistory173e.getOrThrow()
    let headerPeak=completedInitiatorHeaderPrepay173e(tx,item,payment)
    payment.withPeak173e(headerPeak,{=>
    let encoded=encodeStoredValue(completedInitiatorHistoryValue173e(history))
    let args=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.provenance.runId.getOrThrow().value),
        SqlParameter.Text(item.id.value),SqlParameter.Text(COMPLETED_INITIATOR_HEADER173E),SqlParameter.Text(encoded),SqlParameter.Int64Value(item.createdAtMillis)]
    let record=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
        "AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND created_at_millis=? AND commit_sequence=0",args)
    let allHeaders=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=?",
        [SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.provenance.runId.getOrThrow().value),SqlParameter.Text(item.id.value),
            SqlParameter.Text(COMPLETED_INITIATOR_HEADER173E)])
    let complete=tx.query("SELECT COUNT(*) FROM turns t JOIN runs r ON r.turn_id=t.id AND r.thread_id=t.thread_id "+
        "JOIN items i ON i.id=t.user_item_id AND i.thread_id=t.thread_id AND i.turn_id=t.id WHERE i.id=? AND i.thread_id=? "+
        "AND r.id=? AND t.state='completed' AND t.active_run_id IS NULL AND r.state='completed'",
        [SqlParameter.Text(item.id.value),SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.provenance.runId.getOrThrow().value)])
    if(allHeaders.size!=1 || journalStreamInteger(allHeaders[0].required(0))!=1 || record.size!=1 || journalStreamInteger(record[0].required(0))!=1 || complete.size!=1 || journalStreamInteger(complete[0].required(0))!=1){
        throw IllegalStateException("completed initiator history lost its real completed canonical Item/header proof")}
    let observed=CompletedInitiatorEvidenceState173e()
    completedInitiatorVisitHistory173e(tx,item,payment,{label,raw=>
        if(label=="initial.provenance:text"){
            observed.cells++
            if(modelPolicySha256Text(raw)!=history.originDigest){throw IllegalStateException("completed history original origin bytes changed")}
            payment.withDecoded173e(raw,{=>
            let old=decodeStoredProvenance(raw)
            if(old.source!=history.originalSource || match(history.origin){case Some(origin)=>old.directOrigin.isNone() ||
                !sameDirectCallOrigin(origin,old.directOrigin.getOrThrow());case None=>old.directOrigin.isSome()}){
                throw IllegalStateException("completed history does not preserve its full original descriptive origin")}}) }})
    if(observed.cells!=1){throw IllegalStateException("completed history original full origin is not unique")}
    journalStreamCheck(current)
    })
}

func completedInitiatorDescribe173e(tx: SqliteTransaction,source: ThreadItem,payment: CompletedInitiatorPayment173e): CompletedInitiatorHistory173e {
    if(isCompletedInitiatorHistory173e(source)){
        completedInitiatorRequireHistory173e(tx,source,payment.owner,journalStreamAdd(payment.retained,payment.simultaneous),payment.current)
        let old=source.provenance.completedInitiatorHistory173e.getOrThrow()
        return CompletedInitiatorHistory173e(source.threadId.value,source.turnId.value,source.provenance.runId.getOrThrow().value,
            source.id.value,old.originalSource,old.origin,old.originDigest,old.evidenceDigest,old.evidenceCells)}
    let state=CompletedInitiatorEvidenceState173e()
    completedInitiatorVisitOriginal173e(tx,source,payment,{label,raw=>state.add173e(label,raw)})
    let sizes=tx.query("SELECT length(CAST(provenance AS BLOB)) FROM items WHERE thread_id=? AND id=?",
        [SqlParameter.Text(source.threadId.value),SqlParameter.Text(source.id.value)])
    if(sizes.size!=1){throw IllegalStateException("completed origin size changed before its complete codec")}
    payment.fund173e(journalStreamAdd(4194304,ownedThreadReadbackMultiply(journalStreamInteger(sizes[0].required(0)),16)))
    CompletedInitiatorHistory173e(source.threadId.value,source.turnId.value,source.provenance.runId.getOrThrow().value,
        source.id.value,source.provenance.source,source.provenance.directOrigin,
        modelPolicySha256Text(encodeStoredProvenance(source.provenance)),state.digest,state.cells)
}
func completedInitiatorCurrentEvidence173f(tx: SqliteTransaction,source: ThreadItem,
    payment: CompletedInitiatorPayment173e,expected: CompletedInitiatorHistory173e): Unit {
    let actual=CompletedInitiatorEvidenceState173e()
    let consume={label: String,raw: String=>actual.add173e(label,raw)}
    if(isCompletedInitiatorHistory173e(source)){
        completedInitiatorRequireHistory173e(tx,source,payment.owner,
            journalStreamAdd(payment.retained,payment.simultaneous),payment.current)
        completedInitiatorVisitHistory173e(tx,source,payment,consume)
    }else{completedInitiatorVisitOriginal173e(tx,source,payment,consume)}
    if(actual.cells!=expected.evidenceCells || actual.digest!=expected.evidenceDigest){
        throw IllegalStateException("completed original full historical evidence changed in the actual copy transaction")}
}

func completedInitiatorInsertHistory173e(tx: SqliteTransaction,source: ThreadItem,target: ThreadItem,
    owner: LogicalJsonOwnerReservation,retained: Int64,current: () -> Result<Unit>): Unit {
    let payment=CompletedInitiatorPayment173e(owner,retained,current);let state=CompletedInitiatorEvidenceState173e()
    let copy={label: String,raw: String=>
        completedInitiatorInsertCell173e(tx,target,state.cells,label,raw,payment);state.add173e(label,raw)}
    if(isCompletedInitiatorHistory173e(source)){completedInitiatorVisitHistory173e(tx,source,payment,copy)}
    else{completedInitiatorVisitOriginal173e(tx,source,payment,copy)}
    let history=target.provenance.completedInitiatorHistory173e.getOrThrow()
    if(state.cells!=history.evidenceCells || state.digest!=history.evidenceDigest){
        throw IllegalStateException("completed initiator original evidence changed during its exact copy")}
    completedInitiatorCurrentEvidence173f(tx,source,payment,history)
    let headerPeak=completedInitiatorHeaderPrepay173e(tx,target,payment)
    payment.withPeak173e(headerPeak,{=>
    let encoded=encodeStoredValue(completedInitiatorHistoryValue173e(history))
    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES(?,?,?,?,?,?,0)",
        [SqlParameter.Text(target.threadId.value),SqlParameter.Text(target.provenance.runId.getOrThrow().value),SqlParameter.Text(target.id.value),
            SqlParameter.Text(COMPLETED_INITIATOR_HEADER173E),SqlParameter.Text(encoded),SqlParameter.Int64Value(target.createdAtMillis)])
    completedInitiatorRequireHistory173e(tx,target,owner,journalStreamAdd(retained,payment.simultaneous),current)
    completedInitiatorCurrentEvidence173f(tx,source,payment,history)
    })
}
