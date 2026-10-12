package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

let COMPLETED_USER_HEADER174="completed_user_model_history174_v1"
let COMPLETED_USER_CELL174="completed_user_model_cell174_v1:"
let COMPLETED_USER_LEDGER174="completed_user_model_ledger174_v1"

// A private, paid scalar accumulator. No raw SQL cell, DOM, Run or Source is
// returned by a whole graph visitor. The audit has its own digest contract;
// contextSourceDigest and all original ItemProvenance bytes remain unchanged.
class CompletedUserEvidence174 {
    var cells: Int64=0
    var digest=modelPolicySha256Text("axyndra.completed-user-model-evidence/v1")
    var originDigest=""
    func add174(label: String,raw: String): Unit {
        digest=modelPolicySha256Text(digest+":"+modelPolicySha256Text(label)+":"+modelPolicySha256Text(raw));cells++
        if (label=="initial.provenance:text") { originDigest=modelPolicySha256Text(raw) }
    }
}
class CompletedUserAnchor174 {
    let run: String
    let epoch: Int64
    let count: Int64
    let turnState: String
    init(run: String,epoch: Int64,count: Int64,turnState: String) {
        this.run=run;this.epoch=epoch;this.count=count;this.turnState=turnState
    }
}
class CompletedUserTarget174 {
    let thread: String
    let turn: String
    let run: String
    let item: String
    let ordinal: Int64
    let created: Int64
    init(thread: String,turn: String,run: String,item: String,ordinal: Int64,created: Int64) {
        this.thread=thread;this.turn=turn;this.run=run;this.item=item;this.ordinal=ordinal;this.created=created
    }
}

func completedUserOriginal174(item: ThreadItem): Bool {
    item.kind==ItemKind.UserMessage && item.provenance.source=="user" && item.provenance.operationId.isNone() &&
        item.provenance.directOrigin.isNone() && item.provenance.continuationOrigin.isNone() &&
        item.provenance.continuationHistory.isNone() && item.provenance.completedInitiatorHistory173e.isNone()
}
func completedUserFork174(item: ThreadItem): Bool {
    item.kind==ItemKind.UserMessage && item.provenance.source=="fork" && item.provenance.runId.isSome() &&
        item.provenance.operationId.isNone() && item.provenance.directOrigin.isNone() &&
        item.provenance.continuationOrigin.isNone() && item.provenance.continuationHistory.isNone() &&
        item.provenance.completedInitiatorHistory173e.isNone()
}
func completedUserCount174(tx: SqliteTransaction,sql: String,args: Array<SqlParameter>): Int64 {
    let rows=tx.query(sql,args)
    if (rows.size!=1) { throw IllegalStateException("User/model history scalar is absent or duplicated") }
    let count=journalStreamInteger(rows[0].required(0))
    if (count<0) { throw IllegalStateException("User/model history scalar is negative") };count
}
func completedUserParameters174(item: ThreadItem,payment: CompletedInitiatorPayment173e): Array<SqlParameter> {
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(item.threadId.value.size,
        journalStreamAdd(item.turnId.value.size,item.id.value.size)),16)))
    [SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value),SqlParameter.Text(item.id.value)]
}

// The User was committed before Run admission; do not put a fabricated Run in
// its provenance. Select ALL original Runs and a unique maximum epoch only as
// a historical description. Closed failed/cancelled/superseded Turns and older
// Runs of every original valid state remain DATA, including Unknown receipts.
func completedUserWithOriginalAnchor174(tx: SqliteTransaction,item: ThreadItem,payment: CompletedInitiatorPayment173e,
    consume: (CompletedUserAnchor174) -> Unit): Unit {
    if (!completedUserOriginal174(item)) { throw IllegalStateException("User/model history lacks its ordinary original User") }
    let args=completedUserParameters174(item,payment)
    let suffix=" FROM turns t JOIN items i ON i.thread_id=t.thread_id AND i.turn_id=t.id AND i.id=t.user_item_id "+
        "WHERE t.thread_id=? AND t.id=? AND i.id=? AND i.kind='user_message' AND t.active_run_id IS NULL "+
        "AND t.state IN ('completed','failed','cancelled','superseded')"
    if (completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)!=1) {
        throw IllegalStateException("User/model history lacks its actual closed original Turn")
    }
    let runArgs=[args[0],args[1]]
    let counts=tx.query("SELECT COUNT(*),COALESCE(MAX(epoch),0),COALESCE(SUM(CASE WHEN epoch<1 THEN 1 ELSE 0 END),0) "+
        "FROM runs WHERE thread_id=? AND turn_id=?",runArgs)
    if (counts.size!=1 || journalStreamInteger(counts[0].required(0))<1 || journalStreamInteger(counts[0].required(1))<1 ||
        journalStreamInteger(counts[0].required(2))!=0) { throw IllegalStateException("User/model history has no complete original Run set") }
    let count=journalStreamInteger(counts[0].required(0));let epoch=journalStreamInteger(counts[0].required(1))
    let selectedArgs=[args[0],args[1],SqlParameter.Int64Value(epoch)]
    let selected=" FROM runs WHERE thread_id=? AND turn_id=? AND epoch=?"
    let sizes=tx.query("SELECT length(CAST(id AS BLOB))"+selected,selectedArgs)
    if (sizes.size!=1) { throw IllegalStateException("User/model history has ambiguous latest epoch") }
    let bytes=journalStreamInteger(sizes[0].required(0))
    payment.withPeak173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(bytes,16)),{=>
        let rows=tx.query("SELECT id"+selected,selectedArgs)
        if (rows.size!=1 || rows[0].required(0).size!=bytes || rows[0].required(0)=="") {
            throw IllegalStateException("User/model history latest Run identity changed")
        }
        if (item.provenance.runId.isSome() && completedUserCount174(tx,
            "SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=? AND id=?",
            [args[0],args[1],SqlParameter.Text(item.provenance.runId.getOrThrow().value)])!=1) {
            throw IllegalStateException("original User provenance references a foreign Run")
        }
        let states=tx.query("SELECT t.state"+suffix,args)
        if (states.size!=1) { throw IllegalStateException("User/model history Turn changed") }
        let anchor=CompletedUserAnchor174(rows[0].required(0),epoch,count,states[0].required(0))
        consume(anchor)
        if (completedUserCount174(tx,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=?",runArgs)!=count ||
            completedUserCount174(tx,"SELECT COALESCE(MAX(epoch),0) FROM runs WHERE thread_id=? AND turn_id=?",runArgs)!=epoch ||
            completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)!=1) {
            throw IllegalStateException("User/model history original Run set changed during its paid loan")
        }
    })
}

func completedUserColumn174(value: String): Bool {
    if (value=="") { return false }
    for (byte in unsafe { value.rawData() }) {
        if (!((byte>=b'a' && byte<=b'z') || (byte>=b'A' && byte<=b'Z') ||
            (byte>=b'0' && byte<=b'9') || byte==b'_')) { return false }
    };true
}
func completedUserTargetFrom174(tx: SqliteTransaction,item: ThreadItem,target: ThreadId,
    payment: CompletedInitiatorPayment173e): CompletedUserTarget174 {
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(target.value.size,64)))
    let turns=tx.query("SELECT ordinal FROM turns WHERE thread_id=? AND id=?",
        [SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.turnId.value)])
    if (turns.size!=1) { throw IllegalStateException("User/model history source Turn is absent") }
    let ordinal=journalStreamInteger(turns[0].required(0))
    CompletedUserTarget174(target.value,"seed-turn-"+target.value+"-"+ordinal.toString(),
        "seed-run-"+target.value+"-"+ordinal.toString(),"seed-item-"+target.value+"-"+item.ordinal.toString(),item.ordinal,item.createdAtMillis)
}

// INSERT SELECT keeps a complete 8 MiB SQL cell inside SQLite. The ordinary
// raw reader/hash/helper has ALREADY returned before this producer begins, so
// its array/String is not added to a simultaneous second full-text binding.
// Parameters contain paid identities only. Equality compares complete bytes
// in the same transaction; no hash is used as a substitute for that equality.
func completedUserInsertSelectedCell174(tx: SqliteTransaction,target: CompletedUserTarget174,sequence: Int64,
    label: String,table: String,column: String,rowid: Int64,bytes: Int64,payment: CompletedInitiatorPayment173e): Unit {
    payment.withPeak173e(journalStreamAdd(65536,journalStreamAdd(ownedThreadReadbackMultiply(bytes,6),
        ownedThreadReadbackMultiply(label.size,16))),{=>
        let kind=COMPLETED_USER_CELL174+label
        let args=[SqlParameter.Text(target.thread),SqlParameter.Text(target.run),SqlParameter.Text(target.item),
            SqlParameter.Text(kind),SqlParameter.Int64Value(target.created),SqlParameter.Int64Value(sequence),SqlParameter.Int64Value(rowid)]
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) "+
            "SELECT ?,?,?,?,CAST(COALESCE("+column+",'') AS TEXT),?,? FROM "+table+" WHERE rowid=?",args)
        let equal=tx.query("SELECT COUNT(*) FROM audit_events a JOIN "+table+" s ON s.rowid=? "+
            "WHERE a.thread_id=? AND a.run_id=? AND a.operation_id=? AND a.kind=? AND a.created_at_millis=? "+
            "AND a.commit_sequence=? AND CAST(a.payload AS BLOB)=CAST(COALESCE(s."+column+",'') AS BLOB)",
            [args[6],args[0],args[1],args[2],args[3],args[4],args[5]])
        let total=tx.query("SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND operation_id=? AND commit_sequence=? "+
            "AND substr(kind,1,?)=?",[args[0],args[2],args[5],SqlParameter.Int64Value(COMPLETED_USER_CELL174.size),SqlParameter.Text(COMPLETED_USER_CELL174)])
        if (equal.size!=1 || total.size!=1 || journalStreamInteger(equal[0].required(0))!=1 || journalStreamInteger(total[0].required(0))!=1) {
            throw IllegalStateException("User/model history INSERT changed a complete original SQL cell")
        }
        journalStreamCheck(payment.current)
    })
}
func completedUserInsertScalar174(tx: SqliteTransaction,target: CompletedUserTarget174,sequence: Int64,label: String,
    value: String,payment: CompletedInitiatorPayment173e): Unit {
    payment.withPeak173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(label.size,value.size),16)),{=>
        let args=[SqlParameter.Text(target.thread),SqlParameter.Text(target.run),SqlParameter.Text(target.item),
            SqlParameter.Text(COMPLETED_USER_CELL174+label),SqlParameter.Text(value),SqlParameter.Int64Value(target.created),SqlParameter.Int64Value(sequence)]
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES(?,?,?,?,?,?,?)",args)
        if (completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? "+
            "AND kind=? AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND created_at_millis=? AND commit_sequence=?",args)!=1) {
            throw IllegalStateException("User/model history scalar INSERT changed")
        }
    })
}
func completedUserAddScalar174(tx: SqliteTransaction,state: CompletedUserEvidence174,target: ?CompletedUserTarget174,
    label: String,value: String,payment: CompletedInitiatorPayment173e): Unit {
    let sequence=state.cells;state.add174(label,value)
    match (target) { case Some(actual)=>completedUserInsertScalar174(tx,actual,sequence,label,value,payment);case None=>() }
}
func completedUserVisitCell174(tx: SqliteTransaction,table: String,column: String,rowid: Int64,label: String,
    state: CompletedUserEvidence174,target: ?CompletedUserTarget174,payment: CompletedInitiatorPayment173e): Unit {
    let args=[SqlParameter.Int64Value(rowid)];let suffix=" FROM "+table+" WHERE rowid=?"
    let sizes=tx.query("SELECT typeof("+column+"),length(CAST(COALESCE("+column+",'') AS BLOB))"+suffix,args)
    if (sizes.size!=1) { throw IllegalStateException("User/model history cell is absent") }
    let kind=sizes[0].required(0);let bytes=journalStreamInteger(sizes[0].required(1));let fullLabel=label+":"+kind
    let sequence=state.cells
    payment.raw173e(tx,column,suffix,args,{actual,raw=>
        if (actual!=kind) { throw IllegalStateException("User/model history cell storage kind changed") }
        state.add174(fullLabel,raw)
    })
    // No complete raw value leaves the preceding helper. SQLite copies the
    // exact current source cell only after that producer/consumer frame exits.
    match (target) { case Some(actual)=>completedUserInsertSelectedCell174(tx,actual,sequence,fullLabel,table,column,rowid,bytes,payment)
        case None=>() }
}

// Closed host selectors below enumerate every ACTUAL column of each selected
// schema. A later column (including transcript_snapshot) cannot disappear from
// the audit merely because an older codec did not know that column.
func completedUserVisitTable174(tx: SqliteTransaction,table: String,suffix: String,args: Array<SqlParameter>,
    state: CompletedUserEvidence174,target: ?CompletedUserTarget174,payment: CompletedInitiatorPayment173e,labelPrefix!: String=""): Unit {
    journalStreamCheck(payment.current)
    let rows=completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)
    let fields=completedUserCount174(tx,"SELECT COUNT(*) FROM pragma_table_info(?)",[SqlParameter.Text(table)])
    if (fields<1) { throw IllegalStateException("User/model history original schema is absent") }
    let prefix=if(labelPrefix==""){table}else{labelPrefix}
    completedUserAddScalar174(tx,state,target,prefix+".rows:integer",rows.toString(),payment)
    completedUserAddScalar174(tx,state,target,prefix+".columns:integer",fields.toString(),payment)
    for (at in 0..rows) {
        payment.fund173e(65536)
        let selectedArgs=Array<SqlParameter>(args.size+1,{ i=>if(i<args.size){args[i]}else{SqlParameter.Int64Value(at)} })
        let selected=tx.query("SELECT rowid"+suffix+" ORDER BY rowid LIMIT 1 OFFSET ?",selectedArgs)
        if (selected.size!=1) { throw IllegalStateException("User/model history row set changed") }
        let rowid=journalStreamInteger(selected[0].required(0))
        for (columnAt in 0..fields) {
            let ca=[SqlParameter.Text(table),SqlParameter.Int64Value(columnAt)]
            let sizes=tx.query("SELECT length(CAST(name AS BLOB)) FROM pragma_table_info(?) WHERE cid=?",ca)
            if (sizes.size!=1) { throw IllegalStateException("User/model history schema changed") }
            payment.withPeak173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamInteger(sizes[0].required(0)),16)),{=>
                let names=tx.query("SELECT name FROM pragma_table_info(?) WHERE cid=?",ca)
                if (names.size!=1 || names[0].required(0).size!=journalStreamInteger(sizes[0].required(0)) ||
                    !completedUserColumn174(names[0].required(0))) { throw IllegalStateException("User/model history column is not a closed SQL identifier") }
                completedUserVisitCell174(tx,table,names[0].required(0),rowid,prefix+"."+at.toString()+"."+names[0].required(0),state,target,payment)
            })
        }
    }
    if (completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)!=rows) { throw IllegalStateException("User/model history row set changed after its copy") }
}

func completedUserVisitOriginal174(tx: SqliteTransaction,item: ThreadItem,anchor: CompletedUserAnchor174,
    state: CompletedUserEvidence174,target: ?CompletedUserTarget174,payment: CompletedInitiatorPayment173e): Unit {
    let ids=completedUserParameters174(item,payment);let args=[ids[0],ids[1]]
    let initiator=tx.query("SELECT rowid FROM items WHERE thread_id=? AND turn_id=? AND id=?",ids)
    if (initiator.size!=1) { throw IllegalStateException("User/model history initiator Item is absent") }
    completedUserVisitCell174(tx,"items","provenance",journalStreamInteger(initiator[0].required(0)),"initial.provenance",state,target,payment)
    completedUserVisitTable174(tx,"items"," FROM items WHERE thread_id=? AND turn_id=?",args,state,target,payment)
    completedUserVisitTable174(tx,"turns"," FROM turns WHERE thread_id=? AND id=?",args,state,target,payment)
    completedUserVisitTable174(tx,"runs"," FROM runs WHERE thread_id=? AND turn_id=?",args,state,target,payment)
    let runs="SELECT id FROM runs WHERE thread_id=? AND turn_id=?"
    for (table in ["model_attempts","operations","run_model_usage","run_journal","app_run_events",
        "app_run_event_heads","run_continuations","run_continuation_facts","legacy_run_continuation_imports",
        "run_lane_bindings","run_composition_bindings","step_records","lane_run_admissions"]) {
        completedUserVisitTable174(tx,table," FROM "+table+" WHERE run_id IN ("+runs+")",args,state,target,payment)
    }
    // Audit rows can bind an actual operation or continuation commit while
    // run_id is NULL. Preserve those original FK/commit facts as well.
    completedUserVisitTable174(tx,"audit_events"," FROM audit_events WHERE run_id IN ("+runs+") OR "+
        "operation_id IN (SELECT id FROM operations WHERE run_id IN ("+runs+")) OR "+
        "(thread_id=? AND commit_sequence>0 AND commit_sequence IN (SELECT commit_sequence FROM run_continuation_facts WHERE run_id IN ("+runs+")))",
        [args[0],args[1],args[0],args[1],args[0],args[0],args[1]],state,target,payment)
    completedUserVisitTable174(tx,"approval_decisions"," FROM approval_decisions WHERE run_id IN ("+runs+")",args,state,target,payment)
    let decisions="SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id WHERE a.run_id IN ("+runs+")"
    completedUserVisitTable174(tx,"model_decisions"," FROM model_decisions WHERE id IN ("+decisions+")",args,state,target,payment)
    for (table in ["model_decision_blocks","model_decision_usage","canonical_decision_items","decision_operations"]) {
        completedUserVisitTable174(tx,table," FROM "+table+" WHERE decision_id IN ("+decisions+")",args,state,target,payment)
    }
    for (table in ["operation_receipts","operation_effect_records","operation_state_registers","derived_operation_admissions","approvals"]) {
        completedUserVisitTable174(tx,table," FROM "+table+" WHERE operation_id IN (SELECT id FROM operations WHERE run_id IN ("+runs+"))",args,state,target,payment)
    }
    completedUserVisitTable174(tx,"context_manifests"," FROM context_manifests WHERE step_id IN (SELECT id FROM step_records WHERE run_id IN ("+runs+"))",args,state,target,payment)
    completedUserVisitTable174(tx,"composition_snapshots"," FROM composition_snapshots WHERE id IN (SELECT snapshot_id FROM run_composition_bindings WHERE run_id IN ("+runs+"))",args,state,target,payment)
    completedUserVisitTable174(tx,"lane_inbox_entries"," FROM lane_inbox_entries WHERE id IN (SELECT input_entry_id FROM step_records WHERE run_id IN ("+runs+"))",args,state,target,payment)
    completedUserVisitTable174(tx,"item_tree_edges"," FROM item_tree_edges WHERE item_id IN (SELECT id FROM items WHERE thread_id=? AND turn_id=?)",args,state,target,payment)
    // A binding's original lane is not a complete composition description
    // without its real parent chain. UNION deduplicates cycles/aliases rather
    // than manufacturing new lanes, admissions, Runs or grants.
    let laneClosure="WITH RECURSIVE original_user_lanes174(lane_id) AS ("+
        "SELECT lane_id FROM run_lane_bindings WHERE run_id IN ("+runs+") UNION "+
        "SELECT lane_id FROM step_records WHERE run_id IN ("+runs+") UNION "+
        "SELECT lane_id FROM item_tree_edges WHERE item_id IN (SELECT id FROM items WHERE thread_id=? AND turn_id=?) UNION "+
        "SELECT l.parent_lane_id FROM lanes l JOIN original_user_lanes174 s ON s.lane_id=l.lane_id "+
        "WHERE l.thread_id=? AND l.parent_lane_id IS NOT NULL) SELECT lane_id FROM original_user_lanes174"
    let laneArgs=[args[0],args[0],args[1],args[0],args[1],args[0],args[1],args[0]]
    completedUserVisitTable174(tx,"lanes"," FROM lanes WHERE thread_id=? AND lane_id IN ("+laneClosure+")",
        laneArgs,state,target,payment)
    // The outbox stores commit identity rather than a Run FK. Its actual
    // continuation facts bind precisely the original Run commit sequences.
    completedUserVisitTable174(tx,"app_event_outbox"," FROM app_event_outbox WHERE thread_id=? AND commit_sequence IN "+
        "(SELECT commit_sequence FROM run_continuation_facts WHERE run_id IN ("+runs+"))",[args[0],args[0],args[1]],state,target,payment)
    completedUserVisitPromptArtifacts174(tx,args,runs,state,target,payment)
    if (state.originDigest=="" || completedUserCount174(tx,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=?",args)!=anchor.count ||
        completedUserCount174(tx,"SELECT COALESCE(MAX(epoch),0) FROM runs WHERE thread_id=? AND turn_id=?",args)!=anchor.epoch) {
        throw IllegalStateException("User/model history all-Run graph changed inside its copy")
    }
    journalStreamCheck(payment.current)
}

class CompletedUserPromptReference174 {
    var count: Int64=0
    var value=""
}
// Extract one small actual PromptArtifact identity without manufacturing a
// complete ContextManifest DOM or returning its rendered/model request. This
// walks the ORIGINAL tagged Store frames, not JSON or a guessed provider wire.
// The complete source/frame/number/UTF8/count/depth/duplicate checks are kept.
class CompletedUserPromptWalker174 {
    let data: Array<Byte>
    let payment: CompletedInitiatorPayment173e
    let selected: Int64
    let output: CompletedUserPromptReference174
    var offset: Int64=0
    var start: Int64=0
    var end: Int64=0
    var keyBytes: Int64=0
    var keyCount: Int64=0
    init(raw: String,payment: CompletedInitiatorPayment173e,selected: Int64,output: CompletedUserPromptReference174) {
        if(raw.size>8388608){throw IllegalStateException("stored value exceeds 8 MiB")}
        this.data=unsafe{raw.rawData()};this.payment=payment;this.selected=selected;this.output=output
    }
    func frame174(): String {
        payment.fund173e(journalStreamAdd(131072,journalStreamAdd(ownedThreadReadbackMultiply(keyBytes,4),ownedThreadReadbackMultiply(keyCount,128))))
        let begin=offset
        while(offset<data.size && data[offset]>=b'0' && data[offset]<=b'9'){offset++}
        if(begin==offset || offset>=data.size || data[offset]!=b':'){throw IllegalStateException("stored value has an invalid length frame")}
        let size=parseStoredInt(String.fromUtf8(data[begin..offset]),"stored value frame length is invalid");offset++
        if(size<0 || size>data.size-offset){throw IllegalStateException("stored value frame is truncated")}
        start=offset;end=offset+size;let text=String.fromUtf8(data[start..end]);offset=end;text
    }
    func count174(): Int64 {
        let value=parseStoredInt(frame174(),"stored collection count is invalid")
        if(value<0 || value>1000000){throw IllegalStateException("stored collection count is out of bounds")};value
    }
    func value174(depth: Int64,mode: Int64): Unit {
        if(depth>64 || offset>=data.size){throw IllegalStateException("stored value is truncated or too deeply nested")}
        let tag=data[offset];offset++
        match(tag){
            case b'n' | b't' | b'f'=>if(mode==3){throw IllegalStateException("Prompt artifact reference is not text")}
            case b'd'=>let _=numberValue(frame174());if(mode==3){throw IllegalStateException("Prompt artifact reference is not text")}
            case b's'=>
                let text=frame174()
                if(mode==3){
                    if(text.size!=64){throw IllegalStateException("Prompt artifact reference has no original SHA256 identity")}
                    for(byte in unsafe{text.rawData()}){if(!((byte>=b'0' && byte<=b'9') || (byte>=b'a' && byte<=b'f'))){
                        throw IllegalStateException("Prompt artifact reference has no original SHA256 identity")}}
                    if(output.count==selected){output.value=String.fromUtf8(text.toArray())};output.count++
                }
            case b'l'=>
                let amount=count174()
                if(mode==3){throw IllegalStateException("Prompt artifact reference is not text")}
                for(_ in 0..amount){value174(depth+1,if(mode==1){2}else{-1})}
            case b'o'=>object174(depth,mode)
            case _=>throw IllegalStateException("stored value has an unknown type tag")
        }
    }
    func object174(depth: Int64,mode: Int64): Unit {
        if(mode==3){throw IllegalStateException("Prompt artifact reference is not text")}
        let amount=count174();let beforeBytes=keyBytes;let beforeCount=keyCount
        payment.fund173e(journalStreamAdd(65536,journalStreamAdd(ownedThreadReadbackMultiply(keyBytes,4),ownedThreadReadbackMultiply(keyCount,128))))
        let names=HashSet<String>()
        try{
            for(_ in 0..amount){
                let name=frame174();keyCount++;keyBytes=journalStreamAdd(keyBytes,name.size)
                payment.fund173e(journalStreamAdd(65536,journalStreamAdd(ownedThreadReadbackMultiply(keyBytes,4),ownedThreadReadbackMultiply(keyCount,128))))
                if(names.contains(name)){throw IllegalStateException("stored object has duplicate field")};names.add(name)
                let next=if(mode==0 && name=="prompt_contributions"){1}else if(mode==2 && name=="artifact_hash"){3}else{-1}
                value174(depth+1,next)
            }
        }finally{keyBytes=beforeBytes;keyCount=beforeCount}
    }
    func complete174(): Unit { value174(0,0);if(offset!=data.size){throw IllegalStateException("stored value has trailing bytes")} }
}
func completedUserVisitPromptArtifacts174(tx: SqliteTransaction,args: Array<SqlParameter>,runs: String,
    state: CompletedUserEvidence174,target: ?CompletedUserTarget174,payment: CompletedInitiatorPayment173e): Unit {
    let suffix=" FROM context_manifests WHERE step_id IN (SELECT id FROM step_records WHERE run_id IN ("+runs+"))"
    let count=completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)
    for(at in 0..count){
        let row=tx.query("SELECT rowid"+suffix+" ORDER BY rowid LIMIT 1 OFFSET ?",[args[0],args[1],SqlParameter.Int64Value(at)])
        if(row.size!=1){throw IllegalStateException("User/model manifest reference set changed")}
        var reference: Int64=0
        while(true){
            payment.fund173e(131072)
            let found=CompletedUserPromptReference174()
            let selectedReference=reference
            payment.raw173e(tx,"payload"," FROM context_manifests WHERE rowid=?",[SqlParameter.Int64Value(journalStreamInteger(row[0].required(0)))],{kind,raw=>
                if(kind!="text"){throw IllegalStateException("User/model manifest storage type changed")}
                // A fixed reference carrier survives; no full raw/DOM does.
                // The consumer itself returns before an artifact cell is read.
                CompletedUserPromptWalker174(raw,payment,selectedReference,found).complete174()
            })
            if(reference>=found.count){break}
            if(found.value=="" || completedUserCount174(tx,"SELECT COUNT(*) FROM prompt_contribution_artifacts WHERE hash=?",[SqlParameter.Text(found.value)])!=1){
                throw IllegalStateException("User/model original Prompt artifact is missing or duplicated")}
            completedUserVisitTable174(tx,"prompt_contribution_artifacts"," FROM prompt_contribution_artifacts WHERE hash=?",
                [SqlParameter.Text(found.value)],state,target,payment,labelPrefix:"manifest_prompt_artifact."+at.toString()+"."+reference.toString())
            reference++
        }
    }
}

class CompletedUserHistoryIdentity174 {
    let expected: CompletedUserModelHistory174
    var userRow: Int64 = -1
    var userChecks: Int64=0
    var turnChecks: Int64=0
    var runIds: Int64=0
    var anchorIds: Int64=0
    var currentAnchor=false
    var maximumEpoch: Int64=0
    var maximumCount: Int64=0
    var anchorEpoch: Int64=0
    var originalProvenance: Int64=0
    var declaredRuns: Int64 = -1
    init(expected: CompletedUserModelHistory174) { this.expected=expected }
    func observe174(label: String,raw: String,payment: CompletedInitiatorPayment173e): Unit {
        if (label=="initial.provenance:text") {
            originalProvenance++
            if (modelPolicySha256Text(raw)!=expected.originDigest) { throw IllegalStateException("User/model history original provenance digest changed") }
            payment.withDecoded173e(raw,{=>
                let value=decodeStoredProvenance(raw)
                if (value.source!="user" || value.operationId.isSome() || value.directOrigin.isSome() ||
                    value.continuationOrigin.isSome() || value.continuationHistory.isSome() || value.completedInitiatorHistory173e.isSome() ||
                    encodeStoredProvenance(value)!=raw) { throw IllegalStateException("User/model audit changed its ordinary original provenance") }
            })
            return
        }
        if (label=="runs.rows:integer") { declaredRuns=journalStreamInteger(raw);return }
        let parts=label.split(".")
        if (parts.size!=3) { return }
        let row=journalStreamInteger(parts[1]);let field=parts[2]
        if (parts[0]=="items") {
            if (field=="id:text" && raw==expected.itemId) {
                if (userRow>=0) { throw IllegalStateException("User/model audit duplicates the original initiator Item") }
                userRow=row;userChecks++
            }
            if (row==userRow) {
                if (field=="thread_id:text") { if(raw!=expected.threadId){throw IllegalStateException("User/model audit User has a foreign Thread")};userChecks++ }
                if (field=="turn_id:text") { if(raw!=expected.turnId){throw IllegalStateException("User/model audit User has a foreign Turn")};userChecks++ }
                if (field=="kind:text") { if(raw!="user_message"){throw IllegalStateException("User/model audit initiator is not its original User")};userChecks++ }
                if (field=="provenance:text") {
                    if(modelPolicySha256Text(raw)!=expected.originDigest){throw IllegalStateException("User/model audit User provenance disagrees with its independent initial cell")};userChecks++
                }
            }
        }
        if (parts[0]=="turns") {
            if (row!=0) { throw IllegalStateException("User/model audit has more than one original Turn") }
            if (field=="id:text") { if(raw!=expected.turnId){throw IllegalStateException("User/model audit Turn identity changed")};turnChecks++ }
            if (field=="thread_id:text") { if(raw!=expected.threadId){throw IllegalStateException("User/model audit Turn has a foreign Thread")};turnChecks++ }
            if (field=="user_item_id:text") { if(raw!=expected.itemId){throw IllegalStateException("User/model audit Turn references another User")};turnChecks++ }
            if (field=="state:text") { if(raw!=expected.turnState){throw IllegalStateException("User/model audit closed Turn state changed")};turnChecks++ }
            if (field=="active_run_id:null") { if(raw!=""){throw IllegalStateException("User/model audit original Turn is active")};turnChecks++ }
        }
        if (parts[0]=="runs") {
            if (field=="id:text") { runIds++;currentAnchor=raw==expected.runId;if(currentAnchor){anchorIds++} }
            if (field=="thread_id:text" && raw!=expected.threadId) { throw IllegalStateException("User/model audit contains a foreign Run Thread") }
            if (field=="turn_id:text" && raw!=expected.turnId) { throw IllegalStateException("User/model audit contains a foreign Run Turn") }
            if (field=="epoch:integer") {
                let epoch=journalStreamInteger(raw)
                if (epoch<1) { throw IllegalStateException("User/model audit Run epoch is invalid") }
                if (currentAnchor) { anchorEpoch=epoch }
                if (epoch>maximumEpoch) { maximumEpoch=epoch;maximumCount=1 } else if (epoch==maximumEpoch) { maximumCount++ }
            }
            if (field=="state:text" && !(raw=="created" || raw=="running" || raw=="waiting_approval" || raw=="waiting_external" ||
                raw=="cancelling" || raw=="cancelled" || raw=="completed" || raw=="failed" || raw=="recovery_required")) {
                throw IllegalStateException("User/model audit Run state is not an original RunState")
            }
        }
    }
    func finish174(): Unit {
        if (originalProvenance!=1 || userChecks!=5 || turnChecks!=5 || userRow<0 || runIds!=expected.runCount ||
            declaredRuns!=expected.runCount || anchorIds!=1 || anchorEpoch!=expected.latestEpoch ||
            maximumEpoch!=expected.latestEpoch || maximumCount!=1) {
            throw IllegalStateException("User/model audit header is not cross-bound to its complete original Item/Turn/Run cells")
        }
    }
}

// No decoded header escapes this paid callback. Missing/duplicate/corrupt
// present header, ledger or cell evidence is an error, never a None fallback.
// Genuine older forks without ANY of these records retain their old path.
func completedUserWithStoredHistory174(tx: SqliteTransaction,item: ThreadItem,payment: CompletedInitiatorPayment173e,
    consume: (CompletedUserModelHistory174) -> Unit): Bool {
    let parameters=completedUserParameters174(item,payment)
    let ids=[parameters[0],parameters[2]]
    let headers=completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
        [ids[0],ids[1],SqlParameter.Text(COMPLETED_USER_HEADER174)])
    let ledgers=completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND operation_id=? AND kind=?",
        [ids[0],ids[1],SqlParameter.Text(COMPLETED_USER_LEDGER174)])
    let cells=completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND operation_id=? AND substr(kind,1,?)=?",
        [ids[0],ids[1],SqlParameter.Int64Value(COMPLETED_USER_CELL174.size),SqlParameter.Text(COMPLETED_USER_CELL174)])
    if (headers==0 && ledgers==0 && cells==0) { return false }
    if (headers!=1 || ledgers!=1 || cells<1 || !completedUserFork174(item)) {
        throw IllegalStateException("User/model audit header/ledger/cells are absent, duplicated or bound to another Item kind")
    }
    let run=item.provenance.runId.getOrThrow().value
    let exact=[ids[0],SqlParameter.Text(run),ids[1]]
    if (completedUserCount174(tx,"SELECT COUNT(*) FROM turns t JOIN runs r ON r.thread_id=t.thread_id AND r.turn_id=t.id "+
        "JOIN items i ON i.thread_id=t.thread_id AND i.turn_id=t.id AND i.id=t.user_item_id "+
        "WHERE i.thread_id=? AND r.id=? AND i.id=? AND t.state='completed' AND t.active_run_id IS NULL "+
        "AND i.kind='user_message' AND r.state='completed'",exact)!=1) {
        throw IllegalStateException("User/model audit lost its unchanged canonical fork seed locator")
    }
    let headerRows=tx.query("SELECT rowid FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
        "AND created_at_millis=? AND commit_sequence=0",[exact[0],exact[1],exact[2],SqlParameter.Text(COMPLETED_USER_HEADER174),SqlParameter.Int64Value(item.createdAtMillis)])
    if (headerRows.size!=1) { throw IllegalStateException("User/model audit header locator changed") }
    payment.raw173e(tx,"payload"," FROM audit_events WHERE rowid=?",[SqlParameter.Int64Value(journalStreamInteger(headerRows[0].required(0)))],{kind,raw=>
        if (kind!="text") { throw IllegalStateException("User/model audit header storage type changed") }
        payment.withDecoded173e(raw,{=>
            let history=completedUserModelHistoryFromValue174(decodeStoredValue(raw))
            if (encodeStoredValue(completedUserModelHistoryValue174(history))!=raw || history.evidenceCells!=cells ||
                completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
                    "AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND created_at_millis=? AND commit_sequence=?",
                    [exact[0],exact[1],exact[2],SqlParameter.Text(COMPLETED_USER_LEDGER174),SqlParameter.Text(modelPolicySha256Text(raw)),
                        SqlParameter.Int64Value(item.createdAtMillis),SqlParameter.Int64Value(item.ordinal)])!=1) {
                throw IllegalStateException("User/model audit header differs from its independently retained ordinal/seedRun ledger")
            }
            completedUserVisitHistory174(tx,item,history,None<CompletedUserTarget174>,payment)
            consume(history)
        })
    })
    journalStreamCheck(payment.current);true
}

func completedUserVisitHistory174(tx: SqliteTransaction,item: ThreadItem,history: CompletedUserModelHistory174,
    target: ?CompletedUserTarget174,payment: CompletedInitiatorPayment173e): Unit {
    payment.fund173e(131072)
    let state=CompletedUserEvidence174();let identity=CompletedUserHistoryIdentity174(history)
    let suffix=" FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND substr(kind,1,?)=?"
    let args=[SqlParameter.Text(item.threadId.value),SqlParameter.Text(item.provenance.runId.getOrThrow().value),
        SqlParameter.Text(item.id.value),SqlParameter.Int64Value(COMPLETED_USER_CELL174.size),SqlParameter.Text(COMPLETED_USER_CELL174)]
    if (completedUserCount174(tx,"SELECT COUNT(*)"+suffix,args)!=history.evidenceCells ||
        completedUserCount174(tx,"SELECT COUNT(*)"+suffix+" AND created_at_millis!=?",[args[0],args[1],args[2],args[3],args[4],SqlParameter.Int64Value(item.createdAtMillis)])!=0) {
        throw IllegalStateException("User/model audit cell extent or timestamp changed")
    }
    for (at in 0..history.evidenceCells) {
        let selectedArgs=[args[0],args[1],args[2],args[3],args[4],SqlParameter.Int64Value(at)]
        let rows=tx.query("SELECT rowid,length(CAST(kind AS BLOB)),length(CAST(payload AS BLOB))"+suffix+" AND commit_sequence=?",selectedArgs)
        if (rows.size!=1) { throw IllegalStateException("User/model audit has a missing or duplicated cell sequence") }
        let rowid=journalStreamInteger(rows[0].required(0));let labelBytes=journalStreamInteger(rows[0].required(1));let bytes=journalStreamInteger(rows[0].required(2))
        payment.withPeak173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(labelBytes,16)),{=>
            let names=tx.query("SELECT kind FROM audit_events WHERE rowid=?",[SqlParameter.Int64Value(rowid)])
            if (names.size!=1 || names[0].required(0).size!=labelBytes || !names[0].required(0).startsWith(COMPLETED_USER_CELL174)) {
                throw IllegalStateException("User/model audit cell label changed")
            }
            let label=names[0].required(0)[COMPLETED_USER_CELL174.size..]
            payment.raw173e(tx,"payload"," FROM audit_events WHERE rowid=?",[SqlParameter.Int64Value(rowid)],{kind,raw=>
                if (kind!="text") { throw IllegalStateException("User/model audit frozen SQL cell is not TEXT") }
                state.add174(label,raw);identity.observe174(label,raw,payment)
            })
            match (target) { case Some(actual)=>completedUserInsertSelectedCell174(tx,actual,at,label,"audit_events","payload",rowid,bytes,payment)
                case None=>() }
        })
    }
    if (state.cells!=history.evidenceCells || state.digest!=history.evidenceDigest || state.originDigest!=history.originDigest) {
        throw IllegalStateException("User/model audit whole evidence digest changed")
    }
    identity.finish174();journalStreamCheck(payment.current)
}

func completedUserInsertHeader174(tx: SqliteTransaction,target: CompletedUserTarget174,history: CompletedUserModelHistory174,
    payment: CompletedInitiatorPayment173e): Unit {
    var bytes: Int64=0
    for (value in [history.threadId,history.turnId,history.runId,history.itemId]) { bytes=journalStreamAdd(bytes,value.size) }
    payment.withPeak173e(journalStreamAdd(4194304,ownedThreadReadbackMultiply(bytes,32)),{=>
        let encoded=encodeStoredValue(completedUserModelHistoryValue174(history));let digest=modelPolicySha256Text(encoded)
        let args=[SqlParameter.Text(target.thread),SqlParameter.Text(target.run),SqlParameter.Text(target.item),
            SqlParameter.Text(COMPLETED_USER_HEADER174),SqlParameter.Text(encoded),SqlParameter.Int64Value(target.created)]
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES(?,?,?,?,?,?,0)",args)
        tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES(?,?,?,?,?,?,?)",
            [args[0],args[1],args[2],SqlParameter.Text(COMPLETED_USER_LEDGER174),SqlParameter.Text(digest),args[5],SqlParameter.Int64Value(target.ordinal)])
        if (completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND run_id=? AND operation_id=? AND kind=? "+
            "AND CAST(payload AS BLOB)=CAST(? AS BLOB) AND created_at_millis=? AND commit_sequence=0",args)!=1) {
            throw IllegalStateException("User/model audit header changed during its INSERT")
        }
    })
}

// Only a private temporary identity view; its content is the already paid
// immutable source loan. The actual original clone/writer remains untouched.
func completedUserTargetItem174(source: ThreadItem,target: CompletedUserTarget174,
    payment: CompletedInitiatorPayment173e): ThreadItem {
    payment.fund173e(journalStreamAdd(65536,ownedThreadReadbackMultiply(journalStreamAdd(target.thread.size,
        journalStreamAdd(target.turn.size,journalStreamAdd(target.run.size,target.item.size))),16)))
    ThreadItem(ItemId(target.item),ThreadId(target.thread),SemanticTurnId(target.turn),target.ordinal,source.content,
        ItemProvenance("fork",runId:Some(RunId(target.run))),createdAtMillis:target.created)
}
func completedUserRequireCopied174(tx: SqliteTransaction,source: ThreadItem,target: CompletedUserTarget174,
    payment: CompletedInitiatorPayment173e): Unit {
    let item=completedUserTargetItem174(source,target,payment)
    if (!completedUserWithStoredHistory174(tx,item,payment,{_=>()})) {
        throw IllegalStateException("User/model audit just copied lost its required header/ledger")
    }
}

// Called AFTER completedForkInsertItem173d wholly returns and copyPeak is
// cleared. This preserves its original complete payload/provenance encoders,
// fork defaults, seed Runs, direct/continuation audit and old oracle bytes.
func completedUserCopyHistory174(tx: SqliteTransaction,source: ThreadItem,targetThread: ThreadId,
    forkPayment: CompletedForkPayment173d,current: () -> Result<Unit>): Unit {
    if (source.kind!=ItemKind.UserMessage) { return }
    forkPayment.owner.ensureRetainedPeak(forkPayment.extra173d(journalStreamAdd(forkPayment.rowPeak,131072)))
    let payment=CompletedInitiatorPayment173e(forkPayment.owner,forkPayment.extra173d(forkPayment.rowPeak),current)
    payment.withPeak173e(journalStreamAdd(262144,ownedThreadReadbackMultiply(targetThread.value.size,64)),{=>
    let target=completedUserTargetFrom174(tx,source,targetThread,payment)
    if (completedUserOriginal174(source)) {
        let ids=completedUserParameters174(source,payment)
        if (completedUserCount174(tx,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=?",[ids[0],ids[1]])==0) {
            // Legitimate seeded/User-only legacy history has no original Run.
            // Its unchanged original fork recipe is the complete contract.
            return
        }
        completedUserWithOriginalAnchor174(tx,source,payment,{anchor=>
            payment.fund173e(131072)
            let before=CompletedUserEvidence174()
            completedUserVisitOriginal174(tx,source,anchor,before,None<CompletedUserTarget174>,payment)
            let history=CompletedUserModelHistory174(source.threadId.value,source.turnId.value,anchor.run,source.id.value,
                anchor.turnState,anchor.epoch,anchor.count,before.originDigest,before.digest,before.cells)
            let copied=CompletedUserEvidence174()
            completedUserVisitOriginal174(tx,source,anchor,copied,Some(target),payment)
            if (copied.cells!=before.cells || copied.digest!=before.digest || copied.originDigest!=before.originDigest) {
                throw IllegalStateException("User/model complete original graph changed during its copy")
            }
            completedUserInsertHeader174(tx,target,history,payment)
            completedUserRequireCopied174(tx,source,target,payment)
            let after=CompletedUserEvidence174()
            completedUserVisitOriginal174(tx,source,anchor,after,None<CompletedUserTarget174>,payment)
            if (after.cells!=before.cells || after.digest!=before.digest) {
                throw IllegalStateException("User/model original graph changed after its audit INSERTs")
            }
        })
        return
    }
    if (completedUserFork174(source)) {
        // A copied header describes the ORIGINAL Runs, never its seed Run.
        // This continues to work after closing/reopening or dropping the
        // original Thread; no original Run is recreated as live business DATA.
        let _=completedUserWithStoredHistory174(tx,source,payment,{history=>
            completedUserVisitHistory174(tx,source,history,Some(target),payment)
            completedUserInsertHeader174(tx,target,history,payment)
            completedUserRequireCopied174(tx,source,target,payment)
            completedUserVisitHistory174(tx,source,history,None<CompletedUserTarget174>,payment)
        })
    }
    })
}

class CompletedUserThreadEvidence174 {
    var digest=modelPolicySha256Text("axyndra.completed-user-model-thread/v1")
    var persistedCells: Int64=0
    var persistedHeads: Int64=0
    func add174(item: ThreadItem,evidence: String,cells: Int64,persisted: Bool): Unit {
        digest=modelPolicySha256Text(digest+":"+item.ordinal.toString()+":"+modelPolicySha256Text(item.id.value)+":"+evidence)
        if (persisted) { persistedHeads++;persistedCells=journalStreamAdd(persistedCells,cells) }
    }
}
func completedUserThreadEvidence174(tx: SqliteTransaction,thread: ThreadId,header: CompletedForkHeader173d,
    forkPayment: CompletedForkPayment173d,current: () -> Result<Unit>): String {
    forkPayment.transient173d(131072)
    let state=CompletedUserThreadEvidence174()
    var ordinal: Int64=1
    while (ordinal<header.next) {
        completedForkWithItem173d(tx,thread,header.revision,ordinal,forkPayment,current,{item,_,_=>
            forkPayment.owner.ensureRetainedPeak(forkPayment.extra173d(journalStreamAdd(forkPayment.rowPeak,131072)))
            let payment=CompletedInitiatorPayment173e(forkPayment.owner,forkPayment.extra173d(forkPayment.rowPeak),current)
            payment.withPeak173e(131072,{=>
            if (completedUserOriginal174(item)) {
                let ids=completedUserParameters174(item,payment)
                if (completedUserCount174(tx,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND turn_id=?",[ids[0],ids[1]])>0) {
                    completedUserWithOriginalAnchor174(tx,item,payment,{anchor=>
                        payment.fund173e(131072)
                        let evidence=CompletedUserEvidence174()
                        completedUserVisitOriginal174(tx,item,anchor,evidence,None<CompletedUserTarget174>,payment)
                        state.add174(item,evidence.digest,evidence.cells,false)
                    })
                }
            } else if (completedUserFork174(item)) {
                let _=completedUserWithStoredHistory174(tx,item,payment,{history=>state.add174(item,history.evidenceDigest,history.evidenceCells,true)})
            }
            })
        })
        ordinal++
    }
    // The independent thread ledger catches a missing whole User header/cell
    // group while any evidence marker remains. Orphan markers also fail.
    // Removing ALL markers, headers and cells erases the distinction from a
    // real pre174 legacy fork; preserving its original provenance necessarily
    // leaves that information-loss boundary rather than inventing authority.
    let args=[SqlParameter.Text(thread.value)]
    if (completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND kind='completed_user_model_history174_v1'",args)!=state.persistedHeads ||
        completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND kind='completed_user_model_ledger174_v1'",args)!=state.persistedHeads ||
        completedUserCount174(tx,"SELECT COUNT(*) FROM audit_events WHERE thread_id=? AND substr(kind,1,"+
            COMPLETED_USER_CELL174.size.toString()+")='"+COMPLETED_USER_CELL174+"'",args)!=state.persistedCells) {
        throw IllegalStateException("User/model thread history ledger has an absent or orphan User group")
    }
    journalStreamCheck(current);state.digest
}
