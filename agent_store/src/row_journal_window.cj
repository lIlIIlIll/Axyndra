package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

class OpaqueRowJournalWindowCatalog{
    let manifest:AgentValue
    let raw:String
    let revision:Int64
    let fence:OpaqueRowJournalStreamFence
    private let lease:LogicalJsonOwnerReservation
    init(manifest:AgentValue,raw:String,revision:Int64,fence:OpaqueRowJournalStreamFence,lease:LogicalJsonOwnerReservation){
        this.manifest=manifest;this.raw=raw;this.revision=revision;this.fence=fence;this.lease=lease}
    func close():Unit{lease.close()}
}

// The opt-in wrapper is trusted assembly data access. It delegates the old
// document dialect without changing its body and exposes fixed SQL windows
// solely to actual canonical read/append transaction proofs below.
public class SqliteOpaqueRowJournalWindowBackend <: PluginDocumentStorageBackend{
    private let original:SqliteOpaqueRowJournal
    private let namespace:String
    private let key:String
    private let workspace:String
    private let settings:String
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let current:()->Result<Unit>
    private let contextCurrent:?(NormalizedOperationPlan)->Result<Unit>
    private let configurationDigest:String
    public prop identity:String{get(){original.identity}}
    public init(namespace:String,key:String,workspace:String,settings:String,allocate:(Int64)->LogicalJsonOwnerReservation,
        configurationDigest:String,current:()->Result<Unit>,contextReadConfiguration!:?(NormalizedOperationPlan)->Result<Unit>=None){
        this.original=SqliteOpaqueRowJournal(namespace,key,workspace,settings,allocate,configurationDigest,current,
            contextReadConfiguration:contextReadConfiguration)
        this.namespace=namespace;this.key=key;this.workspace=workspace;this.settings=settings;this.allocate=allocate
        this.current=current;this.contextCurrent=contextReadConfiguration;this.configurationDigest=configurationDigest}
    public func read(tx:SqliteTransaction,thread:ThreadId,lane:LaneId,namespace:String,key:String):PluginDocumentSnapshot{
        original.read(tx,thread,lane,namespace,key)}
    public func recordRead(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,snapshot:PluginDocumentSnapshot):Unit{
        original.recordRead(tx,source,plan,snapshot)}
    public func requireParentFence(tx:SqliteTransaction,parent:OperationId,run:RunId,intent:PluginDocumentIntent):Unit{
        original.requireParentFence(tx,parent,run,intent)}
    public func compareExchange(tx:SqliteTransaction,expected:PluginDocumentSnapshot,next:String):PluginDocumentSnapshot{
        original.compareExchange(tx,expected,next)}
    func check(plan:NormalizedOperationPlan):Unit{
        journalStreamCheck(current)
        let request=plan.canonicalArguments;let binding=request.field("binding").getOrThrow()
        if(httpIntentText(binding,"namespace")!=namespace || httpIntentText(request,"key")!=key){
            throw IllegalStateException("window request differs from the trusted fixed mapping")}
        if(httpIntentText(request,"schema")==PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA){
            if(httpIntentText(binding,"configuration_digest")!=configurationDigest){
                throw IllegalStateException("window tool configuration changed")}}
        else if(httpIntentText(request,"schema")=="axyndra.plugin-document-context-window-read/v1"){
            if(contextCurrent.isNone()){throw IllegalStateException("parentless windows require their explicit current profile")}
            journalStreamCheck({=>contextCurrent.getOrThrow()(plan)})
        }else{throw IllegalStateException("unknown strict window dialect")}
    }
    // Trusted backend assembly owns this allocator. Capture indexed bytes
    // before a durable observation is loaded, then keep its decoded lease
    // alive until the actual consumer finishes using the compact witness.
    func observationOwner(plan:NormalizedOperationPlan,bytes:Int64):LogicalJsonOwnerReservation{
        check(plan)
        if(bytes<1 || bytes>65536){throw IllegalStateException("window observation exceeds its fixed durable codec bound")}
        let owner=allocate(bytes)
        try{owner.ensureDecoded(bytes,bytes);check(plan);owner}
        catch(error:Exception){owner.close();throw error}
    }
    func observationWriteOwner(plan:NormalizedOperationPlan):LogicalJsonOwnerReservation{
        check(plan);let owner=allocate(65536)
        // Store builds this fixed 15-field witness from a strict Tool12 or
        // Context9 binding, fixed window/state and six-field public ref.
        // Under 256 nodes, four bounded UTF8/frame copies plus workspace are
        // prepaid before constructing or encoding it; no history DOM here.
        try{owner.ensureRetainedPeak(1048576+65536*4+256*512);owner}
        catch(error:Exception){owner.close();throw error}
    }
    func permitsAppendRecord(binding:AgentValue,record:AgentValue):Bool{
        journalStreamCheck(current)
        let scope=httpIntentText(record,"scopeKind");let value=httpIntentText(record,"scopeKey")
        if(scope=="global"){return value==""};if(scope=="user"){return value!=""}
        if(scope=="workspace"){return workspace!="" && value==workspace}
        if(scope=="session"){return value==httpIntentText(binding,"thread_id")};false
    }
    func revision(tx:SqliteTransaction):Int64{
        let rows=tx.query("SELECT revision,payload FROM plugin_documents WHERE thread_id='$row-journal' AND lane_id='canonical' AND namespace=? AND document_key=?",
            [SqlParameter.Text(namespace),SqlParameter.Text(key)])
        if(rows.isEmpty()){return 1}
        if(rows.size!=1 || rows[0].required(1)!="opaque-fact-events-v3" || journalStreamInteger(rows[0].required(0))<2){
            throw IllegalStateException("window journal revision metadata changed")};journalStreamInteger(rows[0].required(0))
    }
    func full(tx:SqliteTransaction,plan:NormalizedOperationPlan,scope:()->Result<Unit>):OpaqueRowJournalStreamFence{
        streamOpaqueRowJournalFence(tx,allocate,{=>check(plan);scope()})}
    func catalog(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,lane:LaneId,
        scope:()->Result<Unit>):OpaqueRowJournalWindowCatalog{
        check(plan);journalStreamCheck(scope)
        let before=full(tx,plan,scope);let lease=allocate(OPAQUE_JOURNAL_STREAM_CHUNK)
        try{
            let rows=ArrayList<AgentValue>();var after:Int64=0;var metadataBytes:Int64=0
            while(true){check(plan);journalStreamCheck(scope)
                // Indexed first appearance is data order, not a business
                // ranking or an inaccessible-history payload projection.
                let found=tx.query("SELECT m.id,m.thread_id,m.kind,m.revision,length(CAST(m.payload AS BLOB)),MIN(e.id) FROM memories m JOIN memory_events e ON e.memory_id=m.id GROUP BY m.id HAVING MIN(e.id)>? ORDER BY MIN(e.id) LIMIT 1",
                    [SqlParameter.Int64Value(after)])
                if(found.isEmpty()){break};if(found.size!=1){throw IllegalStateException("window row order is ambiguous")}
                let row=found[0];journalStreamMetadata(row)
                if(row[1].isSome()){throw IllegalStateException("window journal has another tenant layout")}
                let rawBytes=journalStreamInteger(row.required(4));after=journalStreamInteger(row.required(5))
                if(rawBytes<1 || rawBytes>67108864 || after<1 || after>=before.nextEvent){
                    throw IllegalStateException("original opaque record codec or event order changed")}
                // SQL extracts only access/index labels. Its opaque payload
                // parser extent is prepaid separately and released per row.
                let rawOwner=allocate(OPAQUE_JOURNAL_STREAM_CHUNK)
                try{
                    rawOwner.ensureRetainedPeak(journalStreamAdd(rawBytes*2,1048576))
                    let labels=tx.query("SELECT json_valid(payload),json_extract(payload,'$.version'),json_extract(payload,'$.record.id'),json_extract(payload,'$.record.revision'),json_extract(payload,'$.record.scopeKind'),json_extract(payload,'$.record.scopeKey'),length(CAST(json_quote(payload) AS BLOB)),(SELECT revision FROM memory_events WHERE memory_id=memories.id ORDER BY id DESC LIMIT 1),(SELECT payload=memories.payload FROM memory_events WHERE memory_id=memories.id ORDER BY id DESC LIMIT 1) FROM memories WHERE id=?",
                        [SqlParameter.Text(row.required(0))])
                    if(labels.size!=1){throw IllegalStateException("window row disappeared")};let label=labels[0];journalStreamMetadata(label)
                    if(label.required(0)!="1" || label.required(1)!="3" || label.required(2)!=row.required(0) ||
                        label.required(3)!=row.required(3) || label.required(7)!=row.required(3) || label.required(8)!="1"){
                        throw IllegalStateException("original opaque current index differs from its last event")}
                    let kind=label.required(4);let value=label.required(5)
                    let allowed=match(kind){case "global"=>value=="";case "user"=>value!="";
                        case "workspace"=>workspace!="" && value==workspace;case "session"=>value==source.threadId.value;
                        case _=>throw IllegalStateException("unknown original data access label")}
                    if(allowed){
                        let digest=SHA256();journalStreamCurrentPayload(tx,row.required(0),rawBytes,digest,{=>check(plan);scope()})
                        metadataBytes=journalStreamAdd(metadataBytes,row.required(0).size+row.required(2).size+512)
                        lease.ensureRetainedPeak(journalStreamAdd(1048576,journalStreamAdd(metadataBytes*4,(rows.size+1)*8192)))
                        rows.add(objectValue([ValueField("key",textValue(row.required(0))),ValueField("kind",textValue(row.required(2))),
                            ValueField("revision",integerValue(journalStreamInteger(row.required(3)))),ValueField("payload_sha256",textValue(journalStreamHex(digest.finish()))),
                            ValueField("payload_bytes",integerValue(rawBytes)),ValueField("payload_json_bytes",integerValue(journalStreamInteger(label.required(6)))),
                            ValueField("first_event_id",integerValue(after))]))}
                }finally{rawOwner.close()}
            }
            let orphan=tx.query("SELECT COUNT(*) FROM memories m WHERE NOT EXISTS(SELECT 1 FROM memory_events e WHERE e.memory_id=m.id)")
            if(orphan.size!=1 || orphan[0].required(0)!="0"){throw IllegalStateException("original current row has no history")}
            let manifest=objectValue([ValueField("schema",textValue(OPAQUE_ROW_JOURNAL_MANIFEST_SCHEMA)),ValueField("layout",textValue("opaque-fact-events-v3")),
                ValueField("state",objectValue([ValueField("sha256",textValue(before.digest)),ValueField("chain_sha256",textValue(before.chain)),
                    ValueField("next_event_id",integerValue(before.nextEvent)),ValueField("rows",integerValue(before.rows)),ValueField("events",integerValue(before.events))])),
                ValueField("rows",listValue(rows.toArray())),ValueField("annotations",objectValue([ValueField("workspace_root",textValue(workspace)),
                    ValueField("settings_root",textValue(settings)),ValueField("thread_id",textValue(source.threadId.value)),ValueField("lane_id",textValue(lane.value))]))])
            let bytes=logicalJsonWriteReservationBytes(manifest,8388608)
            lease.ensureRetainedPeak(journalStreamAdd(1048576,journalStreamAdd(metadataBytes*4+rows.size*8192,bytes*2)))
            let raw=stringifyUnifiedJson(manifest);check(plan);journalStreamCheck(scope)
            OpaqueRowJournalWindowCatalog(manifest,raw,revision(tx),before,lease)
        }catch(error:Exception){lease.close();throw error}
    }
}

func journalWindowFactPlan(tx:SqliteTransaction,link:ContextReadFactLink):NormalizedOperationPlan{
    let fact=requireContextReadFact(tx,link.operationId,link.runId)
    if(canonicalAgentValue(fact.reference())!=canonicalAgentValue(link.toValue())){throw IllegalStateException("window link differs from its actual complete fact")}
    let rows=tx.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",[SqlParameter.Text(link.operationId.value),SqlParameter.Text(link.runId.value)])
    if(rows.size!=1){throw IllegalStateException("window fact lost its original actual plan")};decodeOperationPlan(rows[0].required(0))
}
func requireRowJournalWindowPrefix(tx:SqliteTransaction,source:DirectToolCallRef,plan:NormalizedOperationPlan,
    catalog:OpaqueRowJournalWindowCatalog):Unit{
    let request=plan.canonicalArguments;let links=contextReadFactLinksFromValue(request.field("prior_facts").getOrThrow())
    if(links.isEmpty()){if(httpIntentText(request.field("window").getOrThrow(),"kind")!="manifest"){
        throw IllegalStateException("body windows need their actual manifest fact")};return}
    let first=requireContextReadFact(tx,links[0].operationId,links[0].runId)
    let firstPlan=journalWindowFactPlan(tx,links[0]);var offset:Int64=0
    if(first.origin.parentCallItemId!=""){
        requireContextReadFactConsumptionFields(tx,documentPayloadParentOperation(first),source.runId,ItemId(first.origin.parentCallItemId),
            httpIntentText(request.field("binding").getOrThrow(),"contribution"),links)}
    for(index in 0..links.size){
        let link=links[index];let read=journalWindowFactPlan(tx,link);let fact=requireContextReadFact(tx,link.operationId,link.runId)
        if(link.runId.value!=source.runId.value || !isContextReadPlan(read) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(request.field("binding").getOrThrow()) ||
            httpIntentText(read.canonicalArguments,"projection_digest")!=httpIntentText(request,"projection_digest") ||
            httpIntentText(read.canonicalArguments,"key")!=httpIntentText(request,"key") ||
            httpIntentText(read.canonicalArguments,"schema")!=httpIntentText(request,"schema")){
            throw IllegalStateException("window prefix differs from current original scope")}
        let prior=contextReadFactLinksFromValue(read.canonicalArguments.field("prior_facts").getOrThrow())
        if(prior.size!=index){throw IllegalStateException("window fact does not retain its entire previous prefix")}
        for(position in 0..index){if(canonicalAgentValue(prior[position].toValue())!=canonicalAgentValue(links[position].toValue())){
            throw IllegalStateException("window prefix repeats or substitutes an actual fact")}}
        let output=fact.output();let item=output.field("documents").getOrThrow().items[0]
        let reference=parsePluginDocumentPayloadReference(item.field("payload").getOrThrow()).value().getOrThrow()
        requireDocumentPayloadMetadata(tx,reference)
        if(httpIntentText(output,"schema")!=PLUGIN_DOCUMENT_ROW_JOURNAL_READ_RESULT_SCHEMA ||
            httpIntentText(output,"request_digest")!=modelPolicySha256Text(canonicalAgentValue(read.canonicalArguments)) ||
            httpIntentText(item,"key")!=httpIntentText(request,"key") ||
            journalWindowInteger(item.field("revision").getOrThrow())!=catalog.revision){throw IllegalStateException("window result changed")}
        let window=read.canonicalArguments.field("window").getOrThrow()
        if(index==0){
            if(httpIntentText(window,"kind")!="manifest" || reference.bytes!=catalog.raw.size || reference.digest!=modelPolicySha256Text(catalog.raw)){
                throw IllegalStateException("original actual manifest differs from the full current journal fence")}}
        else{
            if(httpIntentText(window,"kind")!="rows" || journalWindowInteger(window.field("offset").getOrThrow())!=offset){
                throw IllegalStateException("window prefix overlaps or skips a manifest interval")}
            offset=journalStreamAdd(offset,journalWindowInteger(window.field("count").getOrThrow()))
        }
    }
    let selected=request.field("window").getOrThrow();let headers=catalog.manifest.field("rows").getOrThrow().items
    if(httpIntentText(selected,"kind")!="rows" || journalWindowInteger(selected.field("manifest_fact").getOrThrow())!=0 ||
        journalWindowInteger(selected.field("offset").getOrThrow())!=offset || offset>headers.size ||
        journalWindowInteger(selected.field("count").getOrThrow())>headers.size-offset){
        throw IllegalStateException("window request is not the exact next observed interval")}
}
func rowJournalWindowRawBytes(catalog:OpaqueRowJournalWindowCatalog,window:AgentValue):Int64{
    if(httpIntentText(window,"kind")=="manifest"){return catalog.raw.size}
    let offset=journalWindowInteger(window.field("offset").getOrThrow());let count=journalWindowInteger(window.field("count").getOrThrow())
    let header=objectValue([ValueField("schema",textValue(OPAQUE_ROW_JOURNAL_ROWS_SCHEMA)),ValueField("manifest_sha256",textValue(modelPolicySha256Text(catalog.raw))),
        ValueField("offset",integerValue(offset)),ValueField("rows",listValue([]))])
    var bytes=stringifyUnifiedJson(header).size;let rows=catalog.manifest.field("rows").getOrThrow().items
    for(index in offset..offset+count){let row=rows[index]
        let empty=objectValue([ValueField("key",row.field("key").getOrThrow()),ValueField("revision",row.field("revision").getOrThrow()),
            ValueField("payload_sha256",row.field("payload_sha256").getOrThrow()),ValueField("payload",textValue(""))])
        bytes=journalStreamAdd(bytes,stringifyUnifiedJson(empty).size-2+journalWindowInteger(row.field("payload_json_bytes").getOrThrow())+if(index>offset){1}else{0})}
    if(bytes<1 || bytes>8388608){throw IllegalStateException("window body exceeds its original public payload ceiling")};bytes
}
func rowJournalWindowRaw(tx:SqliteTransaction,catalog:OpaqueRowJournalWindowCatalog,window:AgentValue,scope:()->Result<Unit>):String{
    if(httpIntentText(window,"kind")=="manifest"){return catalog.raw}
    let offset=journalWindowInteger(window.field("offset").getOrThrow());let count=journalWindowInteger(window.field("count").getOrThrow())
    let rows=catalog.manifest.field("rows").getOrThrow().items;let output=StringBuilder()
    output.append("{\"schema\":\""+OPAQUE_ROW_JOURNAL_ROWS_SCHEMA+"\",\"manifest_sha256\":\""+modelPolicySha256Text(catalog.raw)+"\",\"offset\":"+offset.toString()+",\"rows\":[")
    for(index in offset..offset+count){journalStreamCheck(scope);let row=rows[index]
        let selected=tx.query("SELECT revision,json_quote(payload),length(CAST(payload AS BLOB)) FROM memories WHERE id=?",[SqlParameter.Text(httpIntentText(row,"key"))])
        if(selected.size!=1 || selected[0].required(0)!=journalWindowInteger(row.field("revision").getOrThrow()).toString() ||
            selected[0].required(1).size!=journalWindowInteger(row.field("payload_json_bytes").getOrThrow()) ||
            selected[0].required(2)!=journalWindowInteger(row.field("payload_bytes").getOrThrow()).toString()){
            throw IllegalStateException("window row changed before its prepaid body copy")}
        if(index>offset){output.append(",")}
        output.append("{\"key\":"+stringifyUnifiedJson(row.field("key").getOrThrow())+",\"revision\":"+selected[0].required(0)+
            ",\"payload_sha256\":"+stringifyUnifiedJson(row.field("payload_sha256").getOrThrow())+",\"payload\":"+selected[0].required(1)+"}")
    };output.append("]}");journalStreamCheck(scope);output.toString()
}

// Store-owned descriptive parser. The Domain contract parser is deliberately
// package-private and cannot be imported as a runtime authority primitive.
func journalWindowInteger(value:AgentValue):Int64{
    if(value.unifiedKind!=ValueKind.Number){throw IllegalStateException("window integer is not numeric")}
    journalStreamInteger(value.asNumberText())
}
