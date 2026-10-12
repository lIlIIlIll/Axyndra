package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

let JOURNAL_STREAM_V2_MAGIC="AXYNDRJ2\n"

class JournalStreamV2Fence {
    let rows:Int64
    let events:Int64
    let payloadBytes:Int64
    let sequence:Int64
    let sequencePresent:Bool
    let digest:String
    init(rows:Int64,events:Int64,payloadBytes:Int64,sequence:Int64,sequencePresent:Bool,digest:String){
        this.rows=rows;this.events=events;this.payloadBytes=payloadBytes;this.sequence=sequence;this.sequencePresent=sequencePresent;this.digest=digest}
    func value():AgentValue{objectValue([ValueField("codec",textValue("fixed-cells/v2")),ValueField("rows",integerValue(rows)),
        ValueField("events",integerValue(events)),ValueField("payload_bytes",integerValue(payloadBytes)),
        ValueField("sequence",integerValue(sequence)),ValueField("sequence_present",boolValue(sequencePresent)),ValueField("sha256",textValue(digest))])}
}
class JournalStreamV2ProjectedCell {
    let cell:FixedJournalCellObservation
    let projection:JsonFieldStreamProjection
    let readable:Bool
    private let owner:LogicalJsonOwnerReservation
    init(cell:FixedJournalCellObservation,projection:JsonFieldStreamProjection,readable:Bool,owner:LogicalJsonOwnerReservation){
        this.cell=cell;this.projection=projection;this.readable=readable;this.owner=owner}
    func close():Unit{owner.close()}
}
class JournalStreamV2Emitter {
    private let hash=SHA256()
    private let action:?(Int64,Array<Byte>)->Unit
    private let guard:()->Result<Unit>
    var bytes:Int64=0
    init(action:?(Int64,Array<Byte>)->Unit,guard:()->Result<Unit>){this.action=action;this.guard=guard}
    func write(value:Array<Byte>):Unit{
        if(value.isEmpty() || value.size>65536){throw IllegalStateException("stream emission exceeds its paid chunk")}
        journalStreamCheck(guard);let next=journalStreamAdd(bytes,value.size)
        hash.write(value);match(action){case Some(consume)=>consume(bytes,value);case None=>()}
        bytes=next;journalStreamCheck(guard)}
    func header(value:AgentValue):Unit{
        let raw=stringifyUnifiedJson(value)
        if(raw.size<1 || raw.size>16384){throw IllegalStateException("fixed stream header exceeds its strict bound")}
        write((raw.size.toString()+":"+raw).toArray())}
    func digest():String{logicalJsonEncodeHex(hash.finish())}
}

// Trusted operator assembly only. This class is not a Source, permission,
// table selector, workspace resolver or Native business service. The original
// document/window data paths still delegate their exact existing backend.
public class SqliteOpaqueRowJournalStreamBackend <: PluginDocumentStorageBackend {
    private let original:SqliteOpaqueRowJournalWindowBackend
    private let namespace:String
    private let documentKey:String
    private let workspace:String
    private let settings:String
    private let access:RowJournalStructuralAccess
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let streamConfiguration:(NormalizedOperationPlan)->Result<Unit>
    public prop identity:String{get(){original.identity}}
    // Closed package-local delegation preserves the original typed Window
    // checks. It does not parse a DTO or grant access to another backend.
    func windowBackend():SqliteOpaqueRowJournalWindowBackend{original}
    public init(original:SqliteOpaqueRowJournalWindowBackend,namespace:String,key:String,workspace:String,settings:String,
        access:RowJournalStructuralAccess,allocate:(Int64)->LogicalJsonOwnerReservation,
        streamConfiguration:(NormalizedOperationPlan)->Result<Unit>){
        if(!httpServicePluginNamespace(namespace) || !documentIdentity(ThreadId("journal"),LaneId("main"),namespace,key)){
            throw IllegalArgumentException("invalid actual fixed stream assembly mapping")}
        this.original=original;this.namespace=namespace;this.documentKey=key;this.workspace=workspace;this.settings=settings
        this.access=access;this.allocate=allocate;this.streamConfiguration=streamConfiguration}
    public func read(tx:SqliteTransaction,thread:ThreadId,lane:LaneId,namespace:String,key:String):PluginDocumentSnapshot{
        original.read(tx,thread,lane,namespace,key)}
    public func recordRead(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,value:PluginDocumentSnapshot):Unit{
        original.recordRead(tx,source,plan,value)}
    public func requireParentFence(tx:SqliteTransaction,parent:OperationId,run:RunId,intent:PluginDocumentIntent):Unit{
        original.requireParentFence(tx,parent,run,intent)}
    public func compareExchange(tx:SqliteTransaction,expected:PluginDocumentSnapshot,next:String):PluginDocumentSnapshot{
        original.compareExchange(tx,expected,next)}
    func check(plan:NormalizedOperationPlan):Unit{
        let request=plan.canonicalArguments
        if((!pluginDocumentJournalStreamReadRequestValid(request) && !pluginDocumentContextJournalStreamReadRequestValid(request)) ||
            httpIntentText(request.field("binding").getOrThrow(),"namespace")!=namespace ||
            httpIntentText(request,"key")!=documentKey || httpIntentText(request,"access_policy_digest")!=access.digest){
            throw IllegalStateException("strict stream request differs from the actual frozen data mapping")}
        journalStreamCheck({=>streamConfiguration(plan)})}
    func owner(bytes:Int64):LogicalJsonOwnerReservation{allocate(bytes)}
    func revision(tx:SqliteTransaction):Int64{original.revision(tx)}
    func annotations(source:DirectToolCallRef,lane:LaneId):AgentValue{
        objectValue([ValueField("workspace_root",textValue(workspace)),ValueField("settings_root",textValue(settings)),
            ValueField("thread_id",textValue(source.threadId.value)),ValueField("lane_id",textValue(lane.value))])}
    func cell(tx:SqliteTransaction,kind:FixedJournalCell,rowid:Int64,guard:()->Result<Unit>):FixedJournalCellObservation{
        tx.readFixedJournalCell(kind,rowid,None,guard,allocate,None)}
    func copy(tx:SqliteTransaction,kind:FixedJournalCell,rowid:Int64,observed:FixedJournalCellObservation,
        guard:()->Result<Unit>,emit:JournalStreamV2Emitter):Unit{
        tx.readFixedJournalCell(kind,rowid,Some(observed),guard,allocate,Some({_,bytes=>emit.write(bytes)}))}
    func project(tx:SqliteTransaction,kind:FixedJournalCell,rowid:Int64,thread:String,guard:()->Result<Unit>):JournalStreamV2ProjectedCell{
        let observed=cell(tx,kind,rowid,guard);let lease=allocate(65536)
        try{
            let parser=access.projector(observed.bytes,observed.digest,lease,thread,workspace)
            tx.readFixedJournalCell(kind,rowid,Some(observed),guard,allocate,Some({offset,bytes=>parser.append(offset,bytes)}))
            let projection=parser.finish();let readable=access.describesReadable(projection,thread,workspace)
            journalStreamCheck(guard);JournalStreamV2ProjectedCell(observed,projection,readable,lease)
        }catch(error:Exception){lease.close();throw error}}
    // Every original row, column, event order and sequence/absence contributes
    // to this private whole fence. No per-private-row ID or raw digest leaves
    // the actual data owner. No corpus, header list or business DTO is retained.
    func full(tx:SqliteTransaction,guard:()->Result<Unit>):JournalStreamV2Fence{
        let lease=allocate(65536)
        try{
            lease.ensureRetainedPeak(1048576+65536*8)
            let hash=SHA256();hash.write("axyndra.fixed-cell-fence/v2".toArray())
            var rowCount:Int64=0;var eventCount:Int64=0;var payloadBytes:Int64=0;var after:?Int64=None
            while(true){journalStreamCheck(guard)
                let rows=match(after){
                    case None=>tx.query("SELECT rowid,revision,thread_id IS NULL FROM memories ORDER BY rowid LIMIT 1")
                    case Some(cursor)=>tx.query("SELECT rowid,revision,thread_id IS NULL FROM memories WHERE rowid>? ORDER BY rowid LIMIT 1",[SqlParameter.Int64Value(cursor)])}
                if(rows.isEmpty()){break};if(rows.size!=1 || rows[0].required(2)!="1"){
                    throw IllegalStateException("fixed current table has another tenant layout")}
                let row=rows[0];let rowid=journalStreamInteger(row.required(0))
                match(after){case Some(cursor)=>if(rowid<=cursor){throw IllegalStateException("fixed current cursor did not strictly advance")};case None=>()}
                after=Some(rowid)
                let key=cell(tx,FixedJournalCell.CurrentKey,rowid,guard);let kind=cell(tx,FixedJournalCell.CurrentKind,rowid,guard)
                let payload=cell(tx,FixedJournalCell.CurrentPayload,rowid,guard)
                let value=objectValue([ValueField("table",textValue("rows")),ValueField("rowid",integerValue(rowid)),
                    ValueField("revision",integerValue(journalStreamInteger(row.required(1)))),
                    ValueField("key_bytes",integerValue(key.bytes)),ValueField("key_sha256",textValue(key.digest)),
                    ValueField("kind_bytes",integerValue(kind.bytes)),ValueField("kind_sha256",textValue(kind.digest)),
                    ValueField("payload_bytes",integerValue(payload.bytes)),ValueField("payload_sha256",textValue(payload.digest))])
                hash.write(journalStreamFrame(canonicalAgentValue(value)).toArray())
                rowCount=journalStreamAdd(rowCount,1);payloadBytes=journalStreamAdd(payloadBytes,payload.bytes)}
            after=None
            while(true){journalStreamCheck(guard)
                let rows=match(after){
                    case None=>tx.query("SELECT rowid,id,revision,created_at_millis FROM memory_events ORDER BY id LIMIT 1")
                    case Some(cursor)=>tx.query("SELECT rowid,id,revision,created_at_millis FROM memory_events WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Int64Value(cursor)])}
                if(rows.isEmpty()){break};if(rows.size!=1){throw IllegalStateException("fixed event order is ambiguous")}
                let row=rows[0];let eventid=journalStreamInteger(row.required(1))
                match(after){case Some(cursor)=>if(eventid<=cursor){throw IllegalStateException("fixed event cursor did not strictly advance")};case None=>()}
                if(journalStreamInteger(row.required(0))!=eventid){throw IllegalStateException("fixed original event rowid/primary key changed")}
                after=Some(eventid)
                let key=cell(tx,FixedJournalCell.EventKey,eventid,guard);let operation=cell(tx,FixedJournalCell.EventOperation,eventid,guard)
                let payload=cell(tx,FixedJournalCell.EventPayload,eventid,guard)
                let value=objectValue([ValueField("table",textValue("events")),ValueField("id",integerValue(eventid)),
                    ValueField("revision",integerValue(journalStreamInteger(row.required(2)))),ValueField("created_at_millis",integerValue(journalStreamInteger(row.required(3)))),
                    ValueField("key_bytes",integerValue(key.bytes)),ValueField("key_sha256",textValue(key.digest)),
                    ValueField("operation_bytes",integerValue(operation.bytes)),ValueField("operation_sha256",textValue(operation.digest)),
                    ValueField("payload_bytes",integerValue(payload.bytes)),ValueField("payload_sha256",textValue(payload.digest))])
                hash.write(journalStreamFrame(canonicalAgentValue(value)).toArray())
                eventCount=journalStreamAdd(eventCount,1);payloadBytes=journalStreamAdd(payloadBytes,payload.bytes)}
            let sequenceRows=tx.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")
            if(sequenceRows.size>1){throw IllegalStateException("fixed event sequence is ambiguous")}
            let sequence=if(sequenceRows.isEmpty()){0}else{journalStreamInteger(sequenceRows[0].required(0))}
            // Read observes exact sequence presence/value, without guessing
            // a positive nextID or refusing old history on an index policy.
            let sequencePresent=!sequenceRows.isEmpty()
            hash.write(journalStreamFrame(canonicalAgentValue(objectValue([ValueField("rows",integerValue(rowCount)),
                ValueField("events",integerValue(eventCount)),ValueField("sequence",integerValue(sequence)),ValueField("sequence_present",boolValue(sequencePresent))]))).toArray())
            journalStreamCheck(guard);JournalStreamV2Fence(rowCount,eventCount,payloadBytes,sequence,sequencePresent,logicalJsonEncodeHex(hash.finish()))
        }finally{lease.close()}}
    func emit(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,lane:LaneId,
        fence:JournalStreamV2Fence,revision:Int64,guard:()->Result<Unit>,action:?(Int64,Array<Byte>)->Unit):FixedJournalCellObservation{
        let owner=allocate(65536)
        try{
            owner.ensureRetainedPeak(1048576+65536*8);let emit=JournalStreamV2Emitter(action,guard)
            emit.write(JOURNAL_STREAM_V2_MAGIC.toArray())
            emit.header(objectValue([ValueField("kind",textValue("start")),ValueField("schema",textValue("axyndra.row-journal-frames/v2")),
                ValueField("body_bytes",integerValue(0)),ValueField("request_digest",textValue(modelPolicySha256Text(canonicalAgentValue(plan.canonicalArguments)))),
                ValueField("access_policy_digest",textValue(access.digest)),ValueField("revision",integerValue(revision)),
                ValueField("annotations",annotations(source,lane)),ValueField("state",fence.value())]))
            var after:?Int64=None;var ordinal:Int64=0;var rawEvents:Int64=0;var rawRows:Int64=0
            while(true){journalStreamCheck(guard)
                let found=match(after){case None=>tx.query("SELECT id FROM memory_events ORDER BY id LIMIT 1")
                    case Some(cursor)=>tx.query("SELECT id FROM memory_events WHERE id>? ORDER BY id LIMIT 1",[SqlParameter.Int64Value(cursor)])}
                if(found.isEmpty()){break};if(found.size!=1){throw IllegalStateException("stream event order is ambiguous")}
                let eventid=journalStreamInteger(found[0].required(0))
                match(after){case Some(cursor)=>if(eventid<=cursor){throw IllegalStateException("stream event cursor did not strictly advance")};case None=>()}
                after=Some(eventid);let projected=project(tx,FixedJournalCell.EventPayload,eventid,source.threadId.value,guard)
                try{emitCell(tx,FixedJournalCell.EventPayload,eventid,"event",ordinal,projected,None,guard,emit)
                    if(projected.readable){rawEvents++};ordinal++}finally{projected.close()}}
            if(ordinal!=fence.events){throw IllegalStateException("stream lost an original history event")}
            after=None;ordinal=0
            while(true){journalStreamCheck(guard)
                let found=match(after){case None=>tx.query("SELECT rowid,revision,thread_id IS NULL FROM memories ORDER BY rowid LIMIT 1")
                    case Some(cursor)=>tx.query("SELECT rowid,revision,thread_id IS NULL FROM memories WHERE rowid>? ORDER BY rowid LIMIT 1",[SqlParameter.Int64Value(cursor)])}
                if(found.isEmpty()){break};if(found.size!=1 || found[0].required(2)!="1"){throw IllegalStateException("stream current tenant layout changed")}
                let rowid=journalStreamInteger(found[0].required(0))
                match(after){case Some(cursor)=>if(rowid<=cursor){throw IllegalStateException("stream current cursor did not strictly advance")};case None=>()}
                after=Some(rowid);let projected=project(tx,FixedJournalCell.CurrentPayload,rowid,source.threadId.value,guard)
                try{
                    let key=cell(tx,FixedJournalCell.CurrentKey,rowid,guard)
                    let metadataOwner=allocate(65536)
                    try{
                        // The native SQLite equality/min-max lookup may load a
                        // large original index key. Its real observed bytes are
                        // prepaid before this fixed internal join, not read as
                        // a managed String and not disclosed for a private row.
                        metadataOwner.ensureRetainedPeak(journalStreamAdd(1048576,key.bytes*4))
                        let history=tx.query("SELECT MIN(e.id) FROM memory_events e WHERE e.memory_id=(SELECT id FROM memories WHERE rowid=?)",
                            [SqlParameter.Int64Value(rowid)])
                        if(history.size!=1){throw IllegalStateException("fixed current index query is ambiguous")}
                        // This is a SQL fact descriptor only. No Host rule
                        // selects the last event as business current, rejects
                        // an orphan cache row, or overwrites either history.
                        let first=match(history[0][0]){case Some(value)=>integerValue(journalStreamInteger(value));case None=>nullValue()}
                        let index:?AgentValue=if(projected.readable){Some(objectValue([ValueField("key_bytes",integerValue(key.bytes)),ValueField("key_sha256",textValue(key.digest)),
                            ValueField("revision",integerValue(journalStreamInteger(found[0].required(1)))),ValueField("first_event_id",first)]))}else{None}
                        emitCell(tx,FixedJournalCell.CurrentPayload,rowid,"row",ordinal,projected,index,guard,emit)
                        if(projected.readable){rawRows++};ordinal++
                    }finally{metadataOwner.close()}
                }finally{projected.close()}}
            if(ordinal!=fence.rows){throw IllegalStateException("stream lost an actual current row")}
            emit.header(objectValue([ValueField("kind",textValue("end")),ValueField("body_bytes",integerValue(0)),
                ValueField("rows",integerValue(fence.rows)),ValueField("events",integerValue(fence.events)),
                ValueField("raw_rows",integerValue(rawRows)),ValueField("raw_events",integerValue(rawEvents)),ValueField("state",fence.value())]))
            journalStreamCheck(guard);FixedJournalCellObservation(emit.bytes,emit.digest())
        }finally{owner.close()}}
    private func emitCell(tx:SqliteTransaction,cell:FixedJournalCell,rowid:Int64,kind:String,ordinal:Int64,
        projected:JournalStreamV2ProjectedCell,index:?AgentValue,guard:()->Result<Unit>,emit:JournalStreamV2Emitter):Unit{
        let body=if(projected.readable){""}else{stringifyUnifiedJson(projected.projection.value)}
        if(!projected.readable && body.size>16384){throw IllegalStateException("frozen structural projection exceeds its disclosure bound")}
        let fields=ArrayList<ValueField>();fields.add(all:[ValueField("kind",textValue(kind)),ValueField("ordinal",integerValue(ordinal)),
            ValueField("visibility",textValue(if(projected.readable){"raw"}else{"projection"})),
            ValueField("body_bytes",integerValue(if(projected.readable){projected.cell.bytes}else{body.size})),
            ValueField("body_sha256",textValue(if(projected.readable){projected.cell.digest}else{modelPolicySha256Text(body)}))])
        match(index){case Some(value)=>fields.add(ValueField("index",value));case None=>()}
        emit.header(objectValue(fields.toArray()))
        if(projected.readable){copy(tx,cell,rowid,projected.cell,guard,emit)}else{emit.write(body.toArray())}}
}

// Only the two actual assembly-owned types are accepted. Every old caller
// still executes the same original backend checks, scope and transaction.
func opaqueRowJournalWindowBackend(value:PluginDocumentStorageBackend):?SqliteOpaqueRowJournalWindowBackend{
    match(value as SqliteOpaqueRowJournalWindowBackend){case Some(actual)=>return Some(actual);case None=>()}
    match(value as SqliteOpaqueRowJournalStreamBackend){case Some(actual)=>Some(actual.windowBackend());case None=>None}
}
