package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Private historical evidence, never a Source, execution permit, lease or
// acknowledgement. The only writer below runs around the original Core
// canonical mutation with its actual invoke-local Source still held.
let LIVE_KNOWN_PARENT_AUDIT="plugin_live_known_parent_canonical_v1"
let LIVE_KNOWN_PARENT_SCHEMA="axyndra.plugin-live-known-parent-canonical/v1"

class LiveKnownCommitEligibility { var witness=true }

// Cancellation after an actual Known result does not erase its original
// canonical/ACK obligations. It prevents this optional recovery witness.
// Actual SQL/current/Source failures are NOT caught or reclassified here.
func liveKnownSettlementGuard(scope:OwnedCanonicalParentCommit,state:LiveKnownCommitEligibility):Result<Unit>{
    match(scope.check()){
        case Result.Ok(_)=>Result.Ok(())
        case Result.Err(error)=>
            if(error.kind==AgentErrorKind.Cancelled || error.kind==AgentErrorKind.Timeout){
                state.witness=false;Result.Ok(())
            }else{Result.Err(error)}
    }
}

// Closed SQL selectors only. Every signed rowid and complete cell enters
// an unambiguous length-framed aggregate; no newest-N or corpus count cap.
class LiveKnownHistoryQuery {
    let rowid:String
    let suffix:String
    let columns:Array<String>
    let stored:Array<Bool>
    let parameters:Array<SqlParameter>
    init(rowid:String,suffix:String,columns:Array<String>,stored:Array<Bool>,parameters:Array<SqlParameter>){
        if(columns.size!=stored.size){throw IllegalStateException("known history selector shape changed")}
        this.rowid=rowid;this.suffix=suffix;this.columns=columns;this.stored=stored;this.parameters=parameters
    }
}

func liveKnownHashFrame(hash:SHA256,value:String,owner:LogicalJsonOwnerReservation,retained:Int64):Unit{
    owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataRawPeak(journalStreamAdd(value.size,128))))
    hash.write((value.size.toString()+":").toArray());hash.write(value.toArray())
}

func liveKnownHistoryDigest(tx:SqliteTransaction,queries:Array<LiveKnownHistoryQuery>,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):String{
    let hash=SHA256();var selector:Int64=0
    for(query in queries){
        liveKnownHashFrame(hash,"selector:"+selector.toString(),owner,retained)
        var cursor:?Int64=None;var count:Int64=0
        while(true){
            journalStreamCheck(guard)
            let args=ArrayList<SqlParameter>();args.add(all:query.parameters)
            let after=match(cursor){case None=>"";case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND "+query.rowid+">?"}
            let found=tx.query("SELECT "+query.rowid+query.suffix+after+" ORDER BY "+query.rowid+" LIMIT 1",args.toArray())
            if(found.isEmpty()){break}
            let rowid=journalStreamInteger(found[0].required(0))
            let rowArgs=ArrayList<SqlParameter>();rowArgs.add(all:query.parameters);rowArgs.add(SqlParameter.Int64Value(rowid))
            let suffix=query.suffix+" AND "+query.rowid+"=?"
            liveKnownHashFrame(hash,"row:"+rowid.toString(),owner,retained)
            for(index in 0..query.columns.size){
                let column=query.columns[index]
                let size=tx.query("SELECT typeof("+column+"),COALESCE(length(CAST("+column+" AS BLOB)),0)"+suffix,rowArgs.toArray())
                if(size.size!=1){throw IllegalStateException("known history row is not unique")}
                liveKnownHashFrame(hash,size[0].required(0),owner,retained)
                let bytes=journalStreamInteger(size[0].required(1))
                if(bytes<0){throw IllegalStateException("negative known history cell extent")}
                if(size[0].required(0)=="null"){
                    if(bytes!=0){throw IllegalStateException("known history NULL extent changed")}
                    liveKnownHashFrame(hash,"null",owner,retained)
                }else if(query.stored[index]){
                    let scanner=LiveKnownStoredStream(tx,column,suffix,rowArgs.toArray(),owner,retained,guard)
                    let digest=scanner.complete()
                    liveKnownHashFrame(hash,"stored:"+bytes.toString()+":"+digest,owner,retained)
                }else{
                    // The entire actual text/integer/blob copy is paid before
                    // SELECT. This does not assume that corrupt IDs are small.
                    owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataRawPeak(bytes)))
                    let raw=tx.query("SELECT "+column+suffix,rowArgs.toArray())
                    if(raw.size!=1 || raw[0].required(0).size!=bytes){
                        throw IllegalStateException("known history metadata extent drift")}
                    liveKnownHashFrame(hash,raw[0].required(0),owner,retained)
                }
            }
            count=journalStreamAdd(count,1);cursor=Some(rowid)
        }
        liveKnownHashFrame(hash,"rows:"+count.toString(),owner,retained);selector++
    }
    journalStreamCheck(guard);logicalJsonEncodeHex(hash.finish())
}

func liveKnownImmutableQueries(parent:OperationId,run:RunId,item:ItemId,read:ContextReadFactLink):Array<LiveKnownHistoryQuery>{
    let ids=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]
    let owned="(e.operation_id=? OR e.operation_id IN (SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?))"
    let all=[SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]
    [
        LiveKnownHistoryQuery("o.rowid"," FROM operations o WHERE o.id=? AND o.run_id=?",
            ["o.id","o.run_id","o.tool_call_item_id","o.normalized_plan"],[false,false,false,true],ids),
        LiveKnownHistoryQuery("e.rowid"," FROM operation_effect_records e WHERE "+owned+" AND e.run_id=?",
            ["e.operation_id","e.run_id","e.tool_call_item_id","e.normalized_plan","e.tool_id","e.tool_version",
             "e.implementation_fingerprint","e.schema_digest","e.effective_arguments_digest","e.replay_contract_version",
             "e.replay_disposition","e.reserved_receipt_id","e.reserved_result_item_id","e.created_at_millis"],
            [false,false,false,true,false,false,false,false,false,false,false,false,false,false],all),
        LiveKnownHistoryQuery("a.rowid"," FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id WHERE a.parent_operation_id=? AND o.run_id=?",
            ["a.operation_id","a.parent_operation_id","a.call_sequence","a.request_key","a.request_digest","a.root_operation_id","a.child_call_id","a.depth",
             "o.run_id","o.tool_call_item_id","o.state","o.revision","o.normalized_plan"],
            [false,false,false,false,false,false,false,false,false,false,false,false,true],ids),
        LiveKnownHistoryQuery("r.rowid"," FROM operation_receipts r JOIN operations o ON o.id=r.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["r.id","r.operation_id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,true,true,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("s.rowid"," FROM operation_state_registers s JOIN operations o ON o.id=s.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["s.operation_id","s.state","s.revision"],[false,false,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("a.rowid"," FROM audit_events a WHERE a.run_id=? AND (a.operation_id=? OR a.operation_id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)) AND a.kind<>?",
            ["a.id","a.thread_id","a.run_id","a.operation_id","a.kind","a.payload","a.created_at_millis","a.commit_sequence"],
            [false,false,false,false,false,true,false,false],
            [SqlParameter.Text(run.value),SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_KNOWN_PARENT_AUDIT)]),
        LiveKnownHistoryQuery("a.rowid"," FROM approvals a JOIN operations o ON o.id=a.operation_id WHERE o.run_id=? AND o.id IN "+
            "(SELECT operation_id FROM derived_operation_admissions WHERE parent_operation_id=?)",
            ["a.id","a.operation_id","a.operation_digest","a.capability_ceiling","a.decision","a.source","a.expires_at_millis"],
            [false,false,false,true,false,false,false],[SqlParameter.Text(run.value),SqlParameter.Text(parent.value)]),
        LiveKnownHistoryQuery("i.rowid"," FROM items i WHERE i.id=?",
            ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
            [false,false,false,false,false,true,true],[SqlParameter.Text(item.value)]),
        LiveKnownHistoryQuery("o.rowid"," FROM operations o WHERE o.id=? AND o.run_id=?",
            ["o.id","o.run_id","o.tool_call_item_id","o.state","o.revision","o.normalized_plan"],
            [false,false,false,false,false,true],[SqlParameter.Text(read.operationId.value),SqlParameter.Text(read.runId.value)]),
        LiveKnownHistoryQuery("r.rowid"," FROM operation_receipts r WHERE r.operation_id=?",
            ["r.id","r.operation_id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,true,true,false],[SqlParameter.Text(read.operationId.value)]),
        LiveKnownHistoryQuery("a.rowid"," FROM audit_events a WHERE a.operation_id=? AND a.run_id=?",
            ["a.id","a.thread_id","a.run_id","a.operation_id","a.kind","a.payload","a.created_at_millis","a.commit_sequence"],
            [false,false,false,false,false,true,false,false],[SqlParameter.Text(read.operationId.value),SqlParameter.Text(read.runId.value)]),
        LiveKnownHistoryQuery("i.rowid"," FROM items i WHERE i.id=?",
            ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
            [false,false,false,false,false,true,true],[SqlParameter.Text(read.sourceItemId.value)]),
        LiveKnownHistoryQuery("i.rowid"," FROM items i WHERE i.id=?",
            ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
            [false,false,false,false,false,true,true],[SqlParameter.Text(read.resultItemId.value)])
    ]
}

// A canonical receipt/result comparison uses the actual held DOM's original
// StoredValue identity. A declared hash or Native lease cannot mint this scope.
func liveKnownCanonicalDigest(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:ThreadId,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):String{
    liveKnownHistoryDigest(tx,[
        LiveKnownHistoryQuery("o.rowid"," FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id AND r.id=e.reserved_receipt_id "+
            "WHERE o.id=? AND o.run_id=? AND o.state='committed' AND s.state='committed' AND r.outcome IN ('completed','failed')",
            ["o.id","o.state","o.revision","s.state","s.revision","r.id","r.outcome","r.detail","r.verification","r.created_at_millis"],
            [false,false,false,false,false,false,false,true,true,false],[SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]),
        LiveKnownHistoryQuery("i.rowid"," FROM items i JOIN operation_effect_records e ON e.reserved_result_item_id=i.id "+
            "WHERE e.operation_id=? AND e.run_id=? AND i.thread_id=? AND i.kind='tool_result'",
            ["i.id","i.thread_id","i.turn_id","i.ordinal","i.kind","i.payload","i.provenance"],
            [false,false,false,false,false,true,true],[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)])
    ],owner,retained,guard)
}

func liveKnownRequireCanonical(tx:SqliteTransaction,transition:ThreadTransition,scope:OwnedCanonicalParentCommit,
    allocate:(Int64)->LogicalJsonOwnerReservation,owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    let item=transition.committedItems[0];let receipt=transition.operationReceipt.getOrThrow()
    livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "+
        "JOIN operation_state_registers s ON s.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id "+
        "JOIN items i ON i.id=e.reserved_result_item_id JOIN threads t ON t.id=i.thread_id "+
        "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND o.state='committed' AND s.state=o.state "+
        "AND r.id=e.reserved_receipt_id AND r.id=? AND r.outcome=? AND i.id=? AND i.thread_id=? AND i.turn_id=? "+
        "AND i.ordinal=? AND i.kind='tool_result' AND t.revision=?",
        [SqlParameter.Text(scope.operation.value),SqlParameter.Text(scope.run.value),SqlParameter.Text(scope.source.itemId().value),
         SqlParameter.Text(receipt.receiptId),SqlParameter.Text(operationOutcomeName(receipt.outcome)),SqlParameter.Text(item.id.value),
         SqlParameter.Text(scope.thread.value),SqlParameter.Text(item.turnId.value),SqlParameter.Int64Value(item.ordinal),
         SqlParameter.Int64Value(transition.after.thread.revision)],"known Parent canonical Receipt/item/mirror/revision is not its actual reserved tuple")
    scope.withOutput({result=>
        let expected=livePolicyInputStoredDigestStreamedOwned(result.output,owner,guard,extraRetained:retained)
        let actual=LiveKnownStoredStream(tx,"detail"," FROM operation_receipts WHERE id=? AND operation_id=?",
            [SqlParameter.Text(receipt.receiptId),SqlParameter.Text(scope.operation.value)],owner,retained,guard).complete()
        if(actual!=expected){throw IllegalStateException("canonical Parent Receipt changed the complete leased Known output")}
        let header=LiveKnownCanonicalStoredStream(tx,"payload"," FROM items WHERE id=? AND thread_id=? AND kind='tool_result'",
            [SqlParameter.Text(item.id.value),SqlParameter.Text(scope.thread.value)],owner,retained,guard)
        let _=header.complete();let fields=header.header()
        if(httpIntentText(fields,"kind")!="tool_result" || httpIntentText(fields,"call_id")!=result.callId ||
            httpIntentText(fields,"operation_id")!=scope.operation.value || httpIntentText(fields,"receipt_id")!=receipt.receiptId ||
            fields.field("is_error").getOrThrow().asBool()!=result.isError || header.fieldDigest("result")!=expected){
            throw IllegalStateException("canonical Parent ToolResult header is not its actual Known output")}
        // Every result byte has been grammar-scanned through EOF and then
        // compared with the actual held Known DOM's complete original SHA.
    })
    withLivePolicyStoredValueOwned(tx,"verification"," FROM operation_receipts WHERE id=? AND operation_id=?",
        [SqlParameter.Text(receipt.receiptId),SqlParameter.Text(scope.operation.value)],allocate,
        guard,owner,retained,{raw=>if(raw!=encodeStoredValue(receipt.verification)){
            throw IllegalStateException("canonical Parent verification differs from original Core evidence")}})
    withLivePolicyStoredValueOwned(tx,"provenance"," FROM items WHERE id=? AND thread_id=?",
        [SqlParameter.Text(item.id.value),SqlParameter.Text(scope.thread.value)],allocate,
        guard,owner,retained,{raw=>if(raw!=encodeStoredProvenance(item.provenance)){
            throw IllegalStateException("canonical Parent provenance differs from original Core evidence")}})
}

// Metadata-only revalidation at Core commit. The actual Host FD verifier
// already ran in the owned terminal path; no success callback impersonates
// an FD check here and no Host mutex/file operation is entered under SQL.
func liveKnownRequireTerminalBlobMetadataOwned(tx:SqliteTransaction,reference:PluginDocumentPayloadReference,
    owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    for(_ in 0..2){
        let sizes=tx.query("SELECT length(CAST(mime AS BLOB)),length(CAST(size AS BLOB)),"+
            "length(CAST(metadata AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=?",
            [SqlParameter.Text(reference.digest)])
        if(sizes.size!=1 || sizes[0].size!=4){throw IllegalStateException("known terminal Blob has no exact metadata")}
        var bytes:Int64=0
        for(index in 0..4){let extent=journalStreamInteger(sizes[0].required(index))
            if(extent<1){throw IllegalStateException("known terminal Blob metadata is empty")};bytes=journalStreamAdd(bytes,extent)}
        if(journalStreamInteger(sizes[0].required(2))>4096){throw IllegalStateException("known terminal Blob metadata exceeds its original bound")}
        owner.ensureRetainedPeak(journalStreamAdd(retained,contextReadMetadataRawPeak(bytes)))
        requireDocumentPayloadMetadata(tx,reference);journalStreamCheck(guard)
    }
}

// The descriptor DOM remains within its true paid Unit. This is a single
// genuine same-pool phase reservation, not a fake allocator borrowing a lease.
func withLiveKnownCanonicalParentCommit(tx:SqliteTransaction,transition:ThreadTransition,
    scope:OwnedCanonicalParentCommit,allocate:(Int64)->LogicalJsonOwnerReservation,action:()->Unit):Unit{
    if(!scope.matches(transition)){throw IllegalStateException("known canonical scope changed its actual invocation")}
    let eligibility=LiveKnownCommitEligibility()
    let guard={=>liveKnownSettlementGuard(scope,eligibility)}
    let owner=allocate(65536)
    try{
        let args=[SqlParameter.Text(scope.operation.value),SqlParameter.Text(scope.run.value),SqlParameter.Text(scope.thread.value)]
        let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_policy_parent_terminal_v1'"
        let cell=contextReadMetadataMeasureOwned(tx,"payload",suffix,args,owner,0,guard)
        withLivePolicyStoredValueOwned(tx,"payload",suffix,args,allocate,guard,owner,0,{encoded=>
            let descriptor=decodeStoredValue(encoded)
            let retained=journalStreamAdd(1048576,contextReadMetadataPeak(cell.bytes,cell.nodes))
            owner.ensureRetainedPeak(retained)
            if(!pluginLivePolicyTerminalDataValid(descriptor,scope.operation.value,scope.plan.bindingDigest)){
                throw IllegalStateException("known Parent terminal descriptor is not its actual bounded contract")}
            let prefix=descriptor.field("prior_receipts").getOrThrow()
            let through=journalStreamInteger(prefix.field("through_sequence").getOrThrow().asNumberText())
            let progress=Some(LivePolicyReadProgress(through,prefix,None<OperationId>))
            scope.withOutput({result=>
                if(result.callId!=scope.source.callId() || result.receiptId!="receipt-"+scope.operation.value || result.payloadLease.isNone() ||
                    result.isError!=descriptor.field("is_error").getOrThrow().asBool()){
                    throw IllegalStateException("known Parent lost its actual held output lease/identity")}
                let reference=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
                livePolicyTerminalOutputIdentityOwned(result.output,owner,guard,{bytes,digest=>
                    if(bytes!=reference.bytes || digest!=reference.digest){
                        throw IllegalStateException("known Parent changed its full previously FD-verified output")}},extraRetained:retained)
                // Existing terminal verification performed both actual fixed
                // FD/EOF/hash checks while its adopted Host owner was held.
                // This SQL-only stage keeps the SAME output lease and exact
                // descriptor; it never reacquires Host locks or opens a path.
                liveKnownRequireTerminalBlobMetadataOwned(tx,reference,owner,retained,guard)
            })
            withLiveKnownPlanEncodingOwned(scope.plan,owner,retained,guard,{expected,peak=>
                withLivePolicyStoredValueOwned(tx,"normalized_plan"," FROM operations WHERE id=? AND run_id=?",
                    [SqlParameter.Text(scope.operation.value),SqlParameter.Text(scope.run.value)],allocate,guard,owner,peak,{raw=>
                        if(raw!=expected){throw IllegalStateException("known Parent changed its entire immutable prepared plan")}})})
            // All original authority/current/fence relations run BEFORE the
            // original Core writer settles the still-executing Parent.
            requirePluginLivePolicyParentSourceForKnownCommitOwned(tx,scope.source,scope.operation,scope.run,scope.thread,
                scope.epoch,scope.plan,allocate,guard,owner,retained,progress:progress)
            requirePluginLivePolicyInputPayloadForKnownParentOwned(tx,scope.operation,scope.run,scope.source.itemId(),
                scope.plan.toolName,scope.plan.canonicalArguments,allocate,guard,owner,retained)
            withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                "AND kind='plugin_live_parent_prepared_v1'",args,allocate,guard,owner,retained,{raw=>
                let marker=decodeStoredValue(raw)
                liveKnownRequireChildHistoricalTuple(tx,scope.operation,scope.run,scope.thread,scope.epoch,scope.plan,
                    marker,allocate,owner,journalStreamAdd(retained,contextReadMetadataPeak(raw.size,livePolicyStoredExtent(marker).nodes)),guard)})
            let immutable=liveKnownHistoryDigest(tx,liveKnownImmutableQueries(scope.operation,scope.run,scope.source.itemId(),
                scope.plan.contextReadFacts[0]),owner,retained,guard)
            liveKnownPrepayOriginalCanonicalMutation(tx,transition,scope,owner,retained,guard)
            action()
            liveKnownRequireCanonical(tx,transition,scope,allocate,owner,retained,guard)
            if(immutable!=liveKnownHistoryDigest(tx,liveKnownImmutableQueries(scope.operation,scope.run,scope.source.itemId(),
                scope.plan.contextReadFacts[0]),owner,retained,guard)){
                throw IllegalStateException("canonical Parent changed its previously validated immutable Source/child history")}
            // No postinsert executing Source call: later history may explain
            // Known debt but never becomes authority to execute/retry.
            journalStreamCheck(guard)
            if(eligibility.witness){
                livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind=?)",
                    [SqlParameter.Text(scope.operation.value),SqlParameter.Text(LIVE_KNOWN_PARENT_AUDIT)],"known Parent cannot overwrite its canonical witness")
                let item=transition.committedItems[0]
                let head=tx.query("SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",[SqlParameter.Text(scope.thread.value)])
                let snapshot=if(head.isEmpty()){Int64(0)}else{journalStreamInteger(head[0].required(0))}
                let value=objectValue([ValueField("schema",textValue(LIVE_KNOWN_PARENT_SCHEMA)),
                    ValueField("parent_operation_id",textValue(scope.operation.value)),ValueField("run_id",textValue(scope.run.value)),
                    ValueField("thread_id",textValue(scope.thread.value)),ValueField("epoch",integerValue(scope.epoch)),
                    ValueField("root_item_id",textValue(scope.source.itemId().value)),ValueField("root_call_id",textValue(scope.source.callId())),
                    ValueField("parent_binding_digest",textValue(scope.plan.bindingDigest)),
                    ValueField("canonical_item_id",textValue(item.id.value)),ValueField("canonical_item_ordinal",integerValue(item.ordinal)),
                    ValueField("canonical_receipt_id",textValue(transition.operationReceipt.getOrThrow().receiptId)),
                    ValueField("post_thread_revision",integerValue(transition.after.thread.revision)),
                    ValueField("snapshot_head",integerValue(snapshot)),ValueField("prior_receipts",prefix),
                    ValueField("terminal_audit_id",integerValue(journalStreamInteger(tx.query("SELECT id"+suffix,args)[0].required(0)))),
                    ValueField("immutable_history_sha256",textValue(immutable)),
                    ValueField("canonical_sha256",textValue(liveKnownCanonicalDigest(tx,scope.operation,scope.run,scope.thread,owner,retained,guard)))])
                let extent=livePolicyStoredExtent(value)
                owner.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),extent.bytes*4)))
                let stored=encodeStoredValue(value)
                if(stored.size!=extent.bytes){throw IllegalStateException("known witness original framing drift")}
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,?,?,?)",
                    [SqlParameter.Text(scope.thread.value),SqlParameter.Text(scope.run.value),SqlParameter.Text(scope.operation.value),
                     SqlParameter.Text(LIVE_KNOWN_PARENT_AUDIT),SqlParameter.Text(stored),SqlParameter.Int64Value(agentUtcMillis())])
                requireStoreChanged(tx,"known Parent witness was not recorded in its canonical transaction")
            }
        })
    }finally{owner.close()}
}

// This conservative accounting covers the UNCHANGED original Core encoder,
// SQLite text escaping and canonical item/provenance temporaries. It is not
// the future large writer optimization: a real maximum result can still
// exhaust the original aggregate. No second pool/lease borrower is invented.
func liveKnownPrepayOriginalCanonicalMutation(tx:SqliteTransaction,transition:ThreadTransition,
    scope:OwnedCanonicalParentCommit,owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    let receipt=transition.operationReceipt.getOrThrow();let item=transition.committedItems[0]
    owner.ensureRetainedPeak(journalStreamAdd(retained,1048576))
    let detail=livePolicyStoredExtent(receipt.detail)
    let verification=livePolicyStoredExtent(receipt.verification)
    // The original two encodes are arguments in one SQL expression and may
    // coexist. Account both through the entire synchronous action.
    var bytes=journalStreamAdd(detail.bytes,verification.bytes)
    bytes=journalStreamAdd(bytes,detail.bytes)
    let plan=contextReadMetadataMeasureOwned(tx,"normalized_plan"," FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(scope.operation.value),SqlParameter.Text(scope.run.value)],owner,retained,guard)
    bytes=journalStreamAdd(bytes,plan.bytes)
    let provenance=contextReadMetadataMeasureOwned(tx,"provenance"," FROM items WHERE id=?",
        [SqlParameter.Text(scope.source.itemId().value)],owner,retained,guard)
    bytes=journalStreamAdd(bytes,provenance.bytes)
    // Fixed wrapper/provenance/Receipt headers are prepaid before the old
    // encoder constructs them. All full raw values keep their original bounds.
    bytes=journalStreamAdd(bytes,1048576)
    for(text in [receipt.receiptId,receipt.operationId.value,item.id.value,item.threadId.value,item.turnId.value,
        item.provenance.source,scope.operation.value,scope.run.value,scope.thread.value,scope.source.callId()]){
        bytes=journalStreamAdd(bytes,text.size)}
    if(bytes>(Int64.Max-retained)/12){throw IllegalStateException("known canonical original writer payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(retained,bytes*12));journalStreamCheck(guard)
}
